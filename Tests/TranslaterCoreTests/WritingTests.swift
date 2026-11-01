import Foundation
import Testing
@testable import Engines
@testable import TranslaterCore

@Suite struct GlossaryTests {
    let tr = Language.code("tr")!, en = Language.code("en")!

    @Test func relevantMatchesWholeWordsCaseInsensitive() {
        let entries = [
            GlossaryEntry(source: "pull request", target: "PR", targetLanguage: tr),
            GlossaryEntry(source: "deploy", target: "yayına alma", targetLanguage: tr),
            GlossaryEntry(source: "invoice", target: "fatura", targetLanguage: en),  // other target language
        ]
        let found = Glossary.relevant(entries, for: "Please review my Pull Request before redeploying.", target: tr)
        #expect(found.map(\.source) == ["pull request"])  // "redeploying" is not the word "deploy"
    }

    @Test func parsesCSVVariants() {
        let csv = """
        kaynak,hedef
        pull request,PR
        "deploy";"yayına alma"
        invoice\tfatura

        broken line
        """
        let entries = Glossary.parseCSV(csv, targetLanguage: tr)
        #expect(entries.map(\.source) == ["pull request", "deploy", "invoice"])
        #expect(entries.map(\.target) == ["PR", "yayına alma", "fatura"])
    }

    @Test func glossaryGoesIntoGenericPrompt() {
        let request = TranslationRequest(text: "Ship the deploy", source: .code("en"), target: tr,
                                         glossary: [GlossaryEntry(source: "deploy", target: "yayına alma", targetLanguage: tr)])
        #expect(PromptTemplate.generic.messages(for: request)[0]["content"]!.contains("\"deploy\" → \"yayına alma\""))
    }
}

@Suite struct WritingPromptTests {
    let tr = Language.code("tr")!

    @Test func rewriteStaysInLanguageForAnyTemplate() {
        let request = TranslationRequest(text: "selam", source: tr, target: tr, kind: .rewrite(.formal))
        for template in [PromptTemplate.generic, .translategemma] {
            let system = template.messages(for: request)[0]["content"]!
            #expect(system.contains("Rewrite the user's text in Turkish"))
            #expect(system.contains("professional"))
        }
    }

    @Test func completionUsesShortLimit() throws {
        let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "m", template: .generic)
        let complete = try engine.makeRequest(.init(text: "Merhaba ben", source: tr, target: tr, kind: .complete))
        let body = try JSONSerialization.jsonObject(with: complete.httpBody!) as! [String: Any]
        #expect(body["max_tokens"] as? Int == 32)
        let messages = body["messages"] as! [[String: String]]
        #expect(messages[0]["content"]!.contains("autocomplete engine for Turkish"))
    }
}

@Suite struct CompletionPolicyTests {
    let en = Language.code("en")!, tr = Language.code("tr")!

    @Test func triggersAfterSpaceAtLineEnd() {
        #expect(InlinePolicy.shouldComplete(prefix: "I will review the document and ", rest: "", target: en, detected: en))
        #expect(InlinePolicy.shouldComplete(prefix: "Thanks a lot, I will check it,", rest: "  ", target: en, detected: en))
    }

    @Test func skipsMidWordFinishedSentenceOtherLanguageOrTextAfter() {
        #expect(!InlinePolicy.shouldComplete(prefix: "I will review the docu", rest: "", target: en, detected: en))
        #expect(!InlinePolicy.shouldComplete(prefix: "I will review the document. ", rest: "", target: en, detected: en))
        #expect(!InlinePolicy.shouldComplete(prefix: "Bunu yarın kontrol edeceğim ", rest: "", target: en, detected: tr))
        #expect(!InlinePolicy.shouldComplete(prefix: "I will review the ", rest: "document", target: en, detected: en))
        #expect(!InlinePolicy.shouldComplete(prefix: "Hi there ", rest: "", target: en, detected: en))
    }

    @Test func cleansContinuation() {
        #expect(InlinePolicy.completionText("get back to you.\nExtra", after: "I will review it and ") == "get back to you.")
        #expect(InlinePolicy.completionText("get back to you.", after: "I will review it and,") == " get back to you.")
        #expect(InlinePolicy.completionText(", and then", after: "I will review it") == ", and then")
        #expect(InlinePolicy.completionText("review it and get back", after: "I will review it and ") == "get back")
        #expect(InlinePolicy.completionText("  \n", after: "x ") == nil)
    }
}

@Suite struct InlineRuleCodingTests {
    @Test func rulesSavedBeforeCompletionsStillDecode() throws {
        let old = #"[{"id":"6F1D2C3B-0000-4000-8000-000000000001","bundleID":"com.apple.TextEdit","appName":"TextEdit","target":{"code":"en","englishName":"English"},"formality":"automatic","isEnabled":true}]"#
        let rules = try JSONDecoder().decode([InlineRule].self, from: Data(old.utf8))
        #expect(rules.count == 1)
        #expect(rules[0].completions == false)
        let roundTrip = try JSONDecoder().decode([InlineRule].self, from: JSONEncoder().encode(rules))
        #expect(roundTrip == rules)
    }
}
