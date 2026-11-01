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

    /// What the model is for. Catalogs written before speech models existed have no `kind`: translation.
    public enum Kind: String, Codable, Sendable {
        case translation, speech
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
    public var kind: Kind

    public init(id: String, name: String, family: String, url: URL, sha256: String, sizeBytes: Int64, minRAMGB: Int,
                tier: Tier, promptTemplate: PromptTemplate, license: License, summary: String, kind: Kind = .translation) {
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
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, family, url, sha256, sizeBytes, minRAMGB, tier, promptTemplate, license, summary, kind
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        family = try c.decode(String.self, forKey: .family)
        url = try c.decode(URL.self, forKey: .url)
        sha256 = try c.decode(String.self, forKey: .sha256)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        minRAMGB = try c.decode(Int.self, forKey: .minRAMGB)
        tier = try c.decode(Tier.self, forKey: .tier)
        // Speech models have no prompt; the field only matters for translation models.
        promptTemplate = try c.decodeIfPresent(PromptTemplate.self, forKey: .promptTemplate) ?? .generic
        license = try c.decode(License.self, forKey: .license)
        summary = try c.decode(String.self, forKey: .summary)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .translation
    }

    public var fileName: String { url.lastPathComponent }

    /// Picks the default model for a machine: the best `fast`-tier model that fits, else the lightest.
    public static func recommended(from models: [CatalogModel], ramGB: Int) -> CatalogModel? {
        let models = models.filter { $0.kind == .translation }
        let fitting = models.filter { $0.minRAMGB <= ramGB && !$0.license.requiresAcceptance }
        return fitting.filter { $0.tier == .fast }.max { $0.minRAMGB < $1.minRAMGB }
            ?? fitting.min { $0.minRAMGB < $1.minRAMGB }
            ?? models.min { $0.minRAMGB < $1.minRAMGB }
    }
}
