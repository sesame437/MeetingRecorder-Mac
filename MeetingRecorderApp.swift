import AppKit
import Combine
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private var cancellables = Set<AnyCancellable>()
    private var liveCaptions: LiveCaptions?
    private var captionPanel: CaptionPanel?
    private var transcriptBuffer: TranscriptBuffer?
    private var notesWriter: NotesWriter?
    private var summaryClient: SummaryClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()

        // Update icon when recording state changes
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.rebuildMenu() }
            .store(in: &cancellables)

        // Update menu every 0.5s during recording (for timer + levels)
        recorder.$elapsedTime
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
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
            let stopItem = NSMenuItem(title: "Stop Recording (\(time))", action: #selector(stopRecording), keyEquivalent: "")
            stopItem.target = self
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
                guard recorder.captionsEnabled else { return }

                guard let recordingURL = recorder.currentRecordingURL() else {
                    NSLog("[AppDelegate] no recording URL; skipping caption setup")
                    return
                }
                let sessionStart = Date()
                let sessionId = UUID()
                let mdURL = recordingURL.deletingPathExtension().appendingPathExtension("md")

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
                recorder.onPCMChunk = { samples, rate in
                    lc.append(samples, sampleRate: rate)
                }
                do {
                    try await lc.start(sessionStart: sessionStart)
                } catch {
                    NSLog("[AppDelegate] WhisperKit load failed: \(error)")
                    panel.showOffline("captions unavailable — model load failed")
                    return
                }

                let summary = SummaryClient(sessionId: sessionId, buffer: buffer, sessionStart: sessionStart)
                self.summaryClient = summary
                summary.onSummary = { [weak panel, weak notes] s in
                    panel?.renderSummary(s)
                    try? notes?.updateSummary(s)
                }
                summary.onOffline = { [weak panel] reason in
                    panel?.showOffline(reason)
                }
                summary.start(intervalSec: 180)
            } catch {
                NSLog("Recording failed: \(error)")
            }
        }
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            await self.liveCaptions?.flush()
            self.liveCaptions?.stop()
            self.recorder.onPCMChunk = nil
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
            recorder.selectedMicID = id
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
