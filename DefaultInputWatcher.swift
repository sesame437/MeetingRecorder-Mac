import Foundation
import AudioToolbox

/// Watches the macOS system "default input device" and fires `onChange`
/// whenever it flips — e.g., user plugs in a USB headset, unplugs back to
/// built-in, or changes the default in System Settings → Sound. The UID
/// passed back matches `AVCaptureDevice.uniqueID` for audio devices on
/// macOS, so callers can hand it straight to `switchMicDevice`.
final class DefaultInputWatcher {
    var onChange: ((String) -> Void)?

    private let queue = DispatchQueue(label: "default-input-watcher")
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.fireCurrent()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address, queue, block
        )
        if status == noErr {
            listener = block
        } else {
            NSLog("default-input-watcher: install failed status=\(status)")
        }
    }

    func stop() {
        guard let block = listener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address, queue, block
        )
        listener = nil
    }

    /// Read once, e.g. at app launch to align before any event fires.
    func currentDefaultInputUID() -> String? { Self.lookupDefaultInputUID() }

    private func fireCurrent() {
        guard let uid = Self.lookupDefaultInputUID() else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(uid) }
    }

    private static func lookupDefaultInputUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let s1 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        )
        guard s1 == noErr, deviceID != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let s2 = AudioObjectGetPropertyData(
            deviceID, &uidAddr, 0, nil, &uidSize, &uid
        )
        guard s2 == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    deinit { stop() }
}
