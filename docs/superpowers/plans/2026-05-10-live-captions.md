# MeetingRecorder Live Captions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in English live captions and rolling-summary overlays to MeetingRecorder v2.7.0, reusing the existing AAC recording path unchanged.

**Architecture:** Single-process. WhisperKit runs in-process on a serial dispatch queue; one floating `NSPanel` shows captions on top and summary on bottom; a timer POSTs the accumulating transcript to the existing backend every 180 s. All feature code is gated on a menu-bar toggle; when the toggle is off the binary runs identically to v2.7.0.

**Tech Stack:** Swift 5.9+, macOS 15+, AppKit, ScreenCaptureKit, AVFoundation, Combine, WhisperKit (SPM), URLSession. Universal binary built via `swift build` + `lipo`.

**Spec:** `docs/superpowers/specs/2026-05-10-live-captions-design.md` in this repo.

**Working directory for all tasks:** `/Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp/`

**Environment prerequisites (user-verified):** Xcode command-line tools installed (`xcrun --show-sdk-path` returns a valid SDK). Backend from PR #2 (`sesame437/smart-meeting-notes`) reachable at `http://localhost:3300` or wherever `LIVE_SUMMARY_URL` points.

---

## Task 1: Scaffolding — git init, Package.swift, build.sh, baseline commit

Initialize a git repo at the project root, capture the v2.7.0 files as baseline, add a `Package.swift` that declares the WhisperKit SPM dependency, and rewrite `build.sh` to drive SPM instead of raw `swiftc`. At the end of this task the existing v2.7.0 behavior must still work.

**Files:**
- Create: `MeetingRecorderApp/.gitignore`
- Create: `MeetingRecorderApp/Package.swift`
- Modify: `MeetingRecorderApp/build.sh`
- Init:   git repo at `MeetingRecorderApp/`

- [ ] **Step 1: Initialize git repo**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
git init
git config user.email "meetingrecorder@local"
git config user.name "MeetingRecorder Dev"
```

- [ ] **Step 2: Write `.gitignore`**

Create `MeetingRecorderApp/.gitignore`:
```
# SPM build output
.build/
Package.resolved

# macOS
.DS_Store

# Bundles and distribution
MeetingRecorder.app/
MeetingRecorder.dmg
MeetingRecorder-v2.7.0.app/
MeetingRecorder-v2.7.0-dual-track.dmg
MeetingRecorder-v2.7.0.dmg

# WhisperKit model cache (just in case it lands inside the project dir)
WhisperKit/
```

- [ ] **Step 3: Baseline commit (capture v2.7.0 as-is)**

```bash
git add .gitignore MeetingRecorderApp.swift AudioRecorder.swift Info.plist AppIcon.icns AppIcon_preview.png generate_icon.py build.sh docs/
git commit -m "chore: baseline v2.7.0 before live captions work"
```

- [ ] **Step 4: Write `Package.swift`**

Create `MeetingRecorderApp/Package.swift`:
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: ".",
            exclude: [
                "build.sh",
                "Info.plist",
                "AppIcon.icns",
                "AppIcon_preview.png",
                "generate_icon.py",
                "MeetingRecorder-v2.7.0.app",
                "MeetingRecorder-v2.7.0-dual-track.dmg",
                "MeetingRecorder-v2.7.0.dmg",
                "MeetingRecorder.dmg",
                "docs",
            ],
            sources: [
                "MeetingRecorderApp.swift",
                "AudioRecorder.swift",
            ]
        )
    ]
)
```

Note: WhisperKit's published tags evolve; if `from: "0.9.0"` doesn't resolve, try `from: "0.7.0"` or `branch: "main"`. The task is done when `swift package resolve` succeeds.

- [ ] **Step 5: Resolve the dependency (sanity check)**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
swift package resolve
```

Expected: ends with no error; creates `Package.resolved` (which is gitignored).

If it fails with "no versions match", update the constraint in `Package.swift` (e.g. try `from: "0.7.0"` or use `branch: "main"`) and retry.

- [ ] **Step 6: Rewrite `build.sh`**

Replace `MeetingRecorderApp/build.sh` with:
```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_DIR="$SCRIPT_DIR/MeetingRecorder.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
DMG_PATH="$SCRIPT_DIR/MeetingRecorder.dmg"

# 1. Build both slices via SPM
echo "Building arm64..."
swift build -c release --arch arm64
echo "Building x86_64..."
swift build -c release --arch x86_64

# 2. Assemble .app bundle
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

ARM64_BIN=".build/arm64-apple-macosx/release/MeetingRecorder"
X86_BIN=".build/x86_64-apple-macosx/release/MeetingRecorder"
lipo -create "$ARM64_BIN" "$X86_BIN" -output "$MACOS/MeetingRecorder"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# 3. Ad-hoc sign
codesign --force --sign - --entitlements /dev/stdin "$APP_DIR" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.screen-capture</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

echo "Built: $APP_DIR"

# 4. DMG
rm -f "$DMG_PATH"
DMG_TMP="$SCRIPT_DIR/.dmg-tmp"
rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"
cp -R "$APP_DIR" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"
hdiutil create -volname "MeetingRecorder" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_TMP"
echo "DMG: $DMG_PATH"
```

Note: `com.apple.security.network.client` entitlement is added now so Task 6 (HTTPS POST to the backend) works without another codesign change.

- [ ] **Step 7: Build and verify v2.7.0 still works**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh
```

