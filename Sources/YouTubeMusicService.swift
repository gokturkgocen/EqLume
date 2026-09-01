import Foundation

/// Reads YouTube Music's web player state from a browser tab by injecting a
/// JavaScript snippet via AppleScript's `execute javascript` command.
///
/// Requirements (one-time, per browser):
///   • Chrome / Brave / Edge / Arc:
///       View → Developer → "Allow JavaScript from Apple Events"
///   • Safari:
///       Safari Settings → Advanced → "Show Develop menu" →
///       Develop → "Allow JavaScript from Apple Events"
///
/// The script reads two pieces of state from the YT Music DOM:
///   1. Currently playing track (from `<ytmusic-player-bar>`)
///   2. The track that will play next (the queue item right after the
///      selected one in `<ytmusic-player-queue>`)
///
/// Returning both in one round-trip is what makes pre-fetching cheap.
@MainActor
enum YouTubeMusicService {

    struct Snapshot: Codable, Equatable {
        var current: Track?
        var next: Track?

        struct Track: Codable, Equatable {
            var title: String
            var artist: String
            var art: String?

            var identity: String { "\(artist.lowercased())||\(title.lowercased())" }
        }
    }

    /// JS we inject. Single statement so it works inside AppleScript's
    /// `execute javascript` (which returns the value of the final expression).
    ///
    /// Two-source strategy:
    ///   1. CURRENT track: always read from `<ytmusic-player-bar>`. This is the
    ///      only DOM element that truly reflects what's playing RIGHT NOW. The
    ///      queue's `[selected]` flag can lag or point at a stale autoplay item
    ///      (saw it return "Guns N' Roses" while Pilli Bebek was actually playing).
    ///   2. NEXT track: walk the queue, find the item whose `.song-title` matches
    ///      the current track's title, then take queue[i+1]. Fallback to `[selected]`
    ///      attribute when title-matching fails (e.g. queue and bar disagree on text).
    ///
    /// Helper readArtistLink() prefers `<a>` with channel URL → any `<a>` →
    /// text-before-bullet as a last resort. This filters out device labels like
    /// "Listening on iPhone" that occasionally appear inline in the byline.
    private static let injectedJS: String = """
    (function(){function readArtistLink(el){if(!el)return '';var a=el.querySelector('a[href*=\"/channel/\"]')||el.querySelector('a');if(a&&a.textContent.trim())return a.textContent.trim();return el.textContent.split('•')[0].trim();}var r={current:null,next:null};var bar=document.querySelector('ytmusic-player-bar');if(bar){var t=bar.querySelector('.title.ytmusic-player-bar');var b=bar.querySelector('.byline.ytmusic-player-bar');var im=bar.querySelector('img.image')||bar.querySelector('img');var art=im?im.src:null;if(t&&t.textContent.trim()){r.current={title:t.textContent.trim(),artist:readArtistLink(b),art:art};}}if(r.current){var q=document.querySelector('ytmusic-player-queue');if(q){var items=q.querySelectorAll('ytmusic-player-queue-item');var i=-1;var ctl=r.current.title.toLowerCase();for(var k=0;k<items.length;k++){var stitle=items[k].querySelector('.song-title');if(stitle&&stitle.textContent.trim().toLowerCase()===ctl){i=k;break;}}if(i<0){for(var k=0;k<items.length;k++){if(items[k].hasAttribute('selected')||items[k].getAttribute('play-button-state')==='playing'){i=k;break;}}}if(i>=0&&i+1<items.length){var nx=items[i+1];var nt=nx.querySelector('.song-title');var nb=nx.querySelector('.byline');if(nt&&nt.textContent.trim()){r.next={title:nt.textContent.trim(),artist:readArtistLink(nb)};}}}}return JSON.stringify(r);})()
    """

    /// Reads YT Music state from the given browser. Returns nil if:
    ///   • the browser isn't running
    ///   • no music.youtube.com tab exists
    ///   • JS injection is blocked (user hasn't enabled the toggle)
    ///   • the page hasn't loaded a track yet
    static func readSnapshot(browser: BrowserKind) async -> Snapshot? {
        let script = buildAppleScript(for: browser, runningJS: injectedJS)
        let result = await AppleScriptRunner.run(script)
        guard case .success(let raw) = result else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("ERROR:") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard var snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        // Clean remaster/remix/etc. tags from DOM titles so catalog lookup matches the
        // canonical recording (the DOM gives raw titles like "... (1997 Digital Remaster)").
        if let c = snap.current { snap.current = .init(title: cleanMusicTitle(c.title), artist: c.artist, art: c.art) }
        if let n = snap.next    { snap.next    = .init(title: cleanMusicTitle(n.title), artist: n.artist, art: n.art) }
        return snap
    }

