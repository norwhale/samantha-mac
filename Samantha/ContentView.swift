//
//  ContentView.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import SwiftUI

struct Message: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let isError: Bool

    init(text: String, isUser: Bool, isError: Bool = false) {
        self.text = text
        self.isUser = isUser
        self.isError = isError
    }
}

enum AppTab {
    case chat
    case insights
    case logs
}

struct ContentView: View {
    @State private var messages: [Message] = [
        Message(text: "こんにちは！何かお手伝いできることはありますか？", isUser: false),
    ]
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var audioService = AudioService()
    @State private var ttsTask: Task<Void, Never>?
    @State private var currentTab: AppTab = .chat
    @State private var lastFailedText: String?
    @Environment(ProactiveService.self) var proactiveService
    @Environment(CognitiveLoadService.self) var cognitiveLoadService

    /// Global timeout for the entire send → response cycle (seconds).
    private let globalTimeout: UInt64 = 60

    /// Font scale for readability on high-DPI displays
    private let fontScale: CGFloat = 1.25
    private func fs(_ size: CGFloat) -> CGFloat { size * fontScale }

    private var isInputDisabled: Bool { isLoading || audioService.isRecording }

    var body: some View {
        ZStack {
            // Background: dark base
            Color.black.ignoresSafeArea()

            // Samantha icon as background — more prominent
            Image("SamanthaIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 360)
                .opacity(0.35)
                .ignoresSafeArea()

            // Subtle gradient overlay for text readability
            LinearGradient(
                colors: [Color.black.opacity(0.45), Color.black.opacity(0.25), Color.black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with tab switcher
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: fs(15)))
                        .foregroundStyle(
                            LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )

                    tabButton("Chat", tab: .chat)
                    tabButton("Insights", tab: .insights, badge: proactiveService.pendingSuggestion != nil)
                    tabButton("Logs", tab: .logs)

                    Spacer()

                    // Command Center button
                    Button {
                        WindowManager.shared.openCommandCenter(
                            proactiveService: proactiveService,
                            cognitiveLoadService: cognitiveLoadService
                        )
                    } label: {
                        Image(systemName: "rectangle.expand.vertical")
                            .font(.system(size: fs(14), weight: .semibold))
                            .foregroundStyle(Color(red: 0.75, green: 0.5, blue: 1.0))
                    }
                    .buttonStyle(.plain)
                    .help("Open Command Center")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.55))

                Divider().overlay(Color.purple.opacity(0.4))

                Group {
                    switch currentTab {
                    case .chat: chatView
                    case .insights: insightsView
                    case .logs: logsView
                    }
                }
                .background(Color.black.opacity(0.35))
            }
        }
        .preferredColorScheme(.dark)
        .task {
            proactiveService.startMonitoring()
            cognitiveLoadService.start()
        }
    }

    private func tabButton(_ title: String, tab: AppTab, badge: Bool = false) -> some View {
        Button { currentTab = tab } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: fs(12), weight: currentTab == tab ? .bold : .medium))
                    .foregroundStyle(
                        currentTab == tab
                            ? Color(red: 0.82, green: 0.56, blue: 1.0)
                            : Color.white.opacity(0.6)
                    )
                if badge {
                    Circle().fill(.red).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                currentTab == tab
                    ? Color.purple.opacity(0.18)
                    : Color.clear
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chat View

    private var chatView: some View {
        VStack(spacing: 0) {
            // Proactive suggestion banner
            if let suggestion = proactiveService.pendingSuggestion {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: fs(11)))
                    Text(suggestion).font(.system(size: fs(11))).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { currentTab = .insights } label: {
                        Text("詳細").font(.system(size: fs(10))).foregroundStyle(.purple)
                    }.buttonStyle(.plain)
                    Button { proactiveService.pendingSuggestion = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: fs(11)))
                    }.buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12))
                .cornerRadius(10)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            // Chat history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            ChatBubble(message: message, fontScale: fontScale)
                                .id(message.id)
                        }

                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("考え中…").font(.system(size: fs(11))).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .id("loading")
                        }

                        if audioService.isSpeaking {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.purple).font(.system(size: fs(11)))
                                Text("読み上げ中…").font(.system(size: fs(11))).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .id("speaking")
                        }

                        // Retry button
                        if let failedText = lastFailedText, !isLoading {
                            Button {
                                lastFailedText = nil
                                inputText = failedText
                                sendMessage()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("再試行")
                                }
                                .font(.system(size: fs(11)))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.purple.opacity(0.15))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .id("retry")
                        }
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) { scrollToBottom(proxy: proxy) }
                .onChange(of: isLoading) { scrollToBottom(proxy: proxy) }
                .onChange(of: audioService.isSpeaking) { scrollToBottom(proxy: proxy) }
            }

            Divider()

            // Input area
            HStack(spacing: 10) {
                Button(action: handleAudioButton) {
                    Image(systemName: audioButtonIconName)
                        .font(.system(size: fs(20)))
                        .foregroundStyle(audioButtonColor)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)

                TextField("メッセージを入力…", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: fs(12)))
                    .foregroundStyle(.white)
                    .tint(.purple)
                    .disabled(isInputDisabled)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: fs(20)))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .disabled(isInputDisabled || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    // MARK: - Insights View

    private var insightsView: some View {
        VStack(spacing: 0) {
            if proactiveService.suggestionHistory.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: fs(32)))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("まだ提案はありません")
                        .font(.system(size: fs(12)))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Samanthaが5分ごとに状況を分析し、\n提案があればここに表示されます。")
                        .font(.system(size: fs(10)))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(proactiveService.suggestionHistory) { suggestion in
                            SuggestionCard(suggestion: suggestion)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { proactiveService.pendingSuggestion = nil }
    }

    // MARK: - Logs View

    private var logsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug Logs")
                    .font(.system(size: fs(11), weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button("Clear") { AppLogger.shared.clear() }
                    .font(.system(size: fs(10)))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(AppLogger.shared.entries) { entry in
                        Text(entry.text)
                            .font(.system(size: fs(10), design: .monospaced))
                            .foregroundStyle(entry.isError ? Color.red : Color.white.opacity(0.75))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Audio controls

    private var audioButtonIconName: String {
        if audioService.isSpeaking { return "speaker.slash.fill" }
        if audioService.isRecording { return "stop.circle.fill" }
        return "mic.fill"
    }

    private var audioButtonColor: Color {
        if audioService.isSpeaking { return .orange }
        if audioService.isRecording { return .red }
        return .purple
    }

    private func handleAudioButton() {
        if audioService.isSpeaking { cancelSpeech(); return }
        toggleRecording()
    }

    private func toggleRecording() {
        if audioService.isRecording {
            Task {
                do {
                    let transcribed = try await audioService.stopRecordingAndTranscribe()
                    guard !transcribed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    inputText = transcribed
                    sendMessage()
                } catch {
                    messages.append(Message(text: "録音エラー: \(error.localizedDescription)", isUser: false, isError: true))
                }
            }
        } else {
            cancelSpeech()
            audioService.startRecording()
        }
    }

    // MARK: - Scroll

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let failedText = lastFailedText, !isLoading, failedText.isEmpty == false {
                proxy.scrollTo("retry", anchor: .bottom)
            } else if audioService.isSpeaking {
                proxy.scrollTo("speaking", anchor: .bottom)
            } else if isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Send (with global timeout + error recovery)

    private func cancelSpeech() {
        ttsTask?.cancel()
        ttsTask = nil
        audioService.stopSpeaking()
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // Handle "Gmail認証" command
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
                        self.messages.append(Message(text: "Gmail認証エラー: \(error.localizedDescription)", isUser: false, isError: true))
                        self.isLoading = false
                    }
                }
            }
            return
        }

        cancelSpeech()
        lastFailedText = nil

        messages.append(Message(text: text, isUser: true))
        ActivityLogger.logUser(text)
        inputText = ""
        isLoading = true

        let history: [(role: String, content: String)] = messages.dropFirst()
            .filter { !$0.isError }
            .map { (role: $0.isUser ? "user" : "assistant", content: $0.text) }

        let capturedHistory = history
        let capturedText = text
        let timeout = globalTimeout

        // Everything runs DETACHED from MainActor with a hard timeout
        Task.detached(priority: .userInitiated) {
            AppLogger.shared.log("[Send] Processing: \(capturedText.prefix(50))…")

            do {
                // Wrap the entire pipeline in a timeout
                let reply: String = try await withThrowingTaskGroup(of: String.self) { group in
                    // Main work
                    group.addTask {
                        // Check if Gemma 4 (Ollama) is available as orchestrator
                        let gemmaAvailable = await OllamaService.isAvailable()

                        if gemmaAvailable {
                            AppLogger.shared.log("[Orchestrator] Gemma 4 31B is online — using as commander")

                            // Gemma decides the approach
                            let plan = try await OllamaService.orchestrate(
                                userMessage: capturedText,
                                availableTools: ["claude_chat", "gmail", "calendar", "shell", "multi_agent", "rag"]
                            )
                            AppLogger.shared.log("[Orchestrator] Plan: \(plan.approach) — \(plan.reasoning)")

                            switch plan.approach {
                            case .direct, .single:
                                // Route to Claude — it's 10x faster than Gemma
                                // direct = simple chat, single = tool use, both go to Claude
                                let ragContext = await Self.fetchRAGContext(query: capturedText)
                                return try await ChatService.send(history: capturedHistory, ragContext: ragContext)

                            case .multiAgent:
                                // Multi-agent analysis via Claude specialists
                                let perspectives = plan.agents.isEmpty
                                    ? ["技術の専門家", "戦略アナリスト", "実務コンサルタント"]
                                    : plan.agents
                                return try await MultiAgentService.analyze(
                                    question: capturedText,
                                    perspectives: perspectives
                                )
                            }
                        } else {
                            // Fallback: Claude handles everything (original flow)
                            AppLogger.shared.log("[Orchestrator] Gemma unavailable — Claude direct mode")
                            let ragContext = await Self.fetchRAGContext(query: capturedText)
                            return try await ChatService.send(history: capturedHistory, ragContext: ragContext)
                        }
                    }

                    // Hard timeout
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                        throw TimeoutError()
                    }

                    guard let result = try await group.next() else {
                        throw TimeoutError()
                    }
                    group.cancelAll()
                    return result
                }

                AppLogger.shared.log("[Send] Reply received (\(reply.count) chars)")

                // Update UI
                await MainActor.run {
                    self.messages.append(Message(text: reply, isUser: false))
                    ActivityLogger.logAssistant(reply)
                    self.isLoading = false
                }

                // TTS (fire-and-forget, fully detached)
                await MainActor.run {
                    self.ttsTask = Task.detached(priority: .utility) {
                        do {
                            try await self.audioService.speak(reply)
                        } catch is CancellationError {} catch {
                            AppLogger.shared.log("[TTS] Failed: \(error)", isError: true)
                        }
                    }
                }

            } catch is TimeoutError {
                AppLogger.shared.log("[Send] TIMEOUT after \(timeout)s", isError: true)
                await MainActor.run {
                    self.messages.append(Message(
                        text: "タイムアウト: 応答に時間がかかりすぎました（\(timeout)秒）。もう一度試してみてください。",
                        isUser: false, isError: true
                    ))
                    self.lastFailedText = capturedText
                    self.isLoading = false
                }
            } catch is CancellationError {
                AppLogger.shared.log("[Send] Cancelled")
                await MainActor.run { self.isLoading = false }
            } catch {
                AppLogger.shared.log("[Send] Error: \(error)", isError: true)
                await MainActor.run {
                    self.messages.append(Message(
                        text: "エラー: \(error.localizedDescription)\nもう一度試してみてください。",
                        isUser: false, isError: true
                    ))
                    self.lastFailedText = capturedText
                    self.isLoading = false
                }
            }
        }
    }

    /// Fetch RAG context off MainActor with a 5s timeout. Returns nil on failure.
    nonisolated private static func fetchRAGContext(query: String) async -> String? {
        do {
            let docs = try await withThrowingTaskGroup(of: [RAGService.Document].self) { group in
                group.addTask { try await RAGService.search(query: query) }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw CancellationError()
                }
                guard let result = try await group.next() else { return [RAGService.Document]() }
                group.cancelAll()
                return result
            }
            guard !docs.isEmpty else { return nil }
            let context = docs.map { doc in
                let snippet = doc.text.count > 3_000 ? "\(String(doc.text.prefix(3_000)))\n..." : doc.text
                return "[\(doc.filename)]\n\(snippet)"
            }.joined(separator: "\n---\n")
            AppLogger.shared.log("[RAG] Context: \(context.count) chars from \(docs.count) doc(s)")
            return context
        } catch {
            AppLogger.shared.log("[RAG] Skipped: \(error)")
            return nil
        }
    }
}