Expected: ends with `DMG: ...MeetingRecorder.dmg`. Total time on first build may be 3-10 min (WhisperKit's Core ML assets compile).

Then:
```bash
open MeetingRecorder.app
```

Manually verify:
- Menu-bar icon appears (microphone symbol)
- Clicking shows Start Recording / Record Microphone / Save to / Quit
- Click Start Recording, speak 10 s, click Stop Recording
- Notification fires, `.mp4` appears in Desktop (or the configured save dir)
- `.mp4` plays back in QuickTime

**If any of the above fails, stop and escalate — the build migration broke something.**

- [ ] **Step 8: Commit**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
git add Package.swift build.sh
git commit -m "build: migrate to SPM, add WhisperKit dependency

- Package.swift declares WhisperKit as SPM dependency
- build.sh now uses swift build (arm64 + x86_64) + lipo
- Added network.client entitlement for upcoming backend POSTs
- No source-code changes in this commit; v2.7.0 behavior unchanged"
```

---

## Task 2: AudioRecorder PCM tap

Add a read-only PCM fan-out from `AudioRecorder.stream(_:didOutputSampleBuffer:of:)`. The AAC write path is unchanged; after writing AAC, if a callback is registered we downmix the sample buffer to Float32 mono 16 kHz and invoke the callback. This task adds plumbing only — nothing consumes it yet.

**Files:**
- Modify: `MeetingRecorderApp/AudioRecorder.swift`

- [ ] **Step 1: Add the callback property**

At the top of the `AudioRecorder` class (after the `@Published` properties, before `private var stream: SCStream?`), add:
```swift
/// Fan-out of the post-mixed audio for live captions.
/// Called from the SCStream audio queue (NOT main). The closure receives
/// Float32 mono samples downsampled to 16 kHz along with that sample rate.
/// Nil by default; AppDelegate wires this up when captions are enabled.
var onPCMChunk: (([Float], Double) -> Void)?
```

- [ ] **Step 2: Add the mono-16k converter helper**

At the end of the class (before the final `}`), add a `nonisolated` static helper:
```swift
// MARK: - PCM tap (for live captions)

/// Downmix a CMSampleBuffer (any float32 layout at any sample rate) into
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
```

- [ ] **Step 3: Invoke the fan-out in the SCStream callback**

Locate the existing method `nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)`.

At the **very end** of that method (after the existing `input.append(...)` / `input.append(interleaved)` branches, outside any early-return paths), add:
```swift
// Fan out to live captions (no-op if callback is nil)
if let onPCM = onPCMChunk, let samples = Self.convertToFloat32Mono16k(sampleBuffer) {
    onPCM(samples, 16_000)
}
```

Place it at the bottom of the method so that if conversion throws or returns nil, the AAC path has already completed.

- [ ] **Step 4: Build**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh
```

Expected: clean build, no warnings about the new code.

- [ ] **Step 5: Regression smoke**

```bash
open MeetingRecorder.app
```

Start Recording, speak 20 s, Stop. Verify:
- `.mp4` file produced in save dir
- plays back in QuickTime, full audio present
- no errors in Console.app from the `MeetingRecorder` process

Since `onPCMChunk` is still nil, this task must not change observable behavior.

- [ ] **Step 6: Commit**

```bash
git add AudioRecorder.swift
git commit -m "feat(audio): add onPCMChunk fan-out with mono-16k downmix

Read-only tap at the bottom of stream(_:didOutputSampleBuffer:of:).
When the callback is nil (default) the path is a no-op; AAC recording
behavior is identical to v2.7.0."
```

---

## Task 3: LiveCaptions (WhisperKit wrapper)

Add `LiveCaptions.swift` that owns a serial buffer queue, lazily loads WhisperKit's `openai_whisper-small.en` model, and emits one `CaptionEvent` every time 5 s of audio has been buffered. Wire a temporary consumer in `AppDelegate` that logs every event to Console.app so we can smoke-test the end-to-end path before building UI.

**Files:**
- Create: `MeetingRecorderApp/LiveCaptions.swift`
- Modify: `MeetingRecorderApp/Package.swift` (add the new source file)
- Modify: `MeetingRecorderApp/MeetingRecorderApp.swift` (temporary wire-up for smoke test)

- [ ] **Step 1: Create `LiveCaptions.swift`**

Write the full file at `MeetingRecorderApp/LiveCaptions.swift`:
```swift
import Foundation
import WhisperKit

// MARK: - Public types

struct CaptionEvent {
    let text: String
    let startSec: Double   // relative to session start, audio-time
    let endSec: Double
}

struct TranscriptEntry {
    let startSec: Double
    let endSec: Double
    let text: String
}

// MARK: - LiveCaptions

/// In-process WhisperKit wrapper. `append` is thread-safe; `onCaption` is always
/// invoked on the main queue. Not @MainActor — append() runs on the audio queue.
final class LiveCaptions {
    /// Invoked on DispatchQueue.main after each transcription window completes.
    var onCaption: ((CaptionEvent) -> Void)?

    private let modelName: String
    private let queue = DispatchQueue(label: "live-captions")
    private let targetRate: Double = 16_000
    private let windowSamples: Int = 16_000 * 5   // 5 s of 16 kHz mono

    private var whisper: WhisperKit?
    private var buffer: [Float] = []       // guarded by queue
    private var sessionStart: Date = .distantPast
    private var lastEmitSec: Double = 0
    private var inFlight: Bool = false     // guarded by queue
    private var stopped: Bool = true       // guarded by queue

    init(modelName: String = "openai_whisper-small.en") {
        self.modelName = modelName
    }

    /// Load WhisperKit and reset state. Throws if the model fails to load.
    /// Caller typically awaits this before the user starts speaking.
    func start(sessionStart: Date) async throws {
        let cfg = WhisperKitConfig(model: modelName)
        let instance = try await WhisperKit(cfg)
        queue.sync {
            self.whisper = instance
            self.buffer.removeAll(keepingCapacity: true)
            self.sessionStart = sessionStart
            self.lastEmitSec = 0
            self.inFlight = false
            self.stopped = false
        }
    }

    /// Append Float32 mono samples. `sampleRate` is the rate of the incoming
    /// samples. We resample to `targetRate` if necessary.
    func append(_ samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }

            let resampled: [Float]
            if abs(sampleRate - self.targetRate) < 1.0 {
                resampled = samples
            } else {
                let ratio = self.targetRate / sampleRate
                let outCount = max(1, Int(Double(samples.count) * ratio))
                var out = [Float](repeating: 0, count: outCount)
                for i in 0..<outCount {
                    let srcIdx = Double(i) / ratio
                    let idx0 = Int(srcIdx)
                    let frac = Float(srcIdx - Double(idx0))
                    let s0 = idx0 < samples.count ? samples[idx0] : 0
                    let s1 = (idx0 + 1) < samples.count ? samples[idx0 + 1] : s0
                    out[i] = s0 + frac * (s1 - s0)
                }
                resampled = out
            }
            self.buffer.append(contentsOf: resampled)
            self.maybeTranscribeWindow(isFinal: false)
        }
    }

    /// Force-transcribe whatever's left in the buffer and emit one last event.
    /// Returns when the final transcription has been dispatched to main queue.
    func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self, !self.stopped else { cont.resume(); return }
                // Drain current buffer as a final window
                let samples = self.buffer
                self.buffer.removeAll(keepingCapacity: true)
                if samples.isEmpty {
                    cont.resume()
                    return
                }
                self.transcribe(samples: samples, isFinal: true) {
                    cont.resume()
                }
            }
        }
    }

    /// Release WhisperKit and stop accepting new samples.
    func stop() {
        queue.sync {
            self.stopped = true
            self.whisper = nil
            self.buffer.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Internals (must run on `queue`)

    private func maybeTranscribeWindow(isFinal: Bool) {
        guard !inFlight else { return }
        guard buffer.count >= windowSamples else { return }
        let windowSize = buffer.count  // take everything up to now
        let samples = Array(buffer.prefix(windowSize))
        buffer.removeFirst(windowSize)
        transcribe(samples: samples, isFinal: isFinal, completion: {})
    }

    private func transcribe(samples: [Float], isFinal: Bool, completion: @escaping () -> Void) {
        guard let whisper else { completion(); return }
        inFlight = true
        let sessionStart = self.sessionStart
        let lastEmit = self.lastEmitSec

        Task.detached { [weak self] in
            defer {
                self?.queue.async {
                    self?.inFlight = false
                    completion()
                }
            }
            do {
                let results = try await whisper.transcribe(audioArray: samples)
                let text: String
                if let first = results.first {
                    text = first.text
                } else {
                    text = ""
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                let nowSec = Date().timeIntervalSince(sessionStart)
                let event = CaptionEvent(text: trimmed, startSec: lastEmit, endSec: nowSec)
                self?.queue.async { self?.lastEmitSec = nowSec }

                DispatchQueue.main.async {
                    self?.onCaption?(event)
                }
            } catch {
                NSLog("[LiveCaptions] transcribe error: \(error)")
            }
        }
    }
}
```

