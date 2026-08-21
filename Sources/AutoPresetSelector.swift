import Foundation

/// Orchestrates Now-Playing detection → genre lookup → preset selection.
///
/// Two modes coexist:
///   1. Spotify Web API mode (when user has connected Spotify Premium):
///      - We can read the queue, so we PRE-FETCH the next track's genre while
///        the current one is still playing. When Spotify switches tracks (or
///        the user hits Next), we already know the right preset → zero perceived delay.
///   2. AppleScript-only mode (Music.app, browsers, or Spotify without OAuth):
///      - Reactive only. We poll faster (1s) and apply preset as soon as a new
///        track is detected. Latency ~1-1.5s but no setup required.
@available(macOS 14.2, *)
@MainActor
final class AutoPresetSelector {
    private let audio: AudioEngine
    private let providers: [NowPlayingProvider]
    private let genreLookup = GenreLookupService()
    private let musicBrainz = MusicBrainzService()

    // Audio-content genre classifier (Discogs-EffNet CoreML). Loaded lazily off-thread
    // on first need; used only when catalog lookup fails or returns a wrong match.
    private var genreClassifier: GenreClassifier?
    private var classifierLoadAttempted = false

    // Spotify OAuth / Web API queue pre-fetch — not in the App Store build (needs a loopback
    // listener + Keychain, i.e. entitlements that build deliberately doesn't ship). Spotify's
    // AppleScript path (now-playing + transport) is unaffected and stays in every build.
    #if !APP_STORE
    let spotifyAuth = SpotifyAuth()
    private lazy var spotifyAPI = SpotifyAPI(auth: spotifyAuth)
    #endif

    private var task: Task<Void, Never>?
    private var lastTrackIdentity: String?
    private(set) var lastDetection: String = "—"
    private(set) var lastArtworkURL: String?

    // Structured detection state — the source of truth for the UI (the view localizes it).
    // Replaces parsing the Turkish `lastDetection` display string.
    private(set) var lastArtist: String?
    private(set) var lastTitle: String?
    private(set) var lastSourceApp: String?          // "YT Music (Chrome)", "Spotify", "Apple Music" …
    private(set) var lastSourceKind: DetectionSourceKind?
    private(set) var lastStatus: DetectionStatus = .idle
    #if !APP_STORE
    /// UI-only label used when the local classifier cannot make a trustworthy choice.
    /// The neutral preset remains active instead of presenting a fabricated genre.
    private(set) var lastGenreLabelOverride: String?
    #endif

    /// Drops the memo of what is playing so the next poll resolves it again. Used after a
    /// pin changes, so the new curve lands without waiting for the track to change.
    func forgetCurrentTrack() {
        lastTrackIdentity = nil
        nextTrackID = nil
        nextTrackPreset = nil
    }

    /// Record a resolved now-playing track structurally so the view can localize it.
    private func markResolved(app: String, artist: String, title: String, kind: DetectionSourceKind?) {
        lastSourceApp = app; lastArtist = artist; lastTitle = title
        lastSourceKind = kind; lastStatus = .playing
        #if !APP_STORE
        lastGenreLabelOverride = nil
        #endif
    }

    /// Pre-fetched preset for whatever Spotify/YT Music will play after the current track.
    /// Filled when we read the queue; consumed when a track change is detected.
    private var nextTrackID: String?
    private var nextTrackPreset: EQPreset?
    private var nextTrackInfo: String?

    /// Browser bundles that we'll try to read YouTube Music DOM from.
    private static let ytMusicBrowsers: [(YouTubeMusicService.BrowserKind, String)] = [
        (.chrome,  "com.google.Chrome"),
        (.arc,     "company.thebrowser.Browser"),
        (.brave,   "com.brave.Browser"),
        (.edge,    "com.microsoft.edgemac"),
        (.safari,  "com.apple.Safari"),
    ]

    var onStatusChange: (() -> Void)?

    /// AppleScript-only polling interval. Spotify-Web-API mode uses on-demand timing.
    private let appleScriptPollInterval: TimeInterval = 1.0

    var enabled: Bool = false {
        didSet {
            if enabled { startPolling() }
            else       { stopPolling() }
        }
    }

    init(audio: AudioEngine) {
        self.audio = audio
        self.providers = [
            SpotifyProvider(),
            MusicProvider(),
            ChromeProvider(),
            ArcProvider(),
            BraveProvider(),
            EdgeProvider(),
            SafariProvider(),
        ]
    }

    private func startPolling() {
        task?.cancel()
        task = Task { [weak self] in
            // Immediate first tick so user doesn't wait.
            await self?.tick()
            while !Task.isCancelled {
                let interval = self?.appleScriptPollInterval ?? 1.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.tick()
            }
        }
    }

    private func stopPolling() {
        task?.cancel()
        task = nil
        audioClassifyTask?.cancel()
        audioClassifyTask = nil
        lastTrackIdentity = nil
        nextTrackID = nil
        nextTrackPreset = nil
        nextTrackInfo = nil
        lastDetection = "—"
        lastArtist = nil; lastTitle = nil; lastSourceApp = nil
        lastSourceKind = nil; lastStatus = .idle
        #if !APP_STORE
        lastGenreLabelOverride = nil
        #endif
        onStatusChange?()
    }

