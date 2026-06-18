import Foundation

/// Thin orchestrator for the verbatim transcription pipeline.
///
/// Responsibilities (post-refactor):
///   * Audio buffer management (append PCM, snapshot for inference)
///   * Inference scheduling (min-chunk gating, in-flight tracking)
///   * Watchdog (consecutive failure counting → server restart)
///   * Lifecycle (start / stop / flush)
///
/// All HTTP/WAV/JSON knowledge lives in `WhisperServerClient`.
/// All agreement/line-building logic lives in `LocalAgreementProcessor`.
final class VerbatimTranscriber: @unchecked Sendable {

    // MARK: - Tuning
    private let minChunkSec: Double = 1.0
    private let trimWindowSec: Double = 15.0
    private static let sampleRate: Int = 16_000

    // MARK: - Dependencies
    private let client: WhisperServerClient
    private let writer: VerbatimWriter

    // MARK: - State (guarded by `queue`)
    private let queue = DispatchQueue(label: "verbatim-transcriber")
    private var audioBuffer: [Float] = []
    private var audioBufferOffsetSec: Double = 0
    private var lastSegments: [LocalAgreementProcessor.Segment] = []
    private var processor = LocalAgreementProcessor()
    private var sessionStart: Date = .distantPast
    private var stopped: Bool = true
    private var inFlight: Bool = false

    // Watchdog
    private var consecutiveFailures: Int = 0
    private let restartFailureThreshold: Int = 2
    private var serverRestartInProgress: Bool = false

    // MARK: - Init

    init(client: WhisperServerClient, writer: VerbatimWriter) {
        self.client = client
        self.writer = writer
    }

    // MARK: - Public lifecycle

    func start(sessionStart: Date, initialOffsetSec: Double = 0) throws {
        try writer.writePreamble()
        queue.sync {
            self.sessionStart = sessionStart
            self.audioBuffer.removeAll(keepingCapacity: true)
            self.audioBufferOffsetSec = initialOffsetSec
            self.lastSegments.removeAll()
            self.processor.reset()
            self.stopped = false
            self.inFlight = false
            self.consecutiveFailures = 0
            self.serverRestartInProgress = false
        }
    }

    func append(_ samples: [Float], sampleRate: Double) {
        guard Int(sampleRate.rounded()) == Self.sampleRate else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.audioBuffer.append(contentsOf: samples)
            self.maybeTranscribe()
        }
    }

    func flush() async {
        let snapshot: ([Float], Double, Bool) = await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self else { cont.resume(returning: ([], 0, true)); return }
                cont.resume(returning: (self.audioBuffer, self.audioBufferOffsetSec, self.stopped))
            }
        }
        let (samples, offsetSec, alreadyStopped) = snapshot
        guard !alreadyStopped else { return }

        if samples.count >= Self.sampleRate / 10 {
            await runInference(samples: samples, offsetSec: offsetSec, isFinal: true)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                if let remaining = self.processor.drainLineBuffer() {
                    try? self.writer.appendLine(remaining.text, at: remaining.atSec)
                }
                let endSec = max(0, Date().timeIntervalSince(self.sessionStart))
                try? self.writer.appendLine("— end of transcript —", at: endSec)
                cont.resume()
            }
        }
    }

    func stop() { queue.sync { self.stopped = true } }

    // MARK: - Inference scheduling

    private func maybeTranscribe() {
        guard !inFlight, !stopped, !serverRestartInProgress else { return }
        let bufferSec = Double(audioBuffer.count) / Double(Self.sampleRate)
        guard bufferSec >= minChunkSec else { return }
        let samples = audioBuffer
        let offsetSec = audioBufferOffsetSec
        inFlight = true
        Task.detached { [weak self] in
            await self?.runInference(samples: samples, offsetSec: offsetSec, isFinal: false)
        }
    }

    private func runInference(samples: [Float], offsetSec: Double, isFinal: Bool) async {
        var success = false
        defer {
            queue.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                if success {
                    self.consecutiveFailures = 0
                    self.maybeTranscribe()
                    return
                }
                self.consecutiveFailures += 1
                if self.consecutiveFailures >= self.restartFailureThreshold,
                   !self.serverRestartInProgress, !self.stopped {
                    NSLog("verbatim: \(self.consecutiveFailures) consecutive failures → restarting")
                    self.serverRestartInProgress = true
                    Task.detached { [weak self] in await self?.doRestart() }
                    return
                }
                self.maybeTranscribe()
            }
        }

        do {
            let segments = try await client.transcribe(samples: samples)
            success = true
            queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                let bufferTailSec = self.audioBufferOffsetSec +
                    Double(self.audioBuffer.count) / Double(Self.sampleRate)
                let result = self.processor.process(
                    newSegments: segments,
                    previousSegments: self.lastSegments,
                    bufferOffsetSec: offsetSec,
                    bufferTailSec: bufferTailSec,
                    isFinal: isFinal
                )
                for line in result.lines {
                    try? self.writer.appendLine(line.text, at: line.atSec)
                }
                self.trimAudioBuffer(toAbsolute: result.trimSec)
                self.lastSegments = result.updatedPendingSegments
            }
        } catch {
            NSLog("verbatim: inference error: \(error.localizedDescription)")
        }
    }

    // MARK: - Server restart

    private func doRestart() async {
        let ok: Bool
        do {
            try await client.restartServer()
            ok = true
            NSLog("verbatim: server restart OK")
        } catch {
            ok = false
            NSLog("verbatim: server restart failed: \(error.localizedDescription)")
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.serverRestartInProgress = false
            if ok { self.consecutiveFailures = 0 }
            self.maybeTranscribe()
        }
    }

    // MARK: - Buffer trim

    private func trimAudioBuffer(toAbsolute cutoff: Double) {
        let trimSec = cutoff - audioBufferOffsetSec
        guard trimSec > 0 else { return }
        // Use truncation (not rounding) to avoid trimming past the
        // requested cutoff — keeps audioBufferOffsetSec ≤ cutoff,
        // preventing sub-ms epoch drift over hundreds of iterations.
        let trimSamples = min(max(Int(trimSec * Double(Self.sampleRate)), 0), audioBuffer.count)
        if trimSamples > 0 {
            audioBuffer.removeFirst(trimSamples)
            audioBufferOffsetSec += Double(trimSamples) / Double(Self.sampleRate)
        }
        // Hard cap safety net. If the buffer is STILL too long (agreement
        // not converging — e.g. language detection flip-flopping), force
        // trim from the head AND invalidate lastSegments so the next
        // iteration doesn't compare against "ghost segments" that
        // reference audio we just discarded.
        let maxSamples = Int(trimWindowSec * Double(Self.sampleRate))
        if audioBuffer.count > maxSamples {
            let excess = audioBuffer.count - maxSamples
            audioBuffer.removeFirst(excess)
            audioBufferOffsetSec += Double(excess) / Double(Self.sampleRate)
            lastSegments.removeAll()
        }
    }
}
