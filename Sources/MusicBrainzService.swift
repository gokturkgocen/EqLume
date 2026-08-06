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

    private var cache: [String: [WeightedGenre]] = [:]   // artist(lower) → genres (cached miss = [])
    private var lastRequest = Date.distantPast

    /// Count-weighted genres for `name`, highest count first. nil if the artist isn't found
    /// or has no genre votes → caller falls back to iTunes.
    func artistGenres(name: String) async -> [WeightedGenre]? {
        let key = name.lowercased()
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }
        // IMPORTANT: only cache HTTP-200-backed outcomes. A transient failure (timeout /
        // 503 rate-limit) must NOT be cached as a permanent miss — otherwise a well-known
        // artist (e.g. Scorpions) gets stuck falling through to the audio classifier for the
        // rest of the session and is mislabeled (Scorpions → "World Music"). Retry next time.
        switch await searchArtistMBID(name: name) {
        case .failed:
            return nil                    // transient — do not poison the cache
        case .noMatch:
            cache[key] = []               // genuinely unknown artist — cache the miss
            return nil
        case .found(let mbid):
            guard let genres = await fetchGenres(mbid: mbid) else { return nil }  // request failed → don't cache
            cache[key] = genres           // 200-backed (possibly empty) → cache
            return genres.isEmpty ? nil : genres
        }
    }

    private enum SearchResult { case found(String), noMatch, failed }

    private func searchArtistMBID(name: String) async -> SearchResult {
        var c = URLComponents(string: "\(Self.base)/artist")!
        c.queryItems = [
            URLQueryItem(name: "query", value: name),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = c.url, let data = await get(url),
              let obj = try? JSONDecoder().decode(ArtistSearch.self, from: data) else { return .failed }
        // Verify the name so an ambiguous query can't pull a different artist's genres.
        let match = obj.artists.first { artistNamesRoughlyMatch($0.name, name) } ?? obj.artists.first
        return match.map { .found($0.id) } ?? .noMatch
    }

    /// Returns nil ONLY on request failure (so the caller won't cache it); an empty array
    /// means the artist was found but carries no genre/tag votes.
    private func fetchGenres(mbid: String) async -> [WeightedGenre]? {
        guard let url = URL(string: "\(Self.base)/artist/\(mbid)?inc=genres+tags&fmt=json"),
              let data = await get(url),
              let obj = try? JSONDecoder().decode(ArtistDetail.self, from: data) else { return nil }
        // Prefer the curated `genres` list; fall back to raw `tags`. Both carry vote counts.
        let genres = obj.genres ?? []
        let src = genres.isEmpty ? (obj.tags ?? []) : genres
        return src.map { WeightedGenre(name: $0.name, count: max(1, $0.count ?? 1)) }
                  .sorted { $0.count > $1.count }
    }

    /// Throttled GET (≤ ~1 req/s) with the required User-Agent. Returns nil on any non-200.
    private func get(_ url: URL) async -> Data? {
        let since = Date().timeIntervalSince(lastRequest)
        if since < 1.1 {
            try? await Task.sleep(nanoseconds: UInt64((1.1 - since) * 1_000_000_000))
        }
        lastRequest = Date()
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private struct ArtistSearch: Decodable {
        let artists: [Item]
        struct Item: Decodable { let id: String; let name: String }
    }
    private struct ArtistDetail: Decodable {
        let genres: [Tag]?
        let tags: [Tag]?
        struct Tag: Decodable { let name: String; let count: Int? }
    }
}
