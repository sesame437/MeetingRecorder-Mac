import AppKit
import Combine
import AVFoundation
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let defaultInputWatcher = DefaultInputWatcher()
    private var cancellables = Set<AnyCancellable>()
    private var liveCaptions: LiveCaptions?
    private var captionPanel: CaptionPanel?
    private var transcriptBuffer: TranscriptBuffer?
    private var notesWriter: NotesWriter?
    private var summaryClient: SummaryClient?
    private var recordingSessionStart: Date?
    private var recordingSessionId: UUID?
    private var summaryServerPanel: SummaryServerPanel?
    private var isStoppingSession = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error = error {
                NSLog("[AppDelegate] notification auth error: \(error)")
            } else if !granted {
                NSLog("[AppDelegate] notification auth denied — soft-fails will be silent")
            }
        }
        // Resolve mic via the fallback chain before drawing the menu, so a
        // stale selectedMicID (e.g., headphones unplugged since last launch)
        // doesn't leave the submenu with nothing ticked.
        recorder.ensureMicSelection()
        updateIcon()
        rebuildMenu()

        // Update icon when recording state changes
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.rebuildMenu() }
            .store(in: &cancellables)

        // Rebuild menu when summary server URL changes (after panel Save)
        recorder.$liveSummaryURL
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.statusItem.button?.isHighlighted != true else { return }
                self.rebuildMenu()
            }
            .store(in: &cancellables)

        // Update menu every 0.5s during recording (for timer + levels)
        recorder.$elapsedTime
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.statusItem.button?.isHighlighted != true else { return }
                self.rebuildMenu()
            }
            .store(in: &cancellables)

        // Auto-follow the macOS system default input device. Plugging in
        // a USB headset (or any system-level routing change) bumps our
        // selectedMicID and, if currently recording, swaps the live
        // capture session over to the new device. Suppressed once the
        // user manually picks a mic from our menu — see `userPinnedMic`.
        defaultInputWatcher.onChange = { [weak self] uid in
            guard let self else { return }
            self.recorder.switchMicDevice(to: uid, manual: false)
            self.rebuildMenu()
        }
        defaultInputWatcher.start()
        if let uid = defaultInputWatcher.currentDefaultInputUID() {
            recorder.switchMicDevice(to: uid, manual: false)
            rebuildMenu()
        }

        // SCStream interruption: macOS killed our system-audio capture
        // (display lock, perm re-prompt, etc.). Notify the user and run
        // the normal stop path so the mp4 / NotesWriter get finalized cleanly.
        recorder.onStreamInterrupted = { [weak self] error in
            guard let self else { return }
            self.postStreamInterruptedNotice(error: error)
            self.stopRecording()
        }
    }

    private func postStreamInterruptedNotice(error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped — system audio capture interrupted"
        content.body = "macOS interrupted the screen-audio stream (\(error.localizedDescription)). Your recording was finalized at the moment of interruption."
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func updateIcon() {
        let name = recorder.isRecording ? "record.circle.fill" : "mic.fill"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "MeetingRecorder") {
            image.size = NSSize(width: 18, height: 18)
            if recorder.isRecording {
                let config = NSImage.SymbolConfiguration(paletteColors: [.red])
                statusItem.button?.image = image.withSymbolConfiguration(config)
            } else {
                statusItem.button?.image = image
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Record / Stop
        if recorder.isRecording {
            let time = formattedTime(recorder.elapsedTime)
            let title = isStoppingSession ? "Finalizing Recording..." : "Stop Recording (\(time))"
            let stopItem = NSMenuItem(title: title, action: #selector(stopRecording), keyEquivalent: "")
            stopItem.target = self
            stopItem.isEnabled = !isStoppingSession
            menu.addItem(stopItem)

            menu.addItem(.separator())

            // Audio levels
            let sysBar = levelBar(recorder.systemAudioLevel)
            let sysItem = NSMenuItem(title: "System Audio:  \(sysBar)", action: nil, keyEquivalent: "")
            sysItem.isEnabled = false
            menu.addItem(sysItem)

            if recorder.useMicrophone {
                let micBar = levelBar(recorder.micAudioLevel)
                let micItem = NSMenuItem(title: "Microphone:    \(micBar)", action: nil, keyEquivalent: "")
                micItem.isEnabled = false
                menu.addItem(micItem)
            }
        } else {
            let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        // Mic toggle
        let micToggle = NSMenuItem(title: "Record Microphone", action: #selector(toggleMic), keyEquivalent: "")
        micToggle.target = self
        micToggle.state = recorder.useMicrophone ? .on : .off
        menu.addItem(micToggle)

        // Live captions toggle
        let capToggle = NSMenuItem(title: "Enable Live Captions", action: #selector(toggleCaptions), keyEquivalent: "")
        capToggle.target = self
        capToggle.state = recorder.captionsEnabled ? .on : .off
        menu.addItem(capToggle)

        // Mic device selector (submenu)
        if recorder.useMicrophone {
            let micMenu = NSMenu()
            let mics = AudioRecorder.availableMicrophones()
            let currentID = recorder.selectedMicID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
            for mic in mics {
                let item = NSMenuItem(title: mic.localizedName, action: #selector(selectMic(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mic.uniqueID
                item.state = (mic.uniqueID == currentID) ? .on : .off
                micMenu.addItem(item)
            }
            let micDeviceItem = NSMenuItem(title: "Microphone Device", action: nil, keyEquivalent: "")
            micDeviceItem.submenu = micMenu
            menu.addItem(micDeviceItem)
        }

        menu.addItem(.separator())

        // Save directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortPath = recorder.saveDirectory.path.replacingOccurrences(of: home, with: "~")
        let dirItem = NSMenuItem(title: "Save to: \(shortPath)", action: #selector(chooseDirectory), keyEquivalent: "")
        dirItem.target = self
        menu.addItem(dirItem)

        // Summary server URL
        let urlDisplay = recorder.liveSummaryURL.isEmpty ? "(not configured)" : truncatedURL(recorder.liveSummaryURL)
        let summaryItem = NSMenuItem(title: "Summary Server: \(urlDisplay)", action: #selector(openSummaryServerPanel), keyEquivalent: "")
        summaryItem.target = self
        menu.addItem(summaryItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Level bar

    private func levelBar(_ level: Float) -> String {
        let blocks = Int(level * 20)
        let filled = String(repeating: "|", count: min(blocks, 20))
        let empty = String(repeating: " ", count: max(20 - blocks, 0))
        return "[\(filled)\(empty)]"
    }

    // MARK: - Actions

    @objc private func startRecording() {
        Task { @MainActor in
            do {
                try await recorder.startRecording()
                guard let recordingURL = recorder.currentRecordingURL() else {
                    NSLog("[AppDelegate] no recording URL; skipping caption setup")
                    return
                }
                let sessionStart = Date()
                let sessionId = UUID()
                let mdURL = recordingURL.deletingPathExtension().appendingPathExtension("md")

                self.recordingSessionStart = sessionStart
                self.recordingSessionId = sessionId

                if recorder.captionsEnabled {
                    self.startLiveCaptionsBranch(
                        recordingURL: recordingURL,
                        mdURL: mdURL,
                        sessionStart: sessionStart,
                        sessionId: sessionId
                    )
                }

                self.wireFanOut()

                if let lc = self.liveCaptions {
                    do {
                        try await lc.start(sessionStart: sessionStart)
                    } catch {
                        NSLog("[AppDelegate] WhisperKit load failed: \(error)")
                        self.captionPanel?.showOffline("captions unavailable — model load failed")
                    }
                }

                if recorder.captionsEnabled,
                   let buffer = self.transcriptBuffer,
                   let summary = SummaryClient(sessionId: sessionId, buffer: buffer, sessionStart: sessionStart) {
                    self.summaryClient = summary
                    summary.onSummary = { [weak self] s in
                        self?.captionPanel?.renderSummary(s)
                        try? self?.notesWriter?.updateSummary(s)
                    }
                    summary.onOffline = { [weak self] reason in
                        self?.captionPanel?.showOffline(reason)
                    }
                    summary.start(intervalSec: 180, initialDelaySec: 30)
                } else if recorder.captionsEnabled {
                    self.captionPanel?.showOffline("summary unavailable — configure Summary Server")
                }
            } catch {
                NSLog("Recording failed: \(error)")
                self.postRecordingFailedNotice(error: error)
            }
        }
    }

    @MainActor
    private func startLiveCaptionsBranch(recordingURL: URL,
                                         mdURL: URL,
                                         sessionStart: Date,
                                         sessionId: UUID) {
        let panel = CaptionPanel()
        self.captionPanel = panel
        panel.show()

        let buffer = TranscriptBuffer()
        self.transcriptBuffer = buffer
        let notes = NotesWriter(mdURL: mdURL, recordingURL: recordingURL,
                                startedAt: sessionStart, sessionId: sessionId)
        self.notesWriter = notes

        let lc = LiveCaptions()
        self.liveCaptions = lc
        lc.onCaption = { [weak panel, weak buffer, weak notes] ev in
            panel?.applyCaption(ev)
            let entry = TranscriptEntry(startSec: ev.startSec, endSec: ev.endSec, text: ev.text)
            buffer?.append(entry)
            try? notes?.appendTranscript(entry)
        }
    }

    /// Connect AudioRecorder's PCM tap to whichever consumers are alive.
    /// Captures live references so adding consumers later doesn't require
    /// re-wiring (each consumer is checked at callback time via `self`).
    @MainActor
    private func wireFanOut() {
        recorder.onPCMChunk = { [weak self] samples, rate in
            guard let self else { return }
            self.liveCaptions?.append(samples, sampleRate: rate)
        }
    }

    private func postRecordingFailedNotice(error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "Recording could not start"
        content.body = error.localizedDescription
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            guard !self.isStoppingSession else { return }
            self.isStoppingSession = true
            defer {
                self.isStoppingSession = false
                self.rebuildMenu()
            }

            // Stop accepting audio first so neither pipeline gets new samples
            // mid-shutdown.
            self.recorder.onPCMChunk = nil

            // Captions teardown.
            await self.liveCaptions?.flush()
            self.liveCaptions?.stop()
            self.liveCaptions = nil

            self.summaryClient?.stop()
            if let summary = self.summaryClient {
                do {
                    let s = try await summary.triggerFinal()
                    try? self.notesWriter?.updateSummary(s)
                    self.captionPanel?.renderSummary(s)
                } catch {
                    NSLog("[AppDelegate] final summary failed: \(error)")
                }
            }
            self.summaryClient = nil

            try? self.notesWriter?.setEnded(Date())
            self.notesWriter = nil
            self.transcriptBuffer = nil
            self.captionPanel?.hide()
            self.captionPanel = nil
            self.recordingSessionStart = nil
            self.recordingSessionId = nil
            await recorder.stopRecording()
        }
    }

    @objc private func toggleMic() {
        recorder.useMicrophone.toggle()
        rebuildMenu()
    }

    @objc private func toggleCaptions() {
        recorder.captionsEnabled.toggle()
        rebuildMenu()
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            recorder.switchMicDevice(to: id)
            rebuildMenu()
        }
    }


    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            recorder.saveDirectory = url
            rebuildMenu()
        }
    }

    @objc private func openSummaryServerPanel() {
        if summaryServerPanel == nil {
            summaryServerPanel = SummaryServerPanel(recorder: recorder)
        }
        summaryServerPanel?.show()
    }

    private func truncatedURL(_ url: String) -> String {
        url.count > 35 ? String(url.prefix(35)) + "…" : url
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func formattedTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
