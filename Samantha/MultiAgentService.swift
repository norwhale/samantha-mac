//
//  MultiAgentService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/10.
//

import Foundation

/// Multi-agent orchestration: run multiple "specialist" Claude agents in parallel,
/// then synthesize their outputs into a single coherent answer.
nonisolated struct MultiAgentService {
    private static let apiKey: String = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String ?? ""
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"

    // MARK: - Public API

    /// Run multiple specialist agents in parallel, then synthesize their findings.
    /// - Parameters:
    ///   - question: The user's original question
    ///   - perspectives: Array of specialist role descriptions (e.g. ["医学の専門家", "経済アナリスト"])
    /// - Returns: A synthesized answer combining all perspectives
    static func analyze(question: String, perspectives: [String]) async throws -> String {
        AppLogger.shared.log("[MultiAgent] Starting \(perspectives.count) agents for: \(question.prefix(50))…")

        // 1. Run all specialist agents in parallel
        let results = await withTaskGroup(of: (String, String).self) { group in
            for perspective in perspectives {
                group.addTask {
                    let result = await runAgent(question: question, role: perspective)
                    return (perspective, result)
                }
            }

            var collected: [(role: String, analysis: String)] = []
            for await (role, analysis) in group {
                collected.append((role, analysis))
                AppLogger.shared.log("[MultiAgent] Agent '\(role.prefix(15))…' done (\(analysis.count) chars)")
            }
            return collected
        }

        // 2. Synthesize all perspectives into a final answer
        let synthesis = try await synthesize(question: question, agentResults: results)
        AppLogger.shared.log("[MultiAgent] Synthesis complete (\(synthesis.count) chars)")

        return synthesis
    }

    /// Plan a complex task, then execute each step sequentially.
    /// - Parameters:
    ///   - task: The user's task description
    ///   - context: Optional additional context
    /// - Returns: The completed result with all steps executed
    static func planAndExecute(task: String, context: String?) async throws -> String {
        AppLogger.shared.log("[MultiAgent] Plan & Execute: \(task.prefix(50))…")

        // Step 1: Planner agent creates a step-by-step plan
        let planPrompt = """
        あなたはタスク計画の専門家です。以下のタスクを実行するための具体的なステップを作成してください。
        各ステップは1行で、番号付きで記述してください。最大5ステップまで。
        ステップだけを出力し、他の説明は不要です。

        タスク: \(task)
        \(context.map { "追加情報: \($0)" } ?? "")
        """

        let plan = await callSingleAgent(systemPrompt: planPrompt, userMessage: task)
        AppLogger.shared.log("[MultiAgent] Plan:\n\(plan)")

        // Step 2: Extract steps
        let steps = plan.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.first?.isNumber == true }

        guard !steps.isEmpty else {
            return "計画を作成できませんでした。タスクを具体的に教えてください。"
        }

        // Step 3: Execute each step sequentially, feeding previous results
        var previousResults: [String] = []
        var output = "**計画（\(steps.count)ステップ）:**\n"
        for step in steps { output += "  \(step)\n" }
        output += "\n**実行結果:**\n"

        for (i, step) in steps.enumerated() {
            AppLogger.shared.log("[MultiAgent] Executing step \(i + 1)/\(steps.count): \(step.prefix(40))…")

            let execPrompt = """
            あなたはタスク実行の専門家です。以下のステップを実行し、結果を簡潔に報告してください。

            全体タスク: \(task)
            現在のステップ (\(i + 1)/\(steps.count)): \(step)
            \(previousResults.isEmpty ? "" : "これまでの結果:\n\(previousResults.joined(separator: "\n"))")
            """

            let result = await callSingleAgent(systemPrompt: execPrompt, userMessage: step)
            previousResults.append("Step \(i + 1): \(result.prefix(200))")
            output += "\n**Step \(i + 1):** \(step)\n\(result)\n"
        }

        return output
    }

    // MARK: - Private: Single agent call

    /// Call Claude with a specific role/system prompt. Returns the text response.
    /// Never throws — returns an error message string on failure.
    private static func runAgent(question: String, role: String) async -> String {
        let systemPrompt = """
        あなたは「\(role)」の専門家です。
        以下の質問に対して、あなたの専門分野の視点から分析・回答してください。
        回答は簡潔に（3〜5文程度）、重要なポイントに絞ってください。
        """

        return await callSingleAgent(systemPrompt: systemPrompt, userMessage: question)
    }

    /// Synthesize multiple agent results into a final answer.
    private static func synthesize(
        question: String,
        agentResults: [(role: String, analysis: String)]
    ) async throws -> String {
        let agentOutputs = agentResults.map { "**[\($0.role)]:**\n\($0.analysis)" }.joined(separator: "\n\n")

        let systemPrompt = """
        あなたはSamantha — 複数の専門家の意見を統合するオーケストレーターです。
        以下の専門家たちの分析結果を統合し、ユーザーにとって最も有用な形で回答を作成してください。

        ルール:
        - 各専門家の重要なポイントを漏らさない
        - 矛盾する意見がある場合は両方を提示し、あなたの見解を添える
        - 最終的なアクションや推奨事項があれば、最後にまとめる
        - ユーザー（Yuichi: ブルガリアの医学生、元東京ITエンジニア）の背景を考慮する
        """

        let userMessage = """
        **質問:** \(question)

        **専門家の分析結果:**
        \(agentOutputs)

        上記を統合して、最終回答を作成してください。
        """

        return await callSingleAgent(systemPrompt: systemPrompt, userMessage: userMessage)
    }

    /// Low-level: single Claude API call with custom system prompt. Never throws.
    private static func callSingleAgent(systemPrompt: String, userMessage: String) async -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedKey.contains("$(") else {
            return "(API key not configured)"
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else {
                return "(agent error: bad response)"
            }
            return text
        } catch {
            return "(agent error: \(error.localizedDescription))"
        }
    }
}
