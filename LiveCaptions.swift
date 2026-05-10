import Foundation
import WhisperKit

// MARK: - Public types

struct CaptionEvent {
    let text: String
    let startSec: Double   // relative to session start, audio-time
    let endSec: Double
}

struct TranscriptEntry {
    let startSec: Double
    let endSec: Double
    let text: String
}

// MARK: - LiveCaptions

/// In-process WhisperKit wrapper. `append` is thread-safe; `onCaption` is always
/// invoked on the main queue. Not @MainActor — append() runs on the audio queue.
final class LiveCaptions {
    /// Invoked on DispatchQueue.main after each transcription window completes.
    var onCaption: ((CaptionEvent) -> Void)?

    private let modelName: String
    private let queue = DispatchQueue(label: "live-captions")
    private let targetRate: Double = 16_000
    private let windowSamples: Int = 16_000 * 5   // 5 s of 16 kHz mono

    private var whisper: WhisperKit?
    private var buffer: [Float] = []       // guarded by queue
    private var sessionStart: Date = .distantPast
    private var lastEmitSec: Double = 0
    private var inFlight: Bool = false     // guarded by queue
    private var stopped: Bool = true       // guarded by queue

    init(modelName: String = "openai_whisper-small.en") {
        self.modelName = modelName
    }

    /// Load WhisperKit and reset state. Throws if the model fails to load.
    /// Caller typically awaits this before the user starts speaking.
    func start(sessionStart: Date) async throws {
        let cfg = WhisperKitConfig(model: modelName)
        let instance = try await WhisperKit(cfg)
        queue.sync {
            self.whisper = instance
            self.buffer.removeAll(keepingCapacity: true)
            self.sessionStart = sessionStart
            self.lastEmitSec = 0
            self.inFlight = false
            self.stopped = false
        }
    }

    /// Append Float32 mono samples. `sampleRate` is the rate of the incoming
    /// samples. We resample to `targetRate` if necessary.
    func append(_ samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }

            let resampled: [Float]
            if abs(sampleRate - self.targetRate) < 1.0 {
                resampled = samples
            } else {
                let ratio = self.targetRate / sampleRate
                let outCount = max(1, Int(Double(samples.count) * ratio))
                var out = [Float](repeating: 0, count: outCount)
                for i in 0..<outCount {
                    let srcIdx = Double(i) / ratio
                    let idx0 = Int(srcIdx)
                    let frac = Float(srcIdx - Double(idx0))
                    let s0 = idx0 < samples.count ? samples[idx0] : 0
                    let s1 = (idx0 + 1) < samples.count ? samples[idx0 + 1] : s0
                    out[i] = s0 + frac * (s1 - s0)
                }
                resampled = out
            }
            self.buffer.append(contentsOf: resampled)
            self.maybeTranscribeWindow(isFinal: false)
        }
    }

    /// Force-transcribe whatever's left in the buffer and emit one last event.
    /// Returns when the final transcription has been dispatched.
    func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self, !self.stopped else { cont.resume(); return }
                let samples = self.buffer
                self.buffer.removeAll(keepingCapacity: true)
                if samples.isEmpty {
                    cont.resume()
                    return
                }
                self.transcribe(samples: samples, isFinal: true) {
                    cont.resume()
                }
            }
        }
    }

    /// Release WhisperKit and stop accepting new samples.
    func stop() {
        queue.sync {
            self.stopped = true
            self.whisper = nil
            self.buffer.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Internals (must run on `queue`)

    private func maybeTranscribeWindow(isFinal: Bool) {
        guard !inFlight else { return }
        guard buffer.count >= windowSamples else { return }
        let windowSize = buffer.count
        let samples = Array(buffer.prefix(windowSize))
        buffer.removeFirst(windowSize)
        transcribe(samples: samples, isFinal: isFinal, completion: {})
    }

    private func transcribe(samples: [Float], isFinal: Bool, completion: @escaping () -> Void) {
        guard let whisper else { completion(); return }
        inFlight = true
        let sessionStart = self.sessionStart
        let lastEmit = self.lastEmitSec

        Task.detached { [weak self] in
            defer {
                self?.queue.async {
                    self?.inFlight = false
                    completion()
                }
            }
            do {
                let results = try await whisper.transcribe(audioArray: samples)
                let text = results.first?.text ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                let nowSec = Date().timeIntervalSince(sessionStart)
                let event = CaptionEvent(text: trimmed, startSec: lastEmit, endSec: nowSec)
                self?.queue.async { self?.lastEmitSec = nowSec }

                DispatchQueue.main.async {
                    self?.onCaption?(event)
                }
            } catch {
                NSLog("[LiveCaptions] transcribe error: \(error)")
            }
        }
    }
}