Note on WhisperKit API: if the SDK version resolved in Task 1 uses a different `transcribe` signature (some versions return `[TranscriptionResult]?` as optional, others non-optional), adjust the `results.first` line. The happy path is: get some `text` string out; everything else is logged and skipped.

- [ ] **Step 2: Add the file to the SPM target**

Edit `MeetingRecorderApp/Package.swift` — in the `sources: [...]` array of the `MeetingRecorder` target, add `"LiveCaptions.swift"`:
```swift
            sources: [
                "MeetingRecorderApp.swift",
                "AudioRecorder.swift",
                "LiveCaptions.swift",
            ]
```

- [ ] **Step 3: Add a temporary smoke hook in `AppDelegate`**

Edit `MeetingRecorderApp/MeetingRecorderApp.swift`. Inside the `AppDelegate` class, add a property right after `private let recorder = AudioRecorder()`:
```swift
    private var liveCaptions: LiveCaptions?
```

Modify the `@objc private func startRecording()` method. Replace its current body:
```swift
    @objc private func startRecording() {
        Task {
            do { try await recorder.startRecording() }
            catch { NSLog("Recording failed: \(error)") }
        }
    }
```
with:
```swift
    @objc private func startRecording() {
        Task {
            do {
                try await recorder.startRecording()

                // TEMP smoke hook for Task 3 — logs captions to Console
                let lc = LiveCaptions()
                self.liveCaptions = lc
                lc.onCaption = { ev in
                    NSLog("[caption] [\(ev.startSec)-\(ev.endSec)] \(ev.text)")
                }
                recorder.onPCMChunk = { samples, rate in
                    lc.append(samples, sampleRate: rate)
                }
                try await lc.start(sessionStart: Date())
            } catch {
                NSLog("Recording failed: \(error)")
            }
        }
    }
```

Modify `@objc private func stopRecording()`. Replace:
```swift
    @objc private func stopRecording() {
        Task { await recorder.stopRecording() }
    }
```
with:
```swift
    @objc private func stopRecording() {
        Task {
            await self.liveCaptions?.flush()
            self.liveCaptions?.stop()
            self.recorder.onPCMChunk = nil
            self.liveCaptions = nil
            await recorder.stopRecording()
        }
    }
```

These hooks are **temporary** and will be replaced in Task 7 by the proper opt-in flow.

- [ ] **Step 4: Build**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh
```

First build with WhisperKit is slow (3-15 min); subsequent builds are fast.

Expected: clean build. If there is a compilation error around `whisper.transcribe`, check the resolved WhisperKit version's API and adapt the call.

- [ ] **Step 5: Smoke test — captions in Console.app**

```bash
open MeetingRecorder.app
```

Open Console.app in another window, filter by `MeetingRecorder`.

In the menu-bar menu, click Start Recording. Speak **clearly in English** for 30 seconds (use a known paragraph if possible, e.g. a news headline). Click Stop Recording.

Expected in Console.app:
- First `[LiveCaptions]` log lines appear 5-15 s after Start (WhisperKit model load + first window)
- Subsequent `[caption]` lines every ~5 s with transcribed text
- `.mp4` file is still produced and playable
- No crash

If the first caption never appears, check:
- Console for WhisperKit model download progress (`~/Library/Caches/WhisperKit/` path)
- Console for `transcribe error: ...` — if so, the API version differs from our call

- [ ] **Step 6: Commit**

```bash
git add LiveCaptions.swift Package.swift MeetingRecorderApp.swift
git commit -m "feat(captions): add LiveCaptions WhisperKit wrapper + smoke hook

- LiveCaptions owns a serial queue, 5s windowed transcription, emits
  CaptionEvent on main queue
- AppDelegate temporarily wires startRecording/stopRecording to log
  captions to NSLog. This wiring is replaced in a later task by
  the menu toggle gate."
```

---

## Task 4: CaptionPanel (single NSPanel UI)

Add `CaptionPanel.swift` — one floating `NSPanel` with a top captions area and a bottom summary area. In this task the summary area is present but blank; Task 6 fills it. The panel shows when captions start, hides when they stop, survives Space switches, and is draggable.

**Files:**
- Create: `MeetingRecorderApp/CaptionPanel.swift`
- Modify: `MeetingRecorderApp/Package.swift` (add source file)
- Modify: `MeetingRecorderApp/MeetingRecorderApp.swift` (replace `NSLog` smoke hook with panel)

- [ ] **Step 1: Create `CaptionPanel.swift`**

Write `MeetingRecorderApp/CaptionPanel.swift`:
```swift
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
```

Note: `renderSummary` takes a `LiveSummary?`. That type is introduced in Task 6 (`SummaryClient.swift`). For this task we must either stub it locally or defer; we stub here to keep `CaptionPanel.swift` self-contained.

- [ ] **Step 2: Stub `LiveSummary` for compilation**

Since Task 6 introduces the full `LiveSummary`, add a minimal forward-compatible stub at the **bottom** of `CaptionPanel.swift` so this task compiles standalone. Task 6's Step 1 replaces this stub with the real thing.

Append to `CaptionPanel.swift`:
```swift
// MARK: - Forward-compatible stub (replaced by SummaryClient.swift in Task 6)

