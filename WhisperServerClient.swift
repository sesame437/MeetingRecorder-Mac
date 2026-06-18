import Foundation

/// Adapter at the whisper-server HTTP seam. Callers hand it Float32
/// samples, get back `[Segment]`. All WAV encoding, multipart body
/// construction, HTTP transport, JSON parsing, and server restart
/// mechanics are hidden behind two methods: `transcribe()` and
/// `restartServer()`.
///
/// Designed so VerbatimTranscriber never touches HTTP details. If the
/// ASR backend changes (Apple SFSpeechRecognizer, remote API), only
/// this file needs to be swapped — VerbatimTranscriber and
/// LocalAgreementProcessor stay untouched.
final class WhisperServerClient: @unchecked Sendable {

    typealias Segment = LocalAgreementProcessor.Segment

    enum TranscribeError: LocalizedError {
        case noInferenceURL
        case wavEncodingFailed
        case httpError(statusCode: Int)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .noInferenceURL: return "whisper-server has no inference URL (not started?)"
            case .wavEncodingFailed: return "failed to encode samples as WAV"
            case .httpError(let code): return "whisper-server returned HTTP \(code)"
            case .parseFailed: return "failed to parse verbose_json response"
            }
        }
    }

    private let server: WhisperServerProcess
    private let language: String
    private let httpSession: URLSession
    private static let sampleRate: Int = 16_000

    init(server: WhisperServerProcess, language: String) {
        self.server = server
        self.language = language
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 15
        self.httpSession = URLSession(configuration: cfg)
    }

    /// POST samples as WAV to whisper-server /inference, return parsed
    /// segments. Throws on any failure — caller is responsible for
    /// tracking consecutive failures and deciding when to restart.
    func transcribe(samples: [Float]) async throws -> [Segment] {
        guard let url = server.inferenceURL else {
            throw TranscribeError.noInferenceURL
        }
        guard let wav = makeWAV(samples: samples) else {
            throw TranscribeError.wavEncodingFailed
        }

        let boundary = "----meeting-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                        forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(boundary: boundary, wav: wav)

        let (data, response) = try await httpSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranscribeError.httpError(statusCode: code)
        }
        guard let segments = parseSegments(data) else {
            throw TranscribeError.parseFailed
        }
        return segments
    }

    /// Kill the current whisper-server subprocess and spawn a fresh one
    /// with the same parameters. Takes ~3-5s on M-series (model reload).
    func restartServer() async throws {
        try await server.restart()
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
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sr.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.reserveCapacity(data.count + samples.count * 2)
        for f in samples {
            let clamped = max(-1.0, min(1.0, f))
            let s = Int16(clamped * 32767)
            data.append(contentsOf: withUnsafeBytes(of: s.littleEndian) { Array($0) })
        }
        return data
    }

    // MARK: - Multipart body

    private func makeMultipartBody(boundary: String, wav: Data) -> Data {
        var body = Data()
        let crlf = "\r\n"

        func appendField(_ name: String, _ value: String) {
            body.append(contentsOf: "--\(boundary)\(crlf)".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".utf8)
            body.append(contentsOf: "\(value)\(crlf)".utf8)
        }

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

    // MARK: - JSON parsing

    private func parseSegments(_ data: Data) -> [Segment]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
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
