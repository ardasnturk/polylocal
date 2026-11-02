import AppKit
import SwiftUI
import PolylocalCore

/// The translation, read-only. Clicking a word (or selecting a phrase) offers alternatives in a popover, like
/// DeepL; selecting the whole text copies it.
struct TranslationTextView: NSViewRepresentable {
    let translator: TranslatorModel
    var fontSize: CGFloat = 20
    /// Called after selecting everything copied the text.
    var onCopiedAll: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = WordTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 5
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        let font = NSFont.systemFont(ofSize: fontSize)
        if textView.string != translator.output || textView.font != font {
            textView.string = translator.output
            textView.font = font
            textView.textColor = .labelColor
            coordinator.popover?.close()
        }
        // Development aid: open the alternatives for a word once the translation is done, e.g. for UI checks.
        if !translator.isTranslating, let word = ProcessInfo.processInfo.environment["POLYLOCAL_ALTERNATIVES_FOR"],
           coordinator.popover == nil, !coordinator.didOpenDebugPopover {
            let range = (textView.string as NSString).range(of: word)
            if range.location != NSNotFound {
                coordinator.didOpenDebugPopover = true
                DispatchQueue.main.async { coordinator.showAlternatives(span: word, range: range) }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        var parent: TranslationTextView?
        weak var textView: WordTextView?
        var popover: NSPopover?
        private var lastCopied: String?
        var didOpenDebugPopover = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let parent else { return }
            let range = textView.selectedRange()
            let text = textView.string
            guard !text.isEmpty, range.location == 0, range.length == (text as NSString).length else {
                lastCopied = nil
                return
            }
            // Select all (⌘A or dragging over everything) copies once.
            guard lastCopied != text else { return }
            lastCopied = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            parent.onCopiedAll()
        }

        /// After a click or a drag: the word under a click, or the selected phrase.
        func didFinishMouseSelection(clickedAt point: NSPoint, dragged: Bool) {
            guard let textView, let parent else { return }
            let translator = parent.translator
            guard translator.mode == .translate, !translator.isTranslating, !translator.output.isEmpty else { return }
            let string = textView.string as NSString
            var range = textView.selectedRange()
            if !dragged || range.length == 0 {
                let index = textView.characterIndexForInsertion(at: point)
                guard index < string.length else { return }
                range = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
            }
            guard range.length > 0, range.length < string.length else { return }
            // Trim spaces and punctuation at the edges; a click on a comma offers nothing.
            let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            while range.length > 0, let scalar = string.substring(with: NSRange(location: range.location, length: 1)).unicodeScalars.first,
                  trimSet.contains(scalar) {
                range = NSRange(location: range.location + 1, length: range.length - 1)
            }
            while range.length > 0, let scalar = string.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)).unicodeScalars.first,
                  trimSet.contains(scalar) {
                range.length -= 1
            }
            guard range.length > 0 else { return }
            textView.setSelectedRange(range)
            showAlternatives(span: string.substring(with: range), range: range)
        }

        func showAlternatives(span: String, range: NSRange) {
            guard let textView, let parent, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            popover?.close()
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y

            let popover = NSPopover()
            // The development aid keeps it open while other windows come and go.
            popover.behavior = didOpenDebugPopover ? .applicationDefined : .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: AlternativesView(
                translator: parent.translator, span: span, range: range,
                close: { [weak popover] in popover?.close() }))
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
        }
    }
}

final class WordTextView: NSTextView {
    weak var coordinator: TranslationTextView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        // NSTextView tracks the drag itself and returns on mouse up.
        super.mouseDown(with: event)
        guard event.clickCount == 1, let current = window?.mouseLocationOutsideOfEventStream else { return }
        let end = convert(current, from: nil)
        let dragged = hypot(end.x - start.x, end.y - start.y) > 3
        coordinator?.didFinishMouseSelection(clickedAt: start, dragged: dragged)
    }
}

/// The popover for one word or phrase: alternatives from the model; picking one rebuilds the sentence.
struct AlternativesView: View {
    let translator: TranslatorModel
    let span: String
    /// UTF-16 range of `span` in the translation.
    let range: NSRange
    let close: () -> Void

    @State private var result: WordAlternatives?
    @State private var error: String?
    @State private var remember = false
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alternatives for “\(span)”")
                .font(.headline)
                .lineLimit(2)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if let result {
                if result.alternatives.isEmpty {
                    Text("No alternatives found.").foregroundStyle(.secondary).font(.callout)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(result.alternatives, id: \.self) { alternative in
                        Button { pick(alternative, result: result) } label: {
                            Text(alternative)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(hovered == alternative ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? alternative : nil }
                    }
                }
                if let term = result.source, !result.alternatives.isEmpty {
                    Divider()
                    Toggle("Always translate “\(term)” this way", isOn: $remember)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .help("Adds the choice to the glossary (Settings → Glossary)")
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding alternatives…").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .task {
            do {
                result = try await translator.alternatives(for: span)
                // Development aid (with POLYLOCAL_ALTERNATIVES_FOR): pick the first alternative.
                if ProcessInfo.processInfo.environment["POLYLOCAL_ALTERNATIVES_PICK"] != nil, let result,
                   let first = result.alternatives.first {
                    try? await Task.sleep(for: .seconds(1))
                    pick(first, result: result)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func pick(_ alternative: String, result: WordAlternatives) {
        translator.choose(alternative, for: span, at: range, source: result.source, remember: remember && result.source != nil)
        close()
    }
}
