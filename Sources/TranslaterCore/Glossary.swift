import Foundation

/// A fixed translation for a term, e.g. "pull request" → "pull request" (keep) or "invoice" → "fatura".
public struct GlossaryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var source: String
    public var target: String
    /// The language `target` is written in; the entry applies only when translating into it.
    public var targetLanguage: Language

    public init(id: UUID = UUID(), source: String, target: String, targetLanguage: Language) {
        self.id = id
        self.source = source
        self.target = target
        self.targetLanguage = targetLanguage
    }
}

public enum Glossary {
    /// Entries for `target` whose source term occurs in `text` (case-insensitive, whole words),
    /// so the prompt only carries terms that matter.
    public static func relevant(_ entries: [GlossaryEntry], for text: String, target: Language) -> [GlossaryEntry] {
        entries.filter { entry in
            let term = entry.source.trimmingCharacters(in: .whitespaces)
            guard entry.targetLanguage == target, !term.isEmpty, !entry.target.isEmpty else { return false }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Parses "source,target" or "source;target" or tab-separated lines; skips blanks and a header row.
    public static func parseCSV(_ text: String, targetLanguage: Language) -> [GlossaryEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\""))) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            if ["source", "kaynak"].contains(parts[0].lowercased()) { return nil }
            return GlossaryEntry(source: parts[0], target: parts[1], targetLanguage: targetLanguage)
        }
    }
}
