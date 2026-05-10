# MeetingRecorder

macOS menu-bar app that captures system audio + microphone into a single AAC track, with opt-in **live captions** (WhisperKit) and **rolling summary** (posted to a backend that calls AWS Bedrock Claude).

## Features

- Menu-bar icon; `Start Recording` / `Stop Recording`
- Captures system audio (ScreenCaptureKit) + microphone (AVCaptureSession), mixed into one stereo AAC @ 48kHz, 192kbps, wrapped in `.mp4`
- Built-in audio-level indicator for system + mic tracks
- **Enable Live Captions** toggle: shows a floating panel with rolling English captions (WhisperKit `openai_whisper-small.en`, local inference) and an automatically-refreshed meeting summary from a Bedrock-backed HTTP endpoint
- Writes a companion `.md` file next to each recording containing the transcript, summary, highlights/lowlights, actions, and decisions
- Universal single binary, ad-hoc signed, no code-sign team required

## Requirements

- macOS 15+
- Apple Silicon (arm64)
- Swift 5.9+ toolchain (Xcode 15+ command-line tools)
- First launch needs network to download the WhisperKit model (~465 MB, cached at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en`). Captions work offline after that.

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
MeetingRecorderApp.swift   # NSApplicationDelegate, menu-bar UI, session wiring
AudioRecorder.swift        # SCStream + AVCaptureSession, AAC via AVAssetWriter, PCM fan-out
LiveCaptions.swift         # WhisperKit wrapper on a serial dispatch queue
CaptionPanel.swift         # Floating NSPanel with captions (top) + summary (bottom)
NotesWriter.swift          # TranscriptBuffer + atomic .md writer
SummaryClient.swift        # 180s timer + POST + JSON decode
Package.swift              # SPM manifest declaring WhisperKit dependency
build.sh                   # swift build → lipo (if needed) → codesign → hdiutil DMG
Info.plist                 # Bundle Info.plist
```

## Privacy & entitlements

Ad-hoc signed with:
- `com.apple.security.device.audio-input`
- `com.apple.security.device.screen-capture`
- `com.apple.security.network.client`

Audio never leaves the local machine. Only the **transcript text** (plus session UUID and elapsed-seconds integer) is sent to the configured `LIVE_SUMMARY_URL`. No original audio data is uploaded anywhere.

## License

Internal; not yet published.
