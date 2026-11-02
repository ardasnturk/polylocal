import Testing
@testable import PolylocalCore

@Suite struct AlternativesTests {
    let tr = Language.code("tr")!
    let de = Language.code("de")!

    @Test func parsesTheModelsJSON() {
        let reply = """
        ```json
        {"alternatives": ["Treffen", "Sitzung", "besprechung", "Treffen", ""], "turkish": "toplantıya"}
        ```
        """
        let parsed = WordAlternatives.parse(reply, span: "Besprechung", sourceText: "Yarın toplantıya gel.")
        #expect(parsed == WordAlternatives(source: "toplantıya", alternatives: ["Treffen", "Sitzung"]))
    }

    @Test func dropsASourceThatIsNotInTheText() {
        let parsed = WordAlternatives.parse(#"{"turkish": "Funktion", "alternatives": ["Merkmal"]}"#,
                                            span: "Funktion", sourceText: "Bu özelliği geliştirmek istiyorum.")
        #expect(parsed?.source == nil)
        #expect(parsed?.alternatives == ["Merkmal"])
    }

    @Test func rejectsNonJSON() {
        #expect(WordAlternatives.parse("Sorry, I can't.", span: "x", sourceText: "y") == nil)
    }

    @Test func marksTheSpanInThePrompt() {
        let request = TranslationRequest(text: "Yarın toplantıya gel.", source: tr, target: de,
                                         kind: .alternatives(span: "Besprechung", translation: "Komm morgen zur Besprechung."))
        let messages = PromptTemplate.generic.messages(for: request)
        #expect(messages[1]["content"]!.contains("German: Komm morgen zur [[Besprechung]]."))
        #expect(messages[0]["content"]!.contains("\"turkish\""))
    }

    @Test func prefixBecomesAnAssistantMessage() {
        let request = TranslationRequest(text: "Yarın gel.", source: tr, target: de, prefix: "Komm")
        let messages = PromptTemplate.generic.messages(for: request)
        #expect(messages.last == ["role": "assistant", "content": "Komm"])
    }

    @Test func informalNamesTheWordForGerman() {
        let request = TranslationRequest(text: "Gelebilir misiniz?", source: tr, target: de, formality: .informal)
        #expect(PromptTemplate.generic.messages(for: request)[0]["content"]!.contains("familiar form of \"you\", du"))
    }

    @Test func translateGemmaGetsFormalityAndGlossary() {
        let request = TranslationRequest(text: "Geliştirici gelsin.", source: tr, target: de, formality: .formal,
                                         glossary: [GlossaryEntry(source: "Geliştirici", target: "Entwickler", targetLanguage: de)])
        let prompt = PromptTemplate.translategemma.messages(for: request)[0]["content"]!
        #expect(prompt.contains("formally"))
        #expect(prompt.contains("\"Geliştirici\" → \"Entwickler\""))
    }
}
