//
//  GmailService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import AppKit
import Foundation

// MARK: - Gmail Service (OAuth 2.0 + Gmail API)

nonisolated struct GmailService {
    private static let clientID: String = Bundle.main.infoDictionary?["GOOGLE_CLIENT_ID"] as? String ?? ""
    private static let clientSecret: String = Bundle.main.infoDictionary?["GOOGLE_CLIENT_SECRET"] as? String ?? ""
    private static let redirectURI = "http://localhost:8089/callback"
    private static let scope = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events"
    private static let tokenFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".samantha/gmail_tokens.json")

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

    // MARK: - Public: check auth status

    static var isAuthenticated: Bool {
        loadTokens() != nil
    }

    // MARK: - Public: OAuth login (opens browser, waits for callback)

    static func authenticate() async throws -> String {
        // PKCE
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)

        let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
            + "?client_id=\(clientID)"
            + "&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
            + "&response_type=code"
            + "&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
            + "&code_challenge=\(challenge)"
            + "&code_challenge_method=S256"
            + "&access_type=offline"
            + "&prompt=consent"

        // Open browser first (must be on MainActor)
        await MainActor.run {
            if let url = URL(string: authURL) {
                NSWorkspace.shared.open(url)
            }
        }
        print("[Gmail] Browser opened, waiting for callback on :8089")

        // Wait for OAuth callback on background thread (socket server)
        let code = try await waitForOAuthCallback()
        print("[Gmail] Got auth code: \(code.prefix(10))…")

        // Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: verifier)
        saveTokens(tokens)
        print("[Gmail] Authenticated successfully")
        return "Gmail認証が完了しました！メールとカレンダーにアクセスできます。"
    }

    // MARK: - Public: Gmail API operations

    static func listUnread(maxResults: Int = 5) async throws -> String {
        let token = try await getValidAccessToken()

        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=is:unread&maxResults=\(maxResults)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageList = json["messages"] as? [[String: Any]] else {
            return "未読メールはありません。"
        }

        var results: [String] = []
        for msg in messageList.prefix(maxResults) {
            guard let id = msg["id"] as? String else { continue }
            let detail = try await fetchMessageMetadata(id: id, token: token)
            results.append(detail)
        }

        return results.isEmpty ? "未読メールはありません。" : results.joined(separator: "\n---\n")
    }

    static func readMessage(id: String) async throws -> String {
        let token = try await getValidAccessToken()

        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailError.parseFailed
        }

        let headers = extractHeaders(from: json)
        let body = extractBody(from: json)

        return """
        From: \(headers["From"] ?? "?")
        Subject: \(headers["Subject"] ?? "?")
        Date: \(headers["Date"] ?? "?")

        \(String(body.prefix(3000)))
        """
    }

    static func searchMessages(query: String, maxResults: Int = 5) async throws -> String {
        let token = try await getValidAccessToken()
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=\(encoded)&maxResults=\(maxResults)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageList = json["messages"] as? [[String: Any]] else {
            return "該当するメールが見つかりませんでした。"
        }

        var results: [String] = []
        for msg in messageList.prefix(maxResults) {
            guard let id = msg["id"] as? String else { continue }
            let detail = try await fetchMessageMetadata(id: id, token: token)
            results.append(detail)
        }

        return results.isEmpty ? "該当するメールが見つかりませんでした。" : results.joined(separator: "\n---\n")
    }

    // MARK: - Token management

    /// Shared: get a valid access token (used by CalendarService too).
    static func getValidAccessToken() async throws -> String {
        guard var tokens = loadTokens() else {
            throw GmailError.notAuthenticated
        }

        // Refresh if expired (with 60s buffer)
        if tokens.expiresAt.timeIntervalSinceNow < 60 {
            print("[Gmail] Token expired, refreshing...")
            tokens = try await refreshAccessToken(refreshToken: tokens.refreshToken)
            saveTokens(tokens)
        }

        return tokens.accessToken
    }

    private static func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> Tokens {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "code=\(code)"
            + "&client_id=\(clientID)"
            + "&client_secret=\(clientSecret)"
            + "&redirect_uri=\(redirectURI)"
            + "&grant_type=authorization_code"
            + "&code_verifier=\(codeVerifier)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw GmailError.tokenExchangeFailed(detail: detail)
        }

        return Tokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(Double(expiresIn))
        )
    }

    private static func refreshAccessToken(refreshToken: String) async throws -> Tokens {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientID)"
            + "&client_secret=\(clientSecret)"
            + "&refresh_token=\(refreshToken)"
            + "&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw GmailError.refreshFailed
        }

        return Tokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(Double(expiresIn))
        )
    }

    // MARK: - Gmail helpers

    private static func fetchMessageMetadata(id: String, token: String) async throws -> String {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "ID: \(id) (読み取り失敗)"
        }

        let headers = extractHeaders(from: json)
        return "ID: \(id)\nFrom: \(headers["From"] ?? "?")\nSubject: \(headers["Subject"] ?? "?")\nDate: \(headers["Date"] ?? "?")"
    }

    private static func extractHeaders(from json: [String: Any]) -> [String: String] {
        guard let payload = json["payload"] as? [String: Any],
              let headers = payload["headers"] as? [[String: Any]] else { return [:] }

        var result: [String: String] = [:]
        for header in headers {
            if let name = header["name"] as? String, let value = header["value"] as? String {
                result[name] = value
            }
        }
        return result
    }

    private static func extractBody(from json: [String: Any]) -> String {
        guard let payload = json["payload"] as? [String: Any] else { return "(本文なし)" }

        // Try direct body
        if let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = base64URLDecode(data) {
            return decoded
        }

        // Try parts
        if let parts = payload["parts"] as? [[String: Any]] {
            for part in parts {
                let mime = part["mimeType"] as? String ?? ""
                if mime == "text/plain",
                   let body = part["body"] as? [String: Any],
                   let data = body["data"] as? String,
                   let decoded = base64URLDecode(data) {
                    return decoded
                }
            }
            // Fallback to first HTML part
            for part in parts {
                let mime = part["mimeType"] as? String ?? ""
                if mime == "text/html",
                   let body = part["body"] as? [String: Any],
                   let data = body["data"] as? String,
                   let decoded = base64URLDecode(data) {
                    // Strip HTML tags
                    return decoded.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                }
            }
        }

        return "(本文を取得できませんでした)"
    }

    private static func base64URLDecode(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
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

    // MARK: - OAuth callback (simple BSD socket, no NWListener deadlock)

    /// Start a minimal HTTP server on port 8089, wait for Google's redirect, return the auth code.
    /// Runs entirely on a background thread. Times out after 120 seconds.
    private static func waitForOAuthCallback() async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let serverFd = socket(AF_INET, SOCK_STREAM, 0)
            guard serverFd >= 0 else { throw GmailError.serverFailed }
            defer { close(serverFd) }

            var opt: Int32 = 1
            setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(8089).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bindResult == 0 else { throw GmailError.serverFailed }
            guard listen(serverFd, 1) == 0 else { throw GmailError.serverFailed }

            // Set timeout so we don't wait forever
            var tv = timeval(tv_sec: 120, tv_usec: 0)
            setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            print("[Gmail] Callback server listening on :8089")

            let clientFd = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ in
                    var clientAddr = sockaddr()
                    var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                    return accept(serverFd, &clientAddr, &clientLen)
                }
            }
            guard clientFd >= 0 else { throw GmailError.noCodeReceived }
            defer { close(clientFd) }

            // Read HTTP request
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientFd, &buffer, buffer.count)
            guard bytesRead > 0 else { throw GmailError.noCodeReceived }

            let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

            // Send success response
            let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body><h2>認証完了！Samanthaに戻ってください。</h2></body></html>"
            _ = httpResponse.withCString { write(clientFd, $0, strlen($0)) }

            // Extract code
            guard let range = requestStr.range(of: "code=([^&\\s]+)", options: .regularExpression),
                  let code = requestStr[range].split(separator: "=").last else {
                throw GmailError.noCodeReceived
            }

            return String(code)
        }.value
    }

    // MARK: - Errors

    enum GmailError: LocalizedError {
        case notAuthenticated
        case tokenExchangeFailed(detail: String)
        case refreshFailed
        case parseFailed
        case serverFailed
        case noCodeReceived

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Gmail未認証。「Gmail認証」と入力してください。"
            case .tokenExchangeFailed(let d): return "Token exchange failed: \(d)"
            case .refreshFailed: return "Token refresh failed"
            case .parseFailed: return "Failed to parse Gmail response"
            case .serverFailed: return "Failed to start callback server"
            case .noCodeReceived: return "No auth code received"
            }
        }
    }
}

// CommonCrypto bridge for SHA256
import CommonCrypto
