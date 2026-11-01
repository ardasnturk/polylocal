import Foundation

/// What meeting mode heard and translated, as saved to the notes folder (docs/MEETING_MODE.md §4).
public struct MeetingTranscript: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Hashable {
        /// When the phrase started.
        public var time: Date
        /// The language that was spoken (ISO code), if known.
        public var language: String?
        public var original: String
        /// nil when the phrase was already in the target language.
        public var translation: String?

        public init(time: Date, language: String?, original: String, translation: String?) {
            self.time = time
            self.language = language
            self.original = original
            self.translation = translation
        }

        /// The phrase in the target language: the translation, or the original when none was needed.
        public var targetText: String { translation ?? original }
    }

    /// The app the audio came from, e.g. "Zoom".
    public var app: String
    public var started: Date
    public var ended: Date?
    /// ISO code of the language the subtitles were in.
    public var targetLanguage: String
    public var segments: [Segment] = []

    public init(app: String, started: Date, targetLanguage: String) {
        self.app = app
        self.started = started
        self.targetLanguage = targetLanguage
    }

    public enum Part: Sendable {
        /// Each phrase, then its translation.
        case interleaved
        case original
        case translation
    }

    public func markdown(_ part: Part) -> String {
        var lines = ["# \(title)", ""]
        let target = Language.code(targetLanguage)?.englishName ?? targetLanguage
        switch part {
        case .interleaved: lines.append("_Original and \(target) translation, recorded by Polylocal on this Mac._")
        case .original: lines.append("_Original speech, recorded by Polylocal on this Mac._")
        case .translation: lines.append("_\(target) translation, recorded by Polylocal on this Mac._")
        }
        lines.append("")
        for segment in segments {
            let stamp = "**\(Self.timeFormat.string(from: segment.time))**"
            switch part {
            case .interleaved:
                lines.append("\(stamp) \(segment.original)  ")
                if let translation = segment.translation { lines.append("→ \(translation)") }
            case .original:
                lines.append("\(stamp) \(segment.original)")
            case .translation:
                lines.append("\(stamp) \(segment.targetText)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public var title: String {
        "\(app) · \(Self.dayFormat.string(from: started))"
    }

    /// Folder for one meeting, e.g. "2026-11-03 14-00 Zoom". Safe on every file system.
    public var folderName: String {
        let app = self.app.unicodeScalars
            .map { CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_.")).contains($0) ? Character($0) : " " }
        let cleaned = String(app).split(separator: " ").joined(separator: " ")
        return "\(Self.folderFormat.string(from: started)) \(cleaned.isEmpty ? "Meeting" : cleaned)"
    }

    /// The whole meeting in the target language, in pieces small enough for one summary request each.
    public func summaryChunks(maxCharacters: Int = 6000) -> [String] {
        var chunks: [String] = []
        var current = ""
        for segment in segments {
            let line = segment.targetText
            if !current.isEmpty, current.count + line.count + 1 > maxCharacters {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    // Fixed formats: notes are read across locales and sorted by name.
    nonisolated(unsafe) private static let timeFormat = formatter("HH:mm:ss")
    nonisolated(unsafe) private static let dayFormat = formatter("yyyy-MM-dd HH:mm")
    nonisolated(unsafe) private static let folderFormat = formatter("yyyy-MM-dd HH-mm")
}
