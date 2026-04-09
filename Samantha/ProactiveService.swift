//
//  ProactiveService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import Foundation
import UserNotifications

/// A single proactive suggestion with its timestamp.
struct Suggestion: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
}

@Observable
final class ProactiveService {

    // MARK: - Observable state

    /// Non-nil when Samantha has a proactive suggestion to show.
    var pendingSuggestion: String?

    /// Full history of suggestions (newest first).
    var suggestionHistory: [Suggestion] = []

    // MARK: - Configuration

    private let checkInterval: Duration = .seconds(300)   // 5 minutes
    private let minSuggestionGap: TimeInterval = 1800     // 30 minutes cooldown
    private let shellTimeout: TimeInterval = 5

    // MARK: - Private state

    private var monitoringTask: Task<Void, Never>?
    private var lastContextHash: Int = 0
    private var lastSuggestionTime: Date = .distantPast

    // MARK: - Lifecycle

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        print("[Proactive] Monitoring started (every 5 min)")

        monitoringTask = Task.detached(priority: .utility) { [weak self] in
            // Initial delay — let the app settle
            try? await Task.sleep(for: .seconds(30))

            while !Task.isCancelled {
                await self?.performCheck()
                try? await Task.sleep(for: self?.checkInterval ?? .seconds(300))
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        print("[Proactive] Monitoring stopped")
    }

    // MARK: - Core proactive loop

    @Sendable
    nonisolated private func performCheck() async {
        print("[Proactive] Running check…")

        // 1. Gather system context
        async let timeStr    = shell("date '+%A %H:%M'")
        async let appsStr    = shell("osascript -e 'tell application \"System Events\" to get name of every process whose background only is false'")
        async let batteryStr = shell("pmset -g batt | grep -Eo '\\d+%'")
        async let frontApp   = shell("osascript -e 'tell application \"System Events\" to get name of first process whose frontmost is true'")
        async let uptimeStr  = shell("uptime | sed 's/.*up /up /' | sed 's/,  [0-9]* user.*//'")

        let time    = await timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps    = await appsStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let battery = await batteryStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let front   = await frontApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let uptime  = await uptimeStr.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Get recent activity summary
        let activity = await ActivityLogger.recentSummary(hours: 24)

        // 3. Change detection + cooldown (single MainActor access)
        let contextString = "\(time)\(apps)\(battery)\(front)\(activity)"
        let newHash = contextString.hashValue

        let shouldSkip = await MainActor.run {
            if newHash == lastContextHash {
                print("[Proactive] No context change, skipping")
                return true
            }
            if Date().timeIntervalSince(lastSuggestionTime) < minSuggestionGap {
                print("[Proactive] Cooldown active, skipping")
                return true
            }
            lastContextHash = newHash
            return false
        }
        if shouldSkip { return }

        // 5. Ask Claude for analysis
        let prompt = """
        あなたはSamanthaのバックグラウンド監視プロセスです。\
        以下のユーザーの現在の状況と最近の活動を分析し、\
        今、ユーザーにとって本当に役立つ提案があれば日本語で1〜2文で提案してください。\
        提案がなければ「NO_SUGGESTION」とだけ返してください。

        ## 現在の状況
        - 時刻: \(time)
        - バッテリー: \(battery)
        - 起動中アプリ: \(apps)
        - 最前面アプリ: \(front)
        - 稼働時間: \(uptime)

        ## 最近の活動（24時間）
        \(activity)

        ## 提案の例
        - 長時間作業している場合 → 休憩を提案
        - バッテリーが低い → 充電を提案
        - 深夜 → 睡眠を提案
        - 勉強関連の会話が多い → 復習やAnki開始を提案
        - 特にない場合 → NO_SUGGESTION
        """

        do {
            let history: [(role: String, content: String)] = [
                (role: "user", content: prompt),
            ]
            let response = try await ChatService.send(history: history, ragContext: nil)
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "NO_SUGGESTION" || trimmed.isEmpty {
                print("[Proactive] No suggestion needed")
                return
            }

            print("[Proactive] Suggestion: \(trimmed)")

            // 6. Surface the suggestion and save to history
            await MainActor.run {
                pendingSuggestion = trimmed
                lastSuggestionTime = Date()
                suggestionHistory.insert(
                    Suggestion(timestamp: Date(), text: trimmed),
                    at: 0
                )
                // Keep only last 50 suggestions
                if suggestionHistory.count > 50 {
                    suggestionHistory = Array(suggestionHistory.prefix(50))
                }
            }
            await postNotification(trimmed)

        } catch {
            print("[Proactive] Check failed: \(error)")
        }
    }

    // MARK: - Notification

    nonisolated private func postNotification(_ suggestion: String) async {
        let content = UNMutableNotificationContent()
        content.title = "✨ Samantha"
        content.body = suggestion
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            print("[Proactive] Notification posted")
        } catch {
            print("[Proactive] Notification failed: \(error)")
        }
    }

    // MARK: - Shell helper (lightweight, for context gathering)

    nonisolated private func shell(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [shellTimeout] in
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env

                var outData = Data()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { outData.append(chunk) }
                }

                do { try process.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: "(error)")
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + shellTimeout)
                timer.setEventHandler {
                    if process.isRunning { process.terminate() }
                }
                timer.resume()

                process.waitUntilExit()
                timer.cancel()

                pipe.fileHandleForReading.readabilityHandler = nil
                outData.append(pipe.fileHandleForReading.readDataToEndOfFile())

                let output = String(data: outData, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}
