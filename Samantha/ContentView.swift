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

struct ContentView: View {
    @State private var messages: [Message] = [
        Message(text: "こんにちは！何かお手伝いできることはありますか？", isUser: false),
    ]
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var audioService = AudioService()
    @Environment(ProactiveService.self) var proactiveService

    private var isBusy: Bool { isLoading || audioService.isRecording || audioService.isSpeaking }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Samantha")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Proactive suggestion banner
            if let suggestion = proactiveService.pendingSuggestion {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(suggestion)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer(minLength: 4)
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
                // Mic button
                Button(action: toggleRecording) {
                    Image(systemName: audioService.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.title2)
                        .foregroundStyle(audioService.isRecording ? .red : .purple)
                }
                .buttonStyle(.plain)
                .disabled(isLoading || audioService.isSpeaking)

                TextField("メッセージを入力…", text: $inputText)
                    .textFieldStyle(.plain)
                    .disabled(isBusy)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .disabled(isBusy || inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .task {
            // Start proactive monitoring when view appears
            proactiveService.startMonitoring()
        }
    }

    // MARK: - Recording

    private func toggleRecording() {
        if audioService.isRecording {
            Task {
                do {
                    let transcribed = try await audioService.stopRecordingAndTranscribe()
                    guard !transcribed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    inputText = transcribed
                    sendMessage()
                } catch {
                    messages.append(Message(text: "録音エラー: \(error.localizedDescription)", isUser: false))
                }
            }
        } else {
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

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isLoading else { return }

        messages.append(Message(text: text, isUser: true))
        ActivityLogger.logUser(text)
        inputText = ""
        isLoading = true

        let history: [(role: String, content: String)] = messages.dropFirst().map { msg in
            (role: msg.isUser ? "user" : "assistant", content: msg.text)
        }

        Task {
            do {
                // RAG
                var ragContext: String? = nil
                do {
                    let docs = try await withThrowingTaskGroup(of: [RAGService.Document].self) { group in
                        group.addTask { try await RAGService.search(query: text) }
                        group.addTask {
                            try await Task.sleep(for: .seconds(5))
                            throw CancellationError()
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                    if !docs.isEmpty {
                        ragContext = docs
                            .map { "[\($0.filename)]\n\($0.text)" }
                            .joined(separator: "\n---\n")
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

                // TTS
                do {
                    try await audioService.speak(reply)
                } catch {
                    print("[Audio] TTS failed: \(error)")
                }
            } catch {
                messages.append(Message(text: "エラー: \(error.localizedDescription)", isUser: false))
            }
            isLoading = false
        }
    }
}

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
