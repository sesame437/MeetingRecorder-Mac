# MeetingRecorder Live Captions + Rolling Summary — Simplified Design

**Date:** 2026-05-10
**Status:** Draft for approval
**Baseline:** MeetingRecorder v2.7.0 (two-file swiftc build at `/Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp/`)

## Goal

Add an opt-in live captions overlay and rolling meeting summary to MeetingRecorder, **without changing the existing recording behavior**. When enabled, a single floating panel shows English captions in real time and a rolling meeting summary (refreshed every 180s via the existing Bedrock backend). A Markdown notes file is written next to the `.mp4`.

## Non-goals

- **Chinese / multi-language.** English meetings only; Chinese meetings simply keep the toggle off.
- **XPC / process isolation.** WhisperKit runs in-process. If WhisperKit crashes, the app crashes and recording stops — acceptable trade-off for simplicity.
- **Preferences UI / Keychain.** Backend URL and API key come from environment variables.
- **Unit tests.** The existing app has zero tests; this addition follows suit. Verification is via manual smoke.
- **Speaker diarization.** Mic + system audio are already mixed pre-encoding; captions will be coarse text only.
- **Xcode project migration.** Continue with `swiftc`/`build.sh`; add a minimal `Package.swift` only to resolve the WhisperKit SPM dependency.

## Architecture (one process, one bundle)

```
                          ┌──────────────────────── MeetingRecorder.app ─────────────────────────┐
                          │                                                                      │
  SCStream(audio) ─┐      │  AudioRecorder.stream(…)  ── writes AAC via AVAssetWriter (unchanged)│
                   ├──────┤                                                                      │
  AVCaptureSession ┘      │          └─► (if captionsEnabled) tapPCM → LiveCaptions              │
                          │                                     │                                │
                          │                                     ▼                                │
                          │   LiveCaptions (WhisperKit small.en)                                 │
                          │     ├─ 5s rolling window, emits CaptionEvent(text, startSec, endSec) │
                          │     └─► CaptionPanel.apply()                                         │
                          │         │                                                            │
                          │         ├─► TranscriptBuffer.append()                                │
                          │         └─► NotesWriter.appendTranscript()                           │
                          │                                                                      │
                          │   every 180s:                                                        │
                          │     SummaryClient.tick()                                             │
                          │       ├─ POST {LIVE_SUMMARY_URL}/api/live-summary                    │
                          │       └─► on 200: CaptionPanel.renderSummary() + NotesWriter.write() │
                          │                                                                      │
                          │   on Stop:                                                           │
                          │     LiveCaptions.flush() → SummaryClient.tick(isFinal:true)          │
                          │       → close panel, write final .md                                 │
                          └──────────────────────────────────────────────────────────────────────┘
```

All components live in the main process. No XPC, no second binary.

## File organization

```
MeetingRecorderApp/
├─ MeetingRecorderApp.swift      # existing; +~30 lines (menu toggle + session wire-up)
├─ AudioRecorder.swift           # existing; +~20 lines (PCM fan-out callback + 16kHz downmix helper)
├─ LiveCaptions.swift            # NEW  — WhisperKit wrapper + 5s window + event emit (~200 lines)
├─ CaptionPanel.swift            # NEW  — single NSPanel with top captions / bottom summary (~150 lines)
├─ SummaryClient.swift           # NEW  — URLSession POST + JSON decode + failure counter (~150 lines)
├─ NotesWriter.swift             # NEW  — atomic .md write (~80 lines)
├─ Package.swift                 # NEW  — declares WhisperKit dep, excludes non-source files
├─ Info.plist                    # unchanged
├─ AppIcon.icns                  # unchanged
├─ build.sh                      # MODIFIED — `swift build` first, then existing lipo/codesign/dmg steps
└─ docs/superpowers/specs/2026-05-10-live-captions-design.md   # this file
```

Total new Swift: ~600 lines across 4 files. `Package.swift` is 20-30 lines.

## Components

### 1. `LiveCaptions` (new file)

Encapsulates WhisperKit. Owns the sample buffer. Emits caption events.

