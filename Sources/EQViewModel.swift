import SwiftUI

/// Observable UI state for the popover. The StatusBarController pushes state in via
/// `update(...)` and a display timer feeds `spectrum`; the SwiftUI view reads it.
@available(macOS 14.2, *)
@MainActor
final class EQViewModel: ObservableObject {
    // Core state
    @Published var userWantsEQ = false
    @Published var isRunning = false
    @Published var bypassReason: String? = nil
    @Published var autoOn = false
    /// True only when auto mode is on AND a real audio source is currently playing.
    /// When auto is on but nothing is playing, this is false so the chips show NO pinned
    /// selection instead of a stale manual pick.
    @Published var autoHasSource = false
    /// Active preset's stable identity key (== EQPreset.name). Used for theming and chip
    /// matching; shown to the user via `presetDisplayName` (localized).
    @Published var presetName = EQPreset.flat.name
    @Published var outputName = "—"
    /// Per-device opt-in state for the CURRENT output (see DeviceEQPolicy). The switch is
    /// only offered when the output isn't the built-in jack (always on) or the built-in
    /// speakers (never processed).
    @Published var canOptInCurrentOutput = false
    @Published var currentOutputAllowed = false
    /// True when the active output runs the desktop-speaker profile (rather than the
    /// built-in jack's Chu II in-ear correction).
    @Published var usingSpeakerProfile = false
    @Published var spotifyConnected = false
    @Published var loginEnabled = false

    // Now playing (structured — set directly by the controller, never parsed from text)
    @Published var nowArtist: String = ""
    @Published var nowTitle: String = ""
    @Published var detectionSourceKind: DetectionSourceKind? = nil
    /// Localized name of the preset pinned to the playing track, nil when it isn't pinned.
    @Published var pinnedPresetName: String? = nil
    /// A track has to be readable before there is anything to pin it to.
    @Published var canPinTrack: Bool = false
    @Published var detectionStatus: DetectionStatus = .idle
    @Published var detectionSourceApp: String = ""
    #if !APP_STORE
    @Published var genreLabelOverride: String? = nil
    #endif
    @Published var artwork: NSImage?
    @Published var artworkAccent: Color?

    // EQ curve
    @Published var freqs: [Double] = []
    @Published var responseDB: [Double] = []

    // Live spectrum (0...1 per band)
    @Published var spectrum: [Float] = []

    let presets: [EQPreset] = EQPreset.builtIn

    /// Localized display name of the active preset (English default / Turkish selectable).
    var presetDisplayName: String {
        #if !APP_STORE
        if let genreLabelOverride { return genreLabelOverride }
        #endif
        return EQPreset.displayName(forName: presetName)
    }

    /// Localized "· <source>" label for the genre line (MusicBrainz / catalog / analyzing …).
    var detectionSource: String { detectionSourceKind?.label ?? "" }

    /// Accent color: prefer the color extracted from album art (Apple-Music style),
    /// then the active preset's genre color, then idle.
    var accent: Color {
        if let art = artworkAccent { return art }
        guard userWantsEQ else { return Theme.idleAccent }
        return Theme.accent(forPresetName: presetName)
    }

    /// The genre color for the small genre dot/label — always reflects the detected
    /// preset's genre color (informative even when EQ is off).
    var genreAccent: Color {
        Theme.accent(forPresetName: presetName)
    }

    // Actions wired by the controller.
    var onToggleEQ: () -> Void = {}
    var onToggleAuto: () -> Void = {}
    var onSelectPreset: (String) -> Void = { _ in }
    var onPrevious: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onNext: () -> Void = {}
    var onConnectSpotify: () -> Void = {}
    var onTestAutomation: () -> Void = {}
    var onTestYTMusic: () -> Void = {}
    var onShowDetection: () -> Void = {}
    var onPinTrack: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onSetLanguage: (AppLanguage) -> Void = { _ in }
    var onToggleCurrentOutput: () -> Void = {}
    var onOpenPrivacy: () -> Void = {}
    var onOpenLicenses: () -> Void = {}
    var onQuit: () -> Void = {}
}
