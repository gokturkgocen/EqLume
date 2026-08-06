import Foundation

/// Which baseline correction applies to the output device currently in use.
///
/// EqLume's genre presets are a small delta (±1–4 dB) layered on a baseline. Which
/// baseline is correct depends entirely on the transducer:
///
///   - `.chuII` — the built-in 3.5 mm headphone jack, the combo this app was measured
///     for. Applies the Chu II → Harman in-ear correction.
///   - `.desktopSpeakers` — any OTHER output the user has explicitly opted in (desk
///     speakers fed from an HDMI monitor, a small 2.1 set, …). Applies the desktop-2.1
///     correction, NOT the in-ear one: an IEC-711 coupler correction has nothing to do
///     with a speaker radiating into a room, so reusing it there would degrade the sound.
enum OutputProfile {
    case chuII
    case desktopSpeakers

    var baseline: [EQBand] {
        switch self {
        case .chuII:           return chuIIBaseline
        case .desktopSpeakers: return desktopSpeakerBaseline
        }
    }
}

/// Per-device opt-in for EQ processing, keyed by Core Audio device UID (stable across
/// reconnects, unlike the AudioObjectID).
///
/// The built-in 3.5 mm jack is always allowed and needs no entry. Built-in speakers are
/// never allowed — Apple's own DSP already tunes them, and our correction would fight it.
/// Everything else is opt-in per device, so plugging in an unknown output can never
/// silently apply a curve that wasn't designed for it.
enum DeviceEQPolicy {
    private static let defaultsKey = "Eqlume.enabledOutputDeviceUIDs"

    static func allowedUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    static func isAllowed(uid: String) -> Bool {
        allowedUIDs().contains(uid)
    }

    static func setAllowed(_ allowed: Bool, uid: String) {
        var uids = allowedUIDs()
        if allowed { uids.insert(uid) } else { uids.remove(uid) }
        UserDefaults.standard.set(Array(uids), forKey: defaultsKey)
    }
}
