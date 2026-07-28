// Excluded from the Mac App Store build: the Spotify OAuth / Web API pre-fetch path
// needs a loopback HTTP listener (network.server) and Keychain storage. The App Store
// build ships neither entitlement, and Spotify still works there via AppleScript
// (now-playing + transport) — only queue pre-fetch is unavailable.
#if !APP_STORE
import Foundation
import Network

/// Tiny single-shot HTTP listener that handles Spotify's OAuth redirect.
/// Spotify redirects the user's browser to `http://127.0.0.1:38123/cb?code=…&state=…`
/// after they grant permission. We read that one request, send back a friendly
/// HTML page that says "you can close this tab", and return the parsed code.
final class SpotifyOAuthServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.gokturkgocen.Eqlume.oauth", qos: .userInitiated)

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 38123
    }

    /// Starts the server. Returns the OAuth `code` (and matches the `expectedState`)
    /// when the browser hits /cb. Times out after `timeout` seconds.
    func waitForCode(expectedState: String, timeout: TimeInterval = 120) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params, on: port)
                self.listener = listener

                var resumed = false
                let resumeOnce: (Result<String, Error>) -> Void = { [weak self] result in
                    guard !resumed else { return }
                    resumed = true
                    self?.listener?.cancel()
                    self?.listener = nil
                    switch result {
                    case .success(let code): cont.resume(returning: code)
                    case .failure(let err):  cont.resume(throwing: err)
                    }
                }

                listener.newConnectionHandler = { [weak self] conn in
                    guard let self else { return }
                    conn.start(queue: self.queue)
                    self.readRequest(on: conn) { rawRequest in
                        let (code, state) = self.parseCodeAndState(from: rawRequest)
                        let success = code != nil && state == expectedState
                        let body = success
                            ? "<!doctype html><meta charset=utf-8><title>" + L.t("Connected", "Bağlandı") + "</title><body style='font:16px -apple-system;text-align:center;margin-top:80px;color:#1db954'>" + L.t("✓ Eqlume connected to Spotify.", "✓ Eqlume Spotify'a bağlandı.") + "<br><span style='color:#666;font-size:13px'>" + L.t("You can close this tab.", "Bu sekmeyi kapatabilirsin.") + "</span></body>"
                            : "<!doctype html><meta charset=utf-8><title>" + L.t("Error", "Hata") + "</title><body style='font:16px -apple-system;text-align:center;margin-top:80px;color:#c00'>" + L.t("✗ Connection failed.", "✗ Bağlantı başarısız.") + "<br><span style='color:#666;font-size:13px'>" + L.t("Go back to Eqlume and try again.", "Eqlume'ya geri dönüp tekrar dene.") + "</span></body>"
                        self.sendHTTPResponse(body: body, on: conn) {
                            conn.cancel()
                            if let code, state == expectedState {
                                resumeOnce(.success(code))
                            } else {
                                resumeOnce(.failure(OAuthError.invalidCallback))
                            }
                        }
                    }
                }

                listener.stateUpdateHandler = { state in
                    if case .failed(let err) = state {
                        resumeOnce(.failure(err))
                    }
                }

                listener.start(queue: queue)

                // Timeout watchdog
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    resumeOnce(.failure(OAuthError.timeout))
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP helpers

    private func readRequest(on conn: NWConnection, completion: @escaping (String) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(raw)
        }
    }

    private func sendHTTPResponse(body: String, on conn: NWConnection, completion: @escaping () -> Void) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            completion()
        })
    }

    private func parseCodeAndState(from request: String) -> (code: String?, state: String?) {
        // First line: "GET /cb?code=…&state=… HTTP/1.1"
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let query = pathPart.components(separatedBy: "?").dropFirst().first
        else { return (nil, nil) }

        var pairs: [String: String] = [:]
        for kv in query.components(separatedBy: "&") {
            let parts = kv.components(separatedBy: "=")
            if parts.count == 2 {
                pairs[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return (pairs["code"], pairs["state"])
    }

    enum OAuthError: LocalizedError {
        case invalidCallback
        case timeout
        var errorDescription: String? {
            switch self {
            case .invalidCallback: return L.t("Invalid response from Spotify (state mismatch).", "Spotify'dan geçersiz yanıt geldi (state uyuşmuyor).")
            case .timeout:         return L.t("Authorization took longer than 2 minutes and was cancelled.", "Yetkilendirme 2 dakikadan uzun sürdü, iptal edildi.")
            }
        }
    }
}
#endif
