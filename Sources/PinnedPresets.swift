import Foundation

/// Per-track preset pins: (artist, title) → preset name, honoured ahead of every detector.
///
/// Detection is a guess by construction — MusicBrainz carries no vote for a track, iTunes
/// has no entry for it, and the audio classifier reads a sparse string quartet as room
/// tone. For the handful of records actually played on repeat, a guess is the wrong
/// mechanism: this is where the answer gets stated once and stops being re-decided.
///
/// The stored value is `EQPreset.name`, the stable identity key — localized labels live in
/// `displayName` — so a pin survives a language switch.
enum PinnedPresets {
    private static let defaultsKey = "Eqlume.pinnedPresets"

    /// Same shape as the now-playing `identity` used elsewhere, so a pin matches exactly
    /// the track the resolver is looking at.
    static func key(artist: String, title: String) -> String {
        "\(artist.lowercased())||\(title.lowercased())"
    }

    private static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func presetName(artist: String, title: String) -> String? {
        all()[key(artist: artist, title: title)]
    }

    static func preset(artist: String, title: String) -> EQPreset? {
        guard let name = presetName(artist: artist, title: title) else { return nil }
        return EQPreset.builtIn.first { $0.name == name }
    }

    /// Pins `presetName`; passing nil removes the pin.
    static func set(_ presetName: String?, artist: String, title: String) {
        var map = all()
        let k = key(artist: artist, title: title)
        if let presetName { map[k] = presetName } else { map.removeValue(forKey: k) }
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}
