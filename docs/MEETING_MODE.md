# Meeting mode — plan

Status: **L1 (live subtitles) implemented** on the `feature/meeting-mode` branch; L2–L5 planned. Spike results that shaped the decisions below are in [prototypes/meeting-spikes](../prototypes/meeting-spikes/README.md).

Measured end to end (M4 Pro, German → Turkish, synthesized speech played in QuickTime): recognition 0.6–0.7 s and translation 0.3–0.5 s per phrase. Including ~0.6 s to notice the pause, a subtitle appears about 1.7 s after the speaker finishes a sentence.

Meeting mode turns Polylocal into a local, two-way interpreter for video calls (Zoom, Google Meet, Teams, Slack huddles, FaceTime…). Everything — speech recognition, translation, speech synthesis — runs on the Mac, like the rest of the app.

Example: the user speaks Turkish, the other participants speak German.

- They speak German → the user sees Turkish subtitles and (optionally) hears a Turkish voice instead of the original audio.
- The user speaks Turkish → the meeting hears a German voice through a Polylocal virtual microphone.
- Both the original and the translated transcript are saved to a folder.

---

## 1. Feature levels

The feature is split into levels that each ship on their own. Each level is useful even if the next one slips.

| Level | What the user gets | New system pieces |
|---|---|---|
| **L1 — Live subtitles** | Floating, always-on-top subtitle bar: incoming speech, transcribed and translated | System-audio capture, streaming ASR, subtitle overlay |
| **L2 — Meeting notes** | Original + translated transcript per meeting, saved to a folder; optional summary | Transcript store, exporters |
| **L3 — Incoming interpretation** | The meeting app's original audio is muted for the user; a translated voice plays instead | Per-process mute (Core Audio tap), TTS, playback queue |
| **L4 — Outgoing interpretation** | The user's speech is translated and spoken into the meeting via a virtual microphone | Mic capture, virtual audio device (driver), TTS routed to it |
| **L5 — Polish** | Speaker labels, per-meeting glossary, voice choices, hotkeys, auto-start on call | Diarization, meeting-app detection |

---

## 2. Pipeline

```
Incoming (them → user)
  meeting app audio ──Core Audio process tap (muted for user in L3)──▶ VAD ─▶ streaming ASR (src lang)
      ─▶ segmenter ─▶ translate (Gemma, existing engine) ─▶ subtitle overlay (L1)
                                                         ─▶ transcript store (L2)
                                                         ─▶ TTS (target lang) ─▶ user's output device (L3)

Outgoing (user → them)
  microphone ──voice processing / AEC──▶ VAD ─▶ streaming ASR (user lang) ─▶ segmenter ─▶ translate
      ─▶ TTS (their lang) ─▶ "Polylocal Microphone" virtual device ─▶ selected as mic in Zoom/Meet/Teams (L4)
                         ─▶ transcript store (L2)
```

Two independent lanes share one translation engine. `llama-server` is started with two slots (`--parallel 2`) so the lanes do not block each other.

### Latency budget (target: 1.5–3 s from end of phrase to translated voice)

| Stage | Target |
|---|---|
| VAD end-of-phrase detection | 300–500 ms of silence |
| ASR of a 3–8 s phrase | 200–600 ms |
| Translation (first token / full sentence) | ~120 ms / 300–800 ms |
| TTS first audio | 100–300 ms |

Subtitles can update faster: show the partial ASR text (source language) immediately, and swap in the translation when the phrase is final. Translating unfinished sentences gives bad results, especially for German verb-final clauses. The voice (L3/L4) always waits for a finished phrase.

---

## 3. Component decisions

### 3.1 System-audio capture — Core Audio process taps

- `AudioHardwareCreateProcessTap` with a `CATapDescription` (macOS 14.2+) captures the audio of specific processes, e.g. only the meeting app, without a virtual driver.
- `CATapDescription.muteBehavior = .mutedWhenTapped` silences that process for the user while Polylocal still receives its audio. This is exactly what L3 needs ("the user does not hear the original").
- Permission: the "System Audio Recording Only" privacy prompt (`NSAudioCaptureUsageDescription`).
- Browser-based meetings (Meet in Chrome/Safari) are tapped by the browser's audio process. This also captures other tabs; the UI should say so.
- Alternative: ScreenCaptureKit audio. It needs the broader Screen Recording permission and cannot mute, so it is the fallback only.

### 3.2 Voice activity detection

- Silero VAD (MIT), run with ONNX Runtime or a Core ML conversion. Very small, ~1 ms per 30 ms frame.
- It segments speech into phrases, drops silence before ASR, and serves as the end-of-turn signal.

### 3.3 Speech recognition (ASR)

Behind a `SpeechRecognizer` protocol, like the translation engines:

