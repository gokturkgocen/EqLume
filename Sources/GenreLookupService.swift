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

/// Fuzzy name match used to validate catalog hits: does `candidate` (what a lookup
/// returned) plausibly name the same artist as `wanted` (what is playing)? Tolerates
/// "feat." tails, punctuation, diacritics and casing.
///
/// Partial matches must be ANCHORED, and which anchor is legal depends on direction:
///   • `wanted` is the shorter one — a short form of a fuller catalog name ("Chopin" vs
///     "Fryderyk Chopin", "Beatles" vs "The Beatles") → prefix OR suffix.
///   • `candidate` is the shorter one — a real name with trailing noise in what's playing
///     ("Sezen Aksu" vs "Sezen Aksu feat. X") → it must be a whole-token prefix, and a
///     SINGLE-token one must additionally be followed by a collaboration word. One token is
///     weak evidence because plenty of acts are named after an ordinary word: MusicBrainz's
///     Dutch trio "Timeless" was answering for the artist "Timeless Serenade", and only
///     stayed harmless because that entry happens to carry no genre votes. Two tokens are
///     strong enough on their own, which keeps "Calvin Harris" matching "Calvin Harris &
///     Dua Lipa" — a collaboration billed with an ampersand or a comma, not a "feat.".
/// An UNANCHORED substring, which this used to accept, is what let a Dallas metal band
/// named "Nocturne" match the query "Chopin: Nocturne in E" and give a piano nocturne the
/// metal preset — and, in the same way, "Helmer" match "Johannes Helmer Pedersen".
func artistNamesRoughlyMatch(_ candidate: String, _ wanted: String) -> Bool {
    let ta = normalizedNameTokens(candidate)
    let tb = normalizedNameTokens(wanted)
    let na = ta.joined(), nb = tb.joined()
    guard !na.isEmpty, !nb.isEmpty else { return false }
    if na == nb { return true }
    // Require the shorter to be at least 4 chars to avoid trivial prefix false-positives
    // ("no1" in "no1xyz").
    guard min(na.count, nb.count) >= 4 else { return false }
    if na.count <= nb.count {
        guard ta.count < tb.count, Array(tb.prefix(ta.count)) == ta else { return false }
        return ta.count >= 2 || collaborationWords.contains(tb[ta.count])
    }
    // What we're looking for is the shorter name: a short form of a fuller catalog name.
    return na.hasPrefix(nb) || na.hasSuffix(nb)
}

/// Words that introduce a guest or co-billing, i.e. the only thing allowed to follow a
/// complete artist name and still describe the same artist.
private let collaborationWords: Set<String> = [
    "feat", "feats", "ft", "featuring", "with", "and", "x", "vs", "versus", "presents", "pres",
]

/// True when two names end in the same surname token (≥4 chars). Used as a last resort
/// for a search engine's own top-ranked hit, where an alias or a transliteration can
/// leave nothing else in common — MusicBrainz indexes "Frédéric Chopin" under the Polish
/// "Fryderyk Chopin", and only "Chopin" survives that.
func artistSurnamesMatch(_ candidate: String, _ wanted: String) -> Bool {
    guard let a = normalizedNameTokens(candidate).last,
          let b = normalizedNameTokens(wanted).last,
          a.count >= 4 else { return false }
    return a == b
}

/// Lowercased, diacritic-folded name tokens with all punctuation dropped.
private func normalizedNameTokens(_ s: String) -> [String] {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
}
