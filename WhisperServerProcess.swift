import Foundation
import Darwin

/// Manages a `whisper-server` (whisper.cpp) subprocess on 127.0.0.1.
///
/// Lifecycle: created idle, `start(...)` spawns the binary on a free port and
/// returns once the HTTP endpoint answers a probe (or times out). `stop()`
/// sends SIGTERM and reaps the PID. Designed for one-recording-per-instance —
/// the AppDelegate creates a new instance per recording so we don't leak
/// state between sessions.
///
/// Failure modes are surfaced via `start(...)`'s `Result`; `AppDelegate`
/// translates them into user-visible notifications and falls through to
/// "recording continues without verbatim" per the soft-fail contract.
final class WhisperServerProcess: @unchecked Sendable {
    enum StartError: LocalizedError {
        case binaryNotFound(path: String)
        case modelNotFound(path: String)
        case noFreePort
        case spawnFailed(underlying: Error)
        case healthCheckTimeout(port: UInt16, lastError: String?)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let p):
                return "whisper-server not found at \(p). Run: brew install whisper-cpp"
            case .modelNotFound(let p):
                return "whisper-cpp model not found at \(p)"
            case .noFreePort:
                return "could not find a free local port for whisper-server"
            case .spawnFailed(let err):
                return "failed to launch whisper-server: \(err.localizedDescription)"
            case .healthCheckTimeout(let port, let lastError):
                let suffix = lastError.map { " (last probe: \($0))" } ?? ""
                return "whisper-server did not become ready within 10s on port \(port)\(suffix)"
            }
        }
    }

    /// Resolved binary path. Override via env var `WHISPER_SERVER_BIN`,
    /// otherwise the Homebrew default.
    static var defaultBinaryPath: String {
        ProcessInfo.processInfo.environment["WHISPER_SERVER_BIN"]
            ?? "/opt/homebrew/bin/whisper-server"
    }

    /// Resolved model path. Override via env var `WHISPER_MODEL_PATH`,
    /// otherwise the path used by `phone-screen-overview` skill.
    static var defaultModelPath: String {
        if let p = ProcessInfo.processInfo.environment["WHISPER_MODEL_PATH"] {
            return p
        }
        return NSString(string: "~/.cache/whisper-cpp/ggml-large-v3-turbo.bin")
            .expandingTildeInPath
    }

    private(set) var port: UInt16 = 0
    private var process: Process?
    private var stderrPipe: Pipe?
    private var stdoutPipe: Pipe?

    // Last successful start args, so `restart()` can re-spawn without the
    // caller re-passing them. Set inside start().
    private var lastModelPath: String = ""
    private var lastBinaryPath: String = ""
    private var lastLanguage: String = "auto"

    /// Final URL components for inference requests once started.
    var inferenceURL: URL? {
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/inference")
    }

    var rootURL: URL? {
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/")
    }

    /// Spawn whisper-server. `language` is a Whisper code: "auto", "zh", "en", …
    /// Returns once the HTTP endpoint is responsive, or fails with a
    /// `StartError` after a 10s health-check timeout.
    func start(modelPath: String = defaultModelPath,
               binaryPath: String = defaultBinaryPath,
               language: String = "auto") async throws {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw StartError.binaryNotFound(path: binaryPath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw StartError.modelNotFound(path: modelPath)
        }

        // Stash for restart()
        self.lastBinaryPath = binaryPath
        self.lastModelPath = modelPath
        self.lastLanguage = language

        let assignedPort = try Self.findFreeLoopbackPort(startingAt: 8137)
        self.port = assignedPort

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(assignedPort),
            "--language", language,
            // commit-5 mitigation: flash-attn (default true) is a known
            // contributor to the long-running Metal pipeline deadlock that
            // hits whisper.cpp around the 7-8 minute mark. Disabling it
            // costs ~10-15% inference speed but avoids the cliff. The
            // watchdog in VerbatimTranscriber will still restart us if
            // the bug recurs.
            "--no-flash-attn",
            // NOTE: --print-progress is a boolean toggle (default false).
            // Do not pass "false" as a value or whisper-server treats it as
            // a stray positional argument, prints help, and exits.
        ]
        // Discard stdout/stderr to /dev/null-like pipes; stash for diagnostics.
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw StartError.spawnFailed(underlying: error)
        }
        self.process = proc
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        NSLog("whisper-server: spawned pid=\(proc.processIdentifier) port=\(assignedPort) lang=\(language)")

        // Wait for the HTTP endpoint to come up. whisper-server takes
        // 2-5s on M-series chips while it loads the GGML model into Metal.
        try await waitUntilReady(port: assignedPort, timeout: 10)
    }

    func stop() {
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate()
            // SIGTERM grace, then SIGKILL. Note: when whisper-server is
            // GPU-deadlocked it does NOT respond to SIGTERM at all (signal
            // handler can't run because the main thread is wedged in a
            // Metal dispatch). The 2 s budget lets clean exits finish but
            // we always escalate to SIGKILL for the deadlock case.
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                // Reap so it doesn't linger as a zombie.
                let killDeadline = Date().addingTimeInterval(1.0)
                while proc.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        process = nil
        stderrPipe = nil
        stdoutPipe = nil
        port = 0
        NSLog("whisper-server: stopped")
    }

    /// Tear down the current subprocess and re-spawn with the same
    /// parameters used in the most recent `start(...)` call. Used by the
    /// VerbatimTranscriber watchdog when the Metal pipeline deadlock
    /// recurs (HTTP keeps answering but /inference hangs forever).
    /// Caller waits ~3-5 s for the new server to load the model and
    /// answer the readiness probe.
    func restart() async throws {
        let binary = lastBinaryPath
        let model = lastModelPath
        let lang = lastLanguage
        guard !binary.isEmpty, !model.isEmpty else {
            throw StartError.spawnFailed(underlying: NSError(
                domain: "WhisperServerProcess", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "restart() called before any start()"]
            ))
        }
        NSLog("whisper-server: restarting (port \(port) → fresh)")
        stop()
        try await start(modelPath: model, binaryPath: binary, language: lang)
    }

    deinit { stop() }

    // MARK: - Helpers

    /// Bind a TCP socket on 127.0.0.1 with port=0 to let the kernel hand us a
    /// free ephemeral port, then close it. Race window between close and
    /// whisper-server's bind is tiny in practice; if we lose it we surface
    /// `StartError.healthCheckTimeout` and the user gets a notification.
    private static func findFreeLoopbackPort(startingAt _: UInt16) throws -> UInt16 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 { throw StartError.noFreePort }
        defer { close(s) }

        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // 0 → kernel picks
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 { throw StartError.noFreePort }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(s, sa, &len)
            }
        }
        if nameResult != 0 { throw StartError.noFreePort }

        return UInt16(bigEndian: assigned.sin_port)
    }

    private func waitUntilReady(port: UInt16, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: String?
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.0
        let session = URLSession(configuration: config)

        while Date() < deadline {
            // If the process died, no point in continuing.
            if let p = process, !p.isRunning {
                let stderrText = drainStderr(maxBytes: 2_048)
                throw StartError.healthCheckTimeout(port: port, lastError: stderrText ?? "process exited")
            }
            do {
                let (_, response) = try await session.data(from: url)
                // whisper-server's root returns 200 (HTML help) when ready.
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    NSLog("whisper-server: ready on port \(port)")
                    return
                }
                lastError = "non-200 status"
            } catch {
                lastError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 250_000_000)  // 250 ms
        }
        throw StartError.healthCheckTimeout(port: port, lastError: lastError)
    }

    /// Drain at most `maxBytes` of stderr from the spawned process — useful
    /// for surfacing why whisper-server failed to start (missing dylib, bad
    /// model file, etc.) into the StartError message.
    private func drainStderr(maxBytes: Int) -> String? {
        guard let pipe = stderrPipe else { return nil }
        let data = pipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return nil }
        let truncated = data.prefix(maxBytes)
        return String(data: truncated, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
