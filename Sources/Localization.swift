import Foundation
import SwiftUI

/// App UI language. Default is English; Turkish is user-selectable at runtime.
enum AppLanguage: String, CaseIterable {
    case en
    case tr

    var label: String {
        switch self {
        case .en: return "English"
        case .tr: return "Türkçe"
        }
    }
}

/// Runtime localization. Deliberately inline (`t(en, tr)`) rather than a key table:
/// every call site supplies both languages, so there are no missing-key bugs and no
/// separate `.strings` bundling. The current language is persisted and published, so
/// SwiftUI views that observe `Loc.shared` re-render immediately on a language switch.
@MainActor
final class Loc: ObservableObject {
    static let shared = Loc()

    private static let defaultsKey = "Eqlume.language"

    @Published private(set) var lang: AppLanguage

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let l = AppLanguage(rawValue: raw) {
            lang = l
        } else {
            lang = .en   // default English
        }
    }

    func setLanguage(_ l: AppLanguage) {
        guard l != lang else { return }
        lang = l
        UserDefaults.standard.set(l.rawValue, forKey: Self.defaultsKey)
    }

    /// Pick the string for the current language.
    func t(_ en: String, _ tr: String) -> String {
        switch lang {
        case .en: return en
        case .tr: return tr
        }
    }
}

/// Non-view / non-@MainActor-isolated convenience. Reads the current language directly
/// from UserDefaults so it works from anywhere (e.g. building HTML off the main actor).
enum L {
    static var lang: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: "Eqlume.language"),
           let l = AppLanguage(rawValue: raw) { return l }
        return .en
    }
    static func t(_ en: String, _ tr: String) -> String {
        lang == .tr ? tr : en
    }
}

// MARK: - Structured detection (replaces Turkish-string parsing)

/// How the current track's preset was resolved — carried structurally so the view can
/// localize the source label instead of sniffing substrings out of a rendered line.
enum DetectionSourceKind {
    case musicBrainz   // MusicBrainz artist genres ("♪")
    case workTitle     // the title itself named a classical work ("♯")
    case catalog       // iTunes / Music.app genre
    case analyzing     // audio-content classifier pending
    case analyzed      // audio-content classifier done
    case prefetch      // came from the Spotify/YT queue pre-fetch cache

    /// Derives the source from the marker the resolver put in its detection tag, so the
    /// call sites don't each re-sniff the string.
    static func forTag(_ tag: String) -> DetectionSourceKind {
        if tag.contains("♪") { return .musicBrainz }
        if tag.contains("♯") { return .workTitle }
        return .catalog
    }

    /// Localized label shown as the small "· <source>" suffix on the genre line.
    var label: String {
        switch self {
        case .musicBrainz: return "MusicBrainz"
        case .workTitle:   return L.t("work title", "eser adı")
        case .catalog:     return L.t("catalog", "katalog")
        case .analyzing:   return L.t("analyzing…", "analiz…")
        case .analyzed:    return L.t("analysis", "analiz")
        case .prefetch:    return L.t("pre-fetch", "ön-yükleme")
        }
    }
}

/// High-level state of auto-detection, so consumers never parse the display line.
enum DetectionStatus {
    case idle          // auto off / nothing resolved yet
    case playing       // a source + track resolved
    case noSource      // auto on but nothing is playing
    case unreadable    // a source app is active but its track couldn't be read
}