struct LiveSummary {
    let summary: String
    let highlights: [Point]
    let lowlights: [Point]
    let actions: [Action]
    let decisions: [Decision]
    let generatedAt: String
    struct Point { let point: String; let detail: String }
    struct Action { let task: String; let owner: String?; let deadline: String?; let priority: String? }
    struct Decision { let decision: String; let rationale: String? }
}
```

- [ ] **Step 3: Add `CaptionPanel.swift` to the SPM target**

Edit `MeetingRecorderApp/Package.swift`, add `"CaptionPanel.swift"` to the `sources` array:
```swift
            sources: [
                "MeetingRecorderApp.swift",
                "AudioRecorder.swift",
                "LiveCaptions.swift",
                "CaptionPanel.swift",
            ]
```

- [ ] **Step 4: Replace the `NSLog` smoke hook with the panel**

Edit `MeetingRecorderApp/MeetingRecorderApp.swift`. Add another property after `private var liveCaptions: LiveCaptions?`:
```swift
    private var captionPanel: CaptionPanel?
```

In `@objc private func startRecording()`, replace the entire Task body. Previously:
```swift
    @objc private func startRecording() {
        Task {
            do {
                try await recorder.startRecording()

                // TEMP smoke hook for Task 3 — logs captions to Console
                let lc = LiveCaptions()
                self.liveCaptions = lc
                lc.onCaption = { ev in
                    NSLog("[caption] [\(ev.startSec)-\(ev.endSec)] \(ev.text)")
                }
                recorder.onPCMChunk = { samples, rate in
                    lc.append(samples, sampleRate: rate)
                }
                try await lc.start(sessionStart: Date())
            } catch {
                NSLog("Recording failed: \(error)")
            }
        }
    }
```
becomes:
```swift
    @objc private func startRecording() {
        Task {
            do {
                try await recorder.startRecording()

                let panel = CaptionPanel()
                self.captionPanel = panel
                panel.show()

                let lc = LiveCaptions()
                self.liveCaptions = lc
                lc.onCaption = { [weak panel] ev in
                    panel?.applyCaption(ev)
                }
                recorder.onPCMChunk = { samples, rate in
                    lc.append(samples, sampleRate: rate)
                }
                try await lc.start(sessionStart: Date())
            } catch {
                NSLog("Recording failed: \(error)")
            }
        }
    }
```

In `@objc private func stopRecording()`, extend to hide the panel. Replace:
```swift
    @objc private func stopRecording() {
        Task {
            await self.liveCaptions?.flush()
            self.liveCaptions?.stop()
            self.recorder.onPCMChunk = nil
            self.liveCaptions = nil
            await recorder.stopRecording()
        }
    }
```
with:
```swift
    @objc private func stopRecording() {
        Task {
            await self.liveCaptions?.flush()
            self.liveCaptions?.stop()
            self.recorder.onPCMChunk = nil
            self.liveCaptions = nil
            self.captionPanel?.hide()
            self.captionPanel = nil
            await recorder.stopRecording()
        }
    }
```

- [ ] **Step 5: Build**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh
```

Expected: clean build.

- [ ] **Step 6: Smoke test — panel shows and scrolls**

```bash
open MeetingRecorder.app
```

Start Recording. Expected:
- Floating panel appears on screen, draggable by background, titled "MeetingRecorder — Live"
- Captions area empty at first; populates after ~5-10 s with transcribed text
- Scrolls as new lines arrive (max 3 visible)
- Summary area shows "Summary will appear every 3 minutes." placeholder

Drag the panel to a corner, switch to another Space (Mission Control), verify panel follows.

Stop Recording. Panel disappears. `.mp4` still produced and plays.

- [ ] **Step 7: Commit**

```bash
git add CaptionPanel.swift Package.swift MeetingRecorderApp.swift
git commit -m "feat(captions): floating NSPanel with captions + summary sections

- CaptionPanel renders rolling captions (top, max 3 lines) and a
  summary placeholder (bottom, Task 6 fills it)
- Offline banner slot hidden until Task 6 wires onOffline
- LiveSummary struct stubbed at the bottom of CaptionPanel.swift;
  replaced by the real type in SummaryClient.swift next task"
```

---

## Task 5: NotesWriter + TranscriptBuffer

Add `NotesWriter.swift` containing `TranscriptBuffer` (in-memory list + `[HH:MM:SS]` text formatter) and `NotesWriter` (atomic `.md` writer). After each caption `final` event, the AppDelegate appends to both and the writer flushes. Summary updates also route through the writer, using the stub `LiveSummary` until Task 6 replaces it.

**Files:**
- Create: `MeetingRecorderApp/NotesWriter.swift`
- Modify: `MeetingRecorderApp/Package.swift`
- Modify: `MeetingRecorderApp/MeetingRecorderApp.swift`

- [ ] **Step 1: Create `NotesWriter.swift`**

