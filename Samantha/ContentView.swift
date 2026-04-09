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
}

enum AppTab {
    case chat
    case insights
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
    @Environment(ProactiveService.self) var proactiveService

    private var isInputDisabled: Bool { isLoading || audioService.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            // Header with tab switcher
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)

                Button { currentTab = .chat } label: {
                    Text("Chat")
                        .font(.caption.weight(currentTab == .chat ? .bold : .regular))
                        .foregroundStyle(currentTab == .chat ? .purple : .secondary)
                }
                .buttonStyle(.plain)

                Button { currentTab = .insights } label: {
                    HStack(spacing: 3) {
                        Text("Insights")
                            .font(.caption.weight(currentTab == .insights ? .bold : .regular))
                            .foregroundStyle(currentTab == .insights ? .purple : .secondary)

                        // Badge for unread suggestion
                        if proactiveService.pendingSuggestion != nil {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Tab content
            switch currentTab {
            case .chat:
                chatView
            case .insights:
                insightsView
            }
        }
        .task {
            proactiveService.startMonitoring()
        }
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
                    Text(suggestion)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        currentTab = .insights
                    } label: {
                        Text("詳細")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    Button {
                        proactiveService.pendingSuggestion = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
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
                                ProgressView()
                                    .controlSize(.small)
                                Text("考え中…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .id("loading")
                        }

                        if audioService.isSpeaking {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.purple)
                                    .font(.caption)
                                Text("読み上げ中…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .id("speaking")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isLoading) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: audioService.isSpeaking) {
                    scrollToBottom(proxy: proxy)
                }
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

    // MARK: - Insights View (Suggestion History)

    private var insightsView: some View {
        VStack(spacing: 0) {
            if proactiveService.suggestionHistory.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("まだ提案はありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Samanthaが5分ごとに状況を分析し、\n提案があればここに表示されます。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
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
        .onAppear {
            // Clear the badge when viewing insights
            proactiveService.pendingSuggestion = nil
        }
    }

    // MARK: - Recording

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
        if audioService.isSpeaking {
            cancelSpeech()
            return
        }
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
                    messages.append(Message(text: "録音エラー: \(error.localizedDescription)", isUser: false))
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
            if audioService.isSpeaking {
                proxy.scrollTo("speaking", anchor: .bottom)
            } else if isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Send

    private func cancelSpeech() {
        ttsTask?.cancel()
        ttsTask = nil
        audioService.stopSpeaking()
    }

    private func makeRAGContext(from docs: [RAGService.Document]) -> String {
        docs
            .map { doc in
                let snippet = doc.text.count > 3_000
                    ? "\(String(doc.text.prefix(3_000)))\n..."
                    : doc.text
                return "[\(doc.filename)]\n\(snippet)"
            }
            .joined(separator: "\n---\n")
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // Stop any ongoing TTS before sending new message
        cancelSpeech()

        messages.append(Message(text: text, isUser: true))
        ActivityLogger.logUser(text)
        inputText = ""
        isLoading = true

        let history: [(role: String, content: String)] = messages.dropFirst().map { msg in
            (role: msg.isUser ? "user" : "assistant", content: msg.text)
        }

        Task {
            do {
                var ragContext: String? = nil
                do {
                    let docs = try await withThrowingTaskGroup(of: [RAGService.Document].self) { group in
                        group.addTask { try await RAGService.search(query: text) }
                        group.addTask {
                            try await Task.sleep(for: .seconds(5))
                            throw CancellationError()
                        }
                        guard let result = try await group.next() else {
                            return [RAGService.Document]()
                        }
                        group.cancelAll()
                        return result
                    }
                    if !docs.isEmpty {
                        ragContext = makeRAGContext(from: docs)
                        print("[RAG] Context length: \(ragContext?.count ?? 0) chars from \(docs.count) doc(s)")
                    } else {
                        print("[RAG] No relevant documents found")
                    }
                } catch {
                    print("[RAG] Search skipped: \(error)")
                }

                let reply = try await ChatService.send(history: history, ragContext: ragContext)
                messages.append(Message(text: reply, isUser: false))
                ActivityLogger.logAssistant(reply)
                isLoading = false

                // TTS: fire-and-forget (does NOT block UI)
                ttsTask = Task(priority: .userInitiated) {
                    do {
                        try await audioService.speak(reply)
                    } catch is CancellationError {
                        // User interrupted playback or started a new request.
                    } catch {
                        print("[Audio] TTS failed: \(error)")
                    }
                }
            } catch {
                messages.append(Message(text: "エラー: \(error.localizedDescription)", isUser: false))
                isLoading = false
            }
        }
    }
}

// MARK: - Suggestion Card

struct SuggestionCard: View {
    let suggestion: Suggestion

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: suggestion.timestamp)
    }

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd"
        return fmt.string(from: suggestion.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption2)
                Text("\(dateString) \(timeString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(suggestion.text)
                .font(.caption)
                .textSelection(.enabled)
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
                .background(message.isUser ? Color.purple.opacity(0.2) : Color.gray.opacity(0.15))
                .cornerRadius(12)
                .foregroundStyle(.primary)

            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}

#Preview {
    ContentView()
        .environment(ProactiveService())
        .frame(width: 300, height: 400)
}
