// Excluded from the Mac App Store build: the Spotify OAuth / Web API pre-fetch path
// needs a loopback HTTP listener (network.server) and Keychain storage. The App Store
// build ships neither entitlement, and Spotify still works there via AppleScript
// (now-playing + transport) — only queue pre-fetch is unavailable.
#if !APP_STORE
import AppKit
import CryptoKit
import Foundation

/// OAuth 2.0 Authorization Code flow with PKCE (no client secret required).
/// Stores access + refresh tokens in Keychain. Handles automatic refresh on expiry.
@MainActor
final class SpotifyAuth {
    static let callbackPort: UInt16 = 38123
    static let redirectURI = "http://127.0.0.1:\(callbackPort)/cb"
    /// Scopes we need:
    ///   user-read-currently-playing — read what's playing now
    ///   user-read-playback-state    — required for /me/player/queue
    static let scope = "user-read-currently-playing user-read-playback-state"

    private(set) var clientID: String?

    init() {
        self.clientID = SpotifyKeychain.get(.clientID)
    }

    var isConnected: Bool {
        return SpotifyKeychain.get(.refreshToken) != nil && clientID != nil
    }

    // MARK: - Connect flow

    func setClientID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        clientID = trimmed
        SpotifyKeychain.set(trimmed, for: .clientID)
    }

    /// Begins the OAuth flow:
    ///   1. Generates PKCE verifier/challenge
    ///   2. Spins up local HTTP server on 127.0.0.1:38123
    ///   3. Opens the browser to Spotify's authorize URL
    ///   4. Waits for the redirect, extracts code, exchanges for tokens
    func connect() async throws {
        guard let clientID, !clientID.isEmpty else {
            throw AuthError.missingClientID
        }

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = UUID().uuidString

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scope),
        ]
        guard let authURL = comps.url else { throw AuthError.urlBuildFailed }

        let server = SpotifyOAuthServer(port: Self.callbackPort)

        // Start listener BEFORE opening the browser, so the redirect always lands.
        let codeTask = Task<String, Error> {
            try await server.waitForCode(expectedState: state)
        }

        NSWorkspace.shared.open(authURL)

        let code = try await codeTask.value
        try await exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
    }

    func disconnect() {
        SpotifyKeychain.set(nil, for: .accessToken)
        SpotifyKeychain.set(nil, for: .refreshToken)
        SpotifyKeychain.set(nil, for: .expiresAt)
        // We keep the client ID so reconnecting is one-click.
    }

    // MARK: - Token management

    /// Returns a valid access token, refreshing if needed. Call this before every API request.
    func validAccessToken() async throws -> String {
        guard let clientID else { throw AuthError.missingClientID }
        guard let token = SpotifyKeychain.get(.accessToken),
              let expiresAtString = SpotifyKeychain.get(.expiresAt),
              let expiresAt = ISO8601DateFormatter().date(from: expiresAtString)
        else {
            // No token yet — must reconnect.
            throw AuthError.notConnected
        }
        // Refresh 60s before expiry to avoid race conditions on long requests.
        if Date() < expiresAt.addingTimeInterval(-60) {
            return token
        }
        return try await refreshAccessToken(clientID: clientID)
    }

    private func refreshAccessToken(clientID: String) async throws -> String {
        guard let refreshToken = SpotifyKeychain.get(.refreshToken) else {
            throw AuthError.notConnected
        }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.tokenRequestFailed
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        SpotifyKeychain.set(decoded.access_token, for: .accessToken)
        if let newRefresh = decoded.refresh_token {
            SpotifyKeychain.set(newRefresh, for: .refreshToken)
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        SpotifyKeychain.set(ISO8601DateFormatter().string(from: expiresAt), for: .expiresAt)
        return decoded.access_token
    }

    private func exchangeCodeForToken(code: String, codeVerifier: String) async throws {
        guard let clientID else { throw AuthError.missingClientID }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.tokenRequestFailed }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.spotifyError(body)
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        SpotifyKeychain.set(decoded.access_token,  for: .accessToken)
        SpotifyKeychain.set(decoded.refresh_token, for: .refreshToken)
        let expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        SpotifyKeychain.set(ISO8601DateFormatter().string(from: expiresAt), for: .expiresAt)
    }

    // MARK: - PKCE

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLString
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLString
    }

    // MARK: - Misc

    private func formEncoded(_ params: [String: String]) -> Data {
        let encoded = params
            .map { "\($0.key)=\(($0.value).addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }

    enum AuthError: LocalizedError {
        case missingClientID
        case notConnected
        case urlBuildFailed
        case tokenRequestFailed
        case spotifyError(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID:    return L.t("Spotify Client ID not entered.", "Spotify Client ID girilmemiş.")
            case .notConnected:       return L.t("No Spotify account connected.", "Spotify hesabı bağlı değil.")
            case .urlBuildFailed:     return L.t("Could not build the authorization URL.", "Yetkilendirme URL'i oluşturulamadı.")
            case .tokenRequestFailed: return L.t("Token request failed.", "Token isteği başarısız oldu.")
            case .spotifyError(let m):return L.t("Spotify error: ", "Spotify hatası: ") + m
            }
        }
    }
}

// MARK: - Helpers

private extension Data {
    /// Base64url encoding (RFC 4648 §5): standard base64 with `+→-`, `/→_`, padding removed.
    var base64URLString: String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
#endif
