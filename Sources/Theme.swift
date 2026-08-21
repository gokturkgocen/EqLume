import SwiftUI

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

/// Genre-driven accent color. Each preset family has a signature hue that themes the
/// whole popover (EQ curve glow, toggles, highlights) and animates when the genre changes.
extension PresetFamily {
    var accent: Color {
        switch self {
        case .hipHop:    return Color(hex: 0xF5B301)   // gold
        case .trap:      return Color(hex: 0x9B5DE5)   // violet
        case .edm:       return Color(hex: 0x00B4FF)   // electric blue (techno = blue)
        case .dnb:       return Color(hex: 0x00E5A0)   // neon teal
        case .rnb:       return Color(hex: 0xFF4D9D)   // magenta
        case .pop:       return Color(hex: 0xFF2D78)   // hot pink
        case .kpop:      return Color(hex: 0xFF74D4)   // bubblegum
        case .rock:      return Color(hex: 0xFF3B3B)   // red
        case .metal:     return Color(hex: 0xAEB8C2)   // chrome/steel (dark-metallic, but visible)
        case .acoustic:  return Color(hex: 0xB5651D)   // brown (country/folk)
        case .jazz:      return Color(hex: 0xE89B3B)   // warm amber
        case .classical: return Color(hex: 0xD8C58A)   // cream gold
        case .blues:     return Color(hex: 0x3A78E0)   // deep blue
        case .latin:     return Color(hex: 0xFF7A33)   // orange
        case .reggae:    return Color(hex: 0x3FB55E)   // green
        case .world:     return Color(hex: 0xD2703F)   // terracotta
        case .indie:     return Color(hex: 0x74B6A6)   // sage teal
        case .ambient:   return Color(hex: 0x86D8FF)   // soft cyan
        case .voice:     return Color(hex: 0x93A4B6)   // slate
        }
    }
}

enum Theme {
    /// Accent when no genre is active (EQ off / flat / unknown). Vibrant indigo so the
    /// glass still has something colorful to refract even when nothing is playing.
    static let idleAccent = Color(hex: 0x5E6AD2)

    /// Popover background gradient (near-black with a faint blue-violet lift).
    static let bgTop = Color(hex: 0x16181F)
    static let bgBottom = Color(hex: 0x0C0D12)

    static let cardFill = Color.white.opacity(0.04)
    static let cardStroke = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.45)

    /// Map an active preset name to its family (for theming). Falls back to idle.
    static func family(forPresetName name: String) -> PresetFamily? {
        #if !APP_STORE
        if name == EQPreset.arabesk.name { return .acoustic }
        #endif
        if name == EQPreset.turkishFolk.name { return .world }
        for f in PresetFamily.allCases where f.preset.name == name { return f }
        return nil
    }

    static func accent(forPresetName name: String) -> Color {
        family(forPresetName: name)?.accent ?? idleAccent
    }
}
