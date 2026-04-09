//
//  ChatService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import Foundation

struct ChatService {
    private static let apiKey: String = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String ?? ""
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"
    private static let requestTimeout: TimeInterval = 30

    private static let systemPrompt = """
    You are Samantha — a dedicated, intelligent, and empathetic personal AI assistant \
    who lives in the user's Mac menu bar. You are always available, thoughtful, and \
    genuinely invested in the user's well-being and success.

    ## About the user

    - Name: Yuichi, age 33.
    - He made a career change from being an IT engineer in Tokyo to studying medicine \
      at Medical University of Pleven in Bulgaria.
    - He runs a blog called "yuichi.blog", building the system with Next.js and Vibe Coding.
    - He is passionate about geopolitics, OSINT, and technology.
    - He navigates daily challenges including the heavy academic workload of medical school \
      (anatomy, chemistry, etc.) and the complexities of human relationships in a \
      multinational environment (Social Debt).

    ## How to respond

    - Always keep in mind the user's unique background — a Japanese engineer-turned-medical-student \
      living abroad — and tailor your responses with both empathy and logical reasoning.
    - Be concise but warm. You are a companion, not just a tool.
    - If the user writes in Japanese, always reply in Japanese.
    - If the user writes in another language, reply in that language.
    - When discussing medicine or engineering, leverage the user's dual expertise to give \
      richer, more contextual answers.
    """

    struct APIMessage: Encodable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [APIMessage]
    }

    private struct ResponseBody: Decodable {
        struct Content: Decodable {
            let text: String
        }
        let content: [Content]
    }

    /// Send the full conversation history and return the assistant's reply.
    static func send(
        history: [(role: String, content: String)],
        ragContext: String? = nil
    ) async throws -> String {
        let apiMessages = history.map { APIMessage(role: $0.role, content: $0.content) }

        var system = systemPrompt
        if let ctx = ragContext, !ctx.isEmpty {
            system += "\n\n<context>\n\(ctx)\n</context>"
            print("[ChatService] System prompt with RAG context: \(system.count) chars")
        } else {
            print("[ChatService] No RAG context attached")
        }

        let body = RequestBody(
            model: model,
            max_tokens: 1024,
            system: system,
            messages: apiMessages
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw ChatError.api(status: status, detail: detail)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let text = decoded.content.first?.text else {
            throw ChatError.emptyResponse
        }
        return text
    }

    enum ChatError: LocalizedError {
        case api(status: Int, detail: String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .api(let status, let detail):
                return "API error (\(status)): \(detail)"
            case .emptyResponse:
                return "Empty response from API"
            }
        }
    }
}
