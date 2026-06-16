import Foundation

/// Writes a `.verbatim.md` file next to the recording, one line per
/// committed transcript chunk. Same atomic-rewrite pattern as `NotesWriter`:
/// every append rewrites the entire file via `.tmp` + `replaceItemAt`, which
/// is O(file size) but keeps the on-disk file readable by tail -F / Obsidian
/// at any instant — never half-written, never empty mid-update.
///
/// File shape (matches the format we agreed during grilling). Two pairs of
/// timestamps:
///   * `started_at` / `ended_at`         — the recording's lifetime (mp4)
///   * `verbatim_started_at` /           — when transcription was actually
///     `verbatim_ended_at`                 active. They equal the pair above
///                                         when the user pre-enabled verbatim
///                                         before pressing Start; they fall
///                                         inside the recording window when
///                                         the user toggled mid-record.
///
///     ---
///     session_id: <uuid>
///     recording: <basename>.mp4
///     notes: <basename>.md
///     started_at: <iso8601>
///     ended_at: <iso8601 or null>
///     verbatim_started_at: <iso8601>
///     verbatim_ended_at: <iso8601 or null>
///     language: zh | en | auto
///     engine: whisper.cpp/ggml-large-v3-turbo
///     algo: LocalAgreement-2
///     chunk_window_sec: 1.0
///     trim_window_sec: 15.0
///     ---
///
///     [00:00:03] 大家好，今天主要讨论 Q2 目标。
///     [00:00:11] 我先说一下背景。
///
final class VerbatimWriter {
    struct Config {
        let language: String          // "auto" | "zh" | "en"
        let engine: String            // e.g. "whisper.cpp/ggml-large-v3-turbo"
        let algo: String              // e.g. "LocalAgreement-2"
        let chunkWindowSec: Double
        let trimWindowSec: Double
    }

    private let mdURL: URL
    private let recordingURL: URL
    private let notesURL: URL?        // companion .md from NotesWriter, if any
    private let startedAt: Date
    private let verbatimStartedAt: Date
    private let sessionId: UUID
    private var config: Config
    private var lines: [Line] = []
    private var endedAt: Date?
    private var verbatimEndedAt: Date?

    private struct Line {
        let startSec: Double
        let text: String
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(verbatimURL: URL,
         recordingURL: URL,
         notesURL: URL?,
         startedAt: Date,
         verbatimStartedAt: Date,
         sessionId: UUID,
         config: Config) {
        self.mdURL = verbatimURL
        self.recordingURL = recordingURL
        self.notesURL = notesURL
        self.startedAt = startedAt
        self.verbatimStartedAt = verbatimStartedAt
        self.sessionId = sessionId
        self.config = config
    }

    /// Append a finalized transcript line. `startSec` is relative to the
    /// session start (the first audio sample). Triggers an atomic rewrite.
    func appendLine(_ text: String, at startSec: Double) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(Line(startSec: max(0, startSec), text: trimmed))
        try flush()
    }

    /// Update the language field (used when `language` was set to "auto" and
    /// whisper-server detects the actual language). No-op if the value
    /// hasn't changed.
    func setDetectedLanguage(_ code: String) throws {
        guard code != config.language else { return }
        config = Config(language: code,
                        engine: config.engine,
                        algo: config.algo,
                        chunkWindowSec: config.chunkWindowSec,
                        trimWindowSec: config.trimWindowSec)
        try flush()
    }

    /// Stamp `ended_at` (mp4 recording end) and rewrite. Call from
    /// stopRecording. If `verbatim_ended_at` hasn't been set yet (typical
    /// case where user didn't toggle verbatim off mid-recording), mirror
    /// `ended_at` into it so the two timestamps match the natural case.
    func setEnded(_ date: Date) throws {
        endedAt = date
        if verbatimEndedAt == nil { verbatimEndedAt = date }
        try flush()
    }

    /// Stamp `verbatim_ended_at` only — used when the user toggled
    /// verbatim OFF mid-recording (recording itself continues).
    func setVerbatimEnded(_ date: Date) throws {
        verbatimEndedAt = date
        try flush()
    }

    /// Initialize the file with frontmatter + empty body. Call once after
    /// init so even a recording with zero committed lines leaves a stub
    /// .verbatim.md instead of nothing.
    func writePreamble() throws {
        try flush()
    }

    // MARK: - Private

    private func flush() throws {
        let md = render()
        let tmp = URL(fileURLWithPath: mdURL.path + ".tmp")
        try md.write(to: tmp, atomically: false, encoding: .utf8)
        // Use replaceItemAt so existing readers see the swap atomically.
        _ = try FileManager.default.replaceItemAt(mdURL, withItemAt: tmp)
    }

    private func render() -> String {
        var md = "---\n"
        md += "session_id: \(sessionId.uuidString.lowercased())\n"
        md += "recording: \(recordingURL.lastPathComponent)\n"
        if let n = notesURL {
            md += "notes: \(n.lastPathComponent)\n"
        }
        md += "started_at: \(Self.iso.string(from: startedAt))\n"
        md += "ended_at: \(endedAt.map { Self.iso.string(from: $0) } ?? "null")\n"
        md += "verbatim_started_at: \(Self.iso.string(from: verbatimStartedAt))\n"
        md += "verbatim_ended_at: \(verbatimEndedAt.map { Self.iso.string(from: $0) } ?? "null")\n"
        md += "language: \(config.language)\n"
        md += "engine: \(config.engine)\n"
        md += "algo: \(config.algo)\n"
        md += "chunk_window_sec: \(config.chunkWindowSec)\n"
        md += "trim_window_sec: \(config.trimWindowSec)\n"
        md += "---\n\n"

        for line in lines {
            md += "\(Self.formatTime(line.startSec)) \(line.text)\n"
        }
        return md
    }

    static func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "[%02d:%02d:%02d]", s / 3600, (s % 3600) / 60, s % 60)
    }
}
