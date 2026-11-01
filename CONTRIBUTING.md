# Contributing to Polylocal

Thanks for your interest. Bug reports, compatibility reports (which apps work and which do not), and pull requests are welcome.

## Build

Requirements: Apple Silicon Mac, macOS 14+, Xcode 16+ (Swift 6), and `cmake` (`brew install cmake`).

```bash
scripts/build-llama-server.sh   # build the bundled llama-server (llama.cpp, static, Metal)
scripts/build-whisper-server.sh # build the bundled whisper-server (whisper.cpp) for meeting mode
scripts/build-app.sh            # build/Polylocal.app (release); pass "debug" for a debug build
open build/Polylocal.app
```

The package can also be opened in Xcode via `Package.swift`.

Use a stable signing identity (`SIGN_IDENTITY`, or an "Apple Development" certificate): macOS ties the Accessibility permission to the code signature, so ad-hoc builds lose the permission on every rebuild.

## Tests

```bash
swift test
POLYLOCAL_NETWORK_TESTS=1 swift test                    # real download + SHA-256 verification (~60 MB)
POLYLOCAL_TEST_GGUF=/path/to/model.gguf swift test       # llama-server integration
```

Add or update tests for logic changes. Pure logic belongs in `PolylocalCore` so it can be tested without AppKit.

## Compatibility testing

`tools/compat/run.sh` drives ⌘C C and ⇧⌘C C in real apps and reads back the result:

```bash
tools/compat/run.sh textedit
tools/compat/run.sh safari textarea
tools/compat/run.sh chrome contenteditable
```

It needs a running Polylocal with a ready engine and Accessibility access for your terminal. It overwrites the clipboard during the run and restores it (text only) at the end.

**Safety rule:** never point it at messaging or email apps (Messages, WhatsApp, Discord, Slack, Mail, …). A stray ↩ can send a real message. The script refuses to send keys unless the expected app (and, for browsers, the test page) is frontmost; do not weaken that guard. Test messaging apps by hand.

Record results in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) with the date, macOS version, and model.

## Code guidelines

- Swift 6 with strict concurrency. Match the style of the surrounding code.
- No telemetry, analytics, or crash reporting that sends data off the device.
- Never log user text. Diagnostic logs (`os.Logger`, subsystem `dev.polylocal.app`) may contain metadata only: which path was used, lengths, timings, error codes.
- Never read secure or password fields.
- No new network access other than model downloads without discussion first. See [docs/PRIVACY.md](docs/PRIVACY.md).
- Keep pull requests focused. Describe how you tested, including which apps.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).

## Translating the UI

English is the development language: the English strings in the Swift code are the localization keys.
Translations live in `Resources/<language>.lproj/Localizable.strings` and are copied into the app by
`scripts/build-app.sh`.

To add a language:

1. Copy `Resources/tr.lproj/Localizable.strings` to `Resources/<code>.lproj/` and translate the right-hand side.
   Keep format specifiers (`%@`, `%lld`) in place.
2. Add the code to `CFBundleLocalizations` in `scripts/build-app.sh` and to the interface-language picker in
   `Sources/Polylocal/UI/SettingsView.swift`.
3. Check with `build/Polylocal.app/Contents/MacOS/Polylocal -AppleLanguages "(<code>)"`.

When you add UI text, write it in English; use `String(localized:)` for strings that are not passed directly to a
SwiftUI view, and add the Turkish entry to `Resources/tr.lproj/Localizable.strings`.

## App icon

The icon is drawn in code by `scripts/make-icon.swift` and committed as `Resources/AppIcon.icns`.
After changing the script, run `swift scripts/make-icon.swift --preview` (the preview lands in
`build/AppIcon-1024.png`) and commit the new `.icns`.
