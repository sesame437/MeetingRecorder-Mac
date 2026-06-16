import AppKit
import Combine
import AVFoundation
import UserNotifications

/// Lifecycle of the verbatim transcription pipeline within a single
/// recording session. Independent of `recorder.verbatimEnabled`, which is
/// the user's *intent*; this enum is the *runtime reality*.
enum VerbatimPipelineState {
    case idle               // not running (recording off, or recording on with toggle off)
    case starting           // whisper-server spawn / writer init in progress
    case transcribing       // pipeline live
    case failed(String)     // spawn failed; click toggle again to retry
    case stopping           // tear-down in progress
}

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
    // Verbatim transcript pipeline. All three are nil when not recording, or
    // when the pipeline failed to start (soft-fail per the agreed contract).
    private var whisperServer: WhisperServerProcess?
    private var verbatimWriter: VerbatimWriter?
    private var verbatimTranscriber: VerbatimTranscriber?
    private var verbatimPipelineState: VerbatimPipelineState = .idle
    // Stashed session info so toggleVerbatim can build a writer with the
    // correct `started_at` (mp4 origin) when verbatim is enabled mid-record.
    private var recordingSessionStart: Date?
    private var recordingSessionId: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Request notification permission up-front. Without this, the
        // soft-fail path's `postVerbatimUnavailable` is silently dropped
        // by macOS — the user has no idea verbatim died (this exact
        // pitfall hit Daisy during commit 1 testing).
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

        // Update menu every 0.5s during recording (for timer + levels)
        recorder.$elapsedTime
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.rebuildMenu() }
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
        // the normal stop path so the mp4 / .verbatim.md / NotesWriter
        // get finalized cleanly.
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

        // Verbatim transcript toggle — the menu's text reflects both the
        // user's intent (verbatimEnabled) and the runtime state of the
        // pipeline (verbatimPipelineState). Disabled while transitioning
        // so rapid double-clicks can't race the spawn / teardown.
        let (verbatimTitle, verbatimEnabled) = self.verbatimMenuItemDisplay()
        let verbatimToggle = NSMenuItem(title: verbatimTitle,
                                        action: #selector(toggleVerbatim),
                                        keyEquivalent: "")
        verbatimToggle.target = self
        verbatimToggle.state = recorder.verbatimEnabled ? .on : .off
        verbatimToggle.isEnabled = verbatimEnabled
        menu.addItem(verbatimToggle)

        // Caption Language submenu — only meaningful when verbatim is
        // enabled (LiveCaptions still uses small.en hard-coded). Hidden
        // when verbatim is off to reduce menu noise.
        if recorder.verbatimEnabled {
            let langMenu = NSMenu()
            let currentLang = recorder.captionLanguage
            for code in ["auto", "zh", "en"] {
                let item = NSMenuItem(title: Self.languageLabel(for: code),
                                      action: #selector(setCaptionLanguage(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = code
                item.state = (code == currentLang) ? .on : .off
                langMenu.addItem(item)
            }
            let langItem = NSMenuItem(title: "Caption Language", action: nil, keyEquivalent: "")
            langItem.submenu = langMenu
            menu.addItem(langItem)
        }

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
                guard let recordingURL = recorder.currentRecordingURL() else {
                    NSLog("[AppDelegate] no recording URL; skipping caption / verbatim setup")
                    return
                }
                let sessionStart = Date()
                let sessionId = UUID()
                let mdURL = recordingURL.deletingPathExtension().appendingPathExtension("md")

                // Stash session info so a mid-recording verbatim toggle ON
                // can build a writer with the correct mp4-anchored
                // `started_at` and reuse the same session_id / notes URL.
                self.recordingSessionStart = sessionStart
                self.recordingSessionId = sessionId

                // 1) Verbatim pipeline — only if user has the toggle on.
                //    Failure here doesn't abort the recording (soft-fail).
                if recorder.verbatimEnabled {
                    await self.startVerbatimPipeline(
                        recordingURL: recordingURL,
                        notesURL: mdURL,
                        sessionStart: sessionStart,
                        sessionId: sessionId
                    )
                }

                // 2) Live captions branch (existing behavior, gated on toggle).
                if recorder.captionsEnabled {
                    self.startLiveCaptionsBranch(
                        recordingURL: recordingURL,
                        mdURL: mdURL,
                        sessionStart: sessionStart,
                        sessionId: sessionId
                    )
                }

                // 3) Fan out PCM samples. Done unconditionally so a
                //    mid-recording verbatim toggle ON can attach without
                //    re-wiring; the closure null-checks each consumer.
                self.wireFanOut()

                // 4) Captions need an explicit start() once the fan-out is in
                //    place, since LiveCaptions.start() loads the WhisperKit
                //    model asynchronously.
                if let lc = self.liveCaptions {
                    do {
                        try await lc.start(sessionStart: sessionStart)
                    } catch {
                        NSLog("[AppDelegate] WhisperKit load failed: \(error)")
                        self.captionPanel?.showOffline("captions unavailable — model load failed")
                    }
                }

                // 5) Summary client. Init is failable: returns nil when
                //    LIVE_SUMMARY_URL is unset, so we just skip the
                //    feature instead of pointing the timer at thin air.
                //    Captions + verbatim continue regardless.
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
                    summary.start(intervalSec: 180)
                } else if recorder.captionsEnabled {
                    self.captionPanel?.showOffline("summary unavailable — set LIVE_SUMMARY_URL")
                }
            } catch {
                NSLog("Recording failed: \(error)")
            }
        }
    }

    /// Spin up whisper-server + VerbatimTranscriber + VerbatimWriter. Used
    /// both at recording start (when `verbatimEnabled` is on) and from
    /// `toggleVerbatim` mid-record. Updates `verbatimPipelineState` so the
    /// menu reflects starting → transcribing or starting → failed.
    /// Caller is responsible for setting state to `.starting` and calling
    /// `rebuildMenu()` BEFORE invoking this; this function transitions to
    /// `.transcribing` or `.failed(...)` on completion.
    @MainActor
    private func startVerbatimPipeline(recordingURL: URL,
                                       notesURL: URL?,
                                       sessionStart: Date,
                                       sessionId: UUID) async {
        let language = recorder.captionLanguage
        // verbatim_started_at is "now" — this is when transcription
        // actually began, possibly long after the recording started.
        let verbatimStartedAt = Date()
        let initialOffsetSec = max(0, verbatimStartedAt.timeIntervalSince(sessionStart))

        let server = WhisperServerProcess()
        do {
            try await server.start(language: language)
        } catch {
            NSLog("[AppDelegate] whisper-server start failed: \(error.localizedDescription)")
            self.postVerbatimUnavailable(reason: error.localizedDescription)
            self.verbatimPipelineState = .failed(error.localizedDescription)
            self.rebuildMenu()
            return
        }
        self.whisperServer = server

        // base path: <savedir>/Recording-YYYY-MM-DD-HHMMSS  (no extension)
        let basePath = recordingURL.deletingPathExtension().path
        let verbatimURL = URL(fileURLWithPath: basePath + ".verbatim.md")

        let writer = VerbatimWriter(
            verbatimURL: verbatimURL,
            recordingURL: recordingURL,
            notesURL: notesURL,
            startedAt: sessionStart,
            verbatimStartedAt: verbatimStartedAt,
            sessionId: sessionId,
            config: VerbatimWriter.Config(
                language: language,
                engine: "whisper.cpp/ggml-large-v3-turbo",
                algo: "LocalAgreement-2",
                chunkWindowSec: 1.0,
                trimWindowSec: 15.0
            )
        )
        let transcriber = VerbatimTranscriber(server: server, writer: writer, language: language)
        do {
            try transcriber.start(sessionStart: sessionStart, initialOffsetSec: initialOffsetSec)
        } catch {
            NSLog("[AppDelegate] verbatim writer preamble failed: \(error)")
            self.postVerbatimUnavailable(reason: "could not write \(verbatimURL.lastPathComponent)")
            server.stop()
            self.whisperServer = nil
            self.verbatimPipelineState = .failed("could not write \(verbatimURL.lastPathComponent)")
            self.rebuildMenu()
            return
        }
        self.verbatimWriter = writer
        self.verbatimTranscriber = transcriber
        self.verbatimPipelineState = .transcribing
        self.rebuildMenu()
        NSLog("[AppDelegate] verbatim pipeline ready → \(verbatimURL.lastPathComponent) (offset=\(initialOffsetSec)s)")
    }

    /// Idempotent verbatim teardown — used both by stopRecording (full
    /// session end) and by toggleVerbatim OFF (mid-record disable). Safe
    /// to call when no pipeline is active. Final force-commit of any
    /// unconfirmed audio happens here per the Stop-semantics decision.
    @MainActor
    private func tearDownVerbatim(stampVerbatimEnded: Bool) async {
        // Snapshot the live trio so we can null them out before the
        // awaits — prevents duplicate teardown if stopRecording races
        // with toggle OFF.
        let transcriber = self.verbatimTranscriber
        let writer = self.verbatimWriter
        let server = self.whisperServer
        self.verbatimTranscriber = nil
        self.verbatimWriter = nil
        self.whisperServer = nil

        guard transcriber != nil || writer != nil || server != nil else { return }

        await transcriber?.flush()
        transcriber?.stop()
        if stampVerbatimEnded {
            try? writer?.setVerbatimEnded(Date())
        }
        server?.stop()
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
            self.verbatimTranscriber?.append(samples, sampleRate: rate)
        }
    }

    private func postVerbatimUnavailable(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Verbatim transcript unavailable"
        content.body = reason
        content.sound = nil
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            // Stop accepting audio first so neither pipeline gets new samples
            // mid-shutdown.
            self.recorder.onPCMChunk = nil

            // Verbatim teardown — force-commit pending buffer (stop
            // semantics), then kill whisper-server. Stamp ended_at on
            // the writer if it's still alive, before tearing it down.
            // `setEnded` mirrors itself into verbatim_ended_at when that
            // hasn't already been stamped (the toggle-OFF-mid-record
            // case stamped it earlier).
            try? self.verbatimWriter?.setEnded(Date())
            await self.tearDownVerbatim(stampVerbatimEnded: false)
            self.verbatimPipelineState = .idle

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

    @objc private func toggleVerbatim() {
        // Defensive gate — menu item is disabled during transitions, but
        // accept-and-ignore in case of timing edge cases.
        switch verbatimPipelineState {
        case .starting, .stopping: return
        default: break
        }

        // Failed-state click means "retry" — intent is already ON, just
        // re-spawn the pipeline. Don't flip verbatimEnabled.
        if case .failed = verbatimPipelineState {
            guard recorder.isRecording,
                  let recordingURL = recorder.currentRecordingURL(),
                  let sessionStart = recordingSessionStart,
                  let sessionId = recordingSessionId else {
                // Recording stopped between failure and retry — drop to idle.
                verbatimPipelineState = .idle
                rebuildMenu()
                return
            }
            let mdURL = recordingURL.deletingPathExtension().appendingPathExtension("md")
            verbatimPipelineState = .starting
            rebuildMenu()
            Task { @MainActor in
                await self.startVerbatimPipeline(
                    recordingURL: recordingURL,
                    notesURL: mdURL,
                    sessionStart: sessionStart,
                    sessionId: sessionId
                )
            }
            return
        }

        // Regular toggle: flip user intent (UserDefaults persists immediately).
        let nowEnabled = !recorder.verbatimEnabled
        recorder.verbatimEnabled = nowEnabled

        // Not recording → just persist intent and rebuild.
        guard recorder.isRecording,
              let recordingURL = recorder.currentRecordingURL(),
              let sessionStart = recordingSessionStart,
              let sessionId = recordingSessionId else {
            rebuildMenu()
            return
        }
        let mdURL = recordingURL.deletingPathExtension().appendingPathExtension("md")

        if nowEnabled {
            // Mid-record toggle ON: spawn pipeline.
            verbatimPipelineState = .starting
            rebuildMenu()
            Task { @MainActor in
                await self.startVerbatimPipeline(
                    recordingURL: recordingURL,
                    notesURL: mdURL,
                    sessionStart: sessionStart,
                    sessionId: sessionId
                )
                // startVerbatimPipeline already updated state + rebuilt menu.
            }
        } else {
            // Mid-record toggle OFF: tear down pipeline, recording continues.
            verbatimPipelineState = .stopping
            rebuildMenu()
            Task { @MainActor in
                await self.tearDownVerbatim(stampVerbatimEnded: true)
                self.verbatimPipelineState = .idle
                self.rebuildMenu()
            }
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            recorder.switchMicDevice(to: id)
            rebuildMenu()
        }
    }

    @objc private func setCaptionLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String,
              ["auto", "zh", "en"].contains(code) else { return }
        recorder.captionLanguage = code
        rebuildMenu()
        // Note: doesn't affect a recording in progress — language is locked
        // when whisper-server spawns. Next recording will pick up the change.
    }

    /// Compute the label + click-enabled state for the verbatim menu
    /// item from the cross-product of `verbatimEnabled` (intent) and
    /// `verbatimPipelineState` (runtime).
    private func verbatimMenuItemDisplay() -> (title: String, enabled: Bool) {
        let base = "Enable Verbatim Transcript"
        let intent = recorder.verbatimEnabled
        switch verbatimPipelineState {
        case .idle:
            return (intent ? "\(base) ✓" : base, true)
        case .starting:
            return ("\(base) ✓ (starting…)", false)
        case .transcribing:
            return ("\(base) ✓ (transcribing)", true)
        case .failed:
            return ("\(base) ✓ ⚠ (unavailable — click to retry)", true)
        case .stopping:
            return ("\(base) (stopping…)", false)
        }
    }

    private static func languageLabel(for code: String) -> String {
        switch code {
        case "auto": return "Auto-detect"
        case "zh":   return "Chinese (中文)"
        case "en":   return "English"
        default:     return code
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
