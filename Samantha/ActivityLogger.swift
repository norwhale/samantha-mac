//
//  ActivityLogger.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import Foundation

// MARK: - Data model

struct ActivityEntry: Codable {
    let timestamp: Date
    let type: EntryType
    let content: String

    enum EntryType: String, Codable {
        case userMessage
        case assistantMessage
        case toolExecution
    }
}

// MARK: - Logger

nonisolated struct ActivityLogger {

    private static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".samantha")
    private static let logFile = logDirectory.appendingPathComponent("activity_log.json")

    // Serialise all file I/O through a private actor
    private actor Store {
        private let dir: URL
        private let file: URL
        private let encoder: JSONEncoder
        private let decoder: JSONDecoder

        init(dir: URL, file: URL) {
            self.dir = dir
            self.file = file
            self.encoder = JSONEncoder()
            self.encoder.dateEncodingStrategy = .iso8601
            self.decoder = JSONDecoder()
            self.decoder.dateDecodingStrategy = .iso8601
        }

        private func ensureDirectory() throws {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        private func load() -> [ActivityEntry] {
            guard let data = try? Data(contentsOf: file),
                  let entries = try? decoder.decode([ActivityEntry].self, from: data) else {
                return []
            }
            return entries
        }

        private func save(_ entries: [ActivityEntry]) throws {
            try ensureDirectory()
            let data = try encoder.encode(entries)
            try data.write(to: file, options: .atomic)
        }

        func append(_ entry: ActivityEntry) {
            var entries = load()
            entries.append(entry)
            try? save(entries)
        }

        func recentEntries(hours: Int) -> [ActivityEntry] {
            let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
            return load().filter { $0.timestamp > cutoff }
        }

        func cleanup(keepDays: Int) {
            let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
            let entries = load().filter { $0.timestamp > cutoff }
            try? save(entries)
            print("[ActivityLogger] Cleanup done, \(entries.count) entries remaining")
        }
    }

    private static let store = Store(dir: logDirectory, file: logFile)

    // MARK: - Public API

    /// Log an activity entry (fire-and-forget, never blocks UI).
    static func log(_ entry: ActivityEntry) {
        Task.detached(priority: .utility) {
            await store.append(entry)
        }
    }

    /// Convenience: log a user message.
    static func logUser(_ text: String) {
        log(ActivityEntry(timestamp: Date(), type: .userMessage, content: text))
    }

    /// Convenience: log an assistant message.
    static func logAssistant(_ text: String) {
        log(ActivityEntry(timestamp: Date(), type: .assistantMessage, content: text))
    }

    /// Convenience: log a tool execution.
    static func logTool(_ command: String, result: String) {
        log(ActivityEntry(
            timestamp: Date(),
            type: .toolExecution,
            content: "$ \(command) → \(String(result.prefix(200)))"
        ))
    }

    /// Return a compact summary of recent activity (for proactive analysis).
    static func recentSummary(hours: Int = 24) async -> String {
        let entries = await store.recentEntries(hours: hours)
        guard !entries.isEmpty else { return "(no recent activity)" }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let lines = entries.suffix(50).map { entry in
            let time = formatter.string(from: entry.timestamp)
            let prefix: String
            switch entry.type {
            case .userMessage:      prefix = "User"
            case .assistantMessage: prefix = "Samantha"
            case .toolExecution:    prefix = "Tool"
            }
            return "[\(time)] \(prefix): \(String(entry.content.prefix(100)))"
        }

        let summary = lines.joined(separator: "\n")
        return String(summary.prefix(2000))
    }

    /// Remove entries older than keepDays.
    static func cleanup(keepDays: Int = 7) async {
        await store.cleanup(keepDays: keepDays)
    }
}
