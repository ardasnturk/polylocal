import Foundation
import Testing
import PolylocalCore

@Suite struct ShortcutMatcherTests {
    enum A: Hashable, Sendable { case translate, replace }

    let altT = Shortcut(keyCode: 17, modifiers: [.control, .option], doublePress: false, keyLabel: "T")

    func run(_ shortcuts: [A: Shortcut], _ presses: [(UInt16, Shortcut.Modifiers, TimeInterval)])
        -> [ShortcutMatcher<A>.Result] {
        var matcher = ShortcutMatcher(shortcuts: shortcuts)
        return presses.map { matcher.press(keyCode: $0.0, modifiers: $0.1, at: $0.2) }
    }

    @Test func doublePressFiresWithoutConsuming() {
        let results = run([.translate: .defaultTranslate], [(8, .command, 1.0), (8, .command, 1.2)])
        #expect(results == [.armed, .fire(.translate, consume: false)])
    }

    @Test func shiftVariantIsSeparate() {
        let results = run([.translate: .defaultTranslate, .replace: .defaultReplace],
                          [(8, .command, 1.0), (8, [.command, .shift], 1.1), (8, [.command, .shift], 1.2)])
        #expect(results == [.armed, .armed, .fire(.replace, consume: false)])
    }

    @Test func typingInBetweenBreaksDoublePress() {
        let results = run([.translate: .defaultTranslate], [(8, .command, 1.0), (0, [], 1.1), (8, .command, 1.2)])
        #expect(results == [.armed, .none, .armed])
    }

    @Test func singlePressFiresAndConsumes() {
        let results = run([.translate: altT], [(17, [.control, .option], 1.0), (17, .control, 1.1)])
        #expect(results == [.fire(.translate, consume: true), .none])
    }

    @Test func extraModifierDoesNotMatch() {
        let results = run([.translate: .defaultTranslate], [(8, [.command, .option], 1.0), (8, [.command, .option], 1.1)])
        #expect(results == [.none, .none])
    }
}

@Suite struct ShortcutValidationTests {
    @Test func defaultsAreValidAndDistinct() {
        #expect(Shortcut.defaultTranslate.problem(conflictingWith: .defaultReplace) == nil)
        #expect(Shortcut.defaultReplace.problem(conflictingWith: .defaultTranslate) == nil)
    }

    @Test func singleCommandCIsReserved() {
        let single = Shortcut(keyCode: 8, modifiers: .command, doublePress: false, keyLabel: "C")
        #expect(single.problem(conflictingWith: nil) == .reservedSystemShortcut)
    }

    @Test func needsModifier() {
        let plain = Shortcut(keyCode: 17, modifiers: [], doublePress: true, keyLabel: "T")
        #expect(plain.problem(conflictingWith: nil) == .needsModifier)
    }

    @Test func sameKeysConflictEvenIfOnlyOneIsDouble() {
        let a = Shortcut(keyCode: 17, modifiers: [.control, .option], doublePress: false, keyLabel: "T")
        var b = a
        b.doublePress = true
        #expect(a.problem(conflictingWith: b) == .sameAsOther)
    }

    @Test func displayAndCopyDetection() {
        #expect(Shortcut.defaultTranslate.displayString == "⌘C C")
        #expect(Shortcut.defaultReplace.displayString == "⇧⌘C C")
        #expect(Shortcut.defaultTranslate.copiesSelection)
        #expect(!Shortcut.defaultReplace.copiesSelection)
    }

    @Test func codableRoundTripIncludingOff() throws {
        let data = try JSONEncoder().encode(Shortcut?.none)
        #expect(try JSONDecoder().decode(Shortcut?.self, from: data) == nil)
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(Shortcut.defaultReplace))
        #expect(back == .defaultReplace)
    }
}

@Suite struct FormalityPromptTests {
    @Test func formalAddsInstructionForTurkish() {
        let request = TranslationRequest(text: "Hi", source: .code("en"), target: .code("tr")!, formality: .formal)
        #expect(PromptTemplate.generic.messages(for: request)[0]["content"]!.contains("formally"))
    }

    @Test func ignoredForEnglishTarget() {
        let request = TranslationRequest(text: "Merhaba", source: .code("tr"), target: .code("en")!, formality: .informal)
        #expect(!PromptTemplate.generic.messages(for: request)[0]["content"]!.contains("informally"))
    }
}
