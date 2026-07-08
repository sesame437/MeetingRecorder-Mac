# MeetingRecorder

macOS menu-bar app that captures system audio + microphone into a single AAC `.mp4`, with optional local live captions and rolling meeting notes.

## Features

- Menu-bar icon with `Start Recording` / `Stop Recording`
- Captures system audio through ScreenCaptureKit and microphone audio through AVCaptureSession
- Mixes system audio and microphone into one stereo AAC track at 48 kHz, 192 kbps, wrapped in `.mp4`
- Built-in audio-level indicators for system and microphone audio
- Optional **Enable Live Captions** toggle: floating panel with rolling English captions from WhisperKit `openai_whisper-small.en`
- Optional rolling summary through a user-configured HTTP backend
- Writes a companion `.md` file next to each recording with transcript snippets, summary, highlights/lowlights, actions, and decisions
- Apple Silicon release bundle, ad-hoc signed, no code-sign team required

## Requirements

- macOS 15+
- Apple Silicon (arm64)
- Swift 5.9+ toolchain (Xcode 15+ command-line tools)

### Live Captions

First launch needs network to download the WhisperKit model, about 465 MB, cached at:

```bash
~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en
```

Captions work offline after the model is cached. Live captions currently use the English-only WhisperKit model.

## Build

```bash
bash build.sh
```

Produces:

- `MeetingRecorder.app`
- `MeetingRecorder.dmg`

First build downloads WhisperKit sources. Incremental builds are much faster.

For development checks:

```bash
swift build
```

## Run

```bash
open MeetingRecorder.app
```

Grant **Screen Recording** and **Microphone** permission when prompted.

Live summary is configured through the menu item **Summary Server**. There is no default backend URL. Without a configured URL, recording and captions still work; only summary stays inert and the floating panel shows `summary unavailable — configure Summary Server`.

Use the **Test** button in that panel to verify that `POST /api/live-summary` returns a 2xx response before recording.

The backend must expose `POST /api/live-summary` matching the contract below. A reference implementation lives at [sesame437/smart-meeting-notes](https://github.com/sesame437/smart-meeting-notes) (Express.js + Bedrock + FunASR).

The app does not send API keys or authentication headers to the summary backend.

## Backend Contract

**Request**:

```json
{
  "sessionId": "<uuid>",
  "transcriptText": "[00:00:05] ...",
  "elapsedSec": 60,
  "meetingType": "general",
  "isFinal": false
}
```

**Response 200**:

```json
{
  "summary": "...",
  "highlights": [{"point": "...", "detail": "..."}],
  "lowlights": [{"point": "...", "detail": "..."}],
  "actions": [{"task": "...", "owner": "...", "deadline": "...", "priority": "..."}],
  "decisions": [{"decision": "...", "rationale": "..."}],
  "generatedAt": "<iso8601>",
  "tokensInput": 123,
  "tokensOutput": 456
}
```

Error codes: `400 VALIDATION_ERROR`, `429 RATE_LIMITED`, `500 INTERNAL`, `503 BEDROCK_UNAVAILABLE`, `504 BEDROCK_TIMEOUT`.

The client posts once after about 30 seconds, then every 180 seconds during recording, and sends one final request with `isFinal: true` on Stop. On 3 consecutive failures the panel displays a red `Summary offline` banner; recording and local notes continue.

## Known Limitations

- System audio and microphone audio are mixed by buffer consumption, not by cross-device presentation timestamp alignment. Very long recordings may accumulate small sync drift between the two sources.
- If the app crashes or is force-quit during recording, the `.mp4` may not be finalized and may not be playable.

## Source Layout

```text
MeetingRecorderApp.swift     # NSApplicationDelegate, menu-bar UI, session wiring
AudioRecorder.swift          # SCStream + AVCaptureSession, AAC writer, PCM fan-out
DefaultInputWatcher.swift    # CoreAudio HAL watcher for default mic changes
LiveCaptions.swift           # WhisperKit live-caption wrapper
CaptionPanel.swift           # Floating NSPanel with captions and summary
NotesWriter.swift            # TranscriptBuffer + atomic .md writer
SummaryClient.swift          # Summary timer + POST + JSON decode
SummaryServerPanel.swift     # Menu-launched summary backend configuration
Package.swift                # SPM manifest declaring WhisperKit dependency
build.sh                     # Release build, app bundle, signing, DMG
Info.plist                   # Bundle metadata and permission text
```

## Privacy & Entitlements

Ad-hoc signed with:

- `com.apple.security.device.audio-input`
- `com.apple.security.network.client`

Audio never leaves the local machine. Only transcript text from live captions, session UUID, meeting type, and elapsed seconds are sent to the configured Summary Server URL. No original audio data is uploaded anywhere.

## License

Internal; not yet published.
