import Foundation
import Testing
@testable import Engines
@testable import TranslaterCore

@Suite struct DoublePressDetectorTests {
    /// Feeds presses and returns which ones fired. (`#expect` cannot wrap a mutating call.)
    func fired(_ presses: [(TimeInterval, Int)], window: TimeInterval = 0.4) -> [Bool] {
        var detector = DoublePressDetector(window: window)
        return presses.map { detector.press(at: $0.0, variant: $0.1) }
    }

    @Test func firesOnSecondPressInsideWindow() {
        #expect(fired([(10.0, 0), (10.3, 0)]) == [false, true])
    }

    @Test func slowSecondPressStartsNewWindow() {
        #expect(fired([(10.0, 0), (10.5, 0), (10.7, 0)]) == [false, false, true])
    }

    @Test func variantsDoNotMix() {
        #expect(fired([(1.0, 0), (1.1, 1), (1.2, 1)]) == [false, false, true])
    }

    @Test func tripleQuickPressFiresOnce() {
        #expect(fired([(1.0, 0), (1.1, 0), (1.2, 0)]) == [false, true, false])
    }
}

@Suite struct LanguageTests {
    let tr = Language.code("tr")!, en = Language.code("en")!, de = Language.code("de")!

    @Test func pairDirection() {
        let pair = LanguagePair(primary: tr, secondary: en)
        #expect(pair.target(forSource: tr) == en)
        #expect(pair.target(forSource: en) == tr)
        #expect(pair.target(forSource: de) == tr)
        #expect(pair.target(forSource: nil) == tr)
    }

    @Test(arguments: [
        ("Toplantıyı yarın saat üçe erteleyebilir miyiz?", "tr"),
        ("Can we push the meeting to three o'clock tomorrow?", "en"),
        ("Können wir das Meeting auf morgen um drei Uhr verschieben?", "de"),
    ])
    func detectsCommonLanguages(text: String, code: String) {
        #expect(LanguageDetector.detect(text)?.code == code)
    }

    /// Regression: with TR/EN hints, German text was detected as Turkish.
    @Test func hintsDoNotOverrideClearLanguage() {
        let german = "Können wir das Meeting auf morgen um drei Uhr verschieben?"
        #expect(LanguageDetector.detect(german, preferring: [tr, en])?.code == "de")
        let turkish = "Toplantıyı yarın saat üçe erteleyebilir miyiz?"
        #expect(LanguageDetector.detect(turkish, preferring: [tr, en])?.code == "tr")
    }

    @Test func tooShortIsNil() {
        #expect(LanguageDetector.detect("ok") == nil || LanguageDetector.detect("ok")?.code == "en")
    }
}

@Suite struct PromptTests {
    @Test func genericHasSystemAndUser() {
        let request = TranslationRequest(text: "Merhaba", source: .code("tr"), target: .code("en")!)
        let messages = PromptTemplate.generic.messages(for: request)
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[0]["content"]!.contains("from Turkish to English"))
        #expect(messages[1]["content"] == "Merhaba")
    }

    @Test func translateGemmaIsSingleUserTurn() {
        let request = TranslationRequest(text: "Merhaba dünya", source: .code("tr"), target: .code("de")!)
        let messages = PromptTemplate.translategemma.messages(for: request)
        #expect(messages.count == 1)
        #expect(messages[0]["content"]!.contains("Turkish (tr) to German (de)"))
        #expect(messages[0]["content"]!.hasSuffix("Merhaba dünya"))
    }
}

@Suite struct SSETests {
    @Test func parsesTokenDoneAndNoise() {
        #expect(SSEChunk.parse(#"data: {"choices":[{"delta":{"content":"Mer"}}]}"#) == .token("Mer"))
        #expect(SSEChunk.parse("data: [DONE]") == .done)
        #expect(SSEChunk.parse(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == .ignore)
        #expect(SSEChunk.parse(": keep-alive") == .ignore)
        #expect(SSEChunk.parse("") == .ignore)
    }

    @Test func requestDisablesThinking() throws {
        let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "m", template: .generic)
        let request = try engine.makeRequest(.init(text: "Hi", source: nil, target: .code("tr")!))
        #expect(request.url?.absoluteString == "http://127.0.0.1:1/v1/chat/completions")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["stream"] as? Bool == true)
        #expect(body["reasoning_effort"] as? String == "none")
    }
}

@Suite struct CatalogTests {
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("models/catalog.json")

    @Test func repoCatalogDecodes() throws {
        let catalog = try ModelCatalog.decode(Data(contentsOf: Self.catalogURL))
        #expect(!catalog.models.isEmpty)
        #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
        for model in catalog.models {
            #expect(model.sha256.count == 64)
            #expect(model.url.scheme == "https")
        }
    }

    @Test func recommendationFollowsRAM() throws {
        let models = try ModelCatalog.decode(Data(contentsOf: Self.catalogURL)).models
        #expect(CatalogModel.recommended(from: models, ramGB: 24)?.id == "gemma-4-e4b-q4_0")
        #expect(CatalogModel.recommended(from: models, ramGB: 8)?.id == "gemma-4-e2b-q4_0")
    }
}
