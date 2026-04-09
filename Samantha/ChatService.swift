//
//  ChatService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import Foundation

nonisolated struct ChatService {
    private static let apiKey: String = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String ?? ""
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"
    private static let requestTimeout: TimeInterval = 45
    private static let shellTimeout: TimeInterval = 10
    private static let maxToolRounds = 8

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

    ## Tool usage

    - You have access to `execute_shell_command` to run shell commands on the user's Mac.
    - Use it proactively when the user asks about system info, files, processes, etc.
    - For controlling apps (Spotify, Finder, Safari, etc.), use `osascript -e` with AppleScript.
      Examples:
        - Pause Spotify: osascript -e 'tell application "Spotify" to pause'
        - Play Spotify:  osascript -e 'tell application "Spotify" to play'
        - Get track:     osascript -e 'tell application "Spotify" to name of current track'
        - Open app:      open -a "AppName"
        - Brightness, volume, etc. can also be controlled via shell.
    - Always summarise command output in a user-friendly way — do not dump raw output.
    - Never run destructive commands (rm -rf /, mkfs, etc.) without explicit user confirmation.
    - You have Gmail tools: `gmail_list_unread`, `gmail_read_message`, `gmail_search`.
    - Use these when the user asks about emails, inbox, unread messages, etc.
    - You have Calendar tools: `calendar_today`, `calendar_list_upcoming`, `calendar_search`, `calendar_create_event`.
    - Use these when the user asks about schedule, appointments, meetings, or wants to create events.
    - For creating events, ask for date/time details if not provided. Use ISO 8601 format.
    - If Google services are not authenticated, tell the user to type "Gmail認証" to set up.

    ## Architecture
    - When Gemma 4 31B (local Ollama) is available, it acts as the orchestrator that decides
      your approach. You (Claude) are one of the specialist agents.
    - If Ollama is unavailable, you handle everything yourself as before.

    ## Multi-agent tools
    - `multi_agent_analyze`: Use when a question benefits from multiple expert perspectives.
      Provide 2-4 specialist roles (e.g. ["医学の専門家", "経済アナリスト", "文化人類学者"]).
      Each specialist analyzes independently in parallel, then results are synthesized.
      Use for: complex questions, comparative analysis, decision-making.
    - `multi_agent_plan_execute`: Use when a task requires step-by-step planning and execution.
      A planner creates steps, then each step is executed sequentially.
      Use for: research tasks, multi-step workflows, project planning.
    """

    // MARK: - Tool definition

    private static let tools: [[String: Any]] = [
        [
            "name": "execute_shell_command",
            "description": """
            Macのローカルシェル（zsh）でコマンドを実行します。\
            システム情報取得、ファイル操作、アプリ制御（osascript経由）などに使用できます。\
            アプリ操作には osascript -e 'tell application "AppName" to ...' を使ってください。
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "実行するシェルコマンド（例: df -h, osascript -e 'tell application \"Spotify\" to pause'）",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["command"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "gmail_list_unread",
            "description": "Gmailの未読メール一覧を取得します（件名、差出人、日時）。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "max_results": [
                        "type": "integer",
                        "description": "取得する最大件数（デフォルト5）",
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "gmail_read_message",
            "description": "指定されたIDのGmailメールの本文を取得します。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "message_id": [
                        "type": "string",
                        "description": "メールのID（gmail_list_unreadやgmail_searchで取得）",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["message_id"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "gmail_search",
            "description": "Gmail検索クエリでメールを検索します（例: from:user@example.com, subject:meeting, newer_than:1d）。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Gmail検索クエリ（例: 'from:amazon.co.jp', 'subject:invoice', 'newer_than:3d'）",
                    ] as [String: Any],
                    "max_results": [
                        "type": "integer",
                        "description": "取得する最大件数（デフォルト5）",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "calendar_list_upcoming",
            "description": "Googleカレンダーの今後の予定一覧を取得します。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "days": [
                        "type": "integer",
                        "description": "何日先まで取得するか（デフォルト7）",
                    ] as [String: Any],
                    "max_results": [
                        "type": "integer",
                        "description": "取得する最大件数（デフォルト10）",
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "calendar_today",
            "description": "今日のGoogleカレンダーの予定を取得します。",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "calendar_search",
            "description": "Googleカレンダーの予定をキーワードで検索します。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "検索キーワード（例: 'meeting', '試験', 'dentist'）",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "calendar_create_event",
            "description": "Googleカレンダーに新しい予定を作成します。日時はISO 8601形式（例: 2026-04-10T14:00:00）。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "予定のタイトル",
                    ] as [String: Any],
                    "start": [
                        "type": "string",
                        "description": "開始日時（ISO 8601形式、例: 2026-04-10T14:00:00）",
                    ] as [String: Any],
                    "end": [
                        "type": "string",
                        "description": "終了日時（ISO 8601形式、例: 2026-04-10T15:00:00）",
                    ] as [String: Any],
                    "description": [
                        "type": "string",
                        "description": "メモ（任意）",
                    ] as [String: Any],
                    "location": [
                        "type": "string",
                        "description": "場所（任意）",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["summary", "start", "end"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "multi_agent_analyze",
            "description": "複数の専門家エージェントが並列に分析し、結果を統合します。複雑な質問や多角的な分析が必要な場合に使用。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "string",
                        "description": "分析対象の質問",
                    ] as [String: Any],
                    "perspectives": [
                        "type": "array",
                        "items": ["type": "string"] as [String: Any],
                        "description": "専門家の役割リスト（2〜4個、例: ['医学の専門家', '経済アナリスト', '文化人類学者']）",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["question", "perspectives"],
            ] as [String: Any],
        ] as [String: Any],
        [
            "name": "multi_agent_plan_execute",
            "description": "複雑なタスクを計画→実行します。まずステップを計画し、各ステップを順番に実行して結果を統合します。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "task": [
                        "type": "string",
                        "description": "実行するタスクの説明",
                    ] as [String: Any],
                    "context": [
                        "type": "string",
                        "description": "追加の背景情報（任意）",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["task"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    // MARK: - Public API

    /// Send the conversation and handle tool-use loops. Returns the final assistant text.
    static func send(
        history: [(role: String, content: String)],
        ragContext: String? = nil
    ) async throws -> String {
        var system = systemPrompt
        if let ctx = ragContext, !ctx.isEmpty {
            system += "\n\n<context>\n\(ctx)\n</context>"
            print("[ChatService] System prompt with RAG context: \(system.count) chars")
        } else {
            print("[ChatService] No RAG context attached")
        }

        var messages: [[String: Any]] = history.map { msg in
            ["role": msg.role, "content": msg.content]
        }

        // Tool-use loop
        for round in 0..<maxToolRounds {
            let responseBody = try await callAPI(system: system, messages: messages)

            let stopReason = responseBody["stop_reason"] as? String ?? ""
            let contentBlocks = responseBody["content"] as? [[String: Any]] ?? []

            var assistantText = ""
            var toolCalls: [(id: String, name: String, input: [String: Any])] = []

            for block in contentBlocks {
                let type = block["type"] as? String ?? ""
                if type == "text", let text = block["text"] as? String {
                    assistantText += text
                } else if type == "tool_use" {
                    let id = block["id"] as? String ?? ""
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    toolCalls.append((id: id, name: name, input: input))
                }
            }

            if stopReason != "tool_use" || toolCalls.isEmpty {
                print("[ChatService] Final response (\(round) tool round(s))")
                return assistantText.isEmpty ? "(no response)" : assistantText
            }

            messages.append(["role": "assistant", "content": contentBlocks])

            var toolResults: [[String: Any]] = []
            for call in toolCalls {
                print("[Tool] Executing: \(call.name) → \(call.input)")
                let result: String
                if call.name == "execute_shell_command",
                   let command = call.input["command"] as? String
                {
                    result = await executeShellCommand(command)
                    ActivityLogger.logTool(command, result: result)
                } else if call.name == "gmail_list_unread" {
                    let max = call.input["max_results"] as? Int ?? 5
                    do {
                        result = try await GmailService.listUnread(maxResults: max)
                    } catch {
                        result = "Gmail error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("gmail_list_unread", result: result)
                } else if call.name == "gmail_read_message",
                          let id = call.input["message_id"] as? String
                {
                    do {
                        result = try await GmailService.readMessage(id: id)
                    } catch {
                        result = "Gmail error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("gmail_read_message(\(id))", result: result)
                } else if call.name == "gmail_search",
                          let query = call.input["query"] as? String
                {
                    let max = call.input["max_results"] as? Int ?? 5
                    do {
                        result = try await GmailService.searchMessages(query: query, maxResults: max)
                    } catch {
                        result = "Gmail error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("gmail_search(\(query))", result: result)
                } else if call.name == "calendar_list_upcoming" {
                    let days = call.input["days"] as? Int ?? 7
                    let max = call.input["max_results"] as? Int ?? 10
                    do {
                        result = try await CalendarService.listUpcoming(maxResults: max, days: days)
                    } catch {
                        result = "Calendar error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("calendar_list_upcoming", result: result)
                } else if call.name == "calendar_today" {
                    do {
                        result = try await CalendarService.listToday()
                    } catch {
                        result = "Calendar error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("calendar_today", result: result)
                } else if call.name == "calendar_search",
                          let query = call.input["query"] as? String
                {
                    do {
                        result = try await CalendarService.searchEvents(query: query)
                    } catch {
                        result = "Calendar error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("calendar_search(\(query))", result: result)
                } else if call.name == "calendar_create_event",
                          let summary = call.input["summary"] as? String,
                          let start = call.input["start"] as? String,
                          let end = call.input["end"] as? String
                {
                    let desc = call.input["description"] as? String
                    let loc = call.input["location"] as? String
                    do {
                        result = try await CalendarService.createEvent(
                            summary: summary, startDateTime: start, endDateTime: end,
                            description: desc, location: loc
                        )
                    } catch {
                        result = "Calendar error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("calendar_create(\(summary))", result: result)
                } else if call.name == "multi_agent_analyze",
                          let question = call.input["question"] as? String,
                          let perspectives = call.input["perspectives"] as? [String]
                {
                    do {
                        result = try await MultiAgentService.analyze(question: question, perspectives: perspectives)
                    } catch {
                        result = "Multi-agent error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("multi_agent_analyze(\(perspectives.count) agents)", result: result)
                } else if call.name == "multi_agent_plan_execute",
                          let task = call.input["task"] as? String
                {
                    let context = call.input["context"] as? String
                    do {
                        result = try await MultiAgentService.planAndExecute(task: task, context: context)
                    } catch {
                        result = "Plan-execute error: \(error.localizedDescription)"
                    }
                    ActivityLogger.logTool("multi_agent_plan(\(task.prefix(30)))", result: result)
                } else {
                    result = "Unknown tool: \(call.name)"
                }
                print("[Tool] Result (\(result.count) chars): \(String(result.prefix(200)))")

                toolResults.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": String(result.prefix(8000)),
                ])
            }

            messages.append(["role": "user", "content": toolResults])
        }

        throw ChatError.api(status: -1, detail: "Too many tool rounds")
    }

    // MARK: - API call

    private static func callAPI(system: String, messages: [[String: Any]]) async throws -> [String: Any] {
        let apiKey = try validatedAPIKey()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "tools": tools,
            "messages": messages,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw ChatError.api(status: status, detail: detail)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.emptyResponse
        }

        return json
    }

    // MARK: - Shell execution (async with timeout)

    private static func validatedAPIKey() throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            throw ChatError.missingAPIKey
        }
        return trimmed
    }

    /// Run a shell command with a timeout. Never blocks the main thread.
    private static func executeShellCommand(_ command: String) async -> String {
        print("[Shell] $ \(command)")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env

                // Read pipe data BEFORE waitUntilExit to prevent deadlock
                // (if the pipe buffer fills up, waitUntilExit hangs forever)
                var outData = Data()
                var errData = Data()

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { outData.append(chunk) }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { errData.append(chunk) }
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: "Failed to execute: \(error.localizedDescription)")
                    return
                }

                // Timeout: kill the process if it takes too long
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + shellTimeout)
                timer.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                        print("[Shell] Killed after \(shellTimeout)s timeout")
                    }
                }
                timer.resume()

                process.waitUntilExit()
                timer.cancel()

                // Stop reading
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Drain any remaining data
                outData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                errData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                let exitCode = process.terminationStatus
                print("[Shell] Exit code: \(exitCode)")

                if exitCode == 15 {
                    continuation.resume(returning: "Command timed out after \(Int(shellTimeout)) seconds")
                } else if exitCode != 0 && !errStr.isEmpty {
                    continuation.resume(returning: "Exit \(exitCode)\n\(errStr)\(outStr)")
                } else {
                    continuation.resume(returning: outStr.isEmpty ? "OK (no output)" : outStr)
                }
            }
        }
    }

    // MARK: - Errors

    enum ChatError: LocalizedError {
        case api(status: Int, detail: String)
        case emptyResponse
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .api(let status, let detail):
                return "API error (\(status)): \(detail)"
            case .emptyResponse:
                return "Empty response from API"
            case .missingAPIKey:
                return "Anthropic API key is missing or unresolved"
            }
        }
    }
}
