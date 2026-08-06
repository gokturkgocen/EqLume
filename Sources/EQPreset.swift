import AVFAudio
import Foundation

// MARK: - Helpers

/// Q factor → AVAudioUnitEQ bandwidth (octaves).
/// Math: BW(oct) = 2 * asinh(0.5 / Q) / ln(2) for peaking biquads.
private func bw(q: Float) -> Float {
    switch q {
    case 0.5:  return 2.54
    case 0.6:  return 2.20
    case 0.61: return 2.12
    case 0.7:  return 1.90
    case 0.8:  return 1.69
    case 0.94: return 1.50
    case 1.0:  return 1.41
    case 1.2:  return 1.18
    case 1.4:  return 1.01
    case 1.7:  return 0.83
    case 2.0:  return 0.72
    default:
        return 2 * asinh(0.5 / q) / Float(log(2.0))
    }
}

private func pk(_ f: Float, _ g: Float, q: Float) -> EQBand {
    EQBand(frequency: f, gain: g, bandwidth: bw(q: q), filterType: .parametric)
}
private func ls(_ f: Float, _ g: Float, q: Float) -> EQBand {
    EQBand(frequency: f, gain: g, bandwidth: bw(q: q), filterType: .lowShelf)
}
private func hs(_ f: Float, _ g: Float, q: Float) -> EQBand {
    EQBand(frequency: f, gain: g, bandwidth: bw(q: q), filterType: .highShelf)
}

// MARK: - Models

struct EQBand: Codable, Equatable {
    var frequency: Float
    var gain: Float
    var bandwidth: Float
    var filterType: FilterType

    enum FilterType: String, Codable {
        case parametric, lowShelf, highShelf, lowPass, highPass
        var avType: AVAudioUnitEQFilterType {
            switch self {
            case .parametric: return .parametric
            case .lowShelf:   return .lowShelf
            case .highShelf:  return .highShelf
            case .lowPass:    return .lowPass
            case .highPass:   return .highPass
            }
        }
    }
}

enum PresetCategory: String, CaseIterable {
    case utility   = "Genel"
    case bass      = "Bas ağırlıklı"
    case pop       = "Pop / Mainstream"
    case rock      = "Rock / Metal"
    case acoustic  = "Akustik / Klasik"
    case world     = "Latin / Dünya / Reggae"
    case ambient   = "Ambient / Indie"
    case voice     = "Konuşma / Diyalog"
}

struct EQPreset: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    /// The preset's own filters. When `usesDeviceBaseline` is true these are ONLY the
    /// genre delta — the active output device's baseline correction is prepended by
    /// `resolved(baseline:)` before the preset reaches the EQ node.
    var bands: [EQBand]
    /// True for music presets, which sit on top of a per-device baseline (Chu II
    /// correction on the built-in jack, neutral/none on other allowed outputs).
    /// False for standalone presets (flat, voice) whose filters are absolute.
    var usesDeviceBaseline: Bool = false
    var categoryRaw: String

    /// Constant gain (dB) added to the EQ output to compensate for the average
    /// RMS loss caused by significant cuts (e.g. Harman correction's 100-200 Hz dip).
    /// Without this, presets with heavy bass-region cuts feel ~3-4 dB quieter than
    /// bypass even though their peak levels are similar — the energy distribution
    /// matters for perceived loudness. The limiter handles any momentary clipping.
    var makeupGainDB: Float

    var category: PresetCategory { PresetCategory(rawValue: categoryRaw) ?? .utility }
    var isFlat: Bool { bands.isEmpty || bands.allSatisfy { abs($0.gain) < 0.01 } }

    /// Headroom: subtract the largest positive band gain to keep EQ output ≤ 0 dBFS.
    /// Combined with `makeupGainDB` it becomes the AVAudioUnitEQ globalGain.
    var preampOffsetDB: Float {
        let maxBoost = bands.map(\.gain).max() ?? 0
        return -max(0, maxBoost)
    }

    /// Final globalGain to apply: preamp (negative, prevents clipping) + makeup (positive,
    /// restores loudness). Combined value is typically a small negative number; the limiter
    /// catches the rare peak that crosses 0 dBFS.
    var globalGainDB: Float { preampOffsetDB + makeupGainDB }

    init(name: String, category: PresetCategory, bands: [EQBand],
         usesDeviceBaseline: Bool = false, makeupGainDB: Float = 0) {
        self.name = name
        self.categoryRaw = category.rawValue
        self.bands = bands
        self.usesDeviceBaseline = usesDeviceBaseline
        self.makeupGainDB = makeupGainDB
    }

    /// Returns the preset with the given device baseline folded in, ready for the EQ node.
    /// Standalone presets (flat, voice) are returned unchanged. Resolving keeps `bands`,
    /// `preampOffsetDB` and `globalGainDB` correct for the device actually in use —
    /// applying the Chu II in-ear correction to, say, desk speakers would be wrong, so a
    /// non-headphone output resolves against an empty baseline (genre delta only).
    func resolved(baseline: [EQBand]) -> EQPreset {
        guard usesDeviceBaseline else { return self }
        var copy = self
        copy.bands = baseline + bands
        copy.usesDeviceBaseline = false   // already folded in; don't apply twice
        return copy
    }
}

