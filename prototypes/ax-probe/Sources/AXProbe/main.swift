// AX probe — Faz 0 prototype.
//
// Verifies the system-integration half of the architecture:
//   ⌘C+C   → read selected text in any app (AX, clipboard fallback) and translate it
//   ⌘⇧C+C  → translate the selection and replace it in place (AX, paste fallback)
// Every capture prints which path worked, so we can fill docs/COMPATIBILITY.md.
//
//   swift run ax-probe            # listen for the shortcuts
//   swift run ax-probe --dry      # capture only, no model call
//   swift run ax-probe --inspect  # dump the focused element after 3 s

import AppKit
import ApplicationServices
import NaturalLanguage

// MARK: - Config

let env = ProcessInfo.processInfo.environment
let baseURL = env["POLYLOCAL_BASE_URL"] ?? "http://localhost:11434/v1"
let model = env["POLYLOCAL_MODEL"] ?? "gemma4"
let pair = (env["POLYLOCAL_PAIR"] ?? "tr,en").split(separator: ",").map(String.init)
let dryRun = CommandLine.arguments.contains("--dry")
let doublePressWindow: TimeInterval = 0.4

let languageNames = ["tr": "Turkish", "en": "English", "de": "German", "fr": "French", "es": "Spanish"]

// MARK: - Accessibility helpers

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func focusedElement() -> AXUIElement? {
    // System-wide lookup first; asking the frontmost app directly is the more reliable fallback.
    var roots = [("system-wide", AXUIElementCreateSystemWide())]
    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
        roots.append(("frontmost app", AXUIElementCreateApplication(pid)))
    }
    for (name, root) in roots {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        log("focused element via \(name) failed (AXError \(status.rawValue))")
    }
    return nil
}

/// Chromium and Electron build their AX tree only when asked.
func enableAccessibilityTree(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

func isSecure(_ element: AXUIElement) -> Bool {
    let subrole: String? = attribute(element, kAXSubroleAttribute)
    return subrole == (kAXSecureTextFieldSubrole as String)
}

func selectionBounds(_ element: AXUIElement) -> CGRect? {
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue else { return nil }
    var boundsValue: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
          let boundsValue else { return nil }
    var rect = CGRect.zero
    AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
    return rect
}

func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
}

// MARK: - Capture

struct Capture {
    var text: String
    var via: String
    var element: AXUIElement?
    var role: String?
    var bounds: CGRect?
    var replaceable: Bool
}

func captureSelection(pasteboardChange: Int) -> Capture? {
    let app = NSWorkspace.shared.frontmostApplication
    if let pid = app?.processIdentifier { enableAccessibilityTree(pid: pid) }

    if let element = focusedElement() {
        if isSecure(element) {
            log("secure text field — skipped")
            return nil
        }
        let role: String? = attribute(element, kAXRoleAttribute)
        if let selected: String = attribute(element, kAXSelectedTextAttribute), !selected.isEmpty {
            return Capture(text: selected, via: "AX", element: element, role: role,
                           bounds: selectionBounds(element),
                           replaceable: isSettable(element, kAXSelectedTextAttribute))
        }
        // AX gave us an element but no selection; the app's own ⌘C already filled the pasteboard.
        if NSPasteboard.general.changeCount != pasteboardChange,
           let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            return Capture(text: text, via: "pasteboard", element: element, role: role,
                           bounds: selectionBounds(element), replaceable: false)
        }
    }
    if NSPasteboard.general.changeCount != pasteboardChange,
       let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
        return Capture(text: text, via: "pasteboard (no AX element)", element: nil, role: nil, bounds: nil, replaceable: false)
    }
    return nil
}

// MARK: - Replace

func replaceSelection(_ capture: Capture, with text: String) {
    if let element = capture.element, capture.replaceable {
        let before: String? = attribute(element, kAXValueAttribute)
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        let after: String? = attribute(element, kAXValueAttribute)
        // Some web views report success but ignore the write; detect that and fall back.
        if status == .success, before != after || before == nil {
            log("replaced via AX")
            return
        }
        log("AX write ignored (status \(status.rawValue)) — falling back to paste")
    }
    pasteReplacing(text)
}

func pasteReplacing(_ text: String) {
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    } ?? []
    pb.clearContents()
    pb.setString(text, forType: .string)

    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey: CGKeyCode = 9
    let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cgSessionEventTap)
    up?.post(tap: .cgSessionEventTap)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }
    log("replaced via paste (pasteboard restored)")
}

// MARK: - Translation (OpenAI-compatible, streaming)

func detectLanguage(_ text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = pair.map { NLLanguage($0) }
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue
}

