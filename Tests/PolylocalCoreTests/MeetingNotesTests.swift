import Foundation
import Testing
@testable import PolylocalCore

@Suite struct MeetingTranscriptTests {
    /// 2026-11-03 14:00:05 UTC, shown in the test machine's time zone like the app does.
    let start = Date(timeIntervalSince1970: 1_793_714_405)

    func transcript() -> MeetingTranscript {
        var t = MeetingTranscript(app: "Zoom", started: start, targetLanguage: "tr")
        t.segments = [
            .init(time: start, language: "de", original: "Guten Morgen zusammen.", translation: "Herkese günaydın."),
            .init(time: start.addingTimeInterval(4), language: "tr", original: "Günaydın.", translation: nil),
        ]
        return t
    }

    @Test func interleavedShowsOriginalThenTranslation() {
        let text = transcript().markdown(.interleaved)
        #expect(text.hasPrefix("# Zoom · "))
        #expect(text.contains("Guten Morgen zusammen.  \n→ Herkese günaydın."))
        // Already in the target language: no arrow line.
        #expect(text.contains("Günaydın.\n\n") || text.hasSuffix("Günaydın.  \n"))
        #expect(!text.contains("→ Günaydın."))
    }

    @Test func separatePartsKeepOneLanguageEach() {
        let original = transcript().markdown(.original)
        #expect(original.contains("Guten Morgen zusammen."))
        #expect(!original.contains("Herkese günaydın."))
        let translation = transcript().markdown(.translation)
        #expect(translation.contains("Herkese günaydın."))
        #expect(translation.contains("Günaydın."))
        #expect(!translation.contains("Guten Morgen"))
    }

    @Test func folderNameIsSortableAndSafe() {
        var t = transcript()
        t.app = "Google Chrome: Meet/Call"
        let name = t.folderName
        #expect(name.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}-\d{2} Google Chrome Meet Call$"#, options: .regularExpression) != nil)
        t.app = "///"
        #expect(t.folderName.hasSuffix(" Meeting"))
    }

    @Test func summaryChunksStayUnderTheLimit() {
        var t = transcript()
        t.segments = (0..<100).map { _ in .init(time: start, language: "de", original: "x", translation: String(repeating: "a", count: 99)) }
        let chunks = t.summaryChunks(maxCharacters: 1000)
        #expect(chunks.count == 10)
        #expect(chunks.allSatisfy { $0.count <= 1000 })
        #expect(chunks.joined(separator: "\n").count == 100 * 100 - 1)
    }

    @Test func roundTripsThroughJSON() throws {
        let t = transcript()
        let decoded = try JSONDecoder().decode(MeetingTranscript.self, from: JSONEncoder().encode(t))
        #expect(decoded == t)
    }

    @Test func summarizePromptAsksForTheTargetLanguage() {
        let request = TranslationRequest(text: "…", source: nil, target: .code("tr")!, kind: .summarize)
        let system = PromptTemplate.generic.messages(for: request)[0]["content"] ?? ""
        #expect(system.contains("Write in Turkish"))
        #expect(system.contains("Action items"))
    }
}
