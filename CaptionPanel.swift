import AppKit

/// Single floating panel: top half shows rolling captions, bottom half shows
/// the most recent summary (or a placeholder). Safe to call all methods from
/// the main queue only.
@MainActor
final class CaptionPanel {
    private let panel: NSPanel
    private let captionsLabel: NSTextField
    private let summaryLabel: NSTextField
    private let offlineBanner: NSTextField
    private let offlineContainer: NSView
    private let separator: NSBox

    private var recentCaptions: [String] = []
    private let maxCaptionLines = 3

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 240, y: 100, width: 820, height: 260),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "MeetingRecorder — Live"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        captionsLabel = NSTextField(labelWithString: "")
        captionsLabel.font = .systemFont(ofSize: 22, weight: .medium)
        captionsLabel.textColor = .white
        captionsLabel.alignment = .left
        captionsLabel.maximumNumberOfLines = maxCaptionLines
        captionsLabel.lineBreakMode = .byWordWrapping
        captionsLabel.translatesAutoresizingMaskIntoConstraints = false

        separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel = NSTextField(labelWithString: "Summary will appear every 3 minutes.")
        summaryLabel.font = .systemFont(ofSize: 13, weight: .regular)
        summaryLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        summaryLabel.alignment = .left
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        offlineBanner = NSTextField(labelWithString: "")
        offlineBanner.font = .systemFont(ofSize: 12, weight: .medium)
        offlineBanner.textColor = .white
        offlineBanner.alignment = .center
        offlineBanner.maximumNumberOfLines = 1
        offlineBanner.translatesAutoresizingMaskIntoConstraints = false
        offlineContainer = NSView()
        offlineContainer.wantsLayer = true
        offlineContainer.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        offlineContainer.translatesAutoresizingMaskIntoConstraints = false
        offlineContainer.addSubview(offlineBanner)
        offlineContainer.isHidden = true

        let content = NSView()
        content.addSubview(offlineContainer)
        content.addSubview(captionsLabel)
        content.addSubview(separator)
        content.addSubview(summaryLabel)

        NSLayoutConstraint.activate([
            // Offline banner pinned to top
            offlineContainer.topAnchor.constraint(equalTo: content.topAnchor),
            offlineContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            offlineContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            offlineContainer.heightAnchor.constraint(equalToConstant: 22),
            offlineBanner.centerXAnchor.constraint(equalTo: offlineContainer.centerXAnchor),
            offlineBanner.centerYAnchor.constraint(equalTo: offlineContainer.centerYAnchor),
            offlineBanner.leadingAnchor.constraint(greaterThanOrEqualTo: offlineContainer.leadingAnchor, constant: 8),
            offlineBanner.trailingAnchor.constraint(lessThanOrEqualTo: offlineContainer.trailingAnchor, constant: -8),

            // Captions area
            captionsLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            captionsLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            captionsLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            // Separator
            separator.topAnchor.constraint(equalTo: captionsLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // Summary area
            summaryLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])

        panel.contentView = content
    }

    func show() {
        recentCaptions.removeAll()
        captionsLabel.stringValue = "Loading captions…"
        summaryLabel.stringValue = "Summary will appear every 3 minutes."
        offlineContainer.isHidden = true
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func applyCaption(_ event: CaptionEvent) {
        recentCaptions.append(event.text)
        if recentCaptions.count > maxCaptionLines {
            recentCaptions.removeFirst(recentCaptions.count - maxCaptionLines)
        }
        captionsLabel.stringValue = recentCaptions.joined(separator: "\n")
    }

    /// Called by Task 6's SummaryClient. `nil` means "reset to placeholder".
    func renderSummary(_ summary: LiveSummary?) {
        guard let s = summary else {
            summaryLabel.stringValue = "Summary will appear every 3 minutes."
            return
        }
        var text = s.summary
        if !s.highlights.isEmpty {
            text += "\n\nHighlights:"
            for h in s.highlights { text += "\n  • \(h.point) — \(h.detail)" }
        }
        if !s.actions.isEmpty {
            text += "\n\nActions:"
            for a in s.actions {
                let owner = a.owner ?? "?"
                let due = a.deadline ?? "no deadline"
                text += "\n  • [\(owner)] \(a.task) — due \(due)"
            }
        }
        if !s.decisions.isEmpty {
            text += "\n\nDecisions:"
            for d in s.decisions { text += "\n  • \(d.decision)" }
        }
        summaryLabel.stringValue = text
    }

    func showOffline(_ reason: String?) {
        if let reason {
            offlineBanner.stringValue = "Summary offline — \(reason)"
            offlineContainer.isHidden = false
        } else {
            offlineContainer.isHidden = true
        }
    }
}