    // MARK: - Preset resolution (catalog → audio analysis → default)

    /// Catalog resolution (no audio). Order:
    ///   0. direct genre hint (Music.app gives genre) — trust it
    ///   1. classical work markers in the TITLE — better than any catalog for this one genre
    ///   2. catalog (MusicBrainz → iTunes) WITH artist-name verification
    ///   3. the same, retried with an "Artist - Title" parsed out of the title
    /// Returns nil when the catalog can't confidently resolve → caller defers to
    /// the audio-content classifier. Used for both now-playing and prefetch.
    private func catalogPreset(artist: String, title: String, genreHint: String?) async -> (EQPreset, String)? {
        // 0. A pin is the user's own answer for this exact track, so it outranks everything
        //    below it — including a genre hint the player supplied.
        if let pinned = PinnedPresets.preset(artist: artist, title: title) {
            return (pinned, "[\(L.t("pinned", "sabit")) \u{2605}]")
        }
        #if !APP_STORE
        if Self.isKnownArabeskArtist(artist) {
            return (.arabesk, "[Arabesk]")
        }
        if Self.isKnownFolkArtist(artist) {
            return (.turkishFolk, "[\(L.t("folk artist", "halk sanatçısı"))]")
        }
        #endif
        if let g = genreHint, !g.isEmpty {
            return (mapGenreToPreset(g), "[\(g)]")
        }
        // 1. Classical works announce themselves in the title (see `looksLikeClassicalWork`).
        //    This runs BEFORE any lookup on purpose: on a classical upload the artist field
        //    holds the performer, who is usually in no catalog at all, while the title states
        //    exactly what the piece is.
        if Self.looksLikeClassicalWork(title) {
            return (.classical, "[\(L.t("classical work", "klasik eser")) ♯]")
        }
        // 2. Resolve the reported (artist, title).
        if let r = await resolveGenre(artist: artist, title: title) { return r }
        // 3. "Artist - Title" embedded in the title field. Common on YouTube / YT Music where
        //    a compilation/upload channel lands in the artist field (e.g. "NEA ZIXNH") and the
        //    real artist sits inside the title ("Gary Moore - Parisienne Walkways"). Split on
        //    the first dash and retry with the artist parsed from the title.
        if let (embArtist, embTitle) = Self.splitArtistTitle(title),
           !artistNamesRoughlyMatch(embArtist, artist) {   // skip if it just repeats the artist
            if let r = await resolveGenre(artist: embArtist, title: embTitle) { return r }
        }
        return nil
    }

    /// Resolves a genre for one (artist, title) candidate, best source first:
    ///   1. MusicBrainz artist-genres — community genre votes WITH counts, count-weighted
    ///      into a family. Accurate for style and free/no-key; fixes the per-track mislabels
    ///      iTunes produces (Buckethead → "Electronic", Dire Straits → "Pop"). Spotify is NOT
    ///      used for genre — it removed `genres` from its Web API in 2024.
    ///   2. iTunes track lookup, verified against the artist name (fallback for artists
    ///      MusicBrainz doesn't cover).
    /// Returns nil if neither resolves confidently → caller defers to the audio classifier.
    private func resolveGenre(artist: String, title: String) async -> (EQPreset, String)? {
        // Album votes before artist votes: they describe THIS record, where artist votes
        // describe a career. Tame Impala is psychedelic rock by career and dance/house on
        // "Deadbeat", and it is the record that should pick the curve. Album coverage is
        // thinner than artist coverage, so this is a preference, not a replacement.
        if let genres = await musicBrainz.albumGenres(artist: artist, title: title),
           let (preset, top) = Self.mapWeightedGenresToPreset(genres) {
            return (preset, "[\(top) ♪]")
        }
        if let genres = await musicBrainz.artistGenres(name: artist),
           let (preset, top) = Self.mapWeightedGenresToPreset(genres) {
            return (preset, "[\(top) ♪]")
        }
        if let hit = await genreLookup.lookup(artist: artist, title: title),
           artistNamesRoughlyMatch(hit.matchedArtist, artist) {
            #if !APP_STORE
            // Apple's storefront taxonomy returns "World"/"Worldwide" for many Turkish
            // releases. That is a broad sales category, not a usable musical genre.
            let normalizedGenre = hit.genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedGenre == "world" || normalizedGenre == "worldwide"
                || normalizedGenre == "world music" {
                return nil
            }
            #endif
            return (mapGenreToPreset(hit.genre), "[\(hit.genre)]")
        }
        return nil
    }

