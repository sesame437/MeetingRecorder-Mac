import Foundation

/// Real-time verbatim transcription pipeline driven by the live PCM tap on
/// `AudioRecorder`.
///
/// Pipeline (per the design we agreed during grilling):
///
///   * Receive Float32 mono 16 kHz samples via `append(_:sampleRate:)`.
///   * Maintain an unconfirmed audio buffer; once it has ≥ `minChunkSec`
///     of new audio AND no inference is in flight, POST the buffer as a
///     WAV to whisper-server's /inference endpoint with
///     `response_format=verbose_json`.
///   * Apply LocalAgreement-2: a segment is "committed" only when its
///     trimmed text matches the same-index segment from the previous
///     iteration (longest common prefix wins).
///   * Trim the audio buffer at the last committed segment's end, then
///     hard-cap at `trimWindowSec` to bound runaway buffers.
///   * Append committed text to the current line buffer; flush a line to
///     `.verbatim.md` when it ends in a sentence terminator (`。！？.!?`)
///     or exceeds `lineMaxChars`.
///
/// On `flush()` (called from stopRecording), we run one final inference
/// over whatever audio is still buffered and commit ALL segments
/// unconditionally — bypassing the two-iteration agreement so the last
/// few seconds of speech don't get dropped.
final class VerbatimTranscriber: @unchecked Sendable {

    // MARK: - Tuning (from Q2/Q3 decisions)
    private let minChunkSec: Double = 1.0           // run inference every ≥1s of new audio
    private let trimWindowSec: Double = 15.0        // hard cap on unconfirmed buffer
    private let lineMaxChars: Int = 80              // failsafe line break
    /// All sentence-terminator characters we accept across zh/en. Includes
    /// half-width ASCII variants because some Whisper outputs mix them in.
    private static let sentenceTerminators: Set<Character> =
        ["。", "！", "？", ".", "!", "?"]
    /// Standard sample rate of AudioRecorder's downmixed tap.
    private static let sampleRate: Int = 16_000

    // MARK: - Dependencies
    private let server: WhisperServerProcess
    private let writer: VerbatimWriter
    private let language: String   // "auto" | "zh" | "en"

    // MARK: - State (guarded by `queue` unless noted)
    private let queue = DispatchQueue(label: "verbatim-transcriber")

    /// Pending audio samples that have not yet been confirmed by LocalAgreement.
    private var audioBuffer: [Float] = []
    /// Wall-clock seconds (relative to sessionStart) at which `audioBuffer[0]`
    /// was captured. Trimming the head of the buffer advances this.
    private var audioBufferOffsetSec: Double = 0

    /// Last inference's segments, with start/end made relative to the
    /// CURRENT buffer head (i.e., re-zeroed every time we trim). Used by
    /// `applyAgreement` for the prefix comparison.
    private var lastSegments: [Segment] = []

    /// Text that's been committed but not yet emitted as a `.verbatim.md`
    /// line. Flushed on punctuation or `lineMaxChars`.
    private var lineBuffer: String = ""
    private var lineStartSec: Double?

    private var sessionStart: Date = .distantPast
    private var stopped: Bool = true
    /// Set while an inference HTTP request is outstanding; gates new
    /// transcribes so they don't pile up faster than whisper-server can
    /// serve them.
    private var inFlight: Bool = false

    private let httpSession: URLSession

    /// One transcribed unit from whisper-server (`segments[]` entry).
    /// Times are in seconds, relative to the WAV we sent.
    private struct Segment {
        let text: String
        let start: Double
        let end: Double
    }

    // MARK: - Init

    init(server: WhisperServerProcess, writer: VerbatimWriter, language: String) {
        self.server = server
        self.writer = writer
        self.language = language
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        self.httpSession = URLSession(configuration: cfg)
    }

    // MARK: - Public surface (called from MainActor / audio queue)

    /// Mark t=0 of the session and lay down the .verbatim.md preamble.
    func start(sessionStart: Date) throws {
        try writer.writePreamble()
        queue.sync {
            self.sessionStart = sessionStart
            self.audioBuffer.removeAll(keepingCapacity: true)
            self.audioBufferOffsetSec = 0
            self.lastSegments.removeAll()
            self.lineBuffer = ""
            self.lineStartSec = nil
            self.stopped = false
            self.inFlight = false
        }
    }

