# ax-probe

Phase 0 prototype. Validates the system-integration part of the architecture: a global shortcut, reading the selected text, replacing it, and translating with a local model.

| Shortcut | What it does |
|---|---|
| ⌘C C | Reads the selected text, translates TR↔EN, and prints it to the terminal |
| ⇧⌘C C | Translates the selected text and replaces it in the app |

## Running

```bash
cd prototypes/ax-probe
swift run ax-probe            # listen for shortcuts
swift run ax-probe --dry      # capture only, do not call the model
swift run ax-probe --inspect  # after 3 s, dump all AX attributes of the focused element
```

Your terminal app needs the **Accessibility** permission (System Settings → Privacy & Security → Accessibility). Some systems also ask for **Input Monitoring**.

Environment variables:

| Variable | Default |
|---|---|
| `POLYLOCAL_BASE_URL` | `http://localhost:11434/v1` (Ollama) |
| `POLYLOCAL_MODEL` | `gemma4` |
| `POLYLOCAL_PAIR` | `tr,en` (the language is detected and translated into the other one) |

## Findings (2026-11-01, macOS 27.0.1, M4 Pro)

- **Double ⌘C detection** is reliable only with a listen-only (`listenOnly`) event tap. The app's own copy behavior is not affected.
- **The system-wide focus query** (`AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`) fails with `-25204` (`kAXErrorCannotComplete`). Asking the **frontmost app's** `AXUIElement` works. The app should follow that order.
- In TextEdit, reading, the selection position, and replacing via AX all work.
- With a cold model, the first translation took ~1.1 s; once warm, the first token arrived in ~380 ms. The app needs to warm up the model in advance.

## Known gaps

- If AX cannot read the selection for ⇧⌘C C, there is no fallback. The app should send a synthetic ⌘C and read the clipboard.
- The translation is only printed to the terminal; there is no popup (Phase 1).
