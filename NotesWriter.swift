import Foundation

// MARK: - TranscriptBuffer

/// In-memory transcript state + formatted text builder.
final class TranscriptBuffer {
    private(set) var entries: [TranscriptEntry] = []

    func append(_ entry: TranscriptEntry) {
        entries.append(entry)
    }

    /// "[HH:MM:SS] text\n..." format. One line per final transcript entry.
    func buildTranscriptText() -> String {
        entries.map { "\(Self.formatTime($0.startSec)) \($0.text)" }.joined(separator: "\n")
    }

    static func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "[%02d:%02d:%02d]", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - NotesWriter

/// Writes a single .md file next to the .mp4. Atomic rewrite on every flush.
final class NotesWriter {
    private let mdURL: URL
    private let recordingURL: URL
    private let startedAt: Date
    private let sessionId: UUID
    private var lastSummary: LiveSummary?
    private var transcriptEntries: [TranscriptEntry] = []
    private var endedAt: Date?
    private let minFlushInterval: TimeInterval = 1.0
    private var lastFlushAt: Date = .distantPast

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(mdURL: URL, recordingURL: URL, startedAt: Date, sessionId: UUID) {
        self.mdURL = mdURL
        self.recordingURL = recordingURL
        self.startedAt = startedAt
        self.sessionId = sessionId
    }

    func appendTranscript(_ entry: TranscriptEntry) throws {
        transcriptEntries.append(entry)
        try flushIfDue()
    }

    func updateSummary(_ summary: LiveSummary) throws {
        lastSummary = summary
        try flush(force: true)
    }

    func setEnded(_ date: Date) throws {
        endedAt = date
        try flush(force: true)
    }

    private func flushIfDue() throws {
        try flush(force: false)
    }

    private func flush(force: Bool) throws {
        let now = Date()
        guard force || lastFlushAt == .distantPast || now.timeIntervalSince(lastFlushAt) >= minFlushInterval else {
            return
        }
        let md = renderMarkdown()
        let tmp = URL(fileURLWithPath: mdURL.path + ".tmp")
        try md.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(mdURL, withItemAt: tmp)
        lastFlushAt = now
    }

    private func renderMarkdown() -> String {
        var md = "---\n"
        md += "title: \(titleFromStart())\n"
        md += "recording: \(recordingURL.lastPathComponent)\n"
        md += "sessionId: \(sessionId.uuidString.lowercased())\n"
        md += "startedAt: \(Self.iso.string(from: startedAt))\n"
        md += "lastUpdated: \(Self.iso.string(from: Date()))\n"
        md += "endedAt: \(endedAt.map { Self.iso.string(from: $0) } ?? "null")\n"
        md += "language: en\n"
        md += "---\n\n"

        md += "# Summary"
        if let s = lastSummary {
            md += " (as of \(s.generatedAt))\n\n\(s.summary)\n\n"
            if !s.highlights.isEmpty {
                md += "## Highlights\n"
                for h in s.highlights { md += "- \(h.point) — \(h.detail)\n" }
                md += "\n"
            }
            if !s.lowlights.isEmpty {
                md += "## Lowlights\n"
                for l in s.lowlights { md += "- \(l.point) — \(l.detail)\n" }
                md += "\n"
            }
            if !s.actions.isEmpty {
                md += "## Actions\n"
                for a in s.actions {
                    let owner = a.owner ?? "?"
                    let due = a.deadline ?? "no deadline"
                    let pri = a.priority ?? "medium"
                    md += "- [ ] **\(owner)** · due \(due) · \(pri) — \(a.task)\n"
                }
                md += "\n"
            }
            if !s.decisions.isEmpty {
                md += "## Decisions\n"
                for d in s.decisions { md += "- \(d.decision) — \(d.rationale ?? "")\n" }
                md += "\n"
            }
        } else {
            md += "\n\n_(no summary yet)_\n\n"
        }

        md += "---\n\n# Transcript\n\n"
        for e in transcriptEntries {
            md += "\(TranscriptBuffer.formatTime(e.startSec)) \(e.text)\n"
        }
        return md
    }

    private func titleFromStart() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(f.string(from: startedAt)) Meeting"
    }
}
