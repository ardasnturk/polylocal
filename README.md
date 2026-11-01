# Polylocal

Polylocal is a free, open-source macOS menu-bar app that translates and rewrites text in any app using an AI model that runs entirely on your Mac. Select text and press ⌘C twice to see a translation, translate what you are typing and replace it in place, or get inline translation suggestions while you write. Your text never leaves the device: the only network access is downloading a model.

> Status: early development (roadmap phases 0–4 implemented and verified in TextEdit). There is no prebuilt release yet; build from source.

## Features

- **Quick translate (⌘C C):** select text in any app and press ⌘C twice; a popup shows the translation as it streams in.
- **Translate and replace (⇧⌘C C):** translate the selection, preview it, and press ↩ to replace the original text.
- **Main window:** a two-pane translation window (DeepL-style) that translates as you type and detects the source language automatically.
- **Customizable shortcuts:** single or double press, e.g. ⌃⌥C.
- **Formal / informal address** (e.g. Sie/du, siz/sen).
- **Inline suggestions:** add a rule for an app or website; when you type in another language there, a translation suggestion appears below the caret. Tab accepts, Esc dismisses, ⌥Tab inserts a real tab.
- **Sentence completion:** optionally, per rule, suggests the rest of a sentence while you type in the target language (only at word boundaries).
- **Writing assistant:** rewrite text in one of five styles: Correct, Fluent, Formal, Casual, Concise. Available in the popup, in the main window, or via an optional shortcut.
- **Glossary:** make specific terms always translate the same way; import from CSV.
- **Optional history:** off by default; stored only on this Mac, readable only by your user account.

The user interface is currently in Turkish only. English localization is planned.

## Requirements

- Apple Silicon Mac, macOS 14 Sonoma or later
- About 5 GB of free RAM and ~4.6 GB of disk space for the default model
- To build: Xcode 16 or later (Swift 6) and `cmake` (`brew install cmake`) for building the bundled `llama-server`

## Build from source

```bash
git clone https://github.com/<owner>/polylocal.git
cd polylocal
scripts/build-llama-server.sh   # builds llama.cpp's llama-server (static, Metal)
scripts/build-app.sh            # builds build/Polylocal.app (release), bundling llama-server
open build/Polylocal.app
```

`scripts/build-app.sh debug` builds a debug configuration. Set `SIGN_IDENTITY` to sign with a specific identity; otherwise the first "Apple Development" identity is used, or ad-hoc signing as a last resort. A stable signing identity matters during development because macOS ties the Accessibility permission to the code signature.

To produce a signed DMG (Developer ID, hardened runtime), with optional notarization through a `notarytool` keychain profile:

```bash
NOTARY_PROFILE=<profile-name> scripts/make-dmg.sh
```

### Tests

```bash
swift test
POLYLOCAL_NETWORK_TESTS=1 swift test                    # real download + SHA-256 verification (~60 MB)
POLYLOCAL_TEST_GGUF=/path/to/model.gguf swift test       # llama-server integration
```

## First run

On first launch an onboarding assistant walks you through:

1. **Accessibility permission** (System Settings → Privacy & Security → Accessibility). Polylocal needs it to detect the shortcuts and to read and replace selected text.
2. **Model download.** Pick a model from the catalog; the default is Gemma 4 E4B (~4.6 GB). The file is downloaded from Hugging Face and verified with SHA-256.

If you rebuild the app with an ad-hoc signature, macOS may revoke the Accessibility permission; grant it again or use a stable signing identity.

## Default shortcuts

| Shortcut | Where | Action |
|---|---|---|
| ⌘C C | any app | Translate the selection in a popup |
| ⇧⌘C C | editable field | Translate, preview, and replace the text |
| ⌘↩ | popup | Replace the selection with the translation |
| ↩ | replace preview | Confirm the replacement |
| Esc | popup / suggestion | Close |
| Tab | inline suggestion | Accept the suggestion |
| ⌥Tab | inline suggestion | Insert a real tab instead |

All global shortcuts can be changed in Settings → General → Shortcuts. The writing assistant has no shortcut by default; you can assign one.

**Known conflict:** ⇧⌘C can collide with clipboard managers such as Raycast's Clipboard History. Rebind either shortcut if both react. See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Privacy

All translation runs locally. The app makes network requests only to download models from Hugging Face. There is no telemetry. History is off by default; the diagnostic log never contains your text; password fields are never read. Details: [docs/PRIVACY.md](docs/PRIVACY.md).

## Engines and models

- **Built-in engine:** `llama-server` from [llama.cpp](https://github.com/ggml-org/llama.cpp), bundled inside the app and run as a child process. End users do not need Homebrew.
- **Ollama (optional):** if you already run [Ollama](https://ollama.com), Polylocal can use its models instead (e.g. `ollama pull gemma4`).

Models are listed in [models/catalog.json](models/catalog.json). Polylocal does not ship a model; you choose one and download it yourself.

| Model | Size | License | Notes |
|---|---:|---|---|
| Gemma 4 E4B (Q4_0) | 4.6 GB | Apache 2.0 | Default. Best quality in our benchmark; ~5 GB RAM, first token ~120 ms on M4 Pro |
| Gemma 4 E2B (Q4_0) | 2.8 GB | Apache 2.0 | Lighter option for 8 GB Macs |
| Gemma 4 26B-A4B (Q4_0) | 14.6 GB | Apache 2.0 | Quality mode; needs 24 GB RAM; not benchmarked yet |
| TranslateGemma 4B (Q4_K_M) | 2.5 GB | Gemma Terms of Use | Translation-specific; weaker than Gemma 4 E4B for Turkish |

Benchmark results: [tools/bench/RESULTS.md](tools/bench/RESULTS.md).

## Project layout

| Path | Contents |
|---|---|
| [Sources/PolylocalCore](Sources/PolylocalCore) | Pure logic: languages, prompts, shortcuts, glossary, inline segmenting, catalog types |
| [Sources/Engines](Sources/Engines) | OpenAI-compatible streaming client, `llama-server` process, Ollama |
| [Sources/ModelManager](Sources/ModelManager) | Catalog, downloads, SHA-256 verification, hardware info |
| [Sources/SystemIntegration](Sources/SystemIntegration) | Global shortcuts (event tap), Accessibility text capture/replace, focus watching, permissions |
| [Sources/Polylocal](Sources/Polylocal) | The menu-bar app: app model, engine controller, history, UI |
| [Tests](Tests) | Swift Testing suites |
| [scripts](scripts) | Build, `llama-server`, and DMG scripts |
| [models/catalog.json](models/catalog.json) | Downloadable model catalog (bundled into the app) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture and roadmap |
| [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) | App compatibility matrix |
| [docs/PRIVACY.md](docs/PRIVACY.md) | What data the app touches and where it goes |
| [tools/bench](tools/bench) | Translation model benchmark |
| [tools/compat](tools/compat) | Semi-automatic compatibility test |
| [prototypes/ax-probe](prototypes/ax-probe) | Phase 0 shortcut and Accessibility prototype |

## Roadmap

Not done yet: prebuilt releases on GitHub, Sparkle auto-update, a Homebrew cask, English UI, and verified inline suggestions in browsers and Electron apps. See [docs/ARCHITECTURE.md §9](docs/ARCHITECTURE.md#9-roadmap).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Models are not part of this repository and come with their own licenses.
