# Live Captions — Acceptance Smoke Run

**Date:** _TBD_
**Builder:** _your name_
**Commit:** _run `git rev-parse HEAD` in `MeetingRecorderApp/`_

## Prep

Before starting, rebuild the release app:

```bash
cd /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp
GIT_CONFIG_GLOBAL=/dev/null bash build.sh
```

First run may take 15-30 minutes (WhisperKit Core ML model compilation + two release slices + DMG). Subsequent runs are much faster.

Grant Screen Recording + Microphone permissions when macOS prompts (System Settings → Privacy & Security). If TCC remembers the old v2.7.0 binary, you may need to re-approve.

## Scenarios

### 1. Regression smoke (captions off)

- [ ] Toggle **off**. Record 30s. Verify `.mp4` plays in QuickTime; no `.md`; no floating panel.

Result:
```
(fill in: PASS / FAIL + notes)
```

### 2. Captions smoke

- [ ] Toggle **on**. Record 30s in English (read a paragraph aloud). Panel appears with captions scrolling; `.mp4` + `.md` both exist next to each other; `.md` transcript contains recognizable words.

Result:
```
(fill in)
```

### 3. Summary smoke

- [ ] Set `LIVE_SUMMARY_URL` to a running backend. Record 4 minutes. Summary populates in panel + `.md` at ~3:00. Final summary refresh visible when Stop is pressed.

Command template:
```bash
export LIVE_SUMMARY_URL="http://localhost:3300"
export LIVE_SUMMARY_API_KEY="your-test-key"
open /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp/MeetingRecorder.app
```

Result:
```
(fill in)
```

### 4. Offline smoke

- [ ] Set `LIVE_SUMMARY_URL` to a bogus host. Record ~10 minutes. Red "Summary offline" banner appears at approximately 9 minutes (after 3 failed POSTs).

Command template:
```bash
export LIVE_SUMMARY_URL="http://localhost:9999"
unset LIVE_SUMMARY_API_KEY
```

Result:
```
(fill in)
```

### 5. No-env smoke

- [ ] Unset both env vars. Record 1 minute with captions toggle on. Captions work; no summary attempts past the first (which will fail against default localhost:3300); no crash.

```bash
unset LIVE_SUMMARY_URL LIVE_SUMMARY_API_KEY
```

Result:
```
(fill in)
```

### 6. Model download smoke

- [ ] Delete WhisperKit cache and restart the app. First record with captions on shows a "Loading captions…" placeholder while the 250MB small.en model downloads; captions start appearing after the download completes; recording is unaffected during the wait.

```bash
rm -rf ~/Library/Caches/WhisperKit
open /Users/qiankai/Downloads/70-学习资料/qcli/MeetingRecorderApp/MeetingRecorder.app
```

Result:
```
(fill in)
```

### 7. Chinese regression

- [ ] Toggle **off**. Record a Chinese meeting. `.mp4` plays back. No `.md`, no panel, no WhisperKit activity in Console.app.

Result:
```
(fill in)
```

## Sign-off

All scenarios PASS → merge + tag. Any FAIL → stop and file a targeted fix task; do not declare the feature complete.
