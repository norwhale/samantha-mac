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
    private static let requestTimeout: TimeInterval = 30
    private static let shellTimeout: TimeInterval = 10
    private static let maxToolRounds = 5

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