```swift
struct CaptionEvent {
    let text: String
    let startSec: Double   // audio-time, relative to session start
    let endSec: Double
}

final class LiveCaptions {   // NOT @MainActor — append() is called from audio queue
    var onCaption: ((CaptionEvent) -> Void)?   // always invoked on main queue

    init(modelName: String = "openai_whisper-small.en")

    func start(sessionStart: Date) async throws  // loads WhisperKit model (first run ~250MB download)
    func append(_ samples: [Float], sampleRate: Double)   // thread-safe; caller supplies Float32 mono at any rate, we downsample to 16k
    func flush() async                                    // transcribes remaining buffer; emits final event
    func stop()                                           // releases WhisperKit, clears buffer
}
```

Internals:
- A serial `DispatchQueue(label: "live-captions")` owns the sample buffer. `append` dispatches async to this queue so the audio thread never blocks on ASR.
- Buffer stores `[Float]` at 16 kHz (downsamples from any incoming rate via `AVAudioConverter`).
- Every 5 s of accumulated audio, spawns a `Task` to call `whisper.transcribe(audioArray:)` and emits one `CaptionEvent`.
- `onCaption` is invoked with `DispatchQueue.main.async` — UI code on the other end is always on main.
- If WhisperKit load fails: `start()` throws; caller shows "captions unavailable" banner and continues recording.

### 2. `CaptionPanel` (new file)

One always-on-top floating `NSPanel`, two vertical sections.

```swift
@MainActor
final class CaptionPanel {
    init()
    func show()
    func hide()

    func applyCaption(_ event: CaptionEvent)    // pushes onto a 3-line rolling top section
    func renderSummary(_ s: LiveSummary?)       // replaces the bottom section
    func showOffline(_ reason: String?)         // red banner when SummaryClient reports 3+ failures
    func clear()
}
```

Layout:
```
┌─────────────────────────────────────────────┐
│  [captions area — last 3 lines, monospace]  │
│  "...  about  the  API  redesign"            │
│  "we should version  the  endpoints"         │
│                                              │
├──── Summary  (tap title to collapse) ───────┤
│  Short summary paragraph here...             │
│  • Highlight 1                               │
│  • Highlight 2                               │
│  Actions: • [Alice] review PR by Fri         │
└─────────────────────────────────────────────┘
```
- Size: ~800 × 240 (captions 120 + summary 120), resizable.
- Style: `.nonactivatingPanel`, `.borderless`, `.floating`, alpha ≈ 0.55 black bg, white text.
- Draggable by background. Survives Space switches (`canJoinAllSpaces`, `fullScreenAuxiliary`).
- Collapsed state: summary section hides; panel shrinks to captions-only height.
- Offline banner: thin red strip at top, text "Summary offline: {reason}".

### 3. `SummaryClient` (new file)

Owns the 180 s timer + HTTPS POST. Stateless per-call.

```swift
struct LiveSummary: Codable {
    let summary: String
    let highlights: [Point]
    let lowlights: [Point]
    let actions: [Action]
    let decisions: [Decision]
    let generatedAt: String
    // tokensInput/tokensOutput ignored client-side
    struct Point: Codable { let point: String; let detail: String }
    struct Action: Codable { let task: String; let owner: String?; let deadline: String?; let priority: String? }
    struct Decision: Codable { let decision: String; let rationale: String? }
}

enum SummaryError: Error {
    case backendUnavailable, backendTimeout, rateLimited, validation(String), decoding, network(Error)
}

@MainActor
final class SummaryClient {
    var onSummary: ((LiveSummary) -> Void)?
    var onOffline: ((String) -> Void)?   // fires after 3 consecutive failures

    init(backendURL: URL, apiKey: String?, sessionId: UUID, buffer: TranscriptBuffer, sessionStart: Date)

    func start(intervalSec: TimeInterval = 180)    // schedules repeating timer
    func stop()
    func triggerFinal() async throws -> LiveSummary  // used on Stop with isFinal:true
}
```