| Option | Pros | Cons |
|---|---|---|
| **whisper.cpp** (MIT), `large-v3-turbo` Q5 (~550 MB) | 99 languages incl. Turkish and German; same build tooling as llama.cpp; Metal | Not natively streaming; run on VAD phrases; occasional hallucinations on silence (VAD fixes most) |
| **WhisperKit** (MIT, Core ML) | Streaming, ANE acceleration, Swift package | Extra dependency; model conversion |
| **Apple SpeechAnalyzer** (macOS 26+) | On-device, streaming, no model download, low power | macOS 26+ only; language list set by Apple |
| Parakeet TDT v3 (CC-BY-4.0) | Very fast | 25 European languages, no Turkish |

Proposal: whisper.cpp as the default (works on macOS 14, covers every language pair), SpeechAnalyzer as an automatic fast path on macOS 26+ when both languages are supported. Spike S2 decides.

### 3.4 Translation

- This is the existing `TranslationEngine` with a new `Kind.interpret`: short spoken phrases, spoken register, previous 2–3 phrases as context, glossary applied.
- Prompt rule: keep numbers and names, do not add explanations, output speakable text.
- RAM: Gemma 4 E4B (~5 GB) + Whisper turbo (~1.5 GB) + TTS fits a 16 GB Mac. On 8 GB, use E2B and whisper `small`.

### 3.5 Speech synthesis (TTS)

