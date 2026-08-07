import Foundation

/// Resolves a (artist, title) pair to a music genre via Apple's free iTunes Search API.
/// Returns the matched artist/track too, so callers can verify the hit actually
/// corresponds to the playing track (iTunes confidently returns wrong matches for
/// ambiguous names — e.g. "no.1 / Kendine İyi Bak" → "Ahmet Kaya"). Cached per session.
actor GenreLookupService {
    struct Hit {
        let genre: String
        let matchedArtist: String
        let matchedTitle: String
    }

    private var cache: [String: Hit?] = [:]

    func lookup(artist: String, title: String) async -> Hit? {
        // Clean remaster/remix/version/etc. tags so iTunes matches the canonical recording
        // (safety net for any source whose title wasn't already cleaned upstream).
        let title = cleanMusicTitle(title)
        let key = "\(artist.lowercased())||\(title.lowercased())"
        if let cached = cache[key] { return cached }

        let term = "\(artist) \(title)"
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            // Ask for several results rather than one: iTunes often puts a cover, remix or
            // "feat." version first (searching "Kıvırcık Ali Gül Tükendi" can return
            // "Kenan Ayık – Gül Tükendi (feat. Kıvırcık Ali)" ahead of the original). With
            // only one result the caller's artist check rejects it and the whole lookup
            // fails; with a few we can pick the entry that actually matches the artist.
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "country", value: "US"),
        ]
        guard let url = comps.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                cache[key] = .some(nil); return nil
            }
            let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            // Prefer the first result whose artist actually matches what's playing; fall back
            // to the top hit so the caller's own verification still gets to judge it.
            let candidates = decoded.results.filter { $0.primaryGenreName != nil }
            let best = candidates.first { artistNamesRoughlyMatch($0.artistName ?? "", artist) }
                    ?? candidates.first
            guard let r = best, let genre = r.primaryGenreName else {
                cache[key] = .some(nil); return nil
            }
            let hit = Hit(genre: genre,
                          matchedArtist: r.artistName ?? "",
                          matchedTitle: r.trackName ?? "")
            cache[key] = hit
            return hit
        } catch {
            cache[key] = .some(nil)
            return nil
        }
    }

    private struct ITunesSearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let primaryGenreName: String?
            let artistName: String?
            let trackName: String?
        }
    }
}

/// Fuzzy name match used to validate catalog hits. Normalizes (lowercase, strip
/// non-alphanumerics) then checks containment either direction. Catches the common
/// wrong-match case while tolerating "feat." / punctuation / casing differences.
func artistNamesRoughlyMatch(_ a: String, _ b: String) -> Bool {
    func norm(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
    let na = norm(a), nb = norm(b)
    guard !na.isEmpty, !nb.isEmpty else { return false }
    if na == nb { return true }
    // Containment handles "artist" vs "artist feat x", but require the shorter to be
    // at least 4 chars to avoid trivial substring false-positives ("no1" in "no1xyz").
    let shorter = na.count <= nb.count ? na : nb
    let longer = na.count <= nb.count ? nb : na
    return shorter.count >= 4 && longer.contains(shorter)
}