- HTTP body: `{ sessionId, transcriptText, elapsedSec, isFinal }` (matches the merged backend contract in PR #2).
- Header `x-api-key` if `LIVE_SUMMARY_API_KEY` set; otherwise omitted.
- Timeout: 60 s.
- On consecutive failures ≥ 3, calls `onOffline` once; resets counter on next success.

### 4. `NotesWriter` (new file)

Writes a single `.md` file next to the recording. Atomic rewrite on every transcript `final` and every summary update.

```swift
final class NotesWriter {
    init(mdURL: URL, recordingURL: URL, startedAt: Date, sessionId: UUID)
    func appendTranscript(_ entry: TranscriptEntry) throws
    func updateSummary(_ s: LiveSummary) throws
    func setEnded(_ date: Date) throws
}

struct TranscriptEntry { let startSec: Double; let endSec: Double; let text: String }
```

- File layout: frontmatter (title, recording filename, sessionId, startedAt, lastUpdated, endedAt, language) → `# Summary` section → `# Transcript` section.
- Write strategy: render full text → write to `{mdURL}.tmp` → `FileManager.replaceItemAt()` for atomic rename.
- `.md` lives at `recordingURL.deletingPathExtension().appendingPathExtension("md")`.

### 5. `TranscriptBuffer` (small helper, can live in `LiveCaptions.swift` or as a struct)

```swift
final class TranscriptBuffer {
    private(set) var entries: [TranscriptEntry] = []
    func append(_ e: TranscriptEntry)
    func buildTranscriptText() -> String   // "[HH:MM:SS] text\n..." format for backend
    var charCount: Int { get }
}
```

Truncation for backend requests: if `charCount > 200_000`, take head 20% + tail 70% (same strategy the backend documents). Implemented inline in `SummaryClient` before the POST.

### 6. `AudioRecorder` changes

Add one callback property + one small helper.

```swift
// NEW property
var onPCMChunk: (([Float], Double) -> Void)?   // Float32 mono @ 16 kHz, called from audio queue

// Inside stream(_:didOutputSampleBuffer:of:) — AFTER the existing AAC write path
if let onPCM = onPCMChunk {
    if let mono16k = Self.convertToFloat32Mono16k(sampleBuffer) {
        onPCM(mono16k, 16000.0)
    }
}
```

`convertToFloat32Mono16k(_:)` uses `AVAudioConverter` with a target format of 16 kHz Float32 mono. Reuses the same pattern already in `extractMicSamples(from:)` but targets 16 kHz instead of 48 kHz.

The fan-out is read-only and asynchronous relative to the AAC path — capture thread writes to AVAssetWriter first, then triggers the PCM callback. Any failure in `LiveCaptions.append` does not affect recording.

### 7. `MeetingRecorderApp` changes

Add `captionsEnabled` (Combine `@Published` on `AudioRecorder` for state consistency with `useMicrophone`), menu toggle, and session wire-up in the AppDelegate.

```swift
// AudioRecorder
@Published var captionsEnabled: Bool {
    didSet { UserDefaults.standard.set(captionsEnabled, forKey: "captionsEnabled") }
}

// AppDelegate — in rebuildMenu()
let capToggle = NSMenuItem(title: "Enable Live Captions", action: #selector(toggleCaptions), keyEquivalent: "")
capToggle.target = self
capToggle.state = recorder.captionsEnabled ? .on : .off
menu.addItem(capToggle)
```

Session lifecycle (owned in `AppDelegate`):

```swift
// startRecording()
if recorder.captionsEnabled {
    let liveCaptions = LiveCaptions()
    let buffer = TranscriptBuffer()
    let notes = try NotesWriter(mdURL: ..., recordingURL: recorder.currentOutputURL!, ...)
    let panel = CaptionPanel(); panel.show()
    let client = SummaryClient(backendURL: envURL, apiKey: envKey, sessionId: UUID(), buffer: buffer, sessionStart: Date())

    recorder.onPCMChunk = { samples, rate in liveCaptions.append(samples, sampleRate: rate) }
    liveCaptions.onCaption = { ev in
        panel.applyCaption(ev)
        let entry = TranscriptEntry(startSec: ev.startSec, endSec: ev.endSec, text: ev.text)
        buffer.append(entry)
        try? notes.appendTranscript(entry)
    }
    client.onSummary = { s in
        panel.renderSummary(s)
        try? notes.updateSummary(s)
    }
    client.onOffline = { reason in panel.showOffline(reason) }

    try await liveCaptions.start(sessionStart: Date())
    client.start()
}

// stopRecording()
await liveCaptions?.flush()
liveCaptions?.stop()
client?.stop()
if let final = try? await client?.triggerFinal() { try? notes?.updateSummary(final) }
try? notes?.setEnded(Date())
panel?.hide()
recorder.onPCMChunk = nil
```

## Configuration

Environment variables read at app launch:
- `LIVE_SUMMARY_URL` — backend base URL (e.g. `http://localhost:3300`). Default: `http://localhost:3300`.
- `LIVE_SUMMARY_API_KEY` — optional; if set, sent as `x-api-key` header.

If `LIVE_SUMMARY_URL` is unreachable or key missing when required, SummaryClient's failure counter kicks in and the panel shows offline — recording and captions continue normally.

WhisperKit model is hard-coded to `openai_whisper-small.en`. If you want to swap it later, it's a one-line edit in `LiveCaptions.swift`.

## Error handling

| Failure | Behavior |
|---|---|
| WhisperKit model download / load fails | `LiveCaptions.start()` throws. AppDelegate logs + panel shows "Captions unavailable"; recording continues; SummaryClient is NOT started (no transcript → no useful summary). |
| WhisperKit `transcribe` call throws | Logged, skipped. Caption for that window is missed. Next window tries again. |
| `SummaryClient` POST fails (network / 5xx / timeout) | Logged. Failure counter ++ . After 3 consecutive, panel shows red "Summary offline" banner. Counter resets on next success. |
| `NotesWriter.flush` IO error | Logged. Next transcript append / summary update retries. |
| Invalid `LIVE_SUMMARY_URL` | SummaryClient constructor falls back to default; first POST fails → standard offline flow. |

Critical invariant: **none of the above stops the recording or corrupts the `.mp4`**. The `AudioRecorder.stream(…)` → `AVAssetWriter` path is never on the critical path for captions/summary.

## Build system

A new `Package.swift` at `MeetingRecorderApp/Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: ".",
            exclude: ["build.sh", "Info.plist", "AppIcon.icns", "AppIcon_preview.png",
                      "generate_icon.py", "MeetingRecorder-v2.7.0.app",
                      "MeetingRecorder-v2.7.0-dual-track.dmg", "MeetingRecorder.dmg", "docs"],
            sources: ["MeetingRecorderApp.swift", "AudioRecorder.swift",
                      "LiveCaptions.swift", "CaptionPanel.swift",
                      "SummaryClient.swift", "NotesWriter.swift"]
        )
    ]
)
```

`build.sh` becomes:

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Build both slices via SPM, then lipo (max compatibility with swift.org & Xcode toolchains)
echo "Building arm64..."
swift build -c release --arch arm64
echo "Building x86_64..."
swift build -c release --arch x86_64

# 2. Assemble .app bundle
APP_DIR="$SCRIPT_DIR/MeetingRecorder.app"
CONTENTS="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

ARM64_BIN=".build/arm64-apple-macosx/release/MeetingRecorder"
X86_BIN=".build/x86_64-apple-macosx/release/MeetingRecorder"
lipo -create "$ARM64_BIN" "$X86_BIN" -output "$CONTENTS/MacOS/MeetingRecorder"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$SCRIPT_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# 3. Ad-hoc sign with same entitlements as v2.7.0
codesign --force --sign - --entitlements /dev/stdin "$APP_DIR" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.screen-capture</key><true/>
</dict></plist>
ENTITLEMENTS

# 4. DMG (unchanged)
DMG_PATH="$SCRIPT_DIR/MeetingRecorder.dmg"
DMG_TMP="$SCRIPT_DIR/.dmg-tmp"
rm -f "$DMG_PATH"; rm -rf "$DMG_TMP"; mkdir -p "$DMG_TMP"
cp -R "$APP_DIR" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"
hdiutil create -volname "MeetingRecorder" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_TMP"

echo "Built: $APP_DIR"
echo "DMG:   $DMG_PATH"
```

Key change: we give up manual `swiftc` + `lipo` control in exchange for `swift build`'s managed dependency resolution. Universal Binary still works via `swift build --arch arm64 --arch x86_64`. Ad-hoc signing and DMG packaging are preserved.

## Verification (manual smoke plan)

1. **Regression smoke**: `Enable Live Captions` toggle **off**. Start recording, speak 30 s, Stop. Verify `.mp4` plays back, duration matches, no `.md` file produced. (Confirms the feature is truly opt-in.)
2. **Captions smoke**: Toggle on. Start, speak English for 30 s, Stop. Verify panel appears, captions scroll roughly real-time (5-7 s delay OK), `.mp4` still plays, `.md` file exists next to it with a `# Transcript` section containing the speech.
3. **Summary smoke**: Set `LIVE_SUMMARY_URL` to a running backend. Record 4 minutes of English. Verify at ~3:00 the summary section in the panel populates; at stop, a final summary update writes to `.md`.
4. **Offline smoke**: Point `LIVE_SUMMARY_URL` at a bogus host. Record 10 minutes. Verify: captions still work; at ~3 min, 6 min, 9 min the offline banner appears; `.md` has transcript but no summary.
5. **No-backend-env smoke**: Unset both env vars. Record 1 minute with captions. Verify captions work (ASR is local) but summary never fires; no crash.
6. **Model download smoke**: On a machine where `~/Library/Caches/WhisperKit/openai_whisper-small.en/` doesn't exist, start recording with captions. First launch: panel shows a "Loading captions…" placeholder while the 250 MB model downloads; recording proceeds normally; captions start appearing once loaded. Verify no audio is lost during the load (PCM is buffered).
7. **Chinese meeting regression**: Toggle off. Record a Chinese meeting. Verify the app behaves identically to v2.7.0 — no panel, no `.md`, no WhisperKit activity.

## What's deliberately *not* in this design

- No `Preferences…` window. Configure via env vars.
- No Keychain. API key is in env var.
- No XCTest. Smoke-test manually per the list above.
- No XPC. WhisperKit failures can crash the app.
- No mic-vs-system audio source separation for ASR — transcript is coarse mixed audio.
- No streaming ASR with cross-window context. Uses a simple 5 s rolling window. Words near window boundaries may occasionally drop; this is acceptable for a note-taking aid.
- No multi-language. `.en` model only.
- No per-task `xcodebuild test` gates. `swift build -c release` is the only compile step that must pass per task.

## Risks & open questions

- **Universal binary build requires running `swift build` twice + `lipo`** (the `build.sh` already does this). If the user's machine is Apple Silicon only and they only ever run locally, the x86_64 build can be dropped for faster iteration during development.
- **WhisperKit cold-start latency** can be 5-15 s while the Core ML model compiles on first app launch on a new machine. The panel's "Loading captions…" placeholder handles this, but it's a UX rough edge worth acknowledging.
- **`swift build` output path layout** is `.build/<arch>-apple-macosx/release/<binary>`. Confirmed on Swift 5.9+.
- **Thread-safety of the `onPCMChunk` callback**: the callback fires on SCStream's internal audio queue. `LiveCaptions.append` must dispatch work onto its own serial queue — documented in the component spec.

If any of the above bites, we fix inline during implementation — none require a design change.

## What gets built (task breakdown preview)

The writing-plans skill will produce a detailed task list next. Rough shape:

1. **Scaffolding**: `git init`, write `Package.swift`, update `build.sh`, verify existing app still builds and runs end-to-end.
2. **AudioRecorder PCM tap**: add `onPCMChunk` callback + 16 kHz downmix helper. Verify recording still works identically and callback fires with expected format.
3. **LiveCaptions** (WhisperKit wrapper): add WhisperKit SPM, implement `LiveCaptions`, wire to `AudioRecorder.onPCMChunk`. Verify console logs show transcription results.
4. **CaptionPanel**: one NSPanel, captions section only first. Verify live rendering.
5. **NotesWriter + TranscriptBuffer**: write `.md` transcript section on each caption final. Verify file grows correctly.
6. **SummaryClient**: POST on 180 s tick + `isFinal` on Stop. Panel summary section renders. `.md` includes summary.
7. **Menu wiring + opt-in flow**: add `Enable Live Captions` toggle, gate everything on it, default off.
8. **Manual smoke**: run the 7 verification scenarios.

Roughly 7 tasks, each with a visible end state that can be smoke-tested.
