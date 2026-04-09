//
//  CommandCenterView.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/10.
//

import SwiftUI

// MARK: - Command Center (Full Window)

struct CommandCenterView: View {
    @State var messages: [Message] = [
        Message(text: "Command Center起動。全システム、オンラインです。", isUser: false),
    ]
    @State var inputText = ""
    @State var isLoading = false
    @State var audioService = AudioService()
    @State var ttsTask: Task<Void, Never>?
    @State var agentStates: [AgentState] = AgentState.defaults
    @State var systemContext = SystemContext()
    @Environment(ProactiveService.self) var proactiveService

    var body: some View {
        HStack(spacing: 0) {
            // Left: Context Panel
            contextPanel
                .frame(width: 240)

            // Vertical divider
            Rectangle()
                .fill(Color.purple.opacity(0.3))
                .frame(width: 1)

            // Center: Chat
            chatPanel

            // Vertical divider
            Rectangle()
                .fill(Color.purple.opacity(0.3))
                .frame(width: 1)

            // Right: Agent Nexus
            agentNexusPanel
                .frame(width: 280)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task { await refreshSystemContext() }
        .task { proactiveService.startMonitoring() }
    }

    // MARK: - Left: Context Panel

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(.cyan)
                Text("SYSTEM CONTEXT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                Spacer()
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            .padding(12)

            Divider().overlay(Color.cyan.opacity(0.3))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    contextRow(icon: "clock", label: "TIME", value: systemContext.time, color: .purple)
                    contextRow(icon: "calendar", label: "DAY", value: systemContext.day, color: .purple)
                    contextRow(icon: "battery.75percent", label: "BATTERY", value: systemContext.battery, color: batteryColor)
                    contextRow(icon: "desktopcomputer", label: "UPTIME", value: systemContext.uptime, color: .orange)
                    contextRow(icon: "app.dashed", label: "FRONT APP", value: systemContext.frontApp, color: .cyan)

                    Divider().overlay(Color.purple.opacity(0.2))

                    Text("RUNNING APPS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.gray)

                    Text(systemContext.runningApps)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.gray.opacity(0.8))
                        .lineLimit(15)

                    Divider().overlay(Color.purple.opacity(0.2))

                    // Proactive suggestion
                    if let suggestion = proactiveService.pendingSuggestion {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundStyle(.yellow)
                                Text("INSIGHT")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.yellow)
                            }
                            Text(suggestion)
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow.opacity(0.9))
                        }
                        .padding(10)
                        .background(Color.yellow.opacity(0.08))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.yellow.opacity(0.2))
                        )
                    }
                }
                .padding(12)
            }
        }
        .background(Color.black.opacity(0.95))
    }

    private var batteryColor: Color {
        if systemContext.battery.contains("1") && !systemContext.battery.contains("10") { return .red }
        return .green
    }

    private func contextRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray)
                Text(value.isEmpty ? "—" : value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Center: Chat Panel

    private var chatPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("SAMANTHA")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("Proactive AI Command Center")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.purple.opacity(0.7))
                }
                Spacer()
                HStack(spacing: 12) {
                    statusPill("RAG", color: .green)
                    statusPill("TTS", color: audioService.isSpeaking ? .orange : .green)
                    statusPill("TOOLS", color: .green)
                }
            }
            .padding(14)
            .background(Color.black)

            Divider().overlay(Color.purple.opacity(0.3))

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { msg in
                            CommandCenterBubble(message: msg)
                                .id(msg.id)
                        }

                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(.purple)
                                Text("処理中…")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.purple)
                            }
                            .padding(.horizontal, 16)
                            .id("loading")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if isLoading { proxy.scrollTo("loading", anchor: .bottom) }
                        else if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: isLoading) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if isLoading { proxy.scrollTo("loading", anchor: .bottom) }
                    }
                }
            }

            Divider().overlay(Color.purple.opacity(0.3))

            // Input
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.purple)

                TextField("コマンドまたはメッセージを入力…", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .disabled(isLoading)
                    .onSubmit { sendFromCommandCenter() }

                if isLoading {
                    ProgressView().controlSize(.mini).tint(.purple)
                } else {
                    Button(action: sendFromCommandCenter) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .background(Color.black)
        }
        .background(Color(white: 0.05))
    }

    private func statusPill(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }

    // MARK: - Right: Agent Nexus

    private var agentNexusPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.pink)
                Text("AGENT NEXUS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.pink)
                Spacer()
            }
            .padding(12)

            Divider().overlay(Color.pink.opacity(0.3))

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(agentStates) { agent in
                        AgentCard(agent: agent)
                    }
                }
                .padding(12)
            }

            Divider().overlay(Color.pink.opacity(0.3))

            // Agent flow visualization
            VStack(alignment: .leading, spacing: 6) {
                Text("FLOW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray)

                HStack(spacing: 4) {
                    ForEach(agentStates) { agent in
                        HStack(spacing: 2) {
                            Circle()
                                .fill(agent.status == .active ? agent.color : .gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                            if agent.id != agentStates.last?.id {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.gray.opacity(0.5))
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.black)
        }
        .background(Color.black.opacity(0.95))
    }

    // MARK: - Send message

    private func sendFromCommandCenter() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // Gmail auth command
        if text.contains("Gmail認証") || text.lowercased().contains("gmail auth") {
            inputText = ""
            messages.append(Message(text: text, isUser: true))
            messages.append(Message(text: "ブラウザでGoogleログイン画面を開きます…", isUser: false))
            isLoading = true
            Task.detached {
                do {
                    let result = try await GmailService.authenticate()
                    await MainActor.run {
                        self.messages.append(Message(text: result, isUser: false))
                        self.isLoading = false
                    }
                } catch {
                    await MainActor.run {
                        self.messages.append(Message(text: "認証エラー: \(error.localizedDescription)", isUser: false, isError: true))
                        self.isLoading = false
                    }
                }
            }
            return
        }

        ttsTask?.cancel()
        audioService.stopSpeaking()

        messages.append(Message(text: text, isUser: true))
        ActivityLogger.logUser(text)
        inputText = ""
        isLoading = true

        // Activate agents visually
        activateAgents(for: text)

        let history: [(role: String, content: String)] = messages.dropFirst()
            .filter { !$0.isError }
            .map { (role: $0.isUser ? "user" : "assistant", content: $0.text) }

        let captured = (history: history, text: text)

        // Timeout: 60s for multi-agent, 30s for simple queries
        let lower = text.lowercased()
        let isComplex = lower.contains("分析") || lower.contains("analyze") || lower.contains("計画")
            || lower.contains("plan") || lower.contains("比較") || lower.contains("調査")
            || lower.contains("多角") || lower.contains("観点")
        let timeout: UInt64 = isComplex ? 90 : 60

        Task.detached(priority: .userInitiated) {
            do {
                let reply: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        let rag = await Self.fetchRAGContext(query: captured.text)
                        return try await ChatService.send(history: captured.history, ragContext: rag)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                        throw TimeoutError()
                    }
                    guard let result = try await group.next() else { throw TimeoutError() }
                    group.cancelAll()
                    return result
                }

                await MainActor.run {
                    self.messages.append(Message(text: reply, isUser: false))
                    self.isLoading = false
                    self.resetAgents()
                }

                // TTS
                await MainActor.run {
                    self.ttsTask = Task.detached(priority: .utility) {
                        do { try await self.audioService.speak(reply) }
                        catch is CancellationError {} catch { print("[Audio] TTS failed: \(error)") }
                    }
                }
            } catch is TimeoutError {
                await MainActor.run {
                    self.messages.append(Message(text: "タイムアウト（\(timeout)秒）。複雑なリクエストの場合は、より具体的に指示してみてください。", isUser: false, isError: true))
                    self.isLoading = false
                    self.resetAgents()
                }
            } catch {
                await MainActor.run {
                    self.messages.append(Message(text: "エラー: \(error.localizedDescription)", isUser: false, isError: true))
                    self.isLoading = false
                    self.resetAgents()
                }
            }
        }
    }

    nonisolated private static func fetchRAGContext(query: String) async -> String? {
        do {
            let docs = try await withThrowingTaskGroup(of: [RAGService.Document].self) { group in
                group.addTask { try await RAGService.search(query: query) }
                group.addTask { try await Task.sleep(for: .seconds(5)); throw CancellationError() }
                guard let result = try await group.next() else { return [RAGService.Document]() }
                group.cancelAll()
                return result
            }
            guard !docs.isEmpty else { return nil }
            return docs.map { doc in
                let snippet = doc.text.count > 3_000 ? "\(String(doc.text.prefix(3_000)))\n..." : doc.text
                return "[\(doc.filename)]\n\(snippet)"
            }.joined(separator: "\n---\n")
        } catch { return nil }
    }

    // MARK: - Agent state management

    private func activateAgents(for text: String) {
        let lower = text.lowercased()
        for i in agentStates.indices {
            if lower.contains("分析") || lower.contains("analyze") || lower.contains("比較") {
                agentStates[i].status = .active
            } else if lower.contains("計画") || lower.contains("plan") {
                agentStates[i].status = i < 2 ? .active : .idle
            } else {
                agentStates[i].status = i == 0 ? .active : .idle
            }
        }
    }

    private func resetAgents() {
        for i in agentStates.indices { agentStates[i].status = .idle }
    }

    // MARK: - System context refresh

    private func refreshSystemContext() async {
        while !Task.isCancelled {
            let ctx = await SystemContext.gather()
            await MainActor.run { systemContext = ctx }
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

// MARK: - Timeout Error

private struct TimeoutError: LocalizedError {
    var errorDescription: String? { "Request timed out" }
}

// MARK: - Data models

struct AgentState: Identifiable {
    let id = UUID()
    let name: String
    let role: String
    let icon: String
    let color: Color
    var status: Status = .idle

    enum Status: String { case idle = "IDLE", active = "ACTIVE", done = "DONE" }

    static var defaults: [AgentState] {
        [
            AgentState(name: "Research", role: "情報収集・分析", icon: "magnifyingglass", color: .cyan),
            AgentState(name: "Strategy", role: "戦略立案・計画", icon: "brain.head.profile", color: .purple),
            AgentState(name: "Action", role: "実行・Mac操作", icon: "bolt.fill", color: .orange),
            AgentState(name: "Schedule", role: "監視・提案調整", icon: "clock.badge.checkmark", color: .green),
        ]
    }
}

struct SystemContext {
    var time = "—"
    var day = "—"
    var battery = "—"
    var uptime = "—"
    var frontApp = "—"
    var runningApps = "—"

    static func gather() async -> SystemContext {
        var ctx = SystemContext()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        ctx.time = fmt.string(from: Date())

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "ja_JP")
        dayFmt.dateFormat = "M/d (E)"
        ctx.day = dayFmt.string(from: Date())

        async let bat = shell("pmset -g batt | grep -Eo '\\d+%'")
        async let up = shell("uptime | sed 's/.*up //' | sed 's/,  [0-9]* user.*//'")
        async let front = shell("osascript -e 'tell application \"System Events\" to get name of first process whose frontmost is true'")
        async let apps = shell("osascript -e 'tell application \"System Events\" to get name of every process whose background only is false'")

        ctx.battery = await bat.trimmingCharacters(in: .whitespacesAndNewlines)
        ctx.uptime = await up.trimmingCharacters(in: .whitespacesAndNewlines)
        ctx.frontApp = await front.trimmingCharacters(in: .whitespacesAndNewlines)
        ctx.runningApps = await apps.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ", ", with: "\n")

        return ctx
    }

    private static func shell(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env

                var out = Data()
                pipe.fileHandleForReading.readabilityHandler = { h in let c = h.availableData; if !c.isEmpty { out.append(c) } }

                do { try process.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: "—")
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 5)
                timer.setEventHandler { if process.isRunning { process.terminate() } }
                timer.resume()

                process.waitUntilExit()
                timer.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                out.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: String(data: out, encoding: .utf8) ?? "—")
            }
        }
    }
}

