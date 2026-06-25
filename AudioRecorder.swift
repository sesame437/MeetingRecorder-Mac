import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Combine
import UserNotifications
import IOKit.pwr_mgt

// `@unchecked Sendable`: every mutable field below is either confined to the
// main queue (the @Published ones) or guarded by `micBufferLock`. Crossing
// queue boundaries via Timer / DispatchQueue.main.async would otherwise trip
// Swift 6 strict-concurrency warnings on every `self` capture.
class AudioRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var useMicrophone: Bool {
        didSet { UserDefaults.standard.set(useMicrophone, forKey: "useMicrophone") }
    }
    @Published var captionsEnabled: Bool {
        didSet { UserDefaults.standard.set(captionsEnabled, forKey: "captionsEnabled") }
    }
    /// User-controlled toggle for the verbatim transcription pipeline.
    /// Default false — the feature is opt-in. When toggled mid-recording,
    /// AppDelegate spins up (or tears down) the whisper-server + writer
    /// live, with a state machine to gate the transition (see
    /// `VerbatimPipelineState`).
    @Published var verbatimEnabled: Bool {
        didSet { UserDefaults.standard.set(verbatimEnabled, forKey: "verbatimEnabled") }
    }
    @Published var saveDirectory: URL {
        didSet { UserDefaults.standard.set(saveDirectory.path, forKey: "saveDirectory") }
    }
    @Published var systemAudioLevel: Float = 0
    @Published var micAudioLevel: Float = 0
    @Published var selectedMicID: String? {
        didSet { UserDefaults.standard.set(selectedMicID, forKey: "selectedMicID") }
    }
    /// Caption / verbatim transcription language. One of "auto", "zh", "en".
    /// Controls both the existing `Enable Live Captions` panel (future) and the
    /// new verbatim transcription pipeline. Persisted across launches.
    @Published var captionLanguage: String {
        didSet { UserDefaults.standard.set(captionLanguage, forKey: "captionLanguage") }
    }
    @Published var liveSummaryURL: String {
        didSet { UserDefaults.standard.set(liveSummaryURL, forKey: "liveSummaryURL") }
    }

    /// Fan-out of the post-mixed audio for live captions.
    /// Called from the SCStream audio queue (NOT main). The closure receives
    /// Float32 mono samples downsampled to 16 kHz along with that sample rate.
    /// Nil by default; AppDelegate wires this up when captions are enabled.
    var onPCMChunk: (([Float], Double) -> Void)?

    /// Fired on main when the underlying SCStream stops with an error
    /// (system audio capture got interrupted by macOS — display lock,
    /// permission re-prompt, audio HAL re-route, etc.). AppDelegate uses
    /// this to surface a notification and tear down the recording, so we
    /// don't silently end up with a half-length mp4 like Daisy's 4:17
    /// cutoff during commit 1 testing.
    var onStreamInterrupted: ((Error) -> Void)?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?  // single mixed track
    private var captureSession: AVCaptureSession?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var currentOutputURL: URL?
    private var sessionStarted = false

    // Mic mixing buffer: stores recent mic samples (float32 mono 48kHz)
    // Protected by micBufferLock
    private var micBuffer = [Float32]()
    private let micBufferLock = NSLock()
    private var micConverter: AVAudioConverter?
    private let targetSampleRate: Double = 48000

    /// Power assertion that prevents macOS idle sleep while recording.
    /// Created in startRecording(), released in stopRecording().
    private var sleepAssertionID: IOPMAssertionID = 0
    private var sleepAssertionActive = false

    /// Set when the user explicitly picks a mic from our menu during a
    /// session. While true, the system-default-input watcher won't override
    /// the choice — otherwise plugging in a USB headset (or other system
    /// routing change) would yank the recording away from what the user
    /// just selected. Reset on every recording start/stop so each session
    /// begins with auto-follow re-enabled.
    private var userPinnedMic = false

    override init() {
        self.useMicrophone = UserDefaults.standard.object(forKey: "useMicrophone") as? Bool ?? true
        self.captionsEnabled = UserDefaults.standard.object(forKey: "captionsEnabled") as? Bool ?? false
        self.verbatimEnabled = UserDefaults.standard.object(forKey: "verbatimEnabled") as? Bool ?? false
        self.selectedMicID = UserDefaults.standard.string(forKey: "selectedMicID")
        self.captionLanguage = UserDefaults.standard.string(forKey: "captionLanguage") ?? "auto"
        self.liveSummaryURL = UserDefaults.standard.string(forKey: "liveSummaryURL") ?? ""
        if let path = UserDefaults.standard.string(forKey: "saveDirectory") {
            self.saveDirectory = URL(fileURLWithPath: path)
        } else {
            self.saveDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        }
        super.init()
    }

    /// Current recording destination, or nil if not recording.
    func currentRecordingURL() -> URL? { currentOutputURL }

    // MARK: - Device listing

    static func availableMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    // MARK: - Public

    func startRecording() async throws {
        // Each session starts with auto-follow re-enabled.
        userPinnedMic = false
        if useMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            NSLog("recorder: mic permission=\(granted)")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        // Output file
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "Recording-\(formatter.string(from: Date())).mp4"
        let outputURL = saveDirectory.appendingPathComponent(filename)
        currentOutputURL = outputURL

        // AVAssetWriter — single audio track
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        self.sessionStarted = false
        self.assetWriter = writer
        self.audioWriterInput = input

        // Reset mic buffer. Use `withLock` so this stays valid in an async
        // context — `lock()/unlock()` is unavailable from async in Swift 6.
        micBufferLock.withLock { micBuffer.removeAll() }
        micConverter = nil

        // SCKit for system audio
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.captureMicrophone = false
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sys-audio"))
        try await scStream.startCapture()
        self.stream = scStream
        NSLog("recorder: system audio started")

        // AVCaptureSession for mic
        if useMicrophone {
            setupMicCapture()
        }

        // Prevent macOS from sleeping due to idle while recording.
        // Without this, the system suspends SCStream after the idle
        // timeout and our recording gets cut short.
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MeetingRecorder is recording audio" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            sleepAssertionID = assertionID
            sleepAssertionActive = true
            NSLog("recorder: idle-sleep assertion created (id=\(assertionID))")
        }

        recordingStartTime = Date()
        isRecording = true
        await MainActor.run {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    func stopRecording() async {
        try? await stream?.stopCapture()
        stream = nil
        captureSession?.stopRunning()
        captureSession = nil

        await MainActor.run { timer?.invalidate(); timer = nil }

        audioWriterInput?.markAsFinished()
        await assetWriter?.finishWriting()

        if let w = assetWriter, w.status == .failed {
            NSLog("recorder: writer failed: \(w.error?.localizedDescription ?? "?")")
        }

        let savedURL = currentOutputURL
        assetWriter = nil
        audioWriterInput = nil
        currentOutputURL = nil
        isRecording = false
        elapsedTime = 0
        systemAudioLevel = 0
        micAudioLevel = 0
        userPinnedMic = false

        // Release the idle-sleep assertion so macOS can sleep normally.
        if sleepAssertionActive {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionActive = false
            NSLog("recorder: idle-sleep assertion released")
        }

        if let url = savedURL { sendNotification(filename: url.lastPathComponent) }
    }

    // MARK: - Mic capture

    /// Resolve which microphone to use, falling back through a chain so we
    /// never silently fail when the user's previously-selected device has
    /// disappeared (e.g., headphones unplugged, BT disconnected).
    ///
    /// Order:
    ///   1. selectedMicID if its device is still present
    ///   2. the built-in "MacBook Pro Microphone" (or any device whose name
    ///      contains "Built-In" / "Built-in" / "内置麦克风")
    ///   3. AVCaptureDevice.default(for: .audio) — whatever the system default is
    ///   4. any mic discovered via DiscoverySession
    /// Run the fallback chain and persist the result to `selectedMicID`, so
    /// the menu's tick mark and the eventual recording path agree on which
    /// mic is current — even before the user starts recording. Call at launch
    /// and whenever the menu is about to be rebuilt.
    func ensureMicSelection() {
        guard let dev = resolveMicrophone() else { return }
        if selectedMicID != dev.uniqueID {
            selectedMicID = dev.uniqueID
        }
    }

    private func resolveMicrophone() -> AVCaptureDevice? {
        let all = Self.availableMicrophones()

        if let id = selectedMicID,
           let dev = all.first(where: { $0.uniqueID == id }) {
            return dev
        }

        if let builtIn = all.first(where: {
            let name = $0.localizedName
            return name.contains("MacBook Pro Microphone")
                || name.contains("MacBook Air Microphone")
                || name.range(of: "built-in", options: .caseInsensitive) != nil
                || name.contains("内置麦克风")
        }) {
            return builtIn
        }

        if let sysDefault = AVCaptureDevice.default(for: .audio) {
            return sysDefault
        }

        return all.first
    }

    /// Switch the active microphone. Persists the preference and, if a
    /// recording is in progress with mic enabled, swaps the input on the
    /// running AVCaptureSession in place. Without this the menu only updated
    /// UserDefaults; the live session kept the original device, so picking
    /// a different mic mid-record had no effect on what got recorded.
    ///
    /// `manual` distinguishes user-driven menu picks from the automatic
    /// system-default follower. A manual pick latches `userPinnedMic` so
    /// later auto-follow events can't yank the device away from the user's
    /// explicit choice for the rest of this session.
    func switchMicDevice(to id: String, manual: Bool = true) {
        if !manual && userPinnedMic { return }
        // Don't write through a stale or unknown UID — caller may pass us a
        // CoreAudio device that isn't a capture device (output-only,
        // aggregate, etc.).
        guard Self.availableMicrophones().contains(where: { $0.uniqueID == id }) else {
            NSLog("recorder: switchMicDevice — unknown device UID \(id)")
            return
        }
        if manual { userPinnedMic = true }
        selectedMicID = id
        guard isRecording, useMicrophone else { return }
        guard let session = captureSession else {
            setupMicCapture()
            return
        }
        if let current = session.inputs.first as? AVCaptureDeviceInput,
           current.device.uniqueID == id {
            return
        }
        guard let dev = Self.availableMicrophones().first(where: { $0.uniqueID == id }),
              let newInput = try? AVCaptureDeviceInput(device: dev) else {
            NSLog("recorder: switchMicDevice — device unavailable for \(id)")
            return
        }

        let oldInputs = session.inputs
        session.beginConfiguration()
        oldInputs.forEach { session.removeInput($0) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            session.commitConfiguration()
            // If CoreAudio interrupted us when the device topology changed
            // (common when an external mic gets auto-promoted to system
            // default), the session is no longer running. Kick it back up.
            if !session.isRunning { session.startRunning() }
            // Drop samples from the previous device so we don't briefly mix
            // both voices into the next output buffer.
            micBufferLock.lock()
            micBuffer.removeAll()
            micBufferLock.unlock()
            micConverter = nil
            NSLog("recorder: switched mic → \(dev.localizedName) [\(id)]")
        } else {
            oldInputs.forEach { if session.canAddInput($0) { session.addInput($0) } }
            session.commitConfiguration()
            NSLog("recorder: cannot add \(dev.localizedName); kept previous mic")
        }
    }

    private func setupMicCapture() {
        let session = AVCaptureSession()
        guard let micDevice = resolveMicrophone(),
              let micSource = try? AVCaptureDeviceInput(device: micDevice) else {
            NSLog("recorder: failed to open mic — no available devices")
            return
        }
        NSLog("recorder: mic = \(micDevice.localizedName) [\(micDevice.uniqueID)]")
        // If we fell back from a stale selectedMicID, sync UserDefaults so the
        // menu tick mark shows the device we actually opened.
        if selectedMicID != micDevice.uniqueID {
            selectedMicID = micDevice.uniqueID
        }
        session.addInput(micSource)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "mic-audio"))
        session.addOutput(audioOutput)
        session.startRunning()
        self.captureSession = session
        NSLog("recorder: mic capture started")
    }

    // MARK: - SCStreamDelegate (interruption / error)

    /// Called by ScreenCaptureKit on its own queue when our SCStream stops
    /// with an error — typically a macOS-side interruption (display lock,
    /// permission revoked, audio HAL re-route, the system bumping us off
    /// the capture pipeline). Without this hook the stream just goes
    /// silent and our recording quietly ends up truncated.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("recorder: SCStream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.onStreamInterrupted?(error)
        }
    }

    // MARK: - SCStreamOutput (system audio) — mix mic in here

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = assetWriter, let input = audioWriterInput else { return }

        let level = peakLevel(from: sampleBuffer)
        DispatchQueue.main.async { self.systemAudioLevel = level }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            NSLog("recorder: session started at \(pts.seconds)")
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }

        // Convert system audio to interleaved float32
        guard let interleaved = convertToInterleaved(sampleBuffer) else { return }

        // Mix mic audio into system audio buffer. Whichever buffer we feed
        // to AVAssetWriter (`outgoing`) is also what we tap for captions —
        // otherwise captions would only see system audio and miss the user's
        // own voice entirely.
        let outgoing: CMSampleBuffer
        if useMicrophone, let mixed = mixMicInto(interleaved) {
            outgoing = mixed
        } else {
            outgoing = interleaved
        }
        input.append(outgoing)

        // Fan out to live captions (no-op if callback is nil)
        if let onPCM = onPCMChunk, let samples = Self.convertToFloat32Mono16k(outgoing) {
            onPCM(samples, 16_000)
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (mic → buffer)

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let level = peakLevel(from: sampleBuffer)
        DispatchQueue.main.async { self.micAudioLevel = level }

        // Extract mic samples as float32, resample to 48kHz mono if needed
        guard let floats = extractMicSamples(from: sampleBuffer) else { return }

        micBufferLock.lock()
        micBuffer.append(contentsOf: floats)
        // Keep max 2 seconds of buffer (48000 * 2 = 96000 samples)
        if micBuffer.count > 96000 {
            micBuffer.removeFirst(micBuffer.count - 96000)
        }
        micBufferLock.unlock()
    }

    /// Extract float32 mono samples from mic CMSampleBuffer, resampled to 48kHz
    private nonisolated func extractMicSamples(from sampleBuffer: CMSampleBuffer) -> [Float32]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let totalBytes = CMBlockBufferGetDataLength(dataBuffer)
        guard totalBytes > 0 else { return nil }

        var rawData = Data(count: totalBytes)
        rawData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalBytes, destination: base)
        }

        let fmt = asbd.pointee
        let isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let numChannels = Int(fmt.mChannelsPerFrame)
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)

        // Convert to mono float32
        var monoFloats = [Float32](repeating: 0, count: numFrames)

        if isFloat {
            rawData.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Float32.self)
                if numChannels == 1 {
                    for i in 0..<numFrames { monoFloats[i] = src[i] }
                } else {
                    // Average channels
                    for i in 0..<numFrames {
                        var sum: Float32 = 0
                        for ch in 0..<numChannels { sum += src[i * numChannels + ch] }
                        monoFloats[i] = sum / Float32(numChannels)
                    }
                }
            }
        } else {
            // Assume int16
            rawData.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int16.self)
                if numChannels == 1 {
                    for i in 0..<numFrames { monoFloats[i] = Float32(src[i]) / 32768.0 }
                } else {
                    for i in 0..<numFrames {
                        var sum: Float32 = 0
                        for ch in 0..<numChannels { sum += Float32(src[i * numChannels + ch]) }
                        monoFloats[i] = sum / (32768.0 * Float32(numChannels))
                    }
                }
            }
        }

        // Simple resample if mic rate != 48kHz
        let micRate = fmt.mSampleRate
        if abs(micRate - targetSampleRate) > 1.0 {
            let ratio = targetSampleRate / micRate
            let outCount = Int(Double(numFrames) * ratio)
            var resampled = [Float32](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let srcIdx = Double(i) / ratio
                let idx0 = Int(srcIdx)
                let frac = Float32(srcIdx - Double(idx0))
                let s0 = idx0 < numFrames ? monoFloats[idx0] : 0
                let s1 = (idx0 + 1) < numFrames ? monoFloats[idx0 + 1] : s0
                resampled[i] = s0 + frac * (s1 - s0)
            }
            return resampled
        }

        return monoFloats
    }

    /// Mix mic mono samples into an interleaved stereo float32 CMSampleBuffer
    private nonisolated func mixMicInto(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let fmt = asbd.pointee
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        let numChannels = Int(fmt.mChannelsPerFrame)
        let totalBytes = CMBlockBufferGetDataLength(dataBuffer)

        // Copy system audio data
        var sysData = Data(count: totalBytes)
        sysData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalBytes, destination: base)
        }

        // Drain mic samples
        micBufferLock.lock()
        let micSamplesToTake = min(micBuffer.count, numFrames)
        let micSamples: [Float32]
        if micSamplesToTake > 0 {
            micSamples = Array(micBuffer.prefix(micSamplesToTake))
            micBuffer.removeFirst(micSamplesToTake)
        } else {
            micSamples = []
        }
        micBufferLock.unlock()

        guard !micSamples.isEmpty else { return nil } // no mic data, use original

        // Mix: add mono mic samples into both channels of stereo system audio
        let mixedSize = totalBytes
        let mixedData = UnsafeMutableRawPointer.allocate(byteCount: mixedSize, alignment: MemoryLayout<Float32>.alignment)
        let dst = mixedData.bindMemory(to: Float32.self, capacity: numFrames * numChannels)

        sysData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float32.self)
            // Copy system audio
            for i in 0..<(numFrames * numChannels) {
                dst[i] = src[i]
            }
        }

        // Add mic (mono → both stereo channels)
        let micGain: Float32 = 1.0
        for i in 0..<min(micSamplesToTake, numFrames) {
            let micSample = micSamples[i] * micGain
            for ch in 0..<numChannels {
                let idx = i * numChannels + ch
                dst[idx] = max(-1.0, min(1.0, dst[idx] + micSample))
            }
        }

        return createInterleavedSampleBuffer(
            data: mixedData, size: mixedSize,
            sampleRate: fmt.mSampleRate, numFrames: numFrames,
            numChannels: numChannels, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    // MARK: - Level measurement

    private nonisolated func peakLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return 0 }
        var data = Data(count: length)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        var peak: Float = 0
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float32.self)
            for i in 0..<min(floats.count, 480) {
                let v = abs(floats[i])
                if v > peak { peak = v }
            }
        }
        return min(peak, 1.0)
    }

    // MARK: - Non-interleaved → interleaved

    private nonisolated func convertToInterleaved(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let fmt = asbd.pointee
        if (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 { return sampleBuffer }

        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        let numChannels = Int(fmt.mChannelsPerFrame)
        guard numFrames > 0, numChannels > 0 else { return nil }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let totalBytes = CMBlockBufferGetDataLength(dataBuffer)
        var rawData = Data(count: totalBytes)
        rawData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalBytes, destination: base)
        }

        let interleavedSize = numFrames * numChannels * MemoryLayout<Float32>.size
        let interleavedData = UnsafeMutableRawPointer.allocate(byteCount: interleavedSize, alignment: MemoryLayout<Float32>.alignment)
        let dst = interleavedData.bindMemory(to: Float32.self, capacity: numFrames * numChannels)

        let framesPerChannel = totalBytes / (numChannels * MemoryLayout<Float32>.size)
        rawData.withUnsafeBytes { srcRaw in
            let src = srcRaw.bindMemory(to: Float32.self)
            if framesPerChannel == numFrames {
                // Contiguous channel blocks (OBS-style)
                for ch in 0..<numChannels {
                    let chOffset = ch * numFrames
                    for i in 0..<numFrames {
                        dst[i * numChannels + ch] = src[chOffset + i]
                    }
                }
            } else {
                // AudioBufferList style — try ABL approach
                // Fallback: treat as flat and interleave naively
                let totalFloats = totalBytes / MemoryLayout<Float32>.size
                for i in 0..<min(numFrames * numChannels, totalFloats) {
                    dst[i] = src[i]
                }
            }
        }

        return createInterleavedSampleBuffer(
            data: interleavedData, size: interleavedSize,
            sampleRate: fmt.mSampleRate, numFrames: numFrames,
            numChannels: numChannels, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    private nonisolated func createInterleavedSampleBuffer(data: UnsafeMutableRawPointer, size: Int,
                                                            sampleRate: Float64, numFrames: Int,
                                                            numChannels: Int, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(numChannels * MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(numChannels * MemoryLayout<Float32>.size),
            mChannelsPerFrame: UInt32(numChannels), mBitsPerChannel: 32, mReserved: 0
        )
        var fd: CMAudioFormatDescription? = nil
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard let formatDesc = fd else { data.deallocate(); return nil }

        var bb: CMBlockBuffer? = nil
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: data, blockLength: size,
                                            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                            offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &bb)
        guard let blockBuf = bb else { data.deallocate(); return nil }

        var sb: CMSampleBuffer? = nil
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                         presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: nil, dataBuffer: blockBuf, dataReady: true, makeDataReadyCallback: nil,
                              refcon: nil, formatDescription: formatDesc, sampleCount: numFrames,
                              sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                              sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        return sb
    }

    // MARK: - Notification

    private func sendNotification(filename: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Saved"
        content.body = filename
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    enum RecorderError: LocalizedError {
        case noDisplay
        var errorDescription: String? {
            switch self { case .noDisplay: return "No display found" }
        }
    }

    // MARK: - PCM tap (for live captions)

    /// Downmix a CMSampleBuffer (float32 layout at any sample rate) into
    /// Float32 mono at 16 kHz. Returns nil on any failure; the caller must
    /// treat nil as "skip this chunk" and continue.
    nonisolated private static func convertToFloat32Mono16k(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let srcFmt = asbdPtr.pointee
        guard (srcFmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else { return nil }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let totalBytes = CMBlockBufferGetDataLength(dataBuffer)
        guard totalBytes > 0 else { return nil }

        var raw = Data(count: totalBytes)
        raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalBytes, destination: base)
        }

        let numChannels = Int(srcFmt.mChannelsPerFrame)
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numChannels > 0, numFrames > 0 else { return nil }

        // Step 1: downmix to mono @ source sample rate
        var mono = [Float](repeating: 0, count: numFrames)
        raw.withUnsafeBytes { rawPtr in
            let src = rawPtr.bindMemory(to: Float.self)
            if (srcFmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 {
                // interleaved
                for i in 0..<numFrames {
                    var sum: Float = 0
                    for ch in 0..<numChannels { sum += src[i * numChannels + ch] }
                    mono[i] = sum / Float(numChannels)
                }
            } else {
                // non-interleaved: channels stored sequentially, numFrames per channel
                for i in 0..<numFrames {
                    var sum: Float = 0
                    for ch in 0..<numChannels { sum += src[ch * numFrames + i] }
                    mono[i] = sum / Float(numChannels)
                }
            }
        }

        // Step 2: resample to 16 kHz
        let srcRate = srcFmt.mSampleRate
        let dstRate: Double = 16_000
        if abs(srcRate - dstRate) < 1.0 { return mono }
        let ratio = dstRate / srcRate
        let outCount = max(1, Int(Double(numFrames) * ratio))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = idx0 < numFrames ? mono[idx0] : 0
            let s1 = (idx0 + 1) < numFrames ? mono[idx0 + 1] : s0
            out[i] = s0 + frac * (s1 - s0)
        }
        return out
    }
}
