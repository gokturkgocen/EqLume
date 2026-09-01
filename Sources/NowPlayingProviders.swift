import Foundation

/// Snapshot of what the user is listening to right now.
struct NowPlayingTrack: Equatable {
    var artist: String
    var title: String
    /// Some sources (Music.app) provide genre directly. nil means "look it up."
    var genre: String?
    /// Bundle ID of the source app, for debugging / status display.
    var sourceBundleID: String

    /// A simple equality key for deduplication (ignoring genre/source variations).
    var identity: String { "\(artist.lowercased())||\(title.lowercased())" }
}

/// Anything that can answer "what's playing in <app> right now?" — Spotify, Music, browsers.
protocol NowPlayingProvider: Sendable {
    var bundleID: String { get }
    func currentTrack() async -> NowPlayingTrack?
}

// MARK: - Spotify (AppleScript)

struct SpotifyProvider: NowPlayingProvider {
    let bundleID = "com.spotify.client"

    func currentTrack() async -> NowPlayingTrack? {
        let script = """
        tell application id "com.spotify.client"
            with timeout of 3 seconds
            if it is running then
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    return t & "‹|›" & a
                end if
            end if
            end timeout
            return ""
        end tell
        """
        guard let out = await AppleScriptRunner.runString(script), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "‹|›")
        guard parts.count == 2 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespaces)
        let artist = parts[1].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return NowPlayingTrack(artist: artist, title: title, genre: nil, sourceBundleID: bundleID)
    }
}

// MARK: - Apple Music (AppleScript — gives us genre directly)

struct MusicProvider: NowPlayingProvider {
    let bundleID = "com.apple.Music"

    func currentTrack() async -> NowPlayingTrack? {
        let script = """
        tell application id "com.apple.Music"
            with timeout of 3 seconds
            if it is running then
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    set g to genre of current track
                    return t & "‹|›" & a & "‹|›" & g
                end if
            end if
            end timeout
            return ""
        end tell
        """
        guard let out = await AppleScriptRunner.runString(script), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "‹|›")
        guard parts.count == 3 else { return nil }
        let title  = parts[0].trimmingCharacters(in: .whitespaces)
        let artist = parts[1].trimmingCharacters(in: .whitespaces)
        let genre  = parts[2].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return NowPlayingTrack(
            artist: artist, title: title,
            genre: genre.isEmpty ? nil : genre,
            sourceBundleID: bundleID
        )
    }
}

// MARK: - Browser-based providers (YouTube, YouTube Music)

/// Reads any browser tab whose URL points at YouTube / YouTube Music,
/// returns the page title for parsing. Generic across Chrome-derivatives.
private func readBrowserTabTitle(bundleID: String, appName: String, useURLPredicate: Bool = true) async -> (url: String, title: String)? {
    // Chrome / Edge / Brave / Arc — all expose `URL` and `title` of `active tab` / `tabs`.
    // Prefer the ACTIVE tab when possible; fall back to scanning all tabs.
    let script: String
    if useURLPredicate {
        script = """
        tell application id "\(bundleID)"
            if it is not running then return ""
            try
                with timeout of 3 seconds
                set foundURL to ""
                set foundTitle to ""
                -- First try the active tab
                if (count of windows) > 0 then
                    set activeURL to URL of active tab of front window
                    set activeTitle to title of active tab of front window
                    if (activeURL contains "youtube.com" or activeURL contains "youtu.be") then
                        return activeURL & "‹|›" & activeTitle
                    end if
                end if
                -- Otherwise scan all tabs
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabURL to URL of t
                        if (tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                            return tabURL & "‹|›" & (title of t)
                        end if
                    end repeat
                end repeat
                end timeout
            on error
                return ""
            end try
            return ""
        end tell
        """
    } else {
        // Safari uses `name of current tab` instead of `title`, and `URL of current tab`.
        script = """
        tell application "\(appName)"
            if it is not running then return ""
            try
                with timeout of 3 seconds
                if (count of windows) > 0 then
                    set u to URL of current tab of front window
                    set n to name of current tab of front window
                    if (u contains "youtube.com" or u contains "youtu.be") then
                        return u & "‹|›" & n
                    end if
                end if
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if (u contains "youtube.com" or u contains "youtu.be") then
                            return u & "‹|›" & (name of t)
                        end if
                    end repeat
                end repeat
                end timeout
            on error
                return ""
            end try
            return ""
        end tell
        """
    }

    guard let out = await AppleScriptRunner.runString(script), !out.isEmpty else { return nil }
    let parts = out.components(separatedBy: "‹|›")
    guard parts.count == 2 else { return nil }
    return (url: parts[0], title: parts[1])
}

struct ChromeProvider: NowPlayingProvider {
    let bundleID = "com.google.Chrome"
    func currentTrack() async -> NowPlayingTrack? {
        guard let (url, title) = await readBrowserTabTitle(bundleID: bundleID, appName: "Google Chrome") else { return nil }
        return parseYouTubeTitle(title: title, url: url, sourceBundle: bundleID)
    }
}

