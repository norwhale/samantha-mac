//
//  GmailService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import Foundation
import Network

// MARK: - Gmail Service (OAuth 2.0 + Gmail API)

nonisolated struct GmailService {
    private static let clientID: String = Bundle.main.infoDictionary?["GOOGLE_CLIENT_ID"] as? String ?? ""
    private static let clientSecret: String = Bundle.main.infoDictionary?["GOOGLE_CLIENT_SECRET"] as? String ?? ""
    private static let redirectURI = "http://localhost:8089/callback"
    private static let scope = "https://www.googleapis.com/auth/gmail.readonly"
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

        // Start local HTTP server to receive callback
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            startCallbackServer { result in
                continuation.resume(with: result)
            }

            // Open browser
            if let url = URL(string: authURL) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: verifier)
        saveTokens(tokens)
        print("[Gmail] Authenticated successfully")
        return "Gmail認証が完了しました！"
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

    private static func getValidAccessToken() async throws -> String {
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

    // MARK: - Local HTTP callback server

    private static func startCallbackServer(completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let listener: NWListener
            do {
                let params = NWParameters.tcp
                listener = try NWListener(using: params, on: 8089)
            } catch {
                completion(.failure(GmailError.serverFailed))
                return
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    defer {
                        // Send success page
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>認証完了！Samanthaに戻ってください。</h2><script>window.close()</script></body></html>"
                        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                            listener.cancel()
                        })
                    }

                    guard let data = data,
                          let request = String(data: data, encoding: .utf8),
                          let codeRange = request.range(of: "code=([^&\\s]+)", options: .regularExpression),
                          let code = request[codeRange].split(separator: "=").last else {
                        completion(.failure(GmailError.noCodeReceived))
                        return
                    }

                    completion(.success(String(code)))
                }
            }

            listener.start(queue: .global())
            print("[Gmail] Callback server listening on :8089")
        }
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
