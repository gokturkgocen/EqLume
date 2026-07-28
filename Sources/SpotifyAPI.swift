// Excluded from the Mac App Store build: the Spotify OAuth / Web API pre-fetch path
// needs a loopback HTTP listener (network.server) and Keychain storage. The App Store
// build ships neither entitlement, and Spotify still works there via AppleScript
// (now-playing + transport) — only queue pre-fetch is unavailable.
#if !APP_STORE
import Foundation

/// Minimal Spotify Web API client. Only the endpoints we need for queue lookahead:
///   - currently-playing (`/v1/me/player/currently-playing`)
///   - queue            (`/v1/me/player/queue`)
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    // NOTE: Spotify is intentionally NOT used for genre. As of 2024 the Web API no longer
    // returns `genres` (nor followers/popularity) on artist objects — `GET /v1/artists/{id}`
    // yields only name/images/uri. Genre resolution lives in MusicBrainzService instead.
    // SpotifyAPI is kept solely for now-playing + queue lookahead (pre-fetch).

    /// What's playing right now + millisecond progress + millisecond duration.
    /// Returns nil if nothing is playing (204) or the call fails.
    func currentlyPlaying() async -> NowPlayingSnapshot? {
        guard auth.isConnected else { return nil }
        do {
            let token = try await auth.validAccessToken()
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 204 { return nil }  // nothing playing
            if http.statusCode != 200 { return nil }  // Premium-only endpoint, can 403/401
            return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    /// Current + next queued tracks. The first entry of `.queue` is what plays next.
    func queue() async -> QueueSnapshot? {
        guard auth.isConnected else { return nil }
        do {
            let token = try await auth.validAccessToken()
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(QueueSnapshot.self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Models

struct SpotifyTrack: Decodable, Equatable {
    let id: String?
    let name: String
    let artists: [Artist]
    let duration_ms: Int?
    let album: Album?

    var primaryArtist: String { artists.first?.name ?? "Bilinmeyen" }
    /// Medium album-art URL (Spotify returns 640/300/64 px; pick the middle one).
    var artworkURL: String? {
        let imgs = album?.images ?? []
        if imgs.count >= 2 { return imgs[1].url }
        return imgs.first?.url
    }

    struct Artist: Decodable, Equatable {
        let name: String
        let id: String?
    }
    struct Album: Decodable, Equatable {
        let images: [Img]?
        struct Img: Decodable, Equatable { let url: String }
    }
}

struct NowPlayingSnapshot: Decodable {
    let item: SpotifyTrack?
    let progress_ms: Int?
    let is_playing: Bool?
}

struct QueueSnapshot: Decodable {
    let currently_playing: SpotifyTrack?
    let queue: [SpotifyTrack]

    /// The track that will play after `currently_playing` ends.
    var nextTrack: SpotifyTrack? { queue.first }
}
#endif