    #if !APP_STORE
    /// Normalizes a Turkish or Azerbaijani name to a bare ASCII-ish key.
    ///
    /// Foundation's diacritic folding handles ş/ç/ğ/ö/ü but NOT the two letters that are
    /// their own characters rather than a base plus a mark: dotless `ı` and Azerbaijani
    /// schwa `ə`. Both have to be mapped by hand — and until this was written the arabesk
    /// list below silently failed on exactly those names, because "İbrahim Tatlıses"
    /// normalized to "ibrahimtatlıses" while the list said "ibrahimtatlises". Two of its
    /// eleven entries could never match.
    private static func turkicNameKey(_ name: String) -> String {
        name
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "I", with: "i")
            .replacingOccurrences(of: "ə", with: "e")
            .replacingOccurrences(of: "Ə", with: "e")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Apple commonly files classic Turkish arabesk/fantezi under the generic
    /// "Worldwide" storefront bucket. Keep a small, explicit local correction list
    /// rather than pretending every Turkish artist belongs to the same genre.
    private static func isKnownArabeskArtist(_ artist: String) -> Bool {
        knownArabeskArtists.contains(turkicNameKey(artist))
    }

    /// Anatolian and Caucasian folk singers the catalogs get wrong in a way no keyword can
    /// reach: Apple files "Evlərinin önü yonca" — an Azerbaijani xalq mahnısı — under
    /// **Pop**, with the artist name matching exactly, so the verification that normally
    /// rejects bad hits passes it through. MusicBrainz simply has no entry for many of them.
    /// When the catalog is not merely thin but confidently wrong, a name is the only
    /// signal left. Deliberately a short list of artists actually listened to here, not an
    /// attempt at a taxonomy.
    private static func isKnownFolkArtist(_ artist: String) -> Bool {
        knownFolkArtists.contains(turkicNameKey(artist))
    }

    private static let knownFolkArtists: Set<String> = [
        "nesetertas",
        "muharremertas",
        "hacitasan",
        "cetinakdeniz",
        "asikveysel",
        "nerminememmedova",
        "gulyanaqmemmedova",
        "gulyazmemmedova",
    ]

    private static let knownArabeskArtists: Set<String> = [
        "azerbulbul",
        "bergen",
        "cengizkurtoglu",
        "ferditayfur",
        "gullu",
        "hakantasiyan",
        "ibrahimtatlises",
        "kamuranakkor",
        "kibariye",
        "muslumgurses",
        "orhangencebay",
    ]
    #endif

    /// True when a title carries an unambiguous classical-publishing marker. Classical
    /// uploads are the one case where the title is a better genre source than any catalog:
    /// the artist field names a performer nobody has indexed ("Johannes Helmer Pedersen"),
    /// while the title spells the work out ("Chopin: Nocturne in E-flat Major, Op. 9 No. 2").
    ///
    /// Two ways to qualify, both chosen to stay out of popular music:
    ///   • an opus or thematic-catalogue number (Op. 9, BWV 846, K. 545) — these appear
    ///     essentially nowhere else, so one is enough on its own;
    ///   • a classical form word TOGETHER WITH a movement number or a stated tonality.
    ///     The tonality alone would not do: "In A Major Way" is a soul album.
    static func looksLikeClassicalWork(_ title: String) -> Bool {
        let t = title.lowercased()
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }

