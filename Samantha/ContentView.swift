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

    /// Global timeout for the entire send → response cycle (seconds).
    private let globalTimeout: UInt64 = 30

    private var isInputDisabled: Bool { isLoading || audioService.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            // Header with tab switcher
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)

                tabButton("Chat", tab: .chat)
                tabButton("Insights", tab: .insights, badge: proactiveService.pendingSuggestion != nil)
                tabButton("Logs", tab: .logs)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch currentTab {
            case .chat: chatView
            case .insights: insightsView
            case .logs: logsView
            }
        }
        .task { proactiveService.startMonitoring() }
    }

    private func tabButton(_ title: String, tab: AppTab, badge: Bool = false) -> some View {
        Button { currentTab = tab } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.caption.weight(currentTab == tab ? .bold : .regular))
                    .foregroundStyle(currentTab == tab ? .purple : .secondary)
                if badge {
                    Circle().fill(.red).frame(width: 6, height: 6)
                }
            }
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
                        .font(.caption)
                    Text(suggestion).font(.caption).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { currentTab = .insights } label: {
                        Text("詳細").font(.caption2).foregroundStyle(.purple)
                    }.buttonStyle(.plain)
                    Button { proactiveService.pendingSuggestion = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }.buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            // Chat history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if isLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("考え中…").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .id("loading")
                        }

                        if audioService.isSpeaking {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.purple).font(.caption)
                                Text("読み上げ中…").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .id("speaking")
                        }

                        // Retry button
                        if let failedText = lastFailedText, !isLoading {
                            Button {
                                lastFailedText = nil
                                inputText = failedText
                                sendMessage()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("再試行")
                                }
                                .font(.caption)
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.purple.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .id("retry")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { scrollToBottom(proxy: proxy) }
                .onChange(of: isLoading) { scrollToBottom(proxy: proxy) }
                .onChange(of: audioService.isSpeaking) { scrollToBottom(proxy: proxy) }
            }

            Divider()

            // Input area
            HStack(spacing: 8) {
                Button(action: handleAudioButton) {
                    Image(systemName: audioButtonIconName)
                        .font(.title2)
                        .foregroundStyle(audioButtonColor)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)

                TextField("メッセージを入力…", text: $inputText)
                    .textFieldStyle(.plain)
                    .disabled(isInputDisabled)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .disabled(isInputDisabled || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
    }

    // MARK: - Insights View

    private var insightsView: some View {
        VStack(spacing: 0) {
            if proactiveService.suggestionHistory.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "lightbulb").font(.largeTitle).foregroundStyle(.secondary)
                    Text("まだ提案はありません").font(.caption).foregroundStyle(.secondary)
                    Text("Samanthaが5分ごとに状況を分析し、\n提案があればここに表示されます。")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(proactiveService.suggestionHistory) { suggestion in
                            SuggestionCard(suggestion: suggestion)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear { proactiveService.pendingSuggestion = nil }
    }

    // MARK: - Logs View

    private var logsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug Logs").font(.caption.bold())
                Spacer()
                Button("Clear") { AppLogger.shared.clear() }
                    .font(.caption2).buttonStyle(.plain).foregroundStyle(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(AppLogger.shared.entries) { entry in
                        Text(entry.text)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(entry.isError ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
        }
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
                        // RAG (5s sub-timeout)
                        let ragContext = await Self.fetchRAGContext(query: capturedText)

                        // Claude API + Tool Use
                        AppLogger.shared.log("[API] Calling ChatService.send()")
                        return try await ChatService.send(history: capturedHistory, ragContext: ragContext)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).font(.caption2)
                Text(suggestion.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            Text(suggestion.text).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.06))
        .cornerRadius(10)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }

            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(bubbleColor)
                .cornerRadius(12)
                .foregroundStyle(message.isError ? .red : .primary)

            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        if message.isError { return Color.red.opacity(0.1) }
        return message.isUser ? Color.purple.opacity(0.2) : Color.gray.opacity(0.15)
    }
}

#Preview {
    ContentView()
        .environment(ProactiveService())
        .frame(width: 300, height: 400)
}