struct ArcProvider: NowPlayingProvider {
    let bundleID = "company.thebrowser.Browser"
    func currentTrack() async -> NowPlayingTrack? {
        guard let (url, title) = await readBrowserTabTitle(bundleID: bundleID, appName: "Arc") else { return nil }
        return parseYouTubeTitle(title: title, url: url, sourceBundle: bundleID)
    }
}

struct BraveProvider: NowPlayingProvider {
    let bundleID = "com.brave.Browser"
    func currentTrack() async -> NowPlayingTrack? {
        guard let (url, title) = await readBrowserTabTitle(bundleID: bundleID, appName: "Brave Browser") else { return nil }
        return parseYouTubeTitle(title: title, url: url, sourceBundle: bundleID)
    }
}

struct EdgeProvider: NowPlayingProvider {
    let bundleID = "com.microsoft.edgemac"
    func currentTrack() async -> NowPlayingTrack? {
        guard let (url, title) = await readBrowserTabTitle(bundleID: bundleID, appName: "Microsoft Edge") else { return nil }
        return parseYouTubeTitle(title: title, url: url, sourceBundle: bundleID)
    }
}

struct SafariProvider: NowPlayingProvider {
    let bundleID = "com.apple.Safari"
    func currentTrack() async -> NowPlayingTrack? {
        guard let (url, title) = await readBrowserTabTitle(bundleID: bundleID, appName: "Safari", useURLPredicate: false) else { return nil }
        return parseYouTubeTitle(title: title, url: url, sourceBundle: bundleID)
    }
}

// MARK: - Title cleaning (shared by all sources)

/// Strips marketing/format noise from a track title so catalog lookups match the
/// canonical recording. Removes any ( ) or [ ] group containing a known keyword
/// (official, video, audio, visualizer, lyric, remaster, remix, version, deluxe,
/// anniversary, live, explicit, HD/4K, etc.) plus a trailing " - Topic".
///
/// Critical for genre accuracy: iTunes often mis-tags specific remaster/remix entries
/// (e.g. Deep Purple "When a Blind Man Cries (2012 Remaster)" is tagged Pop, while the
/// clean title returns Hard Rock). Cleaning before lookup avoids those wrong hits.
func cleanMusicTitle(_ s: String) -> String {
    let noisePattern = #"\s*[\(\[][^\)\]]*\b(official|visualizer|visualiser|lyric|lyrics|audio|hd|hq|4k|8k|uhd|remaster(ed)?|remix|re-?master|mono|stereo|edit|version|deluxe|anniversary|reissue|demo|bonus|explicit|clean|mv|m/v|live|color\s*coded|full\s*(album|concert|version)|radio\s*edit|extended|slowed|sped\s*up|speed\s*up|nightcore|reverb|8d\s*audio|bass\s*boost(ed)?|looped|music\s*video|performance\s*video|video)\b[^\)\]]*[\)\]]"#
    var t = s.replacingOccurrences(of: noisePattern, with: "", options: [.regularExpression, .caseInsensitive])
    t = t.replacingOccurrences(of: #"\s*-\s*Topic$"#, with: "", options: [.regularExpression, .caseInsensitive])
    return t.trimmingCharacters(in: .whitespaces)
}

// MARK: - YouTube / YouTube Music title parser

/// YouTube tab titles aren't standardized. Common shapes:
///   "Artist - Title - YouTube"
///   "Artist - Title (Official Video) - YouTube"
///   "Title - Artist - YouTube Music"            ← YT Music reverses!
///   "(123) Artist - Title - YouTube"            ← (n) prefix when audio is playing in another tab
private func parseYouTubeTitle(title: String, url: String, sourceBundle: String) -> NowPlayingTrack? {
    var work = title

    // Strip leading "(123) " unread-count prefix
    work = work.replacingOccurrences(
        of: #"^\(\d+\)\s*"#,
        with: "",
        options: .regularExpression
    )

    // Determine which suffix marker is present and remove it. Order matters
    // because "- YouTube Music" must match BEFORE "- YouTube".
    let isYouTubeMusic = work.contains("- YouTube Music") || url.contains("music.youtube.com")
    let suffixes = [" - YouTube Music", " - YouTube", " — YouTube Music", " — YouTube"]
    for s in suffixes {
        if let range = work.range(of: s) {
            work = String(work[..<range.lowerBound])
            break
        }
    }

    work = cleanMusicTitle(work)
    guard !work.isEmpty else { return nil }

    // Split on " - " (en-dash, em-dash, hyphen surrounded by spaces)
    let separators = [" - ", " – ", " — "]
    var parts: [String] = [work]
    for sep in separators {
        if work.contains(sep) {
            parts = work.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
            break
        }
    }
    guard parts.count >= 2 else { return nil }

    // YouTube: "Artist - Title"
    // YouTube Music: "Title - Artist"
    let artist: String
    let songTitle: String
    if isYouTubeMusic {
        songTitle = parts[0]
        artist = parts[1]
    } else {
        artist = parts[0]
        songTitle = parts.dropFirst().joined(separator: " - ")
    }

    guard !artist.isEmpty, !songTitle.isEmpty else { return nil }
    return NowPlayingTrack(artist: artist, title: songTitle, genre: nil, sourceBundleID: sourceBundle)
}
