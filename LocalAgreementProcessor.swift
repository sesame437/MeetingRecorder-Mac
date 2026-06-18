import Foundation

/// Pure-logic module for the LocalAgreement-2 streaming transcription
/// algorithm + line builder. No I/O, no queue, no network. Designed to
/// be trivially unit-testable with crafted segment arrays.
///
/// Usage: VerbatimTranscriber holds a `var processor: LocalAgreementProcessor`
/// and calls `process()` after each inference round. The returned
/// `CommitResult` tells the caller what lines to write + how much audio
/// buffer to trim.
struct LocalAgreementProcessor {

    // MARK: - Types

    struct Segment {
        let text: String
        let start: Double
        let end: Double
    }

    struct CommitResult {
        let lines: [(text: String, atSec: Double)]
        let trimSec: Double
        let updatedPendingSegments: [Segment]
    }

    // MARK: - Tuning

    private let stableContextSec: Double = 5.0
    private let lineMaxChars: Int = 80
    private static let sentenceTerminators: Set<Character> =
        ["。", "！", "？", ".", "!", "?"]

    // MARK: - Mutable state (value semantics via struct)

    private var lineBuffer: String = ""
    private var lineStartSec: Double?

    // MARK: - Public interface

    mutating func process(
        newSegments: [Segment],
        previousSegments: [Segment],
        bufferOffsetSec: Double,
        bufferTailSec: Double,
        isFinal: Bool
    ) -> CommitResult {
        if isFinal {
            return applyFinalCommit(
                segments: newSegments,
                offsetSec: bufferOffsetSec
            )
        } else {
            return applyAgreement(
                newSegments: newSegments,
                previousSegments: previousSegments,
                offsetSec: bufferOffsetSec,
                bufferTailSec: bufferTailSec
            )
        }
    }

    mutating func drainLineBuffer() -> (text: String, atSec: Double)? {
        guard !lineBuffer.isEmpty else { return nil }
        let result = (text: lineBuffer, atSec: lineStartSec ?? 0)
        lineBuffer = ""
        lineStartSec = nil
        return result
    }

    mutating func reset() {
        lineBuffer = ""
        lineStartSec = nil
    }

    // MARK: - LocalAgreement-2 core

    private mutating func applyAgreement(
        newSegments: [Segment],
        previousSegments: [Segment],
        offsetSec: Double,
        bufferTailSec: Double
    ) -> CommitResult {
        var committedLines: [(text: String, atSec: Double)] = []
        var trimSec: Double = 0

        let prevText = Self.joinSegments(previousSegments)
        let currentText = Self.joinSegments(newSegments)
        let prefixLen = Self.longestCommonPrefixLength(prevText, currentText)

        var charsUsed = 0
        var lastCommittedEnd: Double = 0
        var first = true
        for seg in newSegments {
            let txt = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.isEmpty { continue }
            let sep = first ? 0 : 1
            let need = charsUsed + sep + txt.count
            if need <= prefixLen {
                committedLines.append(contentsOf: commitText(txt, atSec: offsetSec + seg.start))
                lastCommittedEnd = seg.end
                charsUsed = need
                first = false
            } else {
                break
            }
        }

        if lastCommittedEnd > 0 {
            trimSec = offsetSec + lastCommittedEnd
        }

        // Always-on force-commit (Option B): commit segments with enough
        // trailing context, even without two-iteration agreement.
        for seg in newSegments {
            let segEndAbs = offsetSec + seg.end
            if segEndAbs <= trimSec { continue }
            let trailingContext = bufferTailSec - segEndAbs
            if trailingContext >= stableContextSec {
                let segText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !segText.isEmpty {
                    committedLines.append(contentsOf: commitText(segText, atSec: offsetSec + seg.start))
                }
                trimSec = segEndAbs
            } else {
                break
            }
        }

        // Rebase surviving segments against the new trim point.
        let updatedPending = newSegments.compactMap { seg -> Segment? in
            let absEnd = offsetSec + seg.end
            guard absEnd > trimSec else { return nil }
            let absStart = offsetSec + seg.start
            return Segment(text: seg.text,
                           start: absStart - trimSec,
                           end: absEnd - trimSec)
        }

        return CommitResult(
            lines: committedLines,
            trimSec: trimSec,
            updatedPendingSegments: updatedPending
        )
    }

    private mutating func applyFinalCommit(
        segments: [Segment],
        offsetSec: Double
    ) -> CommitResult {
        var committedLines: [(text: String, atSec: Double)] = []
        var lastEnd: Double = 0
        for seg in segments {
            let txt = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.isEmpty { continue }
            committedLines.append(contentsOf: commitText(txt, atSec: offsetSec + seg.start))
            lastEnd = seg.end
        }
        return CommitResult(
            lines: committedLines,
            trimSec: offsetSec + lastEnd,
            updatedPendingSegments: []
        )
    }

    // MARK: - Line builder

    private mutating func commitText(_ raw: String, atSec startSec: Double) -> [(text: String, atSec: Double)] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return [] }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") { return [] }

        if lineBuffer.isEmpty {
            lineStartSec = startSec
            lineBuffer = trimmed
        } else {
            if Self.needsSpaceJoin(prev: lineBuffer, next: trimmed) {
                lineBuffer += " " + trimmed
            } else {
                lineBuffer += trimmed
            }
        }

        var results: [(text: String, atSec: Double)] = []
        if shouldBreakLine(lineBuffer) {
            results.append((text: lineBuffer, atSec: lineStartSec ?? startSec))
            lineBuffer = ""
            lineStartSec = nil
        }
        return results
    }

    private func shouldBreakLine(_ s: String) -> Bool {
        if let last = s.last, Self.sentenceTerminators.contains(last) { return true }
        if s.count >= lineMaxChars { return true }
        return false
    }

    // MARK: - Pure utilities

    static func joinSegments(_ segments: [Segment]) -> String {
        return segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func longestCommonPrefixLength(_ a: String, _ b: String) -> Int {
        var ai = a.makeIterator()
        var bi = b.makeIterator()
        var n = 0
        while let ac = ai.next(), let bc = bi.next(), ac == bc {
            n += 1
        }
        return n
    }

    static func needsSpaceJoin(prev: String, next: String) -> Bool {
        guard let last = prev.last, let first = next.first else { return false }
        let asciiAlnum = CharacterSet.alphanumerics.intersection(.init(charactersIn: "0"..."z"))
        let lastIsASCII = last.unicodeScalars.allSatisfy { asciiAlnum.contains($0) }
        let firstIsASCII = first.unicodeScalars.allSatisfy { asciiAlnum.contains($0) }
        return lastIsASCII && firstIsASCII
    }
}
