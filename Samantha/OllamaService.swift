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
    static func generate(prompt: String, system: String? = nil) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidURL
        }

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.7,
                "num_predict": 1024,
            ] as [String: Any],
        ]
        if let sys = system { body["system"] = sys }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
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

    /// The orchestrator analyzes the user's request and returns a plan.
    static func orchestrate(userMessage: String, availableTools: [String]) async throws -> OrchestratorPlan {
        let system = """
        You are the Orchestrator — the central brain of Samantha, a personal AI system.
        Your job is to analyze the user's request and decide the best approach.

        Available specialist agents: \(availableTools.joined(separator: ", "))

        Respond ONLY in this JSON format (no markdown, no explanation):
        {
            "approach": "single" or "multi_agent" or "direct",
            "reasoning": "brief explanation",
            "agents": ["agent1", "agent2"],
            "instructions": "specific instructions for the agents"
        }

        Rules:
        - "direct": You can answer this yourself without any agents.
        - "single": Route to one specific agent (e.g., "gmail" for email, "calendar" for schedule).
        - "multi_agent": Complex question needing multiple perspectives.
        - Always prefer "direct" for simple questions (greetings, opinions, general chat).
        - Use "multi_agent" only for analysis, comparison, or research tasks.
        """

        let response = try await generate(prompt: userMessage, system: system)

        // Parse JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: if Gemma doesn't return valid JSON, use direct approach
            return OrchestratorPlan(approach: .direct, reasoning: "Fallback", agents: [], instructions: response)
        }

        let approachStr = json["approach"] as? String ?? "direct"
        let approach: OrchestratorPlan.Approach = switch approachStr {
        case "multi_agent": .multiAgent
        case "single": .single
        default: .direct
        }

        return OrchestratorPlan(
            approach: approach,
            reasoning: json["reasoning"] as? String ?? "",
            agents: json["agents"] as? [String] ?? [],
            instructions: json["instructions"] as? String ?? ""
        )
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
