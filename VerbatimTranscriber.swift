import Foundation

/// Real-time verbatim transcription pipeline driven by the live PCM tap on
/// `AudioRecorder`. Owns a `WhisperServerProcess` and a `VerbatimWriter`,
/// and converts audio → transcript → committed `.verbatim.md` lines.
///
/// **Commit 1 status (this file): SKELETON ONLY.**
/// The transcribe loop is stubbed: every ~2 s of audio, we emit a `[debug]
/// heartbeat` line through `VerbatimWriter` so we can validate the full
/// audio-fan-out → writer → atomic-rewrite plumbing end-to-end without
/// depending on whisper-server's HTTP API. Commit 2 replaces the heartbeat
/// loop with real whisper-server inference + LocalAgreement-2 commit logic.
final class VerbatimTranscriber: @unchecked Sendable {
    private let server: WhisperServerProcess
    private let writer: VerbatimWriter
    private let queue = DispatchQueue(label: "verbatim-transcriber")

    private var sessionStart: Date = .distantPast
    private var totalSamples: UInt64 = 0
    private var lastHeartbeatSec: Double = -1   // -1 = none yet
    private let heartbeatIntervalSec: Double = 2.0
    private var stopped: Bool = false           // guarded by queue

    init(server: WhisperServerProcess, writer: VerbatimWriter) {
        self.server = server
        self.writer = writer
    }

    /// Mark t=0 of the session and write the file preamble so a `.verbatim.md`
    /// stub exists immediately, even if the user stops recording before any
    /// line gets committed.
    func start(sessionStart: Date) throws {
        try writer.writePreamble()
        queue.sync {
            self.sessionStart = sessionStart
            self.totalSamples = 0
            self.lastHeartbeatSec = -1
            self.stopped = false
        }
    }

    /// Receive a PCM chunk. Called from the audio queue.
    /// `sampleRate` is the rate of `samples` (16000 Hz from AudioRecorder's
    /// post-mix tap).
    func append(_ samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.totalSamples &+= UInt64(samples.count)
            self.maybeHeartbeat(sampleRate: sampleRate)
        }
    }

    /// Force-commit any pending state. In the skeleton this just emits a
    /// final `[debug] flush` line; commit 2 will run a final inference over
    /// the unconfirmed audio buffer (per the agreed Stop semantics).
    func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self, !self.stopped else { cont.resume(); return }
                let nowSec = Date().timeIntervalSince(self.sessionStart)
                try? self.writer.appendLine(
                    "[debug] flush — total samples: \(self.totalSamples)",
                    at: nowSec
                )
                cont.resume()
            }
        }
    }

    /// Refuse further audio appends. Idempotent.
    func stop() {
        queue.sync { self.stopped = true }
    }

    // MARK: - Internals (must run on `queue`)

    private func maybeHeartbeat(sampleRate: Double) {
        let nowSec = Date().timeIntervalSince(sessionStart)
        if lastHeartbeatSec < 0 {
            lastHeartbeatSec = nowSec
            // First-tick log: confirms PCM is flowing in.
            try? writer.appendLine(
                "[debug] verbatim pipeline ready (sr=\(Int(sampleRate))Hz, port=\(server.port))",
                at: nowSec
            )
            return
        }
        if nowSec - lastHeartbeatSec >= heartbeatIntervalSec {
            try? writer.appendLine(
                "[debug] heartbeat — \(totalSamples) samples received",
                at: nowSec
            )
            lastHeartbeatSec = nowSec
        }
    }
}
