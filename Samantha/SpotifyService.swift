//
//  SpotifyService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/10.
//
//  Spotify Web API integration: OAuth 2.0 + search + autonomous mood-based playback.
//  Follows the same OAuth flow pattern as GmailService (PKCE + local callback server).
//

import AppKit
import CommonCrypto
import Foundation

nonisolated struct SpotifyService {
    private static let clientID: String = Bundle.main.infoDictionary?["SPOTIFY_CLIENT_ID"] as? String ?? ""
    private static let clientSecret: String = Bundle.main.infoDictionary?["SPOTIFY_CLIENT_SECRET"] as? String ?? ""
    private static let redirectURI = "http://127.0.0.1:8090/callback"
    private static let scope = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "playlist-read-private",
        "user-read-private",
    ].joined(separator: " ")

    private static let tokenFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".samantha/spotify_tokens.json")

    // MARK: - Token storage

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private static func loadTokens() -> Tokens? {
        guard let data = try? Data(contentsOf: tokenFile),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { return nil }
        return tokens
    }

    private static func saveTokens(_ tokens: Tokens) {
        let dir = tokenFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tokens) {
            try? data.write(to: tokenFile, options: .atomic)
        }
    }

    // MARK: - Public: auth status

    static var isAuthenticated: Bool { loadTokens() != nil }

    // MARK: - Public: OAuth login

    static func authenticate() async throws -> String {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)

        let authURL = "https://accounts.spotify.com/authorize"
            + "?client_id=\(clientID)"
            + "&response_type=code"
            + "&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
            + "&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
            + "&code_challenge_method=S256"
            + "&code_challenge=\(challenge)"

        await MainActor.run {
            if let url = URL(string: authURL) {
                NSWorkspace.shared.open(url)
            }
        }
        print("[Spotify] Browser opened, waiting for callback on :8090")

        let code = try await waitForCallback()
        print("[Spotify] Got auth code")

        let tokens = try await exchangeCodeForTokens(code: code, verifier: verifier)
        saveTokens(tokens)
        return "Spotify認証が完了しました！"
    }

    // MARK: - Public: autonomous mood-based playback

    /// Find and play a playlist matching the user's mood/description.
    /// Samantha decides the search query; Spotify returns playlists; we play the first result.
    static func playMood(_ mood: String) async throws -> String {
        let token = try await getValidAccessToken()

        // 1. Search for playlists matching the mood
        let query = mood.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? mood
        let searchURL = URL(string: "https://api.spotify.com/v1/search?q=\(query)&type=playlist&limit=5")!

        var searchRequest = URLRequest(url: searchURL)
        searchRequest.timeoutInterval = 10
        searchRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (searchData, searchResp) = try await URLSession.shared.data(for: searchRequest)
        guard let http = searchResp as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: searchData, encoding: .utf8) ?? "unknown"
            throw SpotifyError.searchFailed(detail: detail)
        }

        guard let json = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let playlistsDict = json["playlists"] as? [String: Any],
              let items = playlistsDict["items"] as? [[String: Any]] else {
            throw SpotifyError.parseFailed
        }

        // Filter out nil entries (Spotify sometimes returns nulls)
        let validItems = items.compactMap { $0 }
        guard let first = validItems.first,
              let uri = first["uri"] as? String,
              let name = first["name"] as? String else {
            return "「\(mood)」に合うプレイリストが見つかりませんでした。"
        }

        let description = first["description"] as? String ?? ""

        // 2. Ensure Spotify app is running (for device)
        _ = await runShell("osascript -e 'tell application \"Spotify\" to activate' 2>/dev/null")
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s to let it launch

        // 3. Play the playlist via Web API
        let playURL = URL(string: "https://api.spotify.com/v1/me/player/play")!
        var playRequest = URLRequest(url: playURL)
        playRequest.httpMethod = "PUT"
        playRequest.timeoutInterval = 10
        playRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        playRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        playRequest.httpBody = try JSONSerialization.data(withJSONObject: ["context_uri": uri])

        let (playData, playResp) = try await URLSession.shared.data(for: playRequest)
        let status = (playResp as? HTTPURLResponse)?.statusCode ?? -1

        // Status 204 = success, 404 = no active device
        if status == 204 {
            return "「\(name)」を再生開始しました 🎵\n\(description.isEmpty ? "" : description)"
        } else if status == 404 {
            // No active device — fall back to AppleScript with the URI
            let applescript = "tell application \"Spotify\" to play track \"\(uri)\""
            _ = await runShell("osascript -e '\(applescript)'")
            return "「\(name)」を再生しました 🎵\n\(description.isEmpty ? "" : description)"
        } else {
            let detail = String(data: playData, encoding: .utf8) ?? "unknown"
            throw SpotifyError.playFailed(status: status, detail: detail)
        }
    }

    /// Get what's currently playing (for Samantha's context awareness).
    static func currentlyPlaying() async throws -> String {
        let token = try await getValidAccessToken()
        let url = URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        if status == 204 {
            return "現在、Spotifyで何も再生されていません。"
        }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = json["item"] as? [String: Any],
              let name = item["name"] as? String else {
            return "再生状態を取得できませんでした。"
        }

        let artists = (item["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: ", ")
        return "🎵 \(name) — \(artists)"
    }

    // MARK: - Token management

    private static func getValidAccessToken() async throws -> String {
        guard var tokens = loadTokens() else {
            throw SpotifyError.notAuthenticated
        }

        if tokens.expiresAt.timeIntervalSinceNow < 60 {
            print("[Spotify] Token expired, refreshing…")
            tokens = try await refreshAccessToken(refreshToken: tokens.refreshToken)
            saveTokens(tokens)
        }

        return tokens.accessToken
    }

    private static func exchangeCodeForTokens(code: String, verifier: String) async throws -> Tokens {
        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic auth header for client authentication
        let authString = "\(clientID):\(clientSecret)"
        if let authData = authString.data(using: .utf8) {
            request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let body = "grant_type=authorization_code"
            + "&code=\(code)"
            + "&redirect_uri=\(redirectURI)"
            + "&client_id=\(clientID)"
            + "&code_verifier=\(verifier)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw SpotifyError.tokenExchangeFailed(detail: detail)
        }

        return Tokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(Double(expiresIn))
        )
    }

    private static func refreshAccessToken(refreshToken: String) async throws -> Tokens {
        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let authString = "\(clientID):\(clientSecret)"
        if let authData = authString.data(using: .utf8) {
            request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientID)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw SpotifyError.refreshFailed
        }

        // Spotify sometimes returns a new refresh token, sometimes not
        let newRefreshToken = (json["refresh_token"] as? String) ?? refreshToken

        return Tokens(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAt: Date().addingTimeInterval(Double(expiresIn))
        )
    }

    // MARK: - PKCE

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - OAuth callback server (BSD socket, 120s timeout)

    private static func waitForCallback() async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let serverFd = socket(AF_INET, SOCK_STREAM, 0)
            guard serverFd >= 0 else { throw SpotifyError.serverFailed }
            defer { close(serverFd) }

            var opt: Int32 = 1
            setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(8090).bigEndian
            // Bind to 127.0.0.1 specifically (not INADDR_ANY)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bindResult == 0 else { throw SpotifyError.serverFailed }
            guard listen(serverFd, 1) == 0 else { throw SpotifyError.serverFailed }

            var tv = timeval(tv_sec: 120, tv_usec: 0)
            setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            print("[Spotify] Callback server listening on 127.0.0.1:8090")

            let clientFd = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ in
                    var clientAddr = sockaddr()
                    var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                    return accept(serverFd, &clientAddr, &clientLen)
                }
            }
            guard clientFd >= 0 else { throw SpotifyError.noCodeReceived }
            defer { close(clientFd) }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientFd, &buffer, buffer.count)
            guard bytesRead > 0 else { throw SpotifyError.noCodeReceived }

            let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

            let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body style='background:#121212;color:#1DB954;font-family:system-ui;text-align:center;padding:60px'><h2>🎵 Spotify認証完了！</h2><p>Samanthaに戻ってください。</p></body></html>"
            _ = httpResponse.withCString { write(clientFd, $0, strlen($0)) }

            guard let range = requestStr.range(of: "code=([^&\\s]+)", options: .regularExpression),
                  let code = requestStr[range].split(separator: "=").last else {
                throw SpotifyError.noCodeReceived
            }
            return String(code)
        }.value
    }

    // MARK: - Shell helper

    private static func runShell(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - Errors

    enum SpotifyError: LocalizedError {
        case notAuthenticated
        case tokenExchangeFailed(detail: String)
        case refreshFailed
        case searchFailed(detail: String)
        case playFailed(status: Int, detail: String)
        case parseFailed
        case serverFailed
        case noCodeReceived

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Spotify未認証。「Spotify認証」と入力してください。"
            case .tokenExchangeFailed(let d): return "Token exchange failed: \(d)"
            case .refreshFailed: return "Token refresh failed"
            case .searchFailed(let d): return "Spotify search failed: \(d)"
            case .playFailed(let s, let d): return "Spotify play failed (\(s)): \(d)"
            case .parseFailed: return "Failed to parse Spotify response"
            case .serverFailed: return "Failed to start callback server"
            case .noCodeReceived: return "No auth code received"
            }
        }
    }
}
