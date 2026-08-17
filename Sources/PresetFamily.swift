import Foundation

/// The set of preset "families" both the catalog genre matcher and the audio
/// classifier resolve to. A single place that maps:
///   - Discogs styles ("Parent---Style")  -> family   (audio classifier)
///   - family -> EQPreset                              (what actually gets applied)
enum PresetFamily: String, CaseIterable {
    case hipHop, trap, edm, dnb, rnb
    case pop, kpop
    case rock, metal
    case acoustic, jazz, classical, blues
    case latin, reggae, world
    case indie, ambient
    case voice

    var preset: EQPreset {
        switch self {
        case .hipHop:    return .hipHop
        case .trap:      return .trap
        case .edm:       return .edm
        case .dnb:       return .dnb
        case .rnb:       return .rnb
        case .pop:       return .pop
        case .kpop:      return .kpop
        case .rock:      return .rock
        case .metal:     return .metal
        case .acoustic:  return .acoustic
        case .jazz:      return .jazz
        case .classical: return .classical
        case .blues:     return .blues
        case .latin:     return .latin
        case .reggae:    return .reggae
        case .world:     return .world
        case .indie:     return .indie
        case .ambient:   return .ambient
        case .voice:     return .voice
        }
    }

    /// Map a Discogs style string ("Parent---Style") to a preset family.
    /// Style-level keywords are checked first (more specific), then the parent genre.
    static func fromDiscogsStyle(_ s: String) -> PresetFamily {
        let lower = s.lowercased()
        let parts = s.components(separatedBy: "---")
        let parent = (parts.first ?? "").lowercased()
        let style = (parts.count > 1 ? parts[1] : "").lowercased()

        // --- Style-level overrides (cross parent) ---
        if style.contains("trap") || style.contains("phonk") { return .trap }
        if style.contains("drum n bass") || style.contains("drum and bass")
            || style.contains("jungle") || style.contains("dubstep")
            || style.contains("breakbeat") || style.contains("breakcore") { return .dnb }
        if style.contains("ambient") || style.contains("downtempo")
            || style.contains("trip hop") || style.contains("new age")
            || style.contains("lounge") || style.contains("drone") { return .ambient }
        if style.contains("metal") || style.contains("grindcore")
            || style.contains("hardcore") || style.contains("thrash") { return .metal }

        // --- Parent-genre mapping ---
        switch parent {
        case "blues":
            return .blues
        case "brass & military":
            return .classical
        case "children's":
            return .voice
        case "classical":
            return .classical
        case "electronic":
            // Discogs files "Modern Classical" (solo piano, Einaudi-style scoring) under
            // the Electronic parent. It is not dance music — bass-lifting it as EDM is the
            // opposite of what it needs.
            if style.contains("classical") { return .classical }
            // Most electronic → EDM; the calmer styles already caught above as ambient.
            return .edm
        case "folk, world, & country":
            if style.contains("country") || style.contains("folk")
                || style.contains("bluegrass") || style.contains("singer") { return .acoustic }
            return .world
        case "funk / soul":
            return .rnb
        case "hip hop":
            return .hipHop
        case "jazz":
            return .jazz
        case "latin":
            return .latin
        case "non-music":
            return .voice          // spoken word, audiobook, interview, etc.
        case "pop":
            return .pop
        case "reggae":
            return .reggae
        case "rock":
            // Metal already caught above. Punk/grunge/etc. stay rock.
            return .rock
        case "stage & screen":
            return .classical      // soundtracks / scores — cinematic
        default:
            // Fall back to keyword scan over the whole string.
            if lower.contains("hip hop") || lower.contains("rap") { return .hipHop }
            if lower.contains("electronic") || lower.contains("techno") || lower.contains("house") { return .edm }
            if lower.contains("rock") { return .rock }
            if lower.contains("jazz") { return .jazz }
            if lower.contains("classical") { return .classical }
            return .pop
        }
    }
}