// MARK: - Chu II measurement-derived baseline
//
// Target: Moondrop Chu 2 → Harman in-ear 2019v2. Values are the CONSENSUS of three
// independent AutoEQ fits published in jaakkopasanen/AutoEq, all measured on
// IEC-711 / GRAS-RA0045-class couplers against the Harman IE 2019v2 target:
//   results/HypetheSonics/GRAS RA0045 in-ear/Moondrop Chu 2/…ParametricEQ.txt
//   results/Kazi/in-ear/Moondrop Chu 2/…ParametricEQ.txt
//   results/Super Review/in-ear/Moondrop Chu 2/…ParametricEQ.txt
// We average the dominant bands and drop single-measurer outliers for a robust fit.
//
// IMPORTANT — why these supersede the earlier hand-set values: a PEQ is only valid
// for the coupler+target pair it was fit on. The previous baseline mixed a B&K-5128
// (4620) style measurement with the GRAS-derived Harman target — which are
// mathematically incompatible — and as a result (a) MISSED the ~6 kHz correction
// that every real fit applies, and (b) BOOSTED the 10 kHz shelf when the Chu 2 in
// fact has *excess* upper treble (the ~14 kHz overshoot noted by ASR) that must be
// CUT. This 711-consistent consensus fixes both. The Chu 2 already tracks Harman
// closely, so the correction stays light.
//
// What this baseline does to a Chu 2:
//   - trims the 100–200 Hz mid-bass bloom (-3.5 LSC, -3.0 PK @170) while keeping
//     sub-bass extension (+2.0 PK @68)
//   - fills the ~730 Hz lower-mid body (+2.0)
//   - softens the ~3.2 kHz upper-mid (-1.5)
//   - lifts the recessed ~6 kHz presence (+3.0)  ← the band the old baseline lacked
//   - tames excess air above 10 kHz (-2.0 HSC)   ← old baseline wrongly boosted this
//
// Every music preset below is THIS baseline + a small genre-specific delta (±1–4 dB
// at a couple of points). The baseline ALWAYS applies (all filters run in series and
// their dB gains sum); the genre delta is relative seasoning, not a replacement.
// Speech / dialogue is a separate path (Harman music target doesn't apply there).

let chuIIBaseline: [EQBand] = [
    ls(105,   -3.5, q: 0.70),
    pk(68,    +2.0, q: 0.90),
    pk(170,   -3.0, q: 0.90),
    pk(730,   +2.0, q: 0.80),
    pk(3200,  -1.5, q: 1.50),
    pk(6100,  +3.0, q: 2.30),   // ← critical presence band the old baseline was missing
    hs(10000, -2.0, q: 0.70),   // ← cut (not boost): Chu 2 has excess upper treble
]