// MARK: - Timeout Error

private struct TimeoutError: LocalizedError {
    var errorDescription: String? { "Request timed out" }
}

// MARK: - App Logger (visible in Logs tab)

@Observable
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private(set) var entries: [LogEntry] = []
    private let lock = NSLock()

    func log(_ message: String, isError: Bool = false) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let entry = LogEntry(text: "[\(fmt.string(from: Date()))] \(message)", isError: isError)
        print(entry.text)
        lock.lock()
        defer { lock.unlock() }
        if entries.count > 200 { entries.removeFirst(50) }
        entries.append(entry)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}

// MARK: - Suggestion Card

struct SuggestionCard: View {
    let suggestion: Suggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(suggestion.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            Text(suggestion.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.75))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: Message
    var fontScale: CGFloat = 1.0

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }

            Text(message.text)
                .font(.system(size: 12 * fontScale))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor)
                .cornerRadius(14)
                .foregroundStyle(message.isError ? .red : .white)

            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        if message.isError { return Color.red.opacity(0.15) }
        return message.isUser ? Color.purple.opacity(0.28) : Color.white.opacity(0.08)
    }
}

#Preview {
    ContentView()
        .environment(ProactiveService())
        .environment(CognitiveLoadService())
        .frame(width: 420, height: 560)
}
