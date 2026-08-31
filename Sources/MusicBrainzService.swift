import Foundation

/// Resolves an artist's dominant genre from MusicBrainz (free, no API key).
///
/// Why MusicBrainz instead of Spotify or iTunes:
///   - Spotify REMOVED `genres` (and followers/popularity) from its Web API in 2024 —
///     `GET /v1/artists/{id}` now returns only name/images/uri, so it's useless for genre.
///   - iTunes gives a single per-track tag that is often wrong at the artist level
///     (e.g. it labels Buckethead "Electronic", Dire Straits "Pop").
///   - MusicBrainz returns community genre/tag votes WITH counts, so count-weighting
///     recovers the artist's real style (Buckethead → progressive metal/rock,
///     Dire Straits → rock, Pentagram → doom metal). Verified against the live API.
///
/// Two requests per artist (search → detail), cached. MusicBrainz requires a descriptive
/// User-Agent and asks clients to stay ≤ ~1 req/s, which the throttle below honours.
actor MusicBrainzService {
    private static let userAgent = "EqLume/1.0 ( https://github.com/gokturkgocen/EqLume )"
    private static let base = "https://musicbrainz.org/ws/2"

    struct WeightedGenre { let name: String; let count: Int }

    /// Three outcomes, not two. "No data" and "no answer" look identical to a caller that
    /// only gets an optional back, and treating them the same is what turns a momentary
    /// network hiccup into a wrong preset: the chain falls through to a source it considers
    /// worse and commits to that answer. Andrea Bocelli is `classical` 6 / `classical
    /// crossover` 3 / `pop` 2 here — MusicBrainz knew — but one unanswered request handed
    /// the track to iTunes, which says Pop.
    enum GenreLookup {
        case genres([WeightedGenre])
        case none          // the entity is known and carries no votes, or is genuinely absent
        case unavailable   // the request failed; the answer is unknown, not empty
    }

    private var cache: [String: [WeightedGenre]] = [:]        // artist(lower) → genres (cached miss = [])
    private var albumCache: [String: [WeightedGenre]] = [:]   // artist||title → album genres
    private var lastRequest = Date.distantPast

    /// Count-weighted genres of the ALBUM a track belongs to, highest count first.
    ///
    /// Artist votes describe a career, and that is the wrong answer whenever one record
    /// departs from it. Tame Impala's artist votes are psychedelic rock 13 / alternative
    /// rock 5 / indie rock 3, so every track of theirs resolves to rock — but "Dracula" is
    /// on *Deadbeat*, whose own votes are dance-pop 3 plus house / tech house / techno /
    /// electronic. The album is the better unit for an EQ curve, so callers try this first
    /// and fall back to `artistGenres` when it comes up empty (many tracks have no
    /// album-level votes at all, and singles have no studio album to look at).
    ///
    /// Two requests (recording search → release-group detail), cached per artist+title.
    func albumGenres(artist: String, title: String) async -> GenreLookup {
        let key = "\(artist.lowercased())||\(title.lowercased())"
        if let cached = albumCache[key] { return cached.isEmpty ? .none : .genres(cached) }
        switch await searchStudioAlbumMBID(artist: artist, title: title) {
        case .failed:
            return .unavailable                // transient — do not poison the cache
        case .noMatch:
            albumCache[key] = []
            return .none
        case .found(let mbid):
            // Genres only, no `tags` fallback: release-group tags are full of things that
            // are not genres at all ("plattentests.de", "offizielle charts", "5+ wochen").
            guard let genres = await fetchGenres(entity: "release-group", mbid: mbid,
                                                 tagsFallback: false) else { return .unavailable }
            albumCache[key] = genres
            return genres.isEmpty ? .none : .genres(genres)
        }
    }

    /// Count-weighted genres for `name`, highest count first. nil if the artist isn't found
    /// or has no genre votes → caller falls back to iTunes.
    func artistGenres(name: String) async -> GenreLookup {
        let key = name.lowercased()
        if let cached = cache[key] { return cached.isEmpty ? .none : .genres(cached) }
        // IMPORTANT: only cache HTTP-200-backed outcomes. A transient failure (timeout /
        // 503 rate-limit) must NOT be cached as a permanent miss — otherwise a well-known
        // artist (e.g. Scorpions) gets stuck falling through to the audio classifier for the
        // rest of the session and is mislabeled (Scorpions → "World Music"). Retry next time.
        switch await searchArtistMBID(name: name) {
        case .failed:
            return .unavailable           // transient — do not poison the cache
        case .noMatch:
            cache[key] = []               // genuinely unknown artist — cache the miss
            return .none
        case .found(let mbid):
            // request failed → don't cache
            guard let genres = await fetchGenres(entity: "artist", mbid: mbid,
                                                 tagsFallback: true) else { return .unavailable }
            cache[key] = genres           // 200-backed (possibly empty) → cache
            return genres.isEmpty ? .none : .genres(genres)
        }
    }

    private enum SearchResult { case found(String), noMatch, failed }

    /// Finds the release group of the studio album a recording belongs to.
    ///
    /// Everything that is not a plain album is skipped, because its genre votes describe
    /// the package rather than the track: "Dracula" is on the compilations "Now That's
    /// What I Call Music! 123" and "Bravo Hits 132", on remix singles, and on DJ-mixes —
    /// the entry we want, `Deadbeat`, is the one with primary type Album and no secondary
    /// type at all. Recordings come back in relevance order, so the first qualifying
    /// release group of the best artist-matching recording is the original album.
    private func searchStudioAlbumMBID(artist: String, title: String) async -> SearchResult {
        var c = URLComponents(string: "\(Self.base)/recording")!
        c.queryItems = [
            URLQueryItem(name: "query",
                         value: "artist:\"\(Self.luceneEscaped(artist))\" AND recording:\"\(Self.luceneEscaped(title))\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = c.url, let data = await get(url),
              let obj = try? JSONDecoder().decode(RecordingSearch.self, from: data) else { return .failed }
        for recording in obj.recordings {
            let credited = (recording.artistCredit ?? []).map(\.artist.name)
            guard credited.contains(where: { artistNamesRoughlyMatch($0, artist) }) else { continue }
            for release in recording.releases ?? [] {
                guard let group = release.releaseGroup,
                      group.primaryType == "Album",
                      (group.secondaryTypes ?? []).isEmpty else { continue }
                return .found(group.id)
            }
        }
        return .noMatch
    }

    /// Escapes the two characters that would break out of a quoted Lucene term.
    private static func luceneEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func searchArtistMBID(name: String) async -> SearchResult {
        var c = URLComponents(string: "\(Self.base)/artist")!
        c.queryItems = [
            URLQueryItem(name: "query", value: name),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = c.url, let data = await get(url),
              let obj = try? JSONDecoder().decode(ArtistSearch.self, from: data) else { return .failed }
        // The name has to actually agree, and there is deliberately NO "take the top hit
        // anyway" fallback. MusicBrainz search always answers with its best fuzzy guesses,
        // so a query that is not really an artist name — a work-title fragment, an upload
        // channel — would otherwise be handed a stranger's genres at full confidence.
        // That is exactly how a Chopin nocturne came out as METAL: the title splitter cut
        // "E-flat" at its dash, the fragment "Chopin: Nocturne in E" went out as an artist
        // query, and a Dallas metal band called Nocturne matched it on a bare substring —
        // outranking the score-100 "Fryderyk Chopin" sitting at the top of the same result.
        // Unknown artist → .noMatch, so the caller can fall back to iTunes and then to
        // audio analysis, both of which are able to say "I don't know".
        //
        // Second chance for the top hit only: MusicBrainz's index knows aliases and
        // transliterations our normalizer cannot ("Frédéric Chopin" is indexed as
        // "Fryderyk Chopin"), and in those the surname is the part that survives.
        let match = obj.artists.first { artistNamesRoughlyMatch($0.name, name) }
            ?? obj.artists.first.flatMap { artistSurnamesMatch($0.name, name) ? $0 : nil }
        return match.map { .found($0.id) } ?? .noMatch
    }

    /// Returns nil ONLY on request failure (so the caller won't cache it); an empty array
    /// means the entity was found but carries no genre/tag votes.
    private func fetchGenres(entity: String, mbid: String, tagsFallback: Bool) async -> [WeightedGenre]? {
        guard let url = URL(string: "\(Self.base)/\(entity)/\(mbid)?inc=genres+tags&fmt=json"),
              let data = await get(url),
              let obj = try? JSONDecoder().decode(GenreDetail.self, from: data) else { return nil }
        // Prefer the curated `genres` list; fall back to raw `tags`. Both carry vote counts.
        let genres = obj.genres ?? []
        let src = (genres.isEmpty && tagsFallback) ? (obj.tags ?? []) : genres
        return src.map { WeightedGenre(name: $0.name, count: max(1, $0.count ?? 1)) }
                  .sorted { $0.count > $1.count }
    }

    /// Throttled GET (≤ ~1 req/s) with the required User-Agent. Returns nil on any non-200.
    private func get(_ url: URL) async -> Data? {
        // Two attempts. Resolving one track can now cost four requests (album search, album
        // detail, artist search, artist detail) and the throttle spaces them at least 1.1 s
        // apart, so a burst of track changes queues up — a single miss used to be enough to
        // hand the track to a worse source. The retry is cheap because the throttle already
        // paces it, and a genuine 404 is not retried into: only a failure to get an answer.
        for attempt in 0..<2 {
            let since = Date().timeIntervalSince(lastRequest)
            if since < 1.1 {
                try? await Task.sleep(nanoseconds: UInt64((1.1 - since) * 1_000_000_000))
            }
            lastRequest = Date()
            var req = URLRequest(url: url)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 8
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                continue                       // no answer at all — worth one more try
            }
            if http.statusCode == 200 { return data }
            // 503 is MusicBrainz asking us to slow down; anything else is a real answer we
            // simply cannot use, and retrying it would only burn the rate limit.
            if http.statusCode != 503 { return nil }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        return nil
    }

    private struct ArtistSearch: Decodable {
        let artists: [Item]
        struct Item: Decodable { let id: String; let name: String }
    }
    /// Genre/tag votes as returned for any MusicBrainz entity (artist, release group, …).
    private struct GenreDetail: Decodable {
        let genres: [Tag]?
        let tags: [Tag]?
        struct Tag: Decodable { let name: String; let count: Int? }
    }

    private struct RecordingSearch: Decodable {
        let recordings: [Recording]

        struct Recording: Decodable {
            let artistCredit: [Credit]?
            let releases: [Release]?

            private enum CodingKeys: String, CodingKey {
                case artistCredit = "artist-credit", releases
            }

            struct Credit: Decodable {
                let artist: Artist
                struct Artist: Decodable { let name: String }
            }

            struct Release: Decodable {
                let releaseGroup: Group?

                private enum CodingKeys: String, CodingKey { case releaseGroup = "release-group" }

                struct Group: Decodable {
                    let id: String
                    let primaryType: String?
                    let secondaryTypes: [String]?

                    private enum CodingKeys: String, CodingKey {
                        case id
                        case primaryType = "primary-type"
                        case secondaryTypes = "secondary-types"
                    }
                }
            }
        }
    }
}