Write `MeetingRecorderApp/NotesWriter.swift`:
```swift
import Foundation

// MARK: - TranscriptBuffer

/// In-memory transcript state + formatted text builder.
final class TranscriptBuffer {
    private(set) var entries: [TranscriptEntry] = []

    var charCount: Int {
        entries.reduce(0) { $0 + $1.text.count + 12 }   // +12 for "[HH:MM:SS] "
    }

    func append(_ entry: TranscriptEntry) {
        entries.append(entry)
    }

    /// "[HH:MM:SS] text\n..." format. One line per final transcript entry.
    func buildTranscriptText() -> String {
        entries.map { "\(Self.formatTime($0.startSec)) \($0.text)" }.joined(separator: "\n")
    }

    static func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "[%02d:%02d:%02d]", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - NotesWriter

/// Writes a single .md file next to the .mp4. Atomic rewrite on every flush.
final class NotesWriter {
    private let mdURL: URL
    private let recordingURL: URL
    private let startedAt: Date
    private let sessionId: UUID
    private var lastSummary: LiveSummary?
    private var transcriptEntries: [TranscriptEntry] = []
    private var endedAt: Date?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(mdURL: URL, recordingURL: URL, startedAt: Date, sessionId: UUID) {
        self.mdURL = mdURL
        self.recordingURL = recordingURL
        self.startedAt = startedAt
        self.sessionId = sessionId
    }

    func appendTranscript(_ entry: TranscriptEntry) throws {
        transcriptEntries.append(entry)
        try flush()
    }

    func updateSummary(_ summary: LiveSummary) throws {
        lastSummary = summary
        try flush()
    }

    func setEnded(_ date: Date) throws {
        endedAt = date
        try flush()
    }

    private func flush() throws {
        let md = renderMarkdown()
        let tmp = URL(fileURLWithPath: mdURL.path + ".tmp")
        try md.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(mdURL, withItemAt: tmp)
    }

    private func renderMarkdown() -> String {
        var md = "---\n"
        md += "title: \(titleFromStart())\n"
        md += "recording: \(recordingURL.lastPathComponent)\n"
        md += "sessionId: \(sessionId.uuidString.lowercased())\n"
        md += "startedAt: \(Self.iso.string(from: startedAt))\n"
        md += "lastUpdated: \(Self.iso.string(from: Date()))\n"
        md += "endedAt: \(endedAt.map { Self.iso.string(from: $0) } ?? "null")\n"
        md += "language: en\n"
        md += "---\n\n"

        md += "# Summary"
        if let s = lastSummary {
            md += " (as of \(s.generatedAt))\n\n\(s.summary)\n\n"
            if !s.highlights.isEmpty {
                md += "## Highlights\n"
                for h in s.highlights { md += "- \(h.point) — \(h.detail)\n" }
                md += "\n"
            }
            if !s.lowlights.isEmpty {
                md += "## Lowlights\n"
                for l in s.lowlights { md += "- \(l.point) — \(l.detail)\n" }
                md += "\n"
            }
            if !s.actions.isEmpty {
                md += "## Actions\n"
                for a in s.actions {
                    let owner = a.owner ?? "?"
                    let due = a.deadline ?? "no deadline"
                    let pri = a.priority ?? "medium"
                    md += "- [ ] **\(owner)** · due \(due) · \(pri) — \(a.task)\n"
                }
                md += "\n"
            }
            if !s.decisions.isEmpty {
                md += "## Decisions\n"
                for d in s.decisions { md += "- \(d.decision) — \(d.rationale ?? "")\n" }
                md += "\n"
            }
        } else {
            md += "\n\n_(no summary yet)_\n\n"
        }

        md += "---\n\n# Transcript\n\n"
        for e in transcriptEntries {
            md += "\(TranscriptBuffer.formatTime(e.startSec)) \(e.text)\n"
        }
        return md
    }

    private func titleFromStart() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(f.string(from: startedAt)) Meeting"
    }
}
```

- [ ] **Step 2: Add `NotesWriter.swift` to the SPM target**

Edit `MeetingRecorderApp/Package.swift`, add `"NotesWriter.swift"` to `sources`:
```swift
            sources: [
                "MeetingRecorderApp.swift",
                "AudioRecorder.swift",
                "LiveCaptions.swift",
                "CaptionPanel.swift",
                "NotesWriter.swift",
            ]
```

- [ ] **Step 3: Wire the writer + buffer in `AppDelegate`**

Edit `MeetingRecorderApp/MeetingRecorderApp.swift`.

Add two more properties:
```swift
    private var transcriptBuffer: TranscriptBuffer?
    private var notesWriter: NotesWriter?
```

Replace `@objc private func startRecording()` body. Previously:
```swift
    @objc private func startRecording() {
        Task {
            do {
                try await recorder.startRecording()

                let panel = CaptionPanel()
                self.captionPanel = panel
                panel.show()

                let lc = LiveCaptions()
                self.liveCaptions = lc
                lc.onCaption = { [weak panel] ev in
                    panel?.applyCaption(ev)
                }
                recorder.onPCMChunk = { samples, rate in
                    lc.append(samples, sampleRate: rate)
                }
                try await lc.start(sessionStart: Date())
            } catch {
                NSLog("Recording failed: \(error)")
            }
        }
    }
```

becomes:
```swift
    @objc private func startRecording() {
        Task {
            do {
                try await recorder.startRecording()

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
                try await lc.start(sessionStart: sessionStart)
            } catch {
                NSLog("Recording failed: \(error)")
            }
        }
    }
```

Note: the `.md` file is created lazily on the first caption event. If the user Starts and immediately Stops (before any caption), `stopRecording` still calls `notesWriter?.setEnded(Date())` which triggers a flush and the `.md` is created then with an empty transcript section. This is acceptable.

Replace `@objc private func stopRecording()`:
```swift
    @objc private func stopRecording() {
        Task {
            await self.liveCaptions?.flush()
            self.liveCaptions?.stop()
            self.recorder.onPCMChunk = nil
            self.liveCaptions = nil
            try? self.notesWriter?.setEnded(Date())
            self.notesWriter = nil
            self.transcriptBuffer = nil
            self.captionPanel?.hide()
            self.captionPanel = nil
            await recorder.stopRecording()
        }
    }
```

- [ ] **Step 4: Expose `currentRecordingURL()` on `AudioRecorder`**

`AudioRecorder` already has `private var currentOutputURL: URL?`. Expose it (read-only) by adding a method:

Edit `MeetingRecorderApp/AudioRecorder.swift`. Add inside the class (near the other public methods):
```swift
    /// Current recording destination, or nil if not recording.
    func currentRecordingURL() -> URL? { currentOutputURL }
```

- [ ] **Step 5: Build**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh
```

Expected: clean build.

- [ ] **Step 6: Smoke test — .md file written**

```bash
open MeetingRecorder.app
```

Start Recording. Speak English for ~45 seconds (enough for at least 5 caption windows). Stop Recording.

In Finder, navigate to your save dir (default: Desktop). Verify:
- `Recording-YYYY-MM-DD-HHMMSS.mp4` exists (unchanged behavior)
- `Recording-YYYY-MM-DD-HHMMSS.md` exists — same base name, `.md` extension
- Open the `.md` in a text editor:
  - Frontmatter (title, recording, sessionId, startedAt, lastUpdated, endedAt, language: en)
  - `# Summary` section with `_(no summary yet)_` (Task 6 fills this)
  - `# Transcript` section with ≥ 1 `[HH:MM:SS] text` lines matching what you said
  - `endedAt` is populated (not `null`)

