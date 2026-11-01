import Foundation
import Testing
import PolylocalCore

@Suite struct TextSegmenterTests {
    @Test func singleParagraph() {
        let text = "  Merhaba dünya, nasılsın?  "
        let seg = TextSegmenter.paragraph(in: text, caretUTF16: 10)
        #expect(seg?.text == "Merhaba dünya, nasılsın?")
        #expect((text as NSString).substring(with: seg!.range) == "Merhaba dünya, nasılsın?")
    }

    @Test func pickParagraphUnderCaret() {
        let text = "Birinci satır burada.\nİkinci satır şurada.\nÜçüncü."
        let caret = (text as NSString).range(of: "şurada").location
        #expect(TextSegmenter.paragraph(in: text, caretUTF16: caret)?.text == "İkinci satır şurada.")
    }

    @Test func caretAtEndOfText() {
        let text = "Bir iki üç"
        #expect(TextSegmenter.paragraph(in: text, caretUTF16: (text as NSString).length)?.text == "Bir iki üç")
    }

    @Test func caretOnFreshEmptyLineIsNil() {
        let text = "Bir iki üç\n"
        #expect(TextSegmenter.paragraph(in: text, caretUTF16: (text as NSString).length) == nil)
    }

    @Test func utf16RangesWithEmoji() {
        let text = "👋 hello there friend"
        let seg = TextSegmenter.paragraph(in: text, caretUTF16: 5)!
        #expect(seg.range == NSRange(location: 0, length: (text as NSString).length))
    }

    @Test func emptyIsNil() {
        #expect(TextSegmenter.paragraph(in: "", caretUTF16: 0) == nil)
        #expect(TextSegmenter.paragraph(in: "   ", caretUTF16: 1) == nil)
    }
}

@Suite struct InlineRuleTests {
    let en = Language.code("en")!, de = Language.code("de")!

    @Test func normalizesDomains() {
        #expect(InlineRule.normalize("https://www.Slack.com/client") == "slack.com")
        #expect(InlineRule.normalize(" app.slack.com ") == "app.slack.com")
    }

    @Test func siteRuleBeatsAppRule() {
        let rules = [
            InlineRule(bundleID: "com.google.Chrome", appName: "Chrome", target: de),
            InlineRule(bundleID: "com.google.Chrome", appName: "Chrome", domain: "slack.com", target: en),
        ]
        #expect(InlineRules.match(rules, bundleID: "com.google.Chrome", host: "app.slack.com")?.target == en)
        #expect(InlineRules.match(rules, bundleID: "com.google.Chrome", host: "example.com")?.target == de)
        #expect(InlineRules.match(rules, bundleID: "com.google.Chrome", host: nil)?.target == de)
    }

    @Test func siteOnlyRuleNeedsMatchingHost() {
        let rules = [InlineRule(bundleID: "com.apple.Safari", appName: "Safari", domain: "slack.com", target: en)]
        #expect(InlineRules.match(rules, bundleID: "com.apple.Safari", host: "notslack.com") == nil)
        #expect(InlineRules.match(rules, bundleID: "com.apple.Safari", host: nil) == nil)
    }

    @Test func disabledRulesIgnored() {
        let rules = [InlineRule(bundleID: "a", appName: "A", target: en, isEnabled: false)]
        #expect(InlineRules.match(rules, bundleID: "a", host: nil) == nil)
    }
}

@Suite struct InlinePolicyTests {
    let en = Language.code("en")!, tr = Language.code("tr")!

    func segment(_ text: String) -> TextSegment { TextSegment(text: text, range: NSRange(location: 0, length: text.utf16.count)) }

    @Test func needsThreeWordsAndOtherLanguage() {
        #expect(!InlinePolicy.shouldSuggest(segment("Merhaba dünya"), target: en, detected: tr))
        #expect(InlinePolicy.shouldSuggest(segment("Yarın toplantı var mı"), target: en, detected: tr))
        #expect(!InlinePolicy.shouldSuggest(segment("Is there a meeting"), target: en, detected: en))
        #expect(!InlinePolicy.shouldSuggest(segment("asdf qwer zxcv"), target: en, detected: nil))
    }
}
