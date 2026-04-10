//
//  OllamaService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/10.
//

import Foundation

/// Interface to the local Ollama server running Gemma 4 31B.
/// Used as the orchestrator ("main brain") for Samantha.
nonisolated struct OllamaService {
    private static let baseURL = "http://localhost:11434"
    private static let model = "gemma4:31b"
    private static let requestTimeout: TimeInterval = 60
    /// Fast timeout for orchestrator decisions — fall back to Claude if exceeded
    private static let orchestratorTimeout: TimeInterval = 12

    // MARK: - Public API

    /// Check if Ollama is running and the model is available.
    static func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return false }
            return models.contains { ($0["name"] as? String ?? "").hasPrefix("gemma4") }
        } catch {
            return false
        }
    }

    /// Send a prompt to Gemma 4 31B and get a response.
    /// Used for orchestration: deciding which agents to call and synthesizing results.
    static func generate(
        prompt: String,
        system: String? = nil,
        maxTokens: Int = 1024,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidURL
        }

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "num_predict": maxTokens,
            ] as [String: Any],
        ]
        if let sys = system { body["system"] = sys }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout ?? requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLogger.shared.log("[Ollama] Generating with \(model)…")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.requestFailed(status: status)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw OllamaError.parseFailed
        }

        let evalDuration = json["eval_duration"] as? Int ?? 0
        let evalCount = json["eval_count"] as? Int ?? 0
        let tokensPerSec = evalDuration > 0 ? Double(evalCount) / (Double(evalDuration) / 1_000_000_000) : 0
        AppLogger.shared.log("[Ollama] Done: \(evalCount) tokens, \(String(format: "%.1f", tokensPerSec)) tok/s")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chat completion with message history (for multi-turn conversations).
    static func chat(
        messages: [(role: String, content: String)],
        system: String? = nil
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw OllamaError.invalidURL
        }

        var msgArray: [[String: String]] = []
        if let sys = system {
            msgArray.append(["role": "system", "content": sys])
        }
        for msg in messages {
            msgArray.append(["role": msg.role, "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": msgArray,
            "stream": false,
            "options": [
                "temperature": 0.7,
                "num_predict": 1024,
            ] as [String: Any],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLogger.shared.log("[Ollama] Chat with \(model)…")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.requestFailed(status: status)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OllamaError.parseFailed
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Orchestrator: decide which agents to use

    /// The orchestrator decides the best approach.
    /// Returns ONE word only. Heuristic pre-filter skips Gemma for simple queries.
    static func orchestrate(userMessage: String, availableTools: [String]) async throws -> OrchestratorPlan {
        // Pre-filter: skip Gemma entirely for clearly simple or tool-heavy requests
        if let quickPlan = quickHeuristic(for: userMessage) {
            AppLogger.shared.log("[Orchestrator] Fast-path: \(quickPlan.approach)")
            return quickPlan
        }

        // Minimal prompt — only ask for one word, 10 tokens max
        let system = """
        You route user requests. Reply with ONE word only:
        - TOOL: needs tools (email, calendar, shell, file, app control, system info)
        - ANALYZE: needs multi-perspective analysis or comparison
        - CHAT: simple conversation, greetings, opinions, feelings
        """

        do {
            let response = try await generate(
                prompt: userMessage,
                system: system,
                maxTokens: 10,
                timeout: orchestratorTimeout
            )

            let upper = response.uppercased()
            let approach: OrchestratorPlan.Approach = {
                if upper.contains("TOOL") { return .single }
                if upper.contains("ANALYZE") { return .multiAgent }
                return .direct
            }()

            AppLogger.shared.log("[Orchestrator] Gemma decision: \(response.prefix(20)) → \(approach)")
            return OrchestratorPlan(approach: approach, reasoning: response, agents: [], instructions: "")
        } catch {
            // Gemma timed out or errored — fall back to Claude with tools
            AppLogger.shared.log("[Orchestrator] Gemma failed: \(error.localizedDescription) → Claude fallback", isError: true)
            return OrchestratorPlan(approach: .single, reasoning: "Gemma fallback", agents: [], instructions: "")
        }
    }

    // MARK: - Quick heuristic (skip Gemma for obvious cases)

    private static func quickHeuristic(for message: String) -> OrchestratorPlan? {
        let lower = message.lowercased()

        // Tool-heavy keywords: route directly to Claude (with tools)
        let toolKeywords = [
            "gmail", "メール", "未読", "mail",
            "カレンダー", "予定", "calendar", "event",
            "spotify", "曲", "音楽", "music", "再生", "停止", "次の",
            "開いて", "起動", "open", "launch",
            "ファイル", "file", "ディスク", "disk", "ssd",
            "バッテリー", "battery",
            "アプリ", "app",
            "シェル", "shell", "コマンド", "command",
            "ブラウザ", "browser", "url",
        ]
        if toolKeywords.contains(where: lower.contains) {
            return OrchestratorPlan(approach: .single, reasoning: "Tool keyword matched", agents: [], instructions: "")
        }

        // Analysis keywords: route to multi-agent
        let analyzeKeywords = [
            "分析", "analyze", "analysis",
            "比較", "compare", "vs",
            "多角", "観点", "視点", "perspective",
            "メリット デメリット", "pros cons",
        ]
        if analyzeKeywords.contains(where: lower.contains) {
            return OrchestratorPlan(approach: .multiAgent, reasoning: "Analysis keyword matched", agents: [], instructions: "")
        }

        // Very short simple messages (greetings, thanks) → direct Gemma chat
        let simplePatterns = ["こんにちは", "おはよう", "こんばんは", "ありがとう", "hello", "hi", "thanks", "thank you"]
        if message.count < 20 && simplePatterns.contains(where: lower.contains) {
            return OrchestratorPlan(approach: .direct, reasoning: "Simple greeting", agents: [], instructions: "")
        }

        return nil  // Let Gemma decide
    }

    // MARK: - Errors

    enum OllamaError: LocalizedError {
        case invalidURL
        case requestFailed(status: Int)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Ollama URL"
            case .requestFailed(let s): return "Ollama error (HTTP \(s))"
            case .parseFailed: return "Failed to parse Ollama response"
            }
        }
    }
}

// MARK: - Orchestrator Plan

struct OrchestratorPlan {
    enum Approach { case direct, single, multiAgent }
    let approach: Approach
    let reasoning: String
    let agents: [String]
    let instructions: String
}