If the `.md` is missing, check Console.app for `appendTranscript` errors.

- [ ] **Step 7: Commit**

```bash
git add NotesWriter.swift AudioRecorder.swift MeetingRecorderApp.swift Package.swift
git commit -m "feat(notes): TranscriptBuffer + atomic .md writer

- .md is written next to the .mp4, same basename
- Frontmatter + Summary placeholder + Transcript section
- Atomic rewrite on every caption final (write .tmp + replaceItemAt)
- AudioRecorder.currentRecordingURL() exposes currentOutputURL"
```

---

## Task 6: SummaryClient — 180 s timer + POST + panel/notes updates

Add `SummaryClient.swift` with the real `LiveSummary` type (replacing the stub in `CaptionPanel.swift`). It owns an `URLSession`, a 180 s repeating timer, and POSTs the accumulated transcript to `{LIVE_SUMMARY_URL}/api/live-summary` with `isFinal: false`. On Stop, the AppDelegate calls `triggerFinal()` for the last `isFinal: true` flush. On 3 consecutive failures, it invokes `onOffline`, which the panel renders as a red banner.

**Files:**
- Create: `MeetingRecorderApp/SummaryClient.swift`
- Modify: `MeetingRecorderApp/CaptionPanel.swift` (remove the stub struct)
- Modify: `MeetingRecorderApp/Package.swift`
- Modify: `MeetingRecorderApp/MeetingRecorderApp.swift`

- [ ] **Step 1: Remove the `LiveSummary` stub from `CaptionPanel.swift`**

Delete the `// MARK: - Forward-compatible stub...` section and the entire `struct LiveSummary { ... }` + nested `Point`/`Action`/`Decision` at the bottom of `CaptionPanel.swift`. It will live in `SummaryClient.swift` now.

- [ ] **Step 2: Create `SummaryClient.swift`**

Write `MeetingRecorderApp/SummaryClient.swift`:
```swift
import Foundation

// MARK: - Public types

struct LiveSummary: Codable {
    let summary: String
    let highlights: [Point]
    let lowlights: [Point]
    let actions: [Action]
    let decisions: [Decision]
    let generatedAt: String

    struct Point: Codable { let point: String; let detail: String }
    struct Action: Codable { let task: String; let owner: String?; let deadline: String?; let priority: String? }
    struct Decision: Codable { let decision: String; let rationale: String? }
}

enum SummaryError: Error {
    case backendUnavailable
    case backendTimeout
    case rateLimited
    case validation(String)
    case decoding
    case network(Error)
}

// MARK: - Env-backed config

enum LiveSummaryConfig {
    static var backendURL: URL {
        let raw = ProcessInfo.processInfo.environment["LIVE_SUMMARY_URL"]
            ?? "http://localhost:3300"
        return URL(string: raw) ?? URL(string: "http://localhost:3300")!
    }
    static var apiKey: String? {
        ProcessInfo.processInfo.environment["LIVE_SUMMARY_API_KEY"]
    }
}

// MARK: - SummaryClient

@MainActor
final class SummaryClient {
    /// Fires on main queue whenever a summary POST succeeds (non-final ticks).
    var onSummary: ((LiveSummary) -> Void)?
    /// Fires on main queue after 3 consecutive failures. Receives a short reason.
    var onOffline: ((String) -> Void)?

    private let backendURL: URL
    private let apiKey: String?
    private let sessionId: UUID
    private let buffer: TranscriptBuffer
    private let sessionStart: Date
    private let session: URLSession
    private let maxChars: Int = 200_000

    private var timer: Timer?
    private var consecutiveFailures: Int = 0
    private let offlineThreshold: Int = 3

    init(backendURL: URL = LiveSummaryConfig.backendURL,
         apiKey: String? = LiveSummaryConfig.apiKey,
         sessionId: UUID,
         buffer: TranscriptBuffer,
         sessionStart: Date) {
        self.backendURL = backendURL
        self.apiKey = apiKey
        self.sessionId = sessionId
        self.buffer = buffer
        self.sessionStart = sessionStart

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 75
        self.session = URLSession(configuration: cfg)
    }

    func start(intervalSec: TimeInterval = 180) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: intervalSec, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Used on Stop — one last POST with isFinal: true, bypasses the backend 60s
    /// rate limit.
    func triggerFinal() async throws -> LiveSummary {
        try await post(isFinal: true)
    }

    // MARK: - Internals

    private func tick() async {
        do {
            let s = try await post(isFinal: false)
            consecutiveFailures = 0
            onSummary?(s)
        } catch {
            consecutiveFailures += 1
            NSLog("[SummaryClient] failure #\(consecutiveFailures): \(error)")
            if consecutiveFailures == offlineThreshold {
                onOffline?(shortReason(for: error))
            }
        }
    }

    private func post(isFinal: Bool) async throws -> LiveSummary {
        var req = URLRequest(url: backendURL.appendingPathComponent("/api/live-summary"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }

        let transcript = truncatedTranscriptText()
        let elapsedSec = max(1, Int(Date().timeIntervalSince(sessionStart)))
        let body: [String: Any] = [
            "sessionId": sessionId.uuidString.lowercased(),
            "transcriptText": transcript,
            "elapsedSec": elapsedSec,
            "isFinal": isFinal,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError where err.code == .timedOut {
            throw SummaryError.backendTimeout
        } catch {
            throw SummaryError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw SummaryError.decoding }
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(LiveSummary.self, from: data)
            } catch {
                throw SummaryError.decoding
            }
        case 400: throw SummaryError.validation(String(data: data, encoding: .utf8) ?? "")
        case 429: throw SummaryError.rateLimited
        case 503: throw SummaryError.backendUnavailable
        case 504: throw SummaryError.backendTimeout
        default:  throw SummaryError.network(
            NSError(domain: "live-summary", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        )
        }
    }

    /// Head 20% + tail 70% sliding window if the transcript is past maxChars.
    private func truncatedTranscriptText() -> String {
        let full = buffer.buildTranscriptText()
        if full.count <= maxChars { return full }
        let headCount = Int(Double(maxChars) * 0.20)
        let tailCount = Int(Double(maxChars) * 0.70)
        let fullArray = Array(full)
        let head = String(fullArray.prefix(headCount))
        let tail = String(fullArray.suffix(tailCount))
        return head + "\n\n[... truncated ...]\n\n" + tail
    }

    private func shortReason(for error: Error) -> String {
        switch error {
        case SummaryError.backendUnavailable: return "backend 503"
        case SummaryError.backendTimeout:     return "timeout"
        case SummaryError.rateLimited:        return "rate limited"
        case SummaryError.validation:         return "validation error"
        case SummaryError.decoding:           return "bad response"
        case SummaryError.network(let e):     return "network: \(e.localizedDescription)"
        default:                              return "unknown"
        }
    }
}
```