    /// Diagnostic helper: returns a human-readable status for the "Test izinleri" menu.
    static func diagnose(browser: BrowserKind) async -> String {
        let script = buildAppleScript(for: browser, runningJS: injectedJS)
        switch await AppleScriptRunner.run(script) {
        case .appNotRunning:           return L.t("• not running", "• çalışmıyor")
        case .permissionDenied:        return L.t("⚠ no automation permission", "⚠ otomasyon izni yok")
        case .otherError(_, let msg):
            if msg.lowercased().contains("javascript") {
                return L.t("⚠ JS-from-AppleEvents disabled (Developer menu)", "⚠ JS-from-AppleEvents kapalı (Developer menüsü)")
            }
            return "✗ \(msg.prefix(50))"
        case .success(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty                  { return L.t("• no music.youtube.com tab", "• music.youtube.com sekmesi yok") }
            if trimmed.hasPrefix("ERROR:")      { return "⚠ \(trimmed.prefix(60))" }
            if let data = trimmed.data(using: .utf8),
               let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                let cur = snap.current.map { "\($0.artist) — \($0.title)" } ?? L.t("(nothing playing)", "(hiç çalmıyor)")
                let nxt = snap.next.map { L.t(" | next: ", " | sıradaki: ") + "\($0.artist) — \($0.title)" } ?? ""
                return "✓ \(cur)\(nxt)"
            }
            return L.t("✗ JSON could not be parsed", "✗ JSON parse edilemedi")
        }
    }

    // MARK: - Playback control

    /// Transport actions we can drive on the YT Music web player.
    enum Control {
        case playPause, next, previous

        /// Selectors to try, in order. Current YT Music renders these as
        /// `yt-icon-button` with the class/id below (verified against the live DOM);
        /// the `tp-yt-paper-icon-button` forms are kept as a fallback for older builds.
        fileprivate var selectorsJS: String {
            switch self {
            case .playPause: return "['#play-pause-button','.play-pause-button']"
            case .next:      return "['.next-button','tp-yt-paper-icon-button.next-button']"
            case .previous:  return "['.previous-button','tp-yt-paper-icon-button.previous-button']"
            }
        }
    }

    /// Clicks the requested transport button in the YT Music player bar of the first
    /// `music.youtube.com` tab. Returns true on a confirmed click. Uses the same JS
    /// injection path (and one-time permission) as `readSnapshot`.
    @discardableResult
    static func sendControl(_ control: Control, browser: BrowserKind) async -> Bool {
        let js = "(function(){var bar=document.querySelector('ytmusic-player-bar');if(!bar)return 'NO_BAR';var s=\(control.selectorsJS);for(var i=0;i<s.length;i++){var el=bar.querySelector(s[i])||document.querySelector(s[i]);if(el){el.click();return 'OK';}}return 'NO_BTN';})()"
        let script = buildAppleScript(for: browser, runningJS: js)
        let out = await AppleScriptRunner.runString(script)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
    }

    // MARK: - Browsers

    /// Chromium-family browsers all expose `execute t javascript "..."` the same way.
    /// Safari uses `current tab` instead of `tabs of window` and has a slightly
    /// different command name for execute.
    enum BrowserKind {
        case chrome, brave, edge, arc, safari

        var bundleID: String {
            switch self {
            case .chrome:  return "com.google.Chrome"
            case .brave:   return "com.brave.Browser"
            case .edge:    return "com.microsoft.edgemac"
            case .arc:     return "company.thebrowser.Browser"
            case .safari:  return "com.apple.Safari"
            }
        }

        var appName: String {
            switch self {
            case .chrome:  return "Google Chrome"
            case .brave:   return "Brave Browser"
            case .edge:    return "Microsoft Edge"
            case .arc:     return "Arc"
            case .safari:  return "Safari"
            }
        }

        var isChromium: Bool { self != .safari }
    }

    private static func buildAppleScript(for browser: BrowserKind, runningJS rawJS: String) -> String {
        // Escape backslashes then double quotes so the JS literal survives both
        // AppleScript string parsing and the eventual JavaScript executor.
        let js = rawJS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // `with timeout` is not optional here. AppleScript's default Apple Event timeout is
        // SIXTY seconds (the log shows it counting down "remaining = 7200 ticks"), and
        // `AppleScriptRunner` serialises every script on one queue — so a browser that is too
        // busy to answer promptly does not just lose one read, it wedges every following read
        // behind it. That is what made the popover sit on "Çalmıyor" while music was plainly
        // playing: nothing was broken, the queue was stuck behind a busy Chrome. Failing fast
        // costs one poll; the next tick a second later simply tries again.
        if browser.isChromium {
            return """
            tell application id "\(browser.bundleID)"
                if it is not running then return ""
                try
                with timeout of 3 seconds
                    repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "music.youtube.com" then
                                return execute t javascript "\(js)"
                            end if
                        end repeat
                    end repeat
                end timeout
                on error errMsg number errNum
                    return "ERROR: " & errMsg & " [" & errNum & "]"
                end try
                return ""
            end tell
            """
        } else {
            // Safari: requires "Allow JavaScript from Apple Events" in Develop menu.
            return """
            tell application "Safari"
                if it is not running then return ""
                try
                with timeout of 3 seconds
                    repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "music.youtube.com" then
                                return do JavaScript "\(js)" in t
                            end if
                        end repeat
                    end repeat
                end timeout
                on error errMsg number errNum
                    return "ERROR: " & errMsg & " [" & errNum & "]"
                end try
                return ""
            end tell
            """
        }
    }
}
