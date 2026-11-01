# Meeting mode spikes

Throwaway CLIs that answer the risky questions in [docs/MEETING_MODE.md §6](../../docs/MEETING_MODE.md#6-work-breakdown) before any app code is written.

```bash
cd prototypes/meeting-spikes
swift run AudioTap --list                                   # audio processes (▶︎ = playing)
swift run AudioTap us.zoom.xos --seconds 10 --mute --out tap.wav
swift run ASRBench --locales
swift run ASRBench tap.wav de-DE
swift run TTSRoute --devices
swift run TTSRoute tr-TR "Yeni sürüm hazır." --device "MacBook Pro"
```

## Results (M4 Pro, macOS 27, 2026-11-01)

### S1 — per-app capture with a Core Audio process tap ✅

- `CATapDescription(stereoMixdownOfProcesses:)` + a private aggregate device works.
  - Target: `afplay` by PID, playing German speech.
  - Output: 48 kHz stereo Float32; first buffer after 33–36 ms.
  - The signal is steady (about −31 dBFS at a 0.2 player volume).
  - No crackles in the recorded WAV.
- With `muteBehavior = .mutedWhenTapped` the tapped audio still arrives normally, and the app is silent on the speakers. This was confirmed by ear during the L3 test: QuickTime playing German, only the Turkish voice audible.
- No permission prompt appeared, because the shell was already allowed. The app will need `NSAudioCaptureUsageDescription`.
- Processes are matched by bundle-ID prefix, so `com.google.Chrome` also covers `com.google.Chrome.helper`, where browser audio actually plays.

### S2 — speech recognition

| Engine | Language | Audio | First result | Done | RTF | Text |
|---|---|---|---|---|---|---|
| Apple SpeechAnalyzer | de-DE | 12.0 s (from the S1 tap) | 155 ms | 323 ms | 0.027 | Word-perfect (the first sentence was missing from the recording, not from recognition) |
| Apple SpeechAnalyzer | tr-TR | — | — | — | — | **Not supported** (no Turkish in `SpeechTranscriber.supportedLocales`) |
| whisper.cpp large-v3-turbo Q5, full window | tr / de | 2–12 s | — | 1,230–1,300 ms | 0.1–0.6 | Word-perfect in both languages |
| same, `--audio-ctx 768` (≈15 s window) | tr / de | 2–12 s | — | 590–690 ms | 0.06–0.27 | Word-perfect |
| same, `--audio-ctx 512` (≈10 s window) | tr / de | 2–12 s | — | 390–460 ms | 0.04–0.18 | Short phrases fine; 11 s clips cut off at the end |
| any of the above, `language=auto` | tr / de | 2–3 s | — | +180–280 ms | — | Language detected correctly |

> **Correction (L2 testing):** the second and third benchmark rounds above ran `whisper-server` with `-nf` (no temperature fallback). That made Whisper loop: phrases came out doubled or repeated many times, and the extra tokens made recognition slower. With fallback on, `--audio-ctx` 512, 640 and 768 were all correct on 5–8 s clips, at 220–340 ms per phrase. The app uses fallback and `audio_ctx` 768.

- SpeechAnalyzer covers en, de, fr, es, it, pt, ja, ko, zh, hi and some other Indic languages, but **not Turkish**.
- So whisper.cpp must be the default engine, as planned. SpeechAnalyzer stays as a fast path when the language is supported.
- whisper.cpp v1.9.5 (static, Metal embedded), `whisper-server`, warm, 6 threads, flash attention, `temperature=0`. Latency is per request over local HTTP and includes the full transcription.
- Whisper always encodes a fixed window (30 s by default), so latency barely depends on phrase length. Shrinking the window (`audio_ctx`) is the main speed lever. Choose it per phrase: about 50 per second of audio, plus 2 s of headroom, rounded up to a multiple of 64. Cap phrases at ~12 s in the segmenter (VAD).
- Setting the language explicitly saves ~200–300 ms. Pass the expected language per lane and use auto only for mixed meetings.
- Default: **whisper.cpp large-v3-turbo Q5 (574 MB)**, about 0.4–0.7 s per phrase on an M4 Pro. SpeechAnalyzer stays as an optional fast path (~0.3 s, no model download) for supported languages.
- Model: `ggml-large-v3-turbo-q5_0.bin`, 574,041,195 bytes, SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` (Hugging Face `ggerganov/whisper.cpp`).

### S4 — TTS into a chosen output device ✅

- `AVSpeechSynthesizer.write(_:toBufferCallback:)` produces PCM, and an `AVAudioEngine` whose output unit is set to a specific device ID plays it there. The system default output is untouched.
- First buffer: 379 ms for Turkish (Yelda) and 596 ms for German (Anna), measured cold, including voice loading. Synthesis is ~10× faster than real time.
- Only the default-quality voices are installed. Enhanced/Premium voices (System Settings → Accessibility → Spoken Content) sound much better; the app should point users to them.

## Open

- S2: real meeting audio (several speakers, noise, compression) instead of synthesized voices; M1/M2 timing; whether `audio_ctx` can be set per request or needs linking libwhisper directly.
- S3 (spoken-phrase translation prompt), S5 (virtual microphone), S6 (echo) — later.
