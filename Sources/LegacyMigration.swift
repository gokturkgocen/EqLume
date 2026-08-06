import Foundation

/// Preserves local choices when upgrading from the original SesEQ development name.
/// The old domain and Keychain records are intentionally left intact so the migration
/// is reversible while EqLume establishes its own preferences.
enum LegacyMigration {
    private static let marker = "Eqlume.didMigrateFromSesEQ"

    static func runIfNeeded() {
        let current = UserDefaults.standard
        guard !current.bool(forKey: marker) else { return }
        defer { current.set(true, forKey: marker) }

        guard let legacy = UserDefaults(suiteName: "com.gokturkgocen.SesEQ") else { return }
        let mappings = [
            ("SesEQ.language", "Eqlume.language"),
            ("SesEQ.activePresetName", "Eqlume.activePresetName"),
            ("SesEQ.autoEnabled", "Eqlume.autoEnabled"),
            ("SesEQ.hasSeenOnboarding", "Eqlume.hasSeenOnboarding"),
        ]
        for (oldKey, newKey) in mappings where current.object(forKey: newKey) == nil {
            if let value = legacy.object(forKey: oldKey) {
                current.set(value, forKey: newKey)
            }
        }
    }
}