        // Single-letter catalogues (Mozart's K., Schubert's D.) require their period —
        // a bare "d 2" is far likelier to be anything else.
        let opusOrCatalogue = has(#"\bop(\.|us)?\s*\d"#)
            || has(#"\b(bwv|hwv|hob|woo|rv|kv)\.?\s*\d{1,4}\b"#)
            || has(#"\b[kd]\.\s*\d{1,4}\b"#)
        if opusOrCatalogue { return true }

        let formWord = has(#"\b(symphony|sonata|concerto|nocturne|prelude|etude|étude|fugue|mazurka|polonaise|rhapsody|waltz|quartet|quintet|cantata|oratorio|requiem|senfoni|sonat|konçerto|noktürn|uvertür|overture)\b"#)
        guard formWord else { return false }
        return has(#"\bno\.?\s*\d"#)
            || has(#"\bin\s+[a-h](\s*-?\s*(flat|sharp))?\s+(major|minor)\b"#)
    }

    /// Splits "Artist - Title" so a channel name sitting in the artist slot can be bypassed.
    ///
    /// Spaced separators (" - ", " – ", " — ") are tried first and are unambiguous. If none
    /// matches we fall back to a BARE dash, because plenty of uploads are titled
    /// "KIVIRCIK ALİ-GÜL TÜKENDİ" with no spaces — without this the real artist is never
    /// looked up and the track ends up misclassified by the audio fallback.
    ///
    /// The bare-dash pass is deliberately conservative, since dashes are also part of names
    /// (Jay-Z, T-Pain, Blink-182, AC-DC). It only splits when BOTH sides are at least 3
    /// characters AND at least one side is multi-word — a hyphenated name almost never
    /// satisfies both, while "Artist Name-Song Name" reliably does.
    private static func splitArtistTitle(_ s: String) -> (artist: String, title: String)? {
        for sep in [" - ", " – ", " — "] {
            guard let r = s.range(of: sep) else { continue }
            let left = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if left.count >= 2 && right.count >= 2 { return (left, right) }
        }
        for sep in ["-", "–", "—"] {
            guard let r = s.range(of: sep) else { continue }
            let left = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard left.count >= 3, right.count >= 3,
                  left.contains(" ") || right.contains(" ") else { continue }
            // A musical key is not "Artist-Title": in "Nocturne in E-flat Major" the text
            // just left of the dash is a single letter. Splitting there yielded the artist
            // query "Chopin: Nocturne in E", which then matched a metal band named Nocturne.
            if left.split(separator: " ").last?.count == 1 { continue }
            return (left, right)
        }
        return nil
    }

    /// Deferred audio-content classification. When the catalog misses, we wait a few
    /// seconds so the analysis ring fills with the CURRENT track (not the previous one's
    /// tail), then classify and apply. Keyed to `identity` so a track change cancels it.
    private var audioClassifyTask: Task<Void, Never>?

    /// Players that only ever hold a music library. On these the audio classifier is not
    /// allowed to answer `.voice`, because there it is always a misfire: the 16 Non-Music
    /// and Children's Discogs styles are where sparse acoustic material leaks — a string
    /// quartet reads as room tone — and genuine speech on these services carries a catalog
    /// genre that resolves long before analysis ever runs. A browser tab is NOT in this set:
    /// a YouTube talk really can be speech, so it keeps the voice verdict.
    static let musicOnlyBundles: Set<String> = ["com.spotify.client", "com.apple.Music"]

    private func scheduleAudioClassification(identity: String, displayPrefix: String,
                                             allowVoice: Bool) {
        audioClassifyTask?.cancel()
        let prefix = displayPrefix
        audioClassifyTask = Task { [weak self] in
            // Let ~4.5s of the current track accumulate in the analysis ring.
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.lastTrackIdentity == identity else { return }   // track changed → abort
            guard let (samples, rate) = self.audio.snapshotAnalysisAudio(seconds: 4.0) else { return }
            guard let clf = await self.ensureClassifier() else {
                self.applyIfChanged(.pop)
                self.lastDetection = "\(prefix) [catalog unavailable] → \(EQPreset.pop.name)"
                self.lastSourceKind = .catalog
                self.onStatusChange?()
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                clf.classify(samples: samples, inputRate: rate, allowVoice: allowVoice)
            }.value
            guard !Task.isCancelled, self.lastTrackIdentity == identity else { return }
            #if !APP_STORE
            guard let r = result, r.isReliable else {
                self.applyIfChanged(.natural)
                self.lastGenreLabelOverride = L.t("Genre uncertain", "Tür belirlenemedi")
                self.lastDetection = "\(prefix) [analysis uncertain] → \(EQPreset.natural.name)"
                self.lastSourceKind = .analyzed
                self.onStatusChange?()
                return
            }
            #else
            guard let r = result else { return }
            #endif
            self.applyIfChanged(r.family.preset)
            #if !APP_STORE
            self.lastGenreLabelOverride = nil
            #endif
            self.lastDetection = String(format: "%@ [%@ · %.0f%%] → %@",
                                        prefix, r.topStyle, r.confidence * 100, r.family.preset.name)
            self.lastSourceKind = .analyzed   // artist/title/app already set when analysis was scheduled
            self.onStatusChange?()
        }
    }

    private func ensureClassifier() async -> GenreClassifier? {
        if let c = genreClassifier { return c }
        if classifierLoadAttempted { return nil }
        classifierLoadAttempted = true
        guard let resDir = Bundle.main.resourceURL else { return nil }
        genreClassifier = await Task.detached(priority: .userInitiated) {
            GenreClassifier(resourceDir: resDir)
        }.value
        return genreClassifier
    }

    // MARK: - Main tick

    private func tick() async {
        guard enabled else { return }

        let sourceBundle = AudioSourceMonitor.currentSourceBundleID()

        // Spotify + Web API path — prefer this when available; gives us queue lookahead.
        // Absent in the App Store build; Spotify falls through to the AppleScript path below.
        #if !APP_STORE
        if sourceBundle == "com.spotify.client" && spotifyAuth.isConnected {
            await tickSpotifyAPI()
            return
        }
        #endif

        // YouTube Music in a browser → try DOM-scraping path for queue lookahead.
        if let browser = Self.ytMusicBrowsers.first(where: { $0.1 == sourceBundle })?.0 {
            if await tickYouTubeMusic(browser: browser) { return }
            // Fell through (no YT Music tab, no JS permission, etc.) → reactive fallback.
        }

        await tickAppleScript(sourceBundle: sourceBundle)
    }

    // MARK: - YouTube Music path (with pre-fetch via JS injection)

    /// Returns true if YT Music produced a usable snapshot; false → caller should fall back.
    private func tickYouTubeMusic(browser: YouTubeMusicService.BrowserKind) async -> Bool {
        guard let snap = await YouTubeMusicService.readSnapshot(browser: browser),
              let current = snap.current
        else { return false }

        let identity = current.identity

        if identity != lastTrackIdentity {
            lastTrackIdentity = identity
            lastArtworkURL = current.art
            audioClassifyTask?.cancel()
            let prefix = "YT Music (\(browser.appName)): \(current.artist) — \(current.title)"
            let app = "YT Music (\(browser.appName))"

            if nextTrackID == identity, let cached = nextTrackPreset {
                applyIfChanged(cached)
                lastDetection = "\(prefix) [pre-fetch ✓] → \(cached.name)"
                markResolved(app: app, artist: current.artist, title: current.title, kind: .prefetch)
            } else if let (preset, tag) = await catalogPreset(artist: current.artist, title: current.title, genreHint: nil) {
                applyIfChanged(preset)
                lastDetection = "\(prefix) \(tag) → \(preset.name)"
                markResolved(app: app, artist: current.artist, title: current.title,
                             kind: DetectionSourceKind.forTag(tag))
            } else {
                lastDetection = "\(prefix) [katalog yok · ses analizi…]"
                markResolved(app: app, artist: current.artist, title: current.title, kind: .analyzing)
                scheduleAudioClassification(identity: identity, displayPrefix: prefix,
                                            allowVoice: false)   // YT Music is music only
            }

            // Pre-resolve the next track if we have it.
            nextTrackID = nil
            nextTrackPreset = nil
            nextTrackInfo = nil
            if let next = snap.next {
                Task { [weak self] in await self?.prefetchYouTubeMusicNext(next) }
            }
            onStatusChange?()
        } else {
            let lookahead = nextTrackInfo.map { "  ⤴ sıradaki: \($0)" } ?? ""
            lastDetection = "YT Music: \(current.artist) — \(current.title)\(lookahead)"
            onStatusChange?()
        }
        return true
    }

    private func prefetchYouTubeMusicNext(_ next: YouTubeMusicService.Snapshot.Track) async {
        // Only prefetch when the catalog can resolve it; audio analysis can't run on a
        // track that isn't playing yet, so on a catalog miss we leave the cache empty
        // and let the real-time path classify the audio once the track actually starts.
        if let (preset, _) = await catalogPreset(artist: next.artist, title: next.title, genreHint: nil) {
            nextTrackID = next.identity
            nextTrackPreset = preset
            nextTrackInfo = "\(next.artist) — \(next.title) → \(preset.name)"
            onStatusChange?()
        } else {
            nextTrackID = nil; nextTrackPreset = nil; nextTrackInfo = nil
        }
    }

    // MARK: - Spotify Web API path (with pre-fetch) — non-App-Store builds only

    #if !APP_STORE
    private func tickSpotifyAPI() async {
        guard let snapshot = await spotifyAPI.currentlyPlaying(),
              let item = snapshot.item
        else {
            // Premium expired? Token failed? Fall back to AppleScript path.
            await tickAppleScript(sourceBundle: "com.spotify.client")
            return
        }

        let trackID = item.id ?? "\(item.primaryArtist)|\(item.name)"

        // Track change detected.
        if trackID != lastTrackIdentity {
            lastTrackIdentity = trackID
            lastArtworkURL = item.artworkURL
            audioClassifyTask?.cancel()
            let prefix = "Spotify: \(item.primaryArtist) — \(item.name)"

            if nextTrackID == trackID, let cached = nextTrackPreset {
                // 1. Pre-fetched preset for this track → apply instantly.
                applyIfChanged(cached)
                lastDetection = "\(prefix) [pre-fetch ✓] → \(cached.name)"
                markResolved(app: "Spotify", artist: item.primaryArtist, title: item.name, kind: .prefetch)
            } else if let (preset, tag) = await catalogPreset(artist: item.primaryArtist, title: item.name, genreHint: nil) {
                // 2. Catalog resolved (verified) → apply instantly.
                applyIfChanged(preset)
                lastDetection = "\(prefix) \(tag) → \(preset.name)"
                markResolved(app: "Spotify", artist: item.primaryArtist, title: item.name,
                             kind: DetectionSourceKind.forTag(tag))
            } else {
                // 3. Catalog miss → defer to audio-content classification.
                lastDetection = "\(prefix) [katalog yok · ses analizi…]"
                markResolved(app: "Spotify", artist: item.primaryArtist, title: item.name, kind: .analyzing)
                scheduleAudioClassification(identity: trackID, displayPrefix: prefix,
                                            allowVoice: false)   // Spotify is music only
            }
            onStatusChange?()

            // 4. Schedule prefetch of the NEXT-after-this track.
            nextTrackID = nil
            nextTrackPreset = nil
            nextTrackInfo = nil
            Task { [weak self] in await self?.prefetchNext() }
        } else {
            // Same track — keep status fresh but don't churn.
            let lookahead = nextTrackInfo.map { "  ⤴ sıradaki: \($0)" } ?? ""
            lastDetection = "Spotify: \(item.primaryArtist) — \(item.name)\(lookahead)"
            onStatusChange?()
        }
    }

    private func prefetchNext() async {
        guard let queueSnap = await spotifyAPI.queue(),
              let next = queueSnap.nextTrack
        else {
            nextTrackID = nil; nextTrackPreset = nil; nextTrackInfo = nil
            return
        }
        if let (preset, _) = await catalogPreset(artist: next.primaryArtist, title: next.name, genreHint: nil) {
            nextTrackID = next.id ?? "\(next.primaryArtist)|\(next.name)"
            nextTrackPreset = preset
            nextTrackInfo = "\(next.primaryArtist) — \(next.name) → \(preset.name)"
            onStatusChange?()
        } else {
            nextTrackID = nil; nextTrackPreset = nil; nextTrackInfo = nil
        }
    }

    #endif  // !APP_STORE — end of Spotify Web API pre-fetch path

    // MARK: - AppleScript path (reactive)

    private func tickAppleScript(sourceBundle: String?) async {
        let preferred = providers.first(where: { $0.bundleID == sourceBundle })
        var track: NowPlayingTrack? = nil
        if let preferred {
            track = await preferred.currentTrack()
        }
        if track == nil {
            for provider in providers where provider.bundleID != sourceBundle {
                if let t = await provider.currentTrack() {
                    track = t; break
                }
            }
        }

        if let track {
            if track.identity == lastTrackIdentity { return }
            lastTrackIdentity = track.identity
            lastArtworkURL = nil   // AppleScript providers don't supply artwork
            audioClassifyTask?.cancel()
            let app = shortAppName(track.sourceBundleID)
            let prefix = "\(app): \(track.artist) — \(track.title)"

            if let (preset, tag) = await catalogPreset(artist: track.artist, title: track.title, genreHint: track.genre) {
                applyIfChanged(preset)
                lastDetection = "\(prefix) \(tag) → \(preset.name)"
                markResolved(app: app, artist: track.artist, title: track.title,
                             kind: DetectionSourceKind.forTag(tag))
            } else {
                lastDetection = "\(prefix) [katalog yok · ses analizi…]"
                markResolved(app: app, artist: track.artist, title: track.title, kind: .analyzing)
                scheduleAudioClassification(
                    identity: track.identity, displayPrefix: prefix,
                    allowVoice: !Self.musicOnlyBundles.contains(track.sourceBundleID))
            }
        } else if let sourceBundle {
            let preset = mapBundleToPreset(sourceBundle)
            lastDetection = "\(shortAppName(sourceBundle)) → \(preset.name)  ⚠ şarkı okunamadı (Otomasyon izni?)"
            applyIfChanged(preset)
            lastSourceApp = shortAppName(sourceBundle)
            lastArtist = nil; lastTitle = nil; lastSourceKind = nil; lastStatus = .unreadable
        } else {
            lastDetection = "Ses kaynağı yok"
            lastSourceApp = nil; lastArtist = nil; lastTitle = nil
            lastSourceKind = nil; lastStatus = .noSource
        }
        onStatusChange?()
    }

    // MARK: - Common helpers

    private func applyIfChanged(_ preset: EQPreset) {
        if audio.activePreset.name != preset.name {
            audio.activePreset = preset
        }
    }

    private func mapGenreToPreset(_ genre: String?) -> EQPreset {
        guard let raw = genre?.lowercased() else { return .pop }

        // Trap / Phonk — extreme sub-bass, check before generic rap.
        if raw.contains("trap") || raw.contains("phonk")                     { return .trap }
        // Hip-hop / rap / drill
        if raw.contains("hip-hop") || raw.contains("hip hop") || raw.contains("rap")
            || raw.contains("drill")                                         { return .hipHop }
        // Drum & bass / dubstep / jungle / breakbeat / future bass
        if raw.contains("dubstep") || raw.contains("drum and bass") || raw.contains("drum & bass")
            || raw.contains("dnb")  || raw.contains("jungle")
            || raw.contains("breakbeat") || raw.contains("future bass")     { return .dnb }
        // EDM family
        if raw.contains("electronic") || raw.contains("dance") || raw.contains("edm")
            || raw.contains("house")  || raw.contains("techno")
            || raw.contains("trance") || raw.contains("synthwave")
            || raw.contains("electronica") || raw.contains("idm")            { return .edm }
        // R&B / Soul / Funk / Disco / Neo-Soul
        if raw.contains("r&b") || raw.contains("r and b") || raw.contains("rnb")
            || raw.contains("soul") || raw.contains("funk")
            || raw.contains("disco") || raw.contains("neo-soul")             { return .rnb }
        // K-Pop / J-Pop / Anime / Vocaloid
        if raw.contains("k-pop") || raw.contains("kpop") || raw.contains("k pop")
            || raw.contains("j-pop") || raw.contains("jpop")
            || raw.contains("korean") || raw.contains("japanese")
            || raw.contains("anime") || raw.contains("vocaloid")             { return .kpop }
        // Latin family
        if raw.contains("reggaeton") || raw.contains("latin")
            || raw.contains("salsa") || raw.contains("bachata")
            || raw.contains("cumbia") || raw.contains("merengue")            { return .latin }
        // Reggae / Ska / Dub / Dancehall
        if raw.contains("reggae") || raw.contains("ska")
            || raw.contains("dancehall") || raw.contains("dub")              { return .reggae }
        // Metal (check before generic rock). Removed "hardcore" — too ambiguous.
        if raw.contains("metal") || raw.contains("heavy metal")
            || raw.contains("death metal") || raw.contains("thrash")
            || raw.contains("metalcore") || raw.contains("grindcore")        { return .metal }
        // Rock — incl. punk, emo, shoegaze, grunge, post-rock
        if raw.contains("rock") || raw.contains("punk") || raw.contains("grunge")
            || raw.contains("emo") || raw.contains("shoegaze")               { return .rock }
        // Indie / alternative / hyperpop / dream pop / bedroom pop
        if raw.contains("indie") || raw.contains("alternative") || raw.contains("alt-rock")
            || raw.contains("hyperpop") || raw.contains("dream pop")
            || raw.contains("bedroom pop")                                   { return .indie }
        // Jazz family — bossa nova, big band, swing
        if raw.contains("jazz") || raw.contains("bossa nova")
            || raw.contains("big band") || raw.contains("swing")             { return .jazz }
        // Classical / film score / video game music (all orchestral / cinematic).
        if raw.contains("classical") || raw.contains("orchestral")
            || raw.contains("opera") || raw.contains("symphony")
            || raw.contains("chamber") || raw.contains("soundtrack")
            || raw.contains("score") || raw.contains("film music")
            || raw.contains("video game")                                    { return .classical }
        // Blues
        if raw.contains("blues")                                             { return .blues }
        // Anatolian folk — bozlak / uzun hava / türkü. iTunes labels the whole tradition
        // simply "Halk", and MusicBrainz's only vote on Neşet Ertaş is "uzun hava", so both
        // short forms have to match or the material falls through to a preset with no delta.
        if raw.contains("uzun hava") || raw.contains("bozlak") || raw.contains("halk")
            || raw.contains("türkü") || raw.contains("turku")
            || raw.contains("mugham") || raw.contains("muğam") || raw.contains("aşıq")
            || raw.contains("turkish folk") || raw.contains("azerbaijani folk") { return .turkishFolk }
        #if !APP_STORE
        if raw.contains("arabesk")                                         { return .acoustic }
        #endif
        // Acoustic / Folk / Country / Singer-songwriter / Americana / Bluegrass
        if raw.contains("acoustic") || raw.contains("folk")
            || raw.contains("country") || raw.contains("singer-songwriter")
            || raw.contains("bluegrass") || raw.contains("americana")        { return .acoustic }
        // Ambient family — downtempo, trip-hop, lo-fi, easy listening, vaporwave, chill
        if raw.contains("ambient") || raw.contains("new age")
            || raw.contains("chillout") || raw.contains("meditation")
            || raw.contains("lo-fi") || raw.contains("lofi")
            || raw.contains("downtempo") || raw.contains("trip-hop")
            || raw.contains("trip hop") || raw.contains("easy listening")
            || raw.contains("vaporwave") || raw.contains("chill")            { return .ambient }
        // World / ethnic — incl. Turkish traditional genres, Celtic, Flamenco
        if raw.contains("world") || raw.contains("ethnic")
            || raw.contains("worldbeat") || raw.contains("traditional")
            || raw.contains("flamenco") || raw.contains("celtic")
            || raw.contains("türk halk") || raw.contains("türk sanat")
            || raw.contains("halk") || raw.contains("türkü") || raw.contains("sanat müziği")
            || raw.contains("arabesk") || raw.contains("turkish folk")
            || raw.contains("turkish classical")                             { return .world }
        // Spoken / podcast / audiobook / comedy / children's content
        if raw.contains("spoken") || raw.contains("audiobook")
            || raw.contains("podcast") || raw.contains("comedy")
            || raw.contains("speech") || raw.contains("children")            { return .voice }
        return .pop
    }

    /// Granular genre tags ("avant-garde metal", "dance pop", "instrumental rock", …) →
    /// preset family. Each artist tag is matched against the FIRST rule it satisfies.
    /// Rule ORDER matters: more specific / less-ambiguous families first, and `.pop`
    /// precedes `.edm`/`.rock` so compounds like "dance pop" / "art pop" / "synth-pop"
    /// resolve to pop instead of EDM. Used to score MusicBrainz's count-weighted votes.
    private static let genreKeywordRules: [(EQPreset, [String])] = [
        (.trap,      ["trap", "phonk"]),
        (.hipHop,    ["hip hop", "hip-hop", "rap", "drill"]),
        (.dnb,       ["drum and bass", "drum & bass", "dnb", "dubstep", "jungle", "breakbeat", "breakcore"]),
        (.kpop,      ["k-pop", "kpop", "j-pop", "jpop", "anime", "vocaloid"]),
        (.metal,     ["metal", "grindcore", "thrash", "metalcore", "deathcore", "djent"]),
        (.pop,       ["pop"]),   // before edm/rock: "dance pop"/"art pop"/"synth-pop" → pop
        (.rnb,       ["r&b", "rnb", "soul", "funk", "disco", "motown", "new jack"]),
        (.reggae,    ["reggae", "ska", "dancehall", "dub "]),
        (.latin,     ["reggaeton", "latin", "salsa", "bachata", "cumbia", "merengue", "mariachi", "tango"]),
        (.rock,      ["rock", "punk", "grunge", "emo", "shoegaze"]),
        (.indie,     ["indie", "alternative", "hyperpop"]),
        (.jazz,      ["jazz", "bossa", "swing", "big band", "bebop"]),
        (.classical, ["classical", "orchestral", "opera", "symphony", "chamber", "soundtrack", "score", "baroque"]),
        (.blues,     ["blues"]),
        // Anatolian and Caucasian traditional repertoire. Mugham is Azerbaijani modal art
        // music rather than Turkish folk, but it shares what the curve actually corrects:
        // a high, ornamented, strained vocal, a plucked-string lead (tar/saz), and an
        // analog-era catalogue. Split it out if it ever turns out to want its own curve.
        (.turkishFolk, ["uzun hava", "bozlak", "türkü", "türk halk", "turkish folk", "halk müziği",
                        "âşık", "asik", "mugham", "muğam", "xalq mahnı", "aşıq",
                        "azerbaijani folk", "azeri folk"]),
        (.acoustic,  ["folk", "country", "acoustic", "singer-songwriter", "bluegrass", "americana"]),
        (.ambient,   ["ambient", "downtempo", "lo-fi", "lofi", "new age", "chillout", "chillwave", "trip hop", "trip-hop", "vaporwave", "drone"]),
        (.edm,       ["electronic", "techno", "house", "edm", "trance", "electro", "dance", "idm", "synthwave", "big room", "garage"]),
        (.world,     ["world", "türk", "turkish", "arabesk", "flamenco", "celtic", "ethnic", "afrobeat", "fado", "balkan"]),
        (.voice,     ["spoken word", "audiobook", "podcast", "comedy"]),
    ]

    /// Picks a preset family from count-weighted genre votes (MusicBrainz). Each vote's
    /// count is added to the family its name maps to; the highest-scoring family wins, so
    /// low-count noise (e.g. a stray "chillout" vote on a metal artist) can't beat the
    /// dominant style. Returns the family plus the genre name to display, which is the
    /// strongest vote INSIDE the winning family — not the strongest vote overall, or the
    /// label could contradict the preset it sits next to (the album "Deadbeat" leads with
    /// `dance-pop`, yet its house/techno/electronic votes add up to the EDM family).
    /// nil when nothing recognizable matched.
    static func mapWeightedGenresToPreset(_ genres: [MusicBrainzService.WeightedGenre]) -> (EQPreset, String)? {
        guard !genres.isEmpty else { return nil }
        var tally = [Int: Int]()               // rule index → summed vote count
        var topVote = [Int: (String, Int)]()   // rule index → its highest single vote
        func record(_ idx: Int, _ wg: MusicBrainzService.WeightedGenre) {
            tally[idx, default: 0] += wg.count
            if wg.count > (topVote[idx]?.1 ?? -1) { topVote[idx] = (wg.name, wg.count) }
        }
        for wg in genres {
            let g = wg.name.lowercased()
            #if !APP_STORE
            // Arabesk only: the folk tags are owned by the `.turkishFolk` rule below.
            if g.contains("arabesk"),
               let idx = genreKeywordRules.firstIndex(where: { $0.0.name == EQPreset.acoustic.name }) {
                record(idx, wg)
                continue
            }
            #endif
            for (idx, rule) in genreKeywordRules.enumerated() where rule.1.contains(where: { g.contains($0) }) {
                record(idx, wg)
                break   // first matching rule wins for this tag
            }
        }
        // Highest summed count wins; ties break toward the earlier (more specific) rule.
        var bestIdx = -1, bestScore = 0
        for (idx, _) in genreKeywordRules.enumerated() {
            let s = tally[idx] ?? 0
            if s > bestScore { bestScore = s; bestIdx = idx }
        }
        guard bestIdx >= 0 else { return nil }
        return (genreKeywordRules[bestIdx].0, topVote[bestIdx]?.0 ?? genres.first?.name ?? "MusicBrainz")
    }

    private func mapBundleToPreset(_ bundle: String) -> EQPreset {
        switch bundle {
        case "us.zoom.xos", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
             "com.apple.FaceTime", "com.hnc.Discord", "net.whatsapp.WhatsApp":
            return .voice
        case "org.videolan.vlc", "io.mpv", "com.apple.QuickTimePlayerX",
             "com.netflix.Netflix":
            return .pop
        case "com.spotify.client", "com.apple.Music",
             "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
             "com.microsoft.edgemac", "com.apple.Safari", "org.mozilla.firefox":
            return .pop
        default:
            return audio.activePreset
        }
    }

    private func shortAppName(_ bundle: String) -> String {
        switch bundle {
        case "com.spotify.client":              return "Spotify"
        case "com.apple.Music":                 return "Apple Music"
        case "com.google.Chrome":               return "Chrome"
        case "company.thebrowser.Browser":      return "Arc"
        case "com.brave.Browser":               return "Brave"
        case "com.microsoft.edgemac":           return "Edge"
        case "com.apple.Safari":                return "Safari"
        case "org.mozilla.firefox":             return "Firefox"
        default:                                return bundle
        }
    }
}
