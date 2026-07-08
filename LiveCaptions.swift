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
///
/// `@unchecked Sendable` is honest here: every piece of mutable state below is
/// either confined to the serial `queue` or only touched from main, and we
/// cross queue boundaries inside `Task.detached` / `DispatchQueue.async`
/// closures (which are themselves @Sendable in Swift 6).
final class LiveCaptions: @unchecked Sendable {
    /// Invoked on DispatchQueue.main after each transcription window completes.
    var onCaption: ((CaptionEvent) -> Void)?

    private let modelName: String
    private let queue = DispatchQueue(label: "live-captions")
    private let targetRate: Double = 16_000
    private let windowSamples: Int = 16_000 * 5   // 5 s of 16 kHz mono
    private let maxBufferSamples: Int = 16_000 * 15

    private var whisper: WhisperKit?
    private var buffer: [Float] = []       // guarded by queue
    private var sessionStart: Date = .distantPast
    private var bufferStartSample: Int64 = 0
    private var inFlight: Bool = false     // guarded by queue
    private var stopped: Bool = true       // guarded by queue

    init(modelName: String = "openai_whisper-small.en") {
        self.modelName = modelName
    }

    /// Load WhisperKit and reset state. Throws if the model fails to load.
    /// Caller typically awaits this before the user starts speaking.
    func start(sessionStart: Date) async throws {
        // If the model has already been downloaded to the default HF location,
        // pass it as modelFolder so WhisperKit skips the network round-trip
        // (setupModels() only hits HF when no folder is supplied — and it does
        //  so on every startup, which breaks captions whenever the user is
        //  offline or behind a restrictive network).
        let localFolder = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(modelName)")
        let hasLocal = FileManager.default.fileExists(atPath: localFolder.path)

        let cfg: WhisperKitConfig
        if hasLocal {
            // Offline-friendly path: load directly from local folder, no network.
            cfg = WhisperKitConfig(model: modelName, modelFolder: localFolder.path, load: true)
        } else {
            // First launch — requires network to download ~465 MB.
            cfg = WhisperKitConfig(model: modelName, load: true)
        }

        let instance = try await WhisperKit(cfg)
        queue.sync {
            self.whisper = instance
            self.buffer.removeAll(keepingCapacity: true)
            self.sessionStart = sessionStart
            self.bufferStartSample = 0
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
            if self.buffer.count > self.maxBufferSamples {
                let excess = self.buffer.count - self.maxBufferSamples
                self.buffer.removeFirst(excess)
                self.bufferStartSample += Int64(excess)
            }
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
                let startSec = Double(self.bufferStartSample) / self.targetRate
                let endSec = Double(self.bufferStartSample + Int64(samples.count)) / self.targetRate
                self.buffer.removeAll(keepingCapacity: true)
                self.bufferStartSample += Int64(samples.count)
                if samples.isEmpty {
                    cont.resume()
                    return
                }
                self.transcribe(samples: samples, startSec: startSec, endSec: endSec, isFinal: true) {
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
        let startSec = Double(bufferStartSample) / targetRate
        bufferStartSample += Int64(windowSize)
        let endSec = Double(bufferStartSample) / targetRate
        transcribe(samples: samples, startSec: startSec, endSec: endSec, isFinal: isFinal, completion: {})
    }

    private func transcribe(samples: [Float],
                            startSec: Double,
                            endSec: Double,
                            isFinal: Bool,
                            completion: @escaping () -> Void) {
        guard let whisper else { completion(); return }
        inFlight = true

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

                let event = CaptionEvent(text: trimmed, startSec: startSec, endSec: endSec)

                DispatchQueue.main.async {
                    self?.onCaption?(event)
                }
            } catch {
                NSLog("[LiveCaptions] transcribe error: \(error)")
            }
        }
    }
}