| Option | Notes |
|---|---|
| **AVSpeechSynthesizer** (default) | Free, offline, all macOS languages (incl. Turkish and German, with downloadable Enhanced/Premium voices). `write(_:toBufferCallback:)` gives PCM buffers that can be routed to any device, including the virtual mic |
| Piper / Kokoro / other neural TTS | More natural, but uneven language coverage (Kokoro has no Turkish/German) and license checks per voice; later, behind a `SpeechSynthesizer` protocol |
| Voice cloning (user's own voice) | Out of scope for now; consent and impersonation risk. Revisit only with explicit opt-in |

Speaking rate adapts to the backlog: if the queue grows beyond about 3 s, speak faster (rate up to about 1.15×). If it grows beyond about 8 s, drop to subtitles only for that lane and show a hint.

### 3.6 Virtual microphone (L4 only)

The meeting app must receive the translated voice as a microphone. macOS has no API for this without a driver.

| Option | Notes |
|---|---|
| **Audio Server Plug-in (HAL driver)** built with [libASPL](https://github.com/gavv/libASPL) (MIT) | Proven approach (BlackHole, Loopback use it). Installed to `/Library/Audio/Plug-Ins/HAL/`, needs an admin password once and a `coreaudiod` restart. Signed and notarized with our Developer ID |
| DriverKit audio driver (system extension) | Modern, user-approved in System Settings; requires an entitlement Apple grants on request. Possible later migration |
| Ask users to install BlackHole | Zero driver work, but GPL-3.0, an extra install, and confusing. Fallback for a beta only |

- The driver exposes one device, "Polylocal Microphone".
- The app writes TTS audio into it through shared memory (ring buffer); the meeting app reads from it.
- When the user's lane is idle, the device passes the user's real mic through at low level or silence (configurable), so the meeting does not hear dead air when the user is not speaking.
- The installer is a separate signed `.pkg` inside the app ("Install Polylocal Microphone…"). Uninstall is in Settings.

### 3.7 Echo and feedback

- The incoming translated voice plays on the user's speakers and must not be picked up by the mic and sent back translated.
- Recommendation is headphones. In addition, the mic is captured through `AVAudioEngine` with voice processing (`setVoiceProcessingEnabled(true)`, Apple's AEC).
- The outgoing lane is also paused while the incoming TTS is speaking, if no headphones are detected.
- The user's own outgoing TTS never plays on the user's speakers.

---

## 4. Meeting notes (L2)

Folder layout (default `~/Documents/Polylocal Meetings/`, configurable):

```
2026-11-03 14-00 Zoom — Weekly sync/
  transcript.md          # interleaved: time, speaker, original, translation
  transcript.original.md # source languages only
  transcript.<target>.md # translations only
  meeting.json           # metadata + segments (start/end, lane, lang, text, translation)
  summary.md             # optional, generated locally after the meeting
```

- Segments are appended as they finalize, so a crash loses at most the current phrase.
- Audio is **not** stored by default. Optional "keep audio" writes `audio.m4a`.
- After the meeting, an optional local summary pass with Gemma produces decisions, action items and open questions, in both languages.
- A consent reminder is shown the first time: recording or transcribing others may require their consent depending on the jurisdiction. There is also an optional "announce" button that speaks a short notice into the meeting in both languages.
- Privacy: same rules as history. Local only, the folder is readable only by the user, and transcript text is never logged.

---

## 5. UI

- **Menu bar:** "Start meeting mode" (hotkey, e.g. ⌃⌥M). Pick the meeting app (auto-suggest the running one: zoom.us, Teams, Chrome/Safari tab with meet.google.com…), the languages ("They speak: auto / German", "I speak: Turkish"), and the levels (Subtitles · Hear translation · Speak translation · Save notes).
- **Subtitle overlay:** a floating, click-through, draggable panel at the bottom of the screen, two lines, last phrase plus the current one. It can optionally show the original under the translation. It stays visible over full-screen apps. Font size and opacity are configurable.
- **Control pill:** shows the state of each lane (listening / translating / speaking). It also has buttons to pause the outgoing voice ("let me speak directly"), push-to-talk mode, and stop.
- **Settings → Meeting:** voices per language, speaking rate, notes folder, keep audio, the virtual mic install/uninstall, and a test sound.

---

## 6. Work breakdown

### Spikes first (de-risk before building UI)

| # | Spike | Done when |
|---|---|---|
| S1 | Process tap on zoom.us / Chrome with `mutedWhenTapped` | CLI records the app's audio to WAV while the user hears nothing from it; unmutes on exit |
| S2 | ASR latency and quality: whisper.cpp turbo vs SpeechAnalyzer vs WhisperKit on Turkish and German speech | Table of latency/WER on M4 Pro (and M1 if available); default chosen |
| S3 | Segmenter + translation of spoken phrases | Prompt and context window chosen; German→Turkish verb-final cases readable |
| S4 | AVSpeechSynthesizer → PCM → arbitrary output device | TTS audible on a chosen device without changing the system default |
| S5 | libASPL virtual mic prototype | Zoom/Meet lists "Polylocal Microphone" and transmits a test tone written by a separate process |
| S6 | Echo test with speakers + voice processing | Incoming TTS is not re-transcribed by the outgoing lane |

### Build

1. **Core types** (`PolylocalCore`): `MeetingSession`, `Lane` (incoming/outgoing), `SpeechSegment`, the `SpeechRecognizer` and `SpeechSynthesizer` protocols, the phrase segmenter, and the backlog policy. All unit tested.
2. **New `Audio` module**: process-tap capture, mic capture with voice processing, resampling to 16 kHz mono, VAD, and output routing.
3. **`Speech` module**: whisper.cpp engine (bundled `whisper-server` or linked library, built like `llama-server`), SpeechAnalyzer engine, and AVSpeech TTS engine. ASR models go into the existing `ModelStore` and catalog.
4. **L1:** meeting session controller, subtitle overlay, menu bar entry, permissions onboarding for system audio and microphone.
5. **L2:** transcript store and exporters, summary prompt, notes folder setting.
6. **L3:** mute-when-tapped incoming lane, TTS playback queue with adaptive rate.
7. **L4:** HAL driver target (C++/libASPL) and its `.pkg` installer, the shared-memory ring buffer, the outgoing lane, the idle passthrough, and in-app install/uninstall.
8. **L5:** speaker labels (pyannote-style diarization is heavy; start with lane plus "speaker change" heuristics), per-meeting glossary, meeting-app auto-detection.
9. **Docs**: PRIVACY.md (audio, notes, consent), COMPATIBILITY.md (Zoom, Meet, Teams, Slack, FaceTime per level), README.

### Releases

- **v0.5:** L1 + L2 (subtitles and notes). No driver, lowest risk.
- **v0.6:** L3 (hear translation).
- **v0.7:** L4 (speak translation, virtual mic), behind a "beta" label.

---

## 7. Risks and open questions

1. **Latency feels like consecutive interpreting, not simultaneous.** 2–3 s per phrase is realistic locally. Subtitles hide most of it; the voice lanes need the backlog policy. Expectation-setting in the UI matters.
2. **Turn-taking:** while the user's German TTS is playing into the meeting, the other side may start talking. Should the outgoing voice be cut, or finished? Default: finish the current phrase, drop the queued ones.
3. **Driver distribution:** a HAL plug-in needs admin rights and a `coreaudiod` restart. Some corporate Macs block it. L4 must degrade gracefully to L1–L3.
4. **Battery and heat:** ASR, an LLM and TTS together for an hour. Measure in S2; offer an "efficient" profile (E2B + whisper small).
5. **Language auto-detection per phrase** (meetings with mixed languages): Whisper detects per segment; route by detected language, not only by lane.
6. **Legal/consent:** transcribing other people is regulated differently by country; the app shows a reminder and never uploads anything, but the responsibility stays with the user.
7. **Mute scope for browser meetings:** muting Chrome mutes all tabs. Acceptable for v0.6? Alternative: suggest the desktop meeting app.