// MARK: - Desktop 2.1 speaker baseline
//
// For a small desk-top 2.1 set (satellites + subwoofer, e.g. Logitech Z-series) fed from a
// monitor's audio out. NOT a measurement of one specific model — these are the failure modes
// the whole class shares, so the correction is deliberately gentle and errs toward cutting:
//
//   - Sub can't reproduce below ~45 Hz; feeding it that content only makes it flap and
//     distort → low shelf trims it away (cleaner, not thinner).
//   - Small subs have a one-note hump around 70–90 Hz → slight cut so bass has pitch
//     instead of a single boom.
//   - Small plastic cabinets plus reflection off the desk pile up around 180–250 Hz —
//     this is the "boxy / cardboard" coloration, and the single most audible fault.
//   - Satellites usually sit below ear level and off-axis, so the 2.5–4 kHz presence
//     region drops; vocals sound recessed. Lifting it is what makes the biggest
//     perceived improvement.
//   - Small full-range drivers roll off above ~10 kHz → a modest shelf restores air.
//
// Boosts are capped at +2.5 dB, so `preampOffsetDB` only costs ~2.5 dB of headroom.
// If it ends up too lean or too forward for your room, adjust by ear from here.
let desktopSpeakerBaseline: [EQBand] = [
    ls(45,    -2.0, q: 0.70),   // below the sub's usable range — remove, don't boost
    pk(80,    -2.0, q: 0.90),   // one-note sub hump
    pk(200,   -3.0, q: 1.00),   // cabinet + desk-boundary boxiness  ← most audible fix
    pk(500,   +1.0, q: 0.90),   // a little body back into the satellites
    pk(3000,  +2.5, q: 1.00),   // presence: off-axis vocal recession  ← biggest gain
    hs(10000, +2.0, q: 0.70),   // air lost to the small drivers' roll-off
]

/// Helper: a music preset carrying ONLY its genre delta. The device baseline (Chu II
/// correction on the built-in jack, empty on other allowed outputs) is prepended later by
/// `EQPreset.resolved(baseline:)`, so the same preset works correctly on both.
/// No makeup gain — the volume drop from the Harman bass-cut is intentional;
/// keeping headroom means the limiter never compresses transients, so dynamics
/// stay pristine. User can compensate at the system volume control.
private func chu(_ name: String, _ category: PresetCategory, delta: [EQBand] = []) -> EQPreset {
    EQPreset(name: name, category: category, bands: delta, usesDeviceBaseline: true)
}

// MARK: - Built-in presets

extension EQPreset {

    // MARK: Utility

    static let flat = EQPreset(name: "Düz (EQ kapalı)", category: .utility, bands: [])

    /// Pure measurement-derived correction. Goal: Chu II → Harman 2019v2 target.
    /// This is what the IEM "should" sound like according to controlled-listening research.
    static let natural = chu("Chu II — Doğal (Harman)", .utility)

    // MARK: Bass-driven (baseline + sub-bass extension on top)

    static let hipHop = chu("Hip-Hop / Rap", .bass, delta: [
        pk(50, +2.0, q: 0.7),    // extra 808 sub-bass
    ])

    static let trap = chu("Trap", .bass, delta: [
        pk(40, +4.0, q: 0.6),    // extreme sub for trap 808s
        pk(200, -1.5, q: 1.0),   // keep low-mid clean against heavy sub
    ])

    static let edm = chu("EDM / Electronic / House", .bass, delta: [
        pk(50, +2.0, q: 0.7),    // sub-bass push for dance floor energy
    ])

    static let dnb = chu("Drum & Bass / Dubstep", .bass, delta: [
        pk(50, +3.0, q: 0.7),    // strong sub
        pk(80, -1.0, q: 1.0),    // separation between sub and kick
    ])

    static let rnb = chu("R&B / Soul / Funk", .bass, delta: [
        pk(250, +1.0, q: 1.0),   // warmth fill
        pk(2500, +1.0, q: 1.0),  // gentle vocal presence
    ])

    // MARK: Pop / Mainstream

    static let pop = chu("Pop", .pop, delta: [
        pk(80, +1.0, q: 0.7),    // hint of extra warmth
    ])

    static let kpop = chu("K-Pop / J-Pop", .pop, delta: [
        pk(80, +1.0, q: 0.7),
        pk(12500, -1.5, q: 1.0), // Korean/Japanese mixes often have hot upper treble
    ])

    // MARK: Rock / Metal

    static let rock = chu("Rock", .rock, delta: [
        pk(100, +1.0, q: 0.7),   // bass warmth
        pk(1500, +1.0, q: 1.0),  // guitar body
    ])

