import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Combine
import UserNotifications

class AudioRecorder: NSObject, ObservableObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var useMicrophone: Bool {
        didSet { UserDefaults.standard.set(useMicrophone, forKey: "useMicrophone") }
    }
    @Published var saveDirectory: URL {
        didSet { UserDefaults.standard.set(saveDirectory.path, forKey: "saveDirectory") }
    }
    @Published var systemAudioLevel: Float = 0
    @Published var micAudioLevel: Float = 0
    @Published var selectedMicID: String? {
        didSet { UserDefaults.standard.set(selectedMicID, forKey: "selectedMicID") }
    }

    /// Fan-out of the post-mixed audio for live captions.
    /// Called from the SCStream audio queue (NOT main). The closure receives
    /// Float32 mono samples downsampled to 16 kHz along with that sample rate.
    /// Nil by default; AppDelegate wires this up when captions are enabled.
    var onPCMChunk: (([Float], Double) -> Void)?

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

    override init() {
        self.useMicrophone = UserDefaults.standard.object(forKey: "useMicrophone") as? Bool ?? true
        self.selectedMicID = UserDefaults.standard.string(forKey: "selectedMicID")
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

        // Reset mic buffer
        micBufferLock.lock()
        micBuffer.removeAll()
        micBufferLock.unlock()
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

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sys-audio"))
        try await scStream.startCapture()
        self.stream = scStream
        NSLog("recorder: system audio started")

        // AVCaptureSession for mic
        if useMicrophone {
            setupMicCapture()
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

        if let url = savedURL { sendNotification(filename: url.lastPathComponent) }
    }

    // MARK: - Mic capture

    private func setupMicCapture() {
        let session = AVCaptureSession()
        let mic: AVCaptureDevice?
        if let id = selectedMicID {
            mic = AVCaptureDevice(uniqueID: id)
        } else {
            mic = AVCaptureDevice.default(for: .audio)
        }
        guard let micDevice = mic,
              let micSource = try? AVCaptureDeviceInput(device: micDevice) else {
            NSLog("recorder: failed to open mic")
            return
        }
        NSLog("recorder: mic = \(micDevice.localizedName)")
        session.addInput(micSource)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "mic-audio"))
        session.addOutput(audioOutput)
        session.startRunning()
        self.captureSession = session
        NSLog("recorder: mic capture started")
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

        // Mix mic audio into system audio buffer
        if useMicrophone {
            if let mixed = mixMicInto(interleaved) {
                input.append(mixed)
            } else {
                input.append(interleaved)
            }
        } else {
            input.append(interleaved)
        }

        // Fan out to live captions (no-op if callback is nil)
        if let onPCM = onPCMChunk, let samples = Self.convertToFloat32Mono16k(sampleBuffer) {
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
