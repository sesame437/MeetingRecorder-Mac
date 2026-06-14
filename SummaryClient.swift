import Foundation

// MARK: - Public types

struct LiveSummary: Codable {
    let summary: String
    let highlights: [Point]
    let lowlights: [Point]
    let actions: [Action]
    let decisions: [Decision]
    let generatedAt: String

    struct Point: Codable { let point: String; let detail: String }
    struct Action: Codable { let task: String; let owner: String?; let deadline: String?; let priority: String? }
    struct Decision: Codable { let decision: String; let rationale: String? }
}

enum SummaryError: Error {
    case backendUnavailable
    case backendTimeout
    case rateLimited
    case validation(String)
    case decoding
    case network(Error)
}

// MARK: - Env-backed config

enum LiveSummaryConfig {
    static var backendURL: URL {
        let fallback = "https://your-backend.example.com"
        let raw = ProcessInfo.processInfo.environment["LIVE_SUMMARY_URL"] ?? fallback
        return URL(string: raw) ?? URL(string: fallback)!
    }
    static var apiKey: String? {
        ProcessInfo.processInfo.environment["LIVE_SUMMARY_API_KEY"]
    }
}

// MARK: - SummaryClient

@MainActor
final class SummaryClient {
    /// Fires on main queue whenever a summary POST succeeds (non-final ticks).
    var onSummary: ((LiveSummary) -> Void)?
    /// Fires on main queue after 3 consecutive failures. Receives a short reason.
    var onOffline: ((String) -> Void)?

    private let backendURL: URL
    private let apiKey: String?
    private let sessionId: UUID
    private let buffer: TranscriptBuffer
    private let sessionStart: Date
    private let session: URLSession
    private let maxChars: Int = 200_000

    private var timer: Timer?
    private var consecutiveFailures: Int = 0
    private let offlineThreshold: Int = 3

    init(backendURL: URL = LiveSummaryConfig.backendURL,
         apiKey: String? = LiveSummaryConfig.apiKey,
         sessionId: UUID,
         buffer: TranscriptBuffer,
         sessionStart: Date) {
        self.backendURL = backendURL
        self.apiKey = apiKey
        self.sessionId = sessionId
        self.buffer = buffer
        self.sessionStart = sessionStart

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 75
        self.session = URLSession(configuration: cfg)
    }

    func start(intervalSec: TimeInterval = 180) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: intervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Used on Stop — one last POST with isFinal: true, bypasses the backend 60s
    /// rate limit.
    func triggerFinal() async throws -> LiveSummary {
        try await post(isFinal: true)
    }

    // MARK: - Internals

    private func tick() async {
        do {
            let s = try await post(isFinal: false)
            consecutiveFailures = 0
            onSummary?(s)
        } catch {
            consecutiveFailures += 1
            NSLog("[SummaryClient] failure #\(consecutiveFailures): \(error)")
            if consecutiveFailures == offlineThreshold {
                onOffline?(shortReason(for: error))
            }
        }
    }

    private func post(isFinal: Bool) async throws -> LiveSummary {
        var req = URLRequest(url: backendURL.appendingPathComponent("/api/live-summary"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }

        let transcript = truncatedTranscriptText()
        let elapsedSec = max(1, Int(Date().timeIntervalSince(sessionStart)))
        let body: [String: Any] = [
            "sessionId": sessionId.uuidString.lowercased(),
            "transcriptText": transcript,
            "elapsedSec": elapsedSec,
            "isFinal": isFinal,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError where err.code == .timedOut {
            throw SummaryError.backendTimeout
        } catch {
            throw SummaryError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw SummaryError.decoding }
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(LiveSummary.self, from: data)
            } catch {
                throw SummaryError.decoding
            }
        case 400: throw SummaryError.validation(String(data: data, encoding: .utf8) ?? "")
        case 429: throw SummaryError.rateLimited
        case 503: throw SummaryError.backendUnavailable
        case 504: throw SummaryError.backendTimeout
        default:  throw SummaryError.network(
            NSError(domain: "live-summary", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        )
        }
    }

    /// Head 20% + tail 70% sliding window if the transcript is past maxChars.
    private func truncatedTranscriptText() -> String {
        let full = buffer.buildTranscriptText()
        if full.count <= maxChars { return full }
        let headCount = Int(Double(maxChars) * 0.20)
        let tailCount = Int(Double(maxChars) * 0.70)
        let fullArray = Array(full)
        let head = String(fullArray.prefix(headCount))
        let tail = String(fullArray.suffix(tailCount))
        return head + "\n\n[... truncated ...]\n\n" + tail
    }

    private func shortReason(for error: Error) -> String {
        switch error {
        case SummaryError.backendUnavailable: return "backend 503"
        case SummaryError.backendTimeout:     return "timeout"
        case SummaryError.rateLimited:        return "rate limited"
        case SummaryError.validation:         return "validation error"
        case SummaryError.decoding:           return "bad response"
        case SummaryError.network(let e):     return "network: \(e.localizedDescription)"
        default:                              return "unknown"
        }
    }
}