- [ ] **Step 3: Add `SummaryClient.swift` to the SPM target**

Edit `MeetingRecorderApp/Package.swift`, add `"SummaryClient.swift"`:
```swift
            sources: [
                "MeetingRecorderApp.swift",
                "AudioRecorder.swift",
                "LiveCaptions.swift",
                "CaptionPanel.swift",
                "NotesWriter.swift",
                "SummaryClient.swift",
            ]
```

- [ ] **Step 4: Wire `SummaryClient` in `AppDelegate`**

Edit `MeetingRecorderApp/MeetingRecorderApp.swift`.

Add one more property:
```swift
    private var summaryClient: SummaryClient?
```

Modify `@objc private func startRecording()`. Find this section inside the Task:
```swift
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
                try await lc.start(sessionStart: sessionStart)
```

Replace it with:
```swift
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
                try await lc.start(sessionStart: sessionStart)

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
```

Modify `@objc private func stopRecording()`. Replace its body:
```swift
    @objc private func stopRecording() {
        Task {
            await self.liveCaptions?.flush()
            self.liveCaptions?.stop()
            self.recorder.onPCMChunk = nil
            self.liveCaptions = nil
            try? self.notesWriter?.setEnded(Date())
            self.notesWriter = nil
            self.transcriptBuffer = nil
            self.captionPanel?.hide()
            self.captionPanel = nil
            await recorder.stopRecording()
        }
    }
```

with:
```swift
    @objc private func stopRecording() {
        Task {
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
```

- [ ] **Step 5: Build**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh
```

Expected: clean build.

- [ ] **Step 6: Smoke test A — happy path with backend**

Prerequisite: the backend from PR #2 is running locally at `http://localhost:3300`. If you have a deployed URL, use that instead.

```bash
export LIVE_SUMMARY_URL="http://localhost:3300"
export LIVE_SUMMARY_API_KEY="<your-test-api-key>"
open MeetingRecorder.app
```

Note: `open` inherits the exporting shell's env vars. If the app is already running, quit it first.

Start Recording. Speak continuously in English for ≥ 4 minutes (use a podcast or read aloud). Observe the panel:
- Captions keep scrolling in the top section
- At ~180 s: the summary section populates with a paragraph + highlights/actions/decisions (if the LLM produced them)
- At ~360 s: summary section updates with the newer content

