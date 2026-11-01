import Foundation

/// "In this app (and optionally this site), I write in `target`": turns on inline suggestions there.
public struct InlineRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    /// Browser site, e.g. "slack.com". nil = the whole app.
    public var domain: String?
    public var target: Language
    public var formality: Formality
    public var isEnabled: Bool

    public init(id: UUID = UUID(), bundleID: String, appName: String, domain: String? = nil,
                target: Language, formality: Formality = .automatic, isEnabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.domain = domain.map(InlineRule.normalize)
        self.target = target
        self.formality = formality
        self.isEnabled = isEnabled
    }

    /// "https://www.Slack.com/x" → "slack.com"
    public static func normalize(_ domain: String) -> String {
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: d.contains("://") ? d : "https://\(d)")?.host() { d = host }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        return d
    }

    func matches(host: String) -> Bool {
        guard let domain else { return true }
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}

public enum InlineRules {
    /// The most specific enabled rule: a site rule beats an app-wide rule.
    public static func match(_ rules: [InlineRule], bundleID: String, host: String?) -> InlineRule? {
        let candidates = rules.filter { $0.isEnabled && $0.bundleID == bundleID }
        if let host, let site = candidates.first(where: { $0.domain != nil && $0.matches(host: host) }) {
            return site
        }
        return candidates.first { $0.domain == nil }
    }

    public static func hasSiteRules(_ rules: [InlineRule], bundleID: String) -> Bool {
        rules.contains { $0.isEnabled && $0.bundleID == bundleID && $0.domain != nil }
    }
}

/// The piece of text a suggestion would replace.
public struct TextSegment: Equatable, Sendable {
    public var text: String
    /// UTF-16 range inside the field's full text (what AX ranges use).
    public var range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

public enum TextSegmenter {
    /// The paragraph the caret is in, trimmed of surrounding whitespace.
    public static func paragraph(in text: String, caretUTF16 caret: Int) -> TextSegment? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(caret, 0), ns.length)
        // A caret right after a newline sits in the new (empty) paragraph.
        if clamped > 0, clamped == ns.length || isNewline(ns.character(at: clamped)),
           isNewline(ns.character(at: clamped - 1)) {
            return nil
        }
        let probe = clamped == ns.length ? clamped - 1 : clamped
        var range = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        // Trim whitespace/newlines on both ends while keeping the range in sync.
        while range.length > 0, isSpace(ns.character(at: range.location)) {
            range.location += 1
            range.length -= 1
        }
        while range.length > 0, isSpace(ns.character(at: range.location + range.length - 1)) {
            range.length -= 1
        }
        guard range.length > 0 else { return nil }
        return TextSegment(text: ns.substring(with: range), range: range)
    }

    private static func isNewline(_ c: unichar) -> Bool {
        c == 10 || c == 13 || c == 0x2028 || c == 0x2029
    }

    private static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

public enum InlinePolicy {
    public static let minimumWords = 3
    public static let maximumLength = 1500

    /// Suggest only for real sentences that are not already in the target language.
    public static func shouldSuggest(_ segment: TextSegment, target: Language, detected: Language?) -> Bool {
        let words = segment.text.split { $0.isWhitespace }.count
        guard words >= minimumWords, segment.text.utf16.count <= maximumLength else { return false }
        guard let detected else { return false }
        return detected != target
    }
}