func translate(_ text: String, onToken: @escaping (String) -> Void) async throws -> (String, String, Double, Double) {
    let source = detectLanguage(text) ?? pair[0]
    let target = source == pair[0] ? pair[1] : pair[0]
    let s = languageNames[source] ?? source, t = languageNames[target] ?? target
    let body: [String: Any] = [
        "model": model,
        "stream": true,
        "temperature": 0,
        "reasoning_effort": "none",
        "chat_template_kwargs": ["enable_thinking": false],
        "messages": [
            ["role": "system", "content": "You are a professional translator. Translate the user's text from \(s) to \(t). Output only the translation. Preserve meaning, tone, numbers and formatting."],
            ["role": "user", "content": text],
        ],
    ]
    var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let start = Date()
    var firstToken: Double?
    var output = ""
    let (bytes, _) = try await URLSession.shared.bytes(for: request)
    for try await line in bytes.lines {
        guard line.hasPrefix("data: ") else { continue }
        let payload = line.dropFirst(6)
        if payload == "[DONE]" { break }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let token = delta["content"] as? String, !token.isEmpty else { continue }
        if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
        output += token
        onToken(token)
    }
    return ("\(source)→\(target)", output.trimmingCharacters(in: .whitespacesAndNewlines),
            firstToken ?? 0, Date().timeIntervalSince(start))
}

// MARK: - Shortcut handling

var lastCopy: (time: TimeInterval, shift: Bool, pasteboardChange: Int)?

func log(_ message: String) { print("  · \(message)") }

func handleTrigger(replace: Bool, pasteboardChange: Int) {
    let app = NSWorkspace.shared.frontmostApplication
    print("\n▶ \(replace ? "⌘⇧C+C (replace)" : "⌘C+C (translate)")  app: \(app?.localizedName ?? "?") [\(app?.bundleIdentifier ?? "?")]")

    // Give the app's own ⌘C a moment to land on the pasteboard.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        guard let capture = captureSelection(pasteboardChange: pasteboardChange) else {
            log("nothing captured")
            return
        }
        log("captured via \(capture.via), role \(capture.role ?? "—"), replaceable: \(capture.replaceable)")
        if let b = capture.bounds { log("selection bounds \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height))") }
        print("  ┌ \(capture.text.replacingOccurrences(of: "\n", with: "\n  │ "))")
        if dryRun { return }

        Task { @MainActor in
            do {
                print("  └ ", terminator: "")
                let (direction, result, ttft, total) = try await translate(capture.text) { token in
                    print(token, terminator: ""); fflush(stdout)
                }
                print("")
                log(String(format: "%@  first token %.0f ms, total %.0f ms", direction, ttft * 1000, total * 1000))
                if replace { replaceSelection(capture, with: result) }
            } catch {
                log("translation failed: \(error.localizedDescription)")
            }
        }
    }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          event.getIntegerValueField(.keyboardEventKeycode) == 8,           // kVK_ANSI_C
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else {
        return Unmanaged.passUnretained(event)
    }
    let shift = flags.contains(.maskShift)
    let now = ProcessInfo.processInfo.systemUptime
    if let last = lastCopy, last.shift == shift, now - last.time < doublePressWindow {
        lastCopy = nil
        let change = last.pasteboardChange
        DispatchQueue.main.async { handleTrigger(replace: shift, pasteboardChange: change) }
    } else {
        lastCopy = (now, shift, NSPasteboard.general.changeCount)
    }
    return Unmanaged.passUnretained(event)
}

var eventTap: CFMachPort?

// MARK: - Inspect mode

func inspect() {
    print("Focus a text field in another app — dumping in 3 s…")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let app = NSWorkspace.shared.frontmostApplication
        if let pid = app?.processIdentifier { enableAccessibilityTree(pid: pid) }
        print("app: \(app?.localizedName ?? "?") [\(app?.bundleIdentifier ?? "?")]")
        guard let el = focusedElement() else { print("no focused AX element"); exit(0) }
        var names: CFArray?
        AXUIElementCopyAttributeNames(el, &names)
        for name in (names as? [String]) ?? [] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(el, name as CFString, &value)
            let text = value.map { String(describing: $0).prefix(120) } ?? "—"
            print("  \(isSettable(el, name) ? "✎" : " ") \(name): \(text)")
        }
        exit(0)
    }
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)  // keep logs intact when piped to a file
let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary) else {
    print("""
    Accessibility permission required.
    System Settings → Privacy & Security → Accessibility → enable your terminal app, then run again.
    """)
    exit(1)
}

if CommandLine.arguments.contains("--inspect") {
    inspect()
} else {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
        print("Could not create event tap. Grant Input Monitoring to your terminal app as well.")
        exit(1)
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("ax-probe listening — ⌘C+C translate, ⌘⇧C+C replace\(dryRun ? " (dry run)" : "")")
    print("model \(model) @ \(baseURL), pair \(pair.joined(separator: "↔")). Ctrl+C to quit.")
}

RunLoop.main.run()