Stop Recording. The Stop handler triggers `triggerFinal()` — the summary should be refreshed one last time before the panel hides (you'll see it for a split second).

In Finder, open the `.md`:
- `# Summary (as of <ISO>)` populated with the backend output
- `## Highlights` / `## Actions` / `## Decisions` sections present if the LLM returned them
- `# Transcript` section has one line per caption final

- [ ] **Step 7: Smoke test B — offline path**

```bash
export LIVE_SUMMARY_URL="http://localhost:9999"   # intentionally wrong port
unset LIVE_SUMMARY_API_KEY
open MeetingRecorder.app
```

Start Recording. Wait ~10 minutes total (3 × 180 s = 540 s ≈ 9 min for threshold).

Expected:
- Captions work normally
- At approximately 9 min (after 3 consecutive failed POSTs), a red `Summary offline — network: ...` banner appears at the top of the panel
- `.md` has transcript but `Summary` section still `_(no summary yet)_`

Stop Recording. The final POST also fails; that's fine — we just log it.

- [ ] **Step 8: Commit**

```bash
git add SummaryClient.swift CaptionPanel.swift MeetingRecorderApp.swift Package.swift
git commit -m "feat(summary): add SummaryClient with 180s timer + isFinal flush

- POST /api/live-summary every 180s, isFinal:true on Stop
- 3 consecutive failures → red offline banner via onOffline
- LIVE_SUMMARY_URL / LIVE_SUMMARY_API_KEY env vars
- Moved LiveSummary type out of CaptionPanel.swift (stub removed)"
```

---

## Task 7: Menu wiring + opt-in toggle

Gate the entire captions/summary pipeline on a new `Enable Live Captions` menu toggle. When the toggle is off, `startRecording` skips all captions work and the app behaves exactly like v2.7.0. Persist the toggle state in `UserDefaults`.

**Files:**
- Modify: `MeetingRecorderApp/AudioRecorder.swift`
- Modify: `MeetingRecorderApp/MeetingRecorderApp.swift`

- [ ] **Step 1: Add `captionsEnabled` to `AudioRecorder`**

Edit `MeetingRecorderApp/AudioRecorder.swift`. Locate the existing `@Published var useMicrophone: Bool`. Immediately after that property, add:
```swift
    @Published var captionsEnabled: Bool {
        didSet { UserDefaults.standard.set(captionsEnabled, forKey: "captionsEnabled") }
    }
```

In the `init()` method, locate the existing line:
```swift
        self.useMicrophone = UserDefaults.standard.object(forKey: "useMicrophone") as? Bool ?? true
```

Immediately after that line, add:
```swift
        self.captionsEnabled = UserDefaults.standard.object(forKey: "captionsEnabled") as? Bool ?? false
```

Note: default is `false` so English-meeting users opt in explicitly, and the feature cannot surprise Chinese-meeting users who never enabled it.

- [ ] **Step 2: Gate the startRecording Task on `captionsEnabled`**

Edit `MeetingRecorderApp/MeetingRecorderApp.swift`. Currently `@objc private func startRecording()` unconditionally sets up the captions pipeline. Wrap the captions setup in a conditional.

Replace the entire body of `@objc private func startRecording()` with:
```swift
    @objc private func startRecording() {
        Task {
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
                    // Keep panel visible (for the offline message) but don't start the summary client
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
```

The `stopRecording()` method stays as-is from Task 6 — nothing to change there, because its teardown paths all tolerate nil state (the guards `self.liveCaptions?`, `self.summaryClient?`, etc. skip when captions were never enabled).

- [ ] **Step 3: Add the menu toggle + handler**

Edit `MeetingRecorderApp/MeetingRecorderApp.swift`. Locate `private func rebuildMenu()`. Find this existing block:
```swift
        // Mic toggle
        let micToggle = NSMenuItem(title: "Record Microphone", action: #selector(toggleMic), keyEquivalent: "")
        micToggle.target = self
        micToggle.state = recorder.useMicrophone ? .on : .off
        menu.addItem(micToggle)
```

Immediately after `menu.addItem(micToggle)` (before the existing mic-device submenu logic), add:
```swift
        // Live captions toggle
        let capToggle = NSMenuItem(title: "Enable Live Captions", action: #selector(toggleCaptions), keyEquivalent: "")
        capToggle.target = self
        capToggle.state = recorder.captionsEnabled ? .on : .off
        menu.addItem(capToggle)
```

Add the handler method. Locate the existing `@objc private func toggleMic()` method:
```swift
    @objc private func toggleMic() {
        recorder.useMicrophone.toggle()
        rebuildMenu()
    }
```

Immediately after `toggleMic`, add:
```swift
    @objc private func toggleCaptions() {
        recorder.captionsEnabled.toggle()
        rebuildMenu()
    }
```

- [ ] **Step 4: Build**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh
```

Expected: clean build.

- [ ] **Step 5: Smoke test A — toggle off (regression)**

```bash
unset LIVE_SUMMARY_URL
unset LIVE_SUMMARY_API_KEY
open MeetingRecorder.app
```

Verify:
- Menu-bar menu shows a new "Enable Live Captions" item (unchecked by default on first run)
- Click Start Recording. Speak for 30 s. Click Stop.
- No floating panel appears.
- Only a `.mp4` file is produced (no `.md`).

- [ ] **Step 6: Smoke test B — toggle on**

```bash
export LIVE_SUMMARY_URL="http://localhost:3300"
open MeetingRecorder.app
```

- Click Enable Live Captions. The menu reopens with the item checked.
- Quit the app (Menu → Quit). Relaunch.
- Reopen the menu — verify "Enable Live Captions" is still checked (persistence works).
- Click Start Recording. Speak 45 s. Click Stop.
- Verify panel appears and shows captions, `.mp4` + `.md` both produced.

- [ ] **Step 7: Smoke test C — toggle off after on**

While the app is still running:
- Click Enable Live Captions to uncheck it.
- Click Start Recording. Speak 20 s. Click Stop.
- Verify no panel, no `.md`.

- [ ] **Step 8: Commit**

```bash
git add AudioRecorder.swift MeetingRecorderApp.swift
git commit -m "feat(menu): Enable Live Captions opt-in toggle

- New @Published AudioRecorder.captionsEnabled, persisted to UserDefaults
- Default off; Chinese-meeting users see no change in behavior
- startRecording gates captions setup on captionsEnabled
- WhisperKit load failure shows 'captions unavailable' banner,
  does not start SummaryClient, recording continues"
```

---

## Task 8: Final manual acceptance smoke

Run the seven scenarios from `2026-05-10-live-captions-design.md § Verification`. Write down the outcome of each. If any fail, stop and debug before declaring the feature done.

**Files:**
- Create: `MeetingRecorderApp/docs/superpowers/specs/2026-05-10-live-captions-acceptance.md`

- [ ] **Step 1: Prepare env**

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
bash build.sh     # clean rebuild from the final tree
```

Kill any running instance of MeetingRecorder before proceeding (menu-bar Quit or `killall MeetingRecorder`).

- [ ] **Step 2: Run the 7 scenarios and note outcomes**

Create `MeetingRecorderApp/docs/superpowers/specs/2026-05-10-live-captions-acceptance.md`. Template:
```markdown
# Live Captions — Acceptance Smoke Run

**Date:** YYYY-MM-DD
**Builder:** <your name / agent id>
**Commit:** <git rev-parse HEAD>

## 1. Regression smoke (captions off)
- [ ] Toggle off. Record 30s. `.mp4` plays; no `.md`; no panel.
- Result:

## 2. Captions smoke
- [ ] Toggle on. Record 30s in English. Panel shows captions; `.mp4` + `.md` both exist; `.md` transcript contains recognizable words.
- Result:

## 3. Summary smoke
- [ ] Set LIVE_SUMMARY_URL to running backend. Record 4 min. Summary appears at ~3:00 in panel + `.md`.
- Result:

## 4. Offline smoke
- [ ] Set LIVE_SUMMARY_URL to bogus host. Record 10 min. Red banner appears at ~9 min.
- Result:

## 5. No-env smoke
- [ ] Unset both env vars. Record 1 min. Captions work; no summary; no crash.
- Result:

## 6. Model download smoke
- [ ] rm -rf ~/Library/Caches/WhisperKit. Restart app. First record shows model-load delay; captions arrive after delay; recording unaffected.
- Result:

## 7. Chinese regression
- [ ] Toggle off. Record a Chinese meeting. `.mp4` plays. No `.md`, no panel, no WhisperKit activity in Console.
- Result:
```

Run each scenario and fill in the result (PASS / FAIL with details).

- [ ] **Step 3: Commit the acceptance log**

```bash
git add docs/superpowers/specs/2026-05-10-live-captions-acceptance.md
git commit -m "docs: live captions acceptance smoke run"
```

- [ ] **Step 4: Done**

If all 7 scenarios PASS, the feature is ready.

If any FAIL, stop and open a targeted fix task — do not declare complete.

---

## Out of scope (deferred)

Explicitly not included and not to be added by subagents without a new plan:

- Preferences window / Keychain API-key storage
- Unit tests (XCTest target)
- XPC helper / process isolation
- Non-English transcription or prompts
- Speaker diarization in the live path
- Two-panel UI (captions vs summary separate)
- Auto-upload of `.mp4` / `.md`
- Calendar / meeting-title auto-fill
- Sandbox / notarization (app stays ad-hoc signed)

If the product direction changes to require any of these, write a new spec via `superpowers:brainstorming` and a new plan via `superpowers:writing-plans`. Do not bolt on.
