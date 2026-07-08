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

        let urlLabel = NSTextField(labelWithString: "Server URL:")
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .systemFont(ofSize: 13)

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
        container.addSubview(urlLabel)
        container.addSubview(urlField)
        container.addSubview(testButton)
        container.addSubview(saveButton)
        container.addSubview(statusLabel)
        container.addSubview(lockedLabel)
        panel.contentView = container

        NSLayoutConstraint.activate([
            urlLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            urlLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            urlField.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 8),
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
        let validation = Self.validateSummaryURL(raw, allowEmpty: false)
        if let error = validation.error {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error
            return
        }
        guard let baseURL = validation.url else { return }

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
        let validation = Self.validateSummaryURL(raw, allowEmpty: true)
        if let error = validation.error {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error
            return
        }
        recorder.liveSummaryURL = raw
        hide()
    }

    private static func validateSummaryURL(_ raw: String, allowEmpty: Bool) -> (url: URL?, error: String?) {
        if raw.isEmpty {
            return allowEmpty ? (nil, nil) : (nil, "Please enter a URL")
        }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              let url = components.url else {
            return (nil, "Invalid URL format")
        }

        if scheme == "https" {
            return (url, nil)
        }
        if scheme == "http", isLocalHost(host) {
            return (url, nil)
        }
        return (nil, "Use HTTPS, except for localhost testing")
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
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
            "meetingType": "general",
            "isFinal": false,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    return (true, "Server OK (HTTP \(http.statusCode))")
                }
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = body?.isEmpty == false ? ": \(body!)" : ""
                return (false, "Server returned HTTP \(http.statusCode)\(suffix)")
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