    static let metal = chu("Metal", .rock, delta: [
        pk(100, +1.0, q: 0.7),
        pk(1500, +1.0, q: 1.0),
        pk(6000, -1.0, q: 1.2),  // cymbal fizz / digital harshness
    ])

    // MARK: Acoustic / Classical

    static let acoustic = chu("Akustik / Folk / Country", .acoustic)
    #if !APP_STORE
    /// Local-build profile for Turkish arabesk/fantezi recordings. It keeps the shared
    /// Chu II correction, adds a little vocal/bağlama body, and softens upper-mid glare.
    static let arabesk = chu("Arabesk / Fantezi", .acoustic, delta: [
        pk(250,  +1.0, q: 0.8),
        pk(1800, +1.0, q: 1.0),
        pk(4500, -0.8, q: 1.2),
    ])
    #endif
    static let jazz     = chu("Jazz", .acoustic)

    static let classical = chu("Klasik / Orkestral", .acoustic, delta: [
        pk(40, +1.5, q: 0.7),    // orchestral low extension
    ])

    static let blues = chu("Blues", .acoustic, delta: [
        pk(80, +1.0, q: 0.7),
    ])

    // MARK: World / Latin / Reggae

    static let latin = chu("Latin / Reggaeton", .world, delta: [
        pk(50, +3.0, q: 0.7),    // perreo bass
    ])

    static let reggae = chu("Reggae / Ska / Dancehall", .world, delta: [
        pk(80, +2.0, q: 0.7),
    ])

    static let world = chu("Dünya Müziği", .world)

    // MARK: Ambient / Indie

    static let indie = chu("Indie / Alternatif", .ambient, delta: [
        pk(80, +0.5, q: 0.7),
    ])

    static let ambient = chu("Ambient / New Age", .ambient, delta: [
        pk(50, +1.0, q: 0.7),
    ])

    // MARK: Voice — NOT measurement-derived (different target than music)
    //
    // Speech/podcast goal is intelligibility, not music neutrality. Harman target
    // doesn't apply. Standalone preset focused on:
    //   - cut rumble below speech fundamentals (~150 Hz)
    //   - lift vocal presence band (2-3 kHz)
    //   - kill sibilance harshness (8 kHz, 12 kHz)
    static let voice = EQPreset(
        name: "Vokal / Diyalog / Podcast",
        category: .voice,
        bands: [
            pk(150,   -1.5, q: 0.7),
            pk(2500,  +2.0, q: 1.0),
            pk(8000,  -1.5, q: 1.2),
            pk(12500, -3.0, q: 1.0),
        ]
    )

    // MARK: List

    static let builtIn: [EQPreset] = [
        // Utility
        .flat, .natural,
        // Bass
        .hipHop, .trap, .edm, .dnb, .rnb,
        // Pop
        .pop, .kpop,
        // Rock
        .rock, .metal,
        // Acoustic
        .acoustic, .jazz, .classical, .blues,
        // World
        .latin, .reggae, .world,
        // Ambient
        .indie, .ambient,
        // Voice
        .voice,
    ]

    // MARK: Localized display name

    /// `.name` is the immutable stable identity key (persisted, matched, and themed by it,
    /// so it must never change). `displayName` is the localized label shown in the UI —
    /// English by default, Turkish when the user selects it. The `.name` values themselves
    /// ARE the Turkish strings, so Turkish returns `.name`; only English needs a lookup.
    var displayName: String { Self.displayName(forName: name) }

    static func displayName(forName name: String) -> String {
        guard L.lang == .en else { return name }
        return enDisplayNames[name] ?? name
    }

    private static let enDisplayNames: [String: String] = [
        "Düz (EQ kapalı)":           "Flat (EQ off)",
        "Chu II — Doğal (Harman)":   "Chu II — Natural (Harman)",
        "Akustik / Folk / Country":  "Acoustic / Folk / Country",
        "Klasik / Orkestral":        "Classical / Orchestral",
        "Dünya Müziği":              "World Music",
        "Indie / Alternatif":        "Indie / Alternative",
        "Vokal / Diyalog / Podcast": "Vocal / Dialogue / Podcast",
    ]
}