    /// Receive a PCM chunk from `AudioRecorder.onPCMChunk`. Runs on the
    /// audio queue, so we hop onto our own serial queue immediately.
    func append(_ samples: [Float], sampleRate: Double) {
        // We only support the AudioRecorder's standard 16 kHz tap; if
        // somebody hands us anything else, we drop it (the post-mix tap
        // is hard-wired to 16k, so this is just defense-in-depth).
        guard Int(sampleRate.rounded()) == Self.sampleRate else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.audioBuffer.append(contentsOf: samples)
            self.maybeTranscribe()
        }
    }

    /// Force-commit anything still unconfirmed. Called from stopRecording
    /// before the whisper-server is killed.
    func flush() async {
        // Snapshot remaining audio + rebase point on the queue, then run
        // one final inference outside it. Anything < 100ms is too short
        // for Whisper to get useful tokens out of, skip.
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

        // Drain anything still in lineBuffer.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                if !self.lineBuffer.isEmpty {
                    let stamp = self.lineStartSec ?? self.audioBufferOffsetSec
                    try? self.writer.appendLine(self.lineBuffer, at: stamp)
                    self.lineBuffer = ""
                    self.lineStartSec = nil
                }
                cont.resume()
            }
        }
    }

    func stop() { queue.sync { self.stopped = true } }

    // MARK: - Inference loop (runs on `queue`)

    private func maybeTranscribe() {
        guard !inFlight, !stopped else { return }
        let bufferSec = Double(audioBuffer.count) / Double(Self.sampleRate)
        guard bufferSec >= minChunkSec else { return }
        // Snapshot under queue, then hop to detached Task — keeps the
        // audio queue free to keep accumulating samples while inference
        // runs (~1-2s on M-series).
        let samples = audioBuffer
        let offsetSec = audioBufferOffsetSec
        inFlight = true
        Task.detached { [weak self] in
            await self?.runInference(samples: samples, offsetSec: offsetSec, isFinal: false)
        }
    }

    private func runInference(samples: [Float], offsetSec: Double, isFinal: Bool) async {
        defer {
            queue.async { [weak self] in
                self?.inFlight = false
                // Allow the next iteration to pick up new buffered audio.
                self?.maybeTranscribe()
            }
        }

        guard let url = server.inferenceURL else { return }
        guard let wav = makeWAV(samples: samples) else { return }

        let boundary = "----meeting-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(boundary: boundary, wav: wav)

        do {
            let (data, response) = try await httpSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("verbatim: inference HTTP \(code)")
                return
            }
            guard let segments = parseSegments(data) else {
                NSLog("verbatim: failed to parse verbose_json")
                return
            }
            queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                if isFinal {
                    self.applyFinalCommit(segments: segments, offsetSec: offsetSec)
                } else {
                    self.applyAgreement(newSegments: segments, offsetSec: offsetSec)
                }
            }
        } catch {
            NSLog("verbatim: inference error: \(error.localizedDescription)")
        }
    }

    // MARK: - LocalAgreement-2 (runs on `queue`)

    private func applyAgreement(newSegments: [Segment], offsetSec: Double) {
        // The samples we sent might pre-date current buffer head if
        // append() trimmed concurrently; but since we set inFlight before
        // sending, applyAgreement runs with offsetSec equal to the head
        // we sent — `lastSegments` are also relative to that head.
        let common = Self.longestCommonPrefix(prev: lastSegments, current: newSegments)

        var lastEndRelative: Double = 0
        for seg in common {
            commitText(seg.text, atSec: offsetSec + seg.start)
            lastEndRelative = seg.end
        }

        // Trim audio buffer past the last committed segment.
        if !common.isEmpty {
            let trimSamples = Int((lastEndRelative * Double(Self.sampleRate)).rounded())
            let safeTrim = min(max(trimSamples, 0), audioBuffer.count)
            if safeTrim > 0 {
                audioBuffer.removeFirst(safeTrim)
                audioBufferOffsetSec += Double(safeTrim) / Double(Self.sampleRate)
            }
        }

        // Hard cap. If the agreement isn't progressing (e.g., language
        // detection thrashing), force-trim from the head so we don't
        // grow without bound.
        let maxSamples = Int(trimWindowSec * Double(Self.sampleRate))
        if audioBuffer.count > maxSamples {
            let excess = audioBuffer.count - maxSamples
            audioBuffer.removeFirst(excess)
            audioBufferOffsetSec += Double(excess) / Double(Self.sampleRate)
        }

        // Re-zero the unconfirmed-tail segments against the NEW buffer
        // head, so next round's prefix comparison lines up.
        let remaining = newSegments.dropFirst(common.count)
        lastSegments = remaining.map {
            Segment(text: $0.text,
                    start: $0.start - lastEndRelative,
                    end: $0.end - lastEndRelative)
        }
    }

    private func applyFinalCommit(segments: [Segment], offsetSec: Double) {
        for seg in segments {
            commitText(seg.text, atSec: offsetSec + seg.start)
        }
    }

    private static func longestCommonPrefix(prev: [Segment], current: [Segment]) -> [Segment] {
        var result: [Segment] = []
        let limit = min(prev.count, current.count)
        for i in 0..<limit {
            let a = prev[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = current[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty && a == b {
                result.append(current[i])
            } else {
                break
            }
        }
        return result
    }

    // MARK: - Line builder (runs on `queue`)

    private func commitText(_ raw: String, atSec startSec: Double) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Whisper's standalone "[BLANK_AUDIO]", "[Music]", "[音乐]" etc. are
        // metadata, not transcript content. Drop them.
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") { return }

        if lineBuffer.isEmpty {
            lineStartSec = startSec
            lineBuffer = trimmed
        } else {
            // ASCII-vs-ASCII boundary needs a space; CJK runs don't.
            if Self.needsSpaceJoin(prev: lineBuffer, next: trimmed) {
                lineBuffer += " " + trimmed
            } else {
                lineBuffer += trimmed
            }
        }

        if shouldBreakLine(lineBuffer) {
            try? writer.appendLine(lineBuffer, at: lineStartSec ?? startSec)
            lineBuffer = ""
            lineStartSec = nil
        }
    }

    private func shouldBreakLine(_ s: String) -> Bool {
        if let last = s.last, Self.sentenceTerminators.contains(last) { return true }
        if s.count >= lineMaxChars { return true }
        return false
    }

    /// Heuristic: insert a space when joining two runs of ASCII letters/
    /// digits (English-style word boundaries). Any CJK on either side
    /// means no space.
    private static func needsSpaceJoin(prev: String, next: String) -> Bool {
        guard let last = prev.last, let first = next.first else { return false }
        let asciiAlnum = CharacterSet.alphanumerics.intersection(.init(charactersIn: "0"..."z"))
        let lastIsASCII = last.unicodeScalars.allSatisfy { asciiAlnum.contains($0) }
        let firstIsASCII = first.unicodeScalars.allSatisfy { asciiAlnum.contains($0) }
        return lastIsASCII && firstIsASCII
    }

    // MARK: - WAV encoding (Float32 mono 16 kHz → s16le PCM + RIFF)

    private func makeWAV(samples: [Float]) -> Data? {
        guard !samples.isEmpty else { return nil }
        let sr = UInt32(Self.sampleRate)
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sr * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count) * UInt32(bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))
        // RIFF
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        // fmt
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sr.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        // data
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        // PCM samples
        data.reserveCapacity(data.count + samples.count * 2)
        for f in samples {
            // Clamp + scale to Int16 range.
            let clamped = max(-1.0, min(1.0, f))
            let s = Int16(clamped * 32767)
            data.append(contentsOf: withUnsafeBytes(of: s.littleEndian) { Array($0) })
        }
        return data
    }

    // MARK: - Multipart body for whisper-server's /inference

    private func makeMultipartBody(boundary: String, wav: Data) -> Data {
        var body = Data()
        let crlf = "\r\n"

        func appendField(_ name: String, _ value: String) {
            body.append(contentsOf: "--\(boundary)\(crlf)".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".utf8)
            body.append(contentsOf: "\(value)\(crlf)".utf8)
        }

        // file part
        body.append(contentsOf: "--\(boundary)\(crlf)".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(crlf)".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\(crlf)\(crlf)".utf8)
        body.append(wav)
        body.append(contentsOf: crlf.utf8)

        appendField("response_format", "verbose_json")
        appendField("language", language)
        appendField("temperature", "0.0")

        body.append(contentsOf: "--\(boundary)--\(crlf)".utf8)
        return body
    }

    // MARK: - JSON parse (verbose_json → [Segment])

    private func parseSegments(_ data: Data) -> [Segment]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // whisper-server's verbose_json: top-level "segments": [{ start, end, text, ... }, …]
        guard let raw = obj["segments"] as? [[String: Any]] else { return [] }
        var out: [Segment] = []
        out.reserveCapacity(raw.count)
        for seg in raw {
            guard let text = seg["text"] as? String else { continue }
            let start = (seg["start"] as? Double) ?? 0
            let end = (seg["end"] as? Double) ?? start
            out.append(Segment(text: text, start: start, end: end))
        }
        return out
    }
}
