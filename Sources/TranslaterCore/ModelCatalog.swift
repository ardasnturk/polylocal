import Foundation

public struct ModelCatalog: Codable, Sendable {
    public var version: Int
    public var models: [CatalogModel]

    public init(version: Int, models: [CatalogModel]) {
        self.version = version
        self.models = models
    }

    public static func decode(_ data: Data) throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: data)
    }
}

public struct CatalogModel: Codable, Sendable, Identifiable, Hashable {
    public enum Tier: String, Codable, Sendable {
        case light, fast, quality
    }

    public struct License: Codable, Sendable, Hashable {
        public var name: String
        public var url: URL
        public var requiresAcceptance: Bool

        public init(name: String, url: URL, requiresAcceptance: Bool) {
            self.name = name
            self.url = url
            self.requiresAcceptance = requiresAcceptance
        }
    }

    public var id: String
    public var name: String
    public var family: String
    public var url: URL
    public var sha256: String
    public var sizeBytes: Int64
    public var minRAMGB: Int
    public var tier: Tier
    public var promptTemplate: PromptTemplate
    public var license: License
    public var summary: String

    public init(id: String, name: String, family: String, url: URL, sha256: String, sizeBytes: Int64, minRAMGB: Int,
                tier: Tier, promptTemplate: PromptTemplate, license: License, summary: String) {
        self.id = id
        self.name = name
        self.family = family
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.minRAMGB = minRAMGB
        self.tier = tier
        self.promptTemplate = promptTemplate
        self.license = license
        self.summary = summary
    }

    public var fileName: String { url.lastPathComponent }

    /// Picks the default model for a machine: the best `fast`-tier model that fits, else the lightest.
    public static func recommended(from models: [CatalogModel], ramGB: Int) -> CatalogModel? {
        let fitting = models.filter { $0.minRAMGB <= ramGB && !$0.license.requiresAcceptance }
        return fitting.filter { $0.tier == .fast }.max { $0.minRAMGB < $1.minRAMGB }
            ?? fitting.min { $0.minRAMGB < $1.minRAMGB }
            ?? models.min { $0.minRAMGB < $1.minRAMGB }
    }
}