// MARK: - Agent Card

struct AgentCard: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(agent.status == .active ? agent.color.opacity(0.2) : Color.gray.opacity(0.1))
                    .frame(width: 36, height: 36)
                if agent.status == .active {
                    Circle()
                        .stroke(agent.color.opacity(0.5), lineWidth: 1)
                        .frame(width: 36, height: 36)
                }
                Image(systemName: agent.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(agent.status == .active ? agent.color : .gray)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(agent.status == .active ? .white : .gray)
                Text(agent.role)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.gray.opacity(0.7))
            }

            Spacer()

            Text(agent.status.rawValue)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(agent.status == .active ? agent.color : .gray.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    (agent.status == .active ? agent.color : Color.gray).opacity(0.1)
                )
                .cornerRadius(3)
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(agent.status == .active ? agent.color.opacity(0.3) : Color.clear)
        )
    }
}

// MARK: - Chat bubble for Command Center

struct CommandCenterBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if !message.isUser {
                    Text("SAMANTHA")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.purple.opacity(0.6))
                }
                Text(message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .cornerRadius(12)
                    .foregroundStyle(message.isError ? .red : .white)
            }

            if !message.isUser { Spacer(minLength: 60) }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if message.isError { return AnyShapeStyle(Color.red.opacity(0.15)) }
        if message.isUser { return AnyShapeStyle(Color.purple.opacity(0.25)) }
        return AnyShapeStyle(Color.white.opacity(0.06))
    }
}
