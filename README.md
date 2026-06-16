# MeetingRecorder

macOS menu-bar app that captures system audio + microphone into a single AAC track, with opt-in **live captions** (WhisperKit) and **rolling summary** (posted to a backend that calls AWS Bedrock Claude).

## Features

- Menu-bar icon; `Start Recording` / `Stop Recording`
- Captures system audio (ScreenCaptureKit) + microphone (AVCaptureSession), mixed into one stereo AAC @ 48kHz, 192kbps, wrapped in `.mp4`
- Built-in audio-level indicator for system + mic tracks
- **Enable Live Captions** toggle: floating panel with rolling English captions (WhisperKit `openai_whisper-small.en`, local inference) plus auto-refreshed meeting summary from a Bedrock-backed HTTP endpoint
- **Enable Verbatim Transcript** toggle (multilingual): writes a `.verbatim.md` file alongside the recording with timestamped, speaker-paragraph-level transcription. Backed by local `whisper-server` (whisper.cpp, large-v3-turbo). Mid-recording toggle supported (toggle ON/OFF live without disrupting the mp4). LocalAgreement-2 streaming algorithm for stable output. Watchdog auto-restart on rare server stalls.
- Writes a companion `.md` file next to each recording containing summary, highlights/lowlights, actions, and decisions
- Universal single binary, ad-hoc signed, no code-sign team required

## Requirements

### Always required
- macOS 15+
- Apple Silicon (arm64)
- Swift 5.9+ toolchain (Xcode 15+ command-line tools)

### Required if you use **Live Captions**
- First launch needs network to download the WhisperKit model (~465 MB, cached at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en`). Captions work offline after that.

### Required if you use **Verbatim Transcript**

The verbatim feature is OFF by default — enable in the menu when you need it. When enabled, the app spawns a local `whisper-server` subprocess; you must have these prerequisites installed:

| Component | Version | Install |
|---|---|---|
| **whisper-cpp** binary | **≥ 1.8.5** (1.8.6 recommended) | `brew install whisper-cpp` |
| **ffmpeg** | any recent | `brew install ffmpeg` (only used for the offline reference comparison; not strictly required for verbatim itself) |
| **whisper.cpp model file** | `ggml-large-v3-turbo` (~1.5 GB) | `mkdir -p ~/.cache/whisper-cpp && curl -L -o ~/.cache/whisper-cpp/ggml-large-v3-turbo.bin "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true"` |

> ⚠️ **Why ≥ 1.8.5?** whisper-cpp 1.8.4 has a server-side params leak (PR #3784) that causes the Metal pipeline to deadlock around the 7-8 minute mark of long recordings — `POST /inference` hangs forever while `GET /` keeps answering. 1.8.5 fixes it, 1.8.6 is the current stable. The app will still run on 1.8.4 but verbatim transcripts on long meetings will silently truncate.

**Verify your install** before enabling verbatim:

```bash
brew list --versions whisper-cpp           # should print 1.8.5 or higher
ls -la ~/.cache/whisper-cpp/ggml-large-v3-turbo.bin   # should be ~1.5 GB
```

**Optional env-var overrides** (defaults match the install paths above):
```bash
export WHISPER_SERVER_BIN=/opt/homebrew/bin/whisper-server
export WHISPER_MODEL_PATH=$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin
```

If verbatim is enabled but a prerequisite is missing or whisper-server fails to start, the app surfaces a macOS notification (`Verbatim transcript unavailable: …`) and the **mp4 recording continues normally** — verbatim soft-fails, never blocks recording.

## Build

```bash
bash build.sh
```

Produces:
- `MeetingRecorder.app` — the app bundle
- `MeetingRecorder.dmg` — distributable image

First build downloads WhisperKit sources (~several hundred MB, 5-15 min). Incremental builds take seconds.

## Run

```bash
open MeetingRecorder.app
```

Grant **Screen Recording** and **Microphone** permission when prompted.

To enable the rolling-summary feature, export the backend URL before launch:

```bash
export LIVE_SUMMARY_URL="https://your-backend.example.com"
export LIVE_SUMMARY_API_KEY="<optional>"        # only if backend requires it
open MeetingRecorder.app
```

The backend must expose `POST /api/live-summary` matching the contract below.

## Backend contract

**Request** (JSON):
```json
{
  "sessionId":      "<uuid>",
  "transcriptText": "[00:00:05] ...",
  "elapsedSec":     60,
  "meetingType":    "general|weekly|tech|customer|interview",
  "isFinal":        false
}
```

**Response 200**:
```json
{
  "summary":     "...",
  "highlights":  [{"point": "...", "detail": "..."}],
  "lowlights":   [{"point": "...", "detail": "..."}],
  "actions":     [{"task": "...", "owner": "...", "deadline": "...", "priority": "..."}],
  "decisions":   [{"decision": "...", "rationale": "..."}],
  "generatedAt": "<iso8601>",
  "tokensInput":  123,
  "tokensOutput": 456
}
```

Error codes: `400 VALIDATION_ERROR`, `429 RATE_LIMITED`, `500 INTERNAL`, `503 BEDROCK_UNAVAILABLE`, `504 BEDROCK_TIMEOUT`.

The client POSTs every 180 s during recording and sends one final request with `isFinal: true` on Stop (bypassing per-session rate limit). On 3 consecutive failures the panel displays a red "Summary offline" banner; transcript keeps writing.

## Source layout

```
MeetingRecorderApp.swift     # NSApplicationDelegate, menu-bar UI, session wiring
AudioRecorder.swift          # SCStream + AVCaptureSession, AAC via AVAssetWriter, PCM fan-out
DefaultInputWatcher.swift    # CoreAudio HAL watcher: auto-follow system default mic
LiveCaptions.swift           # WhisperKit wrapper on a serial dispatch queue
CaptionPanel.swift           # Floating NSPanel with captions (top) + summary (bottom)
NotesWriter.swift            # TranscriptBuffer + atomic .md writer
SummaryClient.swift          # 180s timer + POST + JSON decode
WhisperServerProcess.swift   # whisper-server subprocess lifecycle + watchdog restart
VerbatimWriter.swift         # atomic .verbatim.md writer (NotesWriter sibling)
VerbatimTranscriber.swift    # WAV encode + multipart POST + LocalAgreement-2 + line builder
Package.swift                # SPM manifest declaring WhisperKit dependency
build.sh                     # swift build → lipo (if needed) → codesign → hdiutil DMG
Info.plist                   # Bundle Info.plist
```

## Privacy & entitlements

Ad-hoc signed with:
- `com.apple.security.device.audio-input`
- `com.apple.security.device.screen-capture`
- `com.apple.security.network.client`

Audio never leaves the local machine. Only the **transcript text** (plus session UUID and elapsed-seconds integer) is sent to the configured `LIVE_SUMMARY_URL`. No original audio data is uploaded anywhere.

## License

Internal; not yet published.
