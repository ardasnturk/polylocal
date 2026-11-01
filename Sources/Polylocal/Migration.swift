import Foundation

/// Carries data over from the pre-release name "Translater": the downloaded models (GBs) and settings.
enum Migration {
    static let legacyBundleID = "dev.translater.app"

    static func run() {
        moveLegacySupportFolder()
        copyLegacyDefaults()
    }

    private static func moveLegacySupportFolder() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("Translater", isDirectory: true)
        let current = support.appendingPathComponent("Polylocal", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }

    private static func copyLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != legacyBundleID,
              defaults.persistentDomain(forName: bundleID)?.isEmpty ?? true,
              let legacy = defaults.persistentDomain(forName: legacyBundleID), !legacy.isEmpty else { return }
        // Window frames belong to the old windows; everything else is a user preference.
        for (key, value) in legacy where !key.hasPrefix("NSWindow Frame") {
            defaults.set(value, forKey: key)
        }
    }
}
