import AppKit
import Foundation

final class SummaryServerPanel {
    private let panel: NSPanel
    private let urlField: NSTextField
    private let testButton: NSButton
    private let saveButton: NSButton
    private let statusLabel: NSTextField
    private let lockedLabel: NSTextField
    private weak var recorder: AudioRecorder?

    init(recorder: AudioRecorder) {
        self.recorder = recorder

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Live Summary Server"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()

        // URL label
        let label = NSTextField(labelWithString: "Server URL:")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)

        // URL text field
        urlField = NSTextField(frame: .zero)
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.placeholderString = "https://your-server.com"
        urlField.font = .systemFont(ofSize: 13)
        urlField.lineBreakMode = .byTruncatingTail
        urlField.stringValue = recorder.liveSummaryURL

        // Test button
        testButton = NSButton(title: "Test", target: nil, action: nil)
        testButton.translatesAutoresizingMaskIntoConstraints = false

        // Save button
        saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail

        // Locked label (hidden by default)
        lockedLabel = NSTextField(labelWithString: "Locked during recording")
        lockedLabel.translatesAutoresizingMaskIntoConstraints = false
        lockedLabel.font = .systemFont(ofSize: 11)
        lockedLabel.textColor = .systemOrange
        lockedLabel.isHidden = true

        // Wire targets after all stored properties are initialized
        testButton.target = self
        testButton.action = #selector(testTapped)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(urlField)
        container.addSubview(testButton)
        container.addSubview(saveButton)
        container.addSubview(statusLabel)
        container.addSubview(lockedLabel)
        panel.contentView = container

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            urlField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            urlField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            urlField.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -8),

            testButton.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            testButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            testButton.widthAnchor.constraint(equalToConstant: 60),

            statusLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            lockedLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 8),
            lockedLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
    }

    func show() {
        guard let recorder else { return }
        urlField.stringValue = recorder.liveSummaryURL
        statusLabel.stringValue = ""

        let locked = recorder.isRecording
        urlField.isEditable = !locked
        testButton.isEnabled = !locked
        saveButton.isEnabled = !locked
        lockedLabel.isHidden = !locked

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func testTapped() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Please enter a URL"
            return
        }
        guard let baseURL = URL(string: raw) else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Invalid URL format"
            return
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing…"
        testButton.isEnabled = false

        Task { @MainActor [weak self] in
            guard let self else { return }
            let (success, message) = await Self.testConnection(baseURL: baseURL)
            self.statusLabel.textColor = success ? .systemGreen : .systemRed
            self.statusLabel.stringValue = message
            self.testButton.isEnabled = true
        }
    }

    @objc private func saveTapped() {
        guard let recorder else { return }
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        recorder.liveSummaryURL = raw
        hide()
    }

    private static func testConnection(baseURL: URL) async -> (success: Bool, message: String) {
        let endpoint = baseURL.appendingPathComponent("/api/live-summary")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        let body: [String: Any] = [
            "sessionId": "test",
            "transcriptText": "",
            "elapsedSec": 1,
            "isFinal": false,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                return (true, "Server reachable (HTTP \(http.statusCode))")
            }
            return (true, "Server reachable")
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return (false, "Timeout — server did not respond")
            case .cannotConnectToHost:
                return (false, "Cannot connect to host")
            case .cannotFindHost:
                return (false, "Cannot find host — check URL")
            default:
                return (false, error.localizedDescription)
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
