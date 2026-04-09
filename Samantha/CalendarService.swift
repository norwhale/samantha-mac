//
//  CalendarService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import Foundation

// MARK: - Google Calendar Service (uses shared OAuth tokens from GmailService)

nonisolated struct CalendarService {
    private static let baseURL = "https://www.googleapis.com/calendar/v3"

    // MARK: - Public API

    /// List upcoming events from the primary calendar.
    static func listUpcoming(maxResults: Int = 10, days: Int = 7) async throws -> String {
        let token = try await GmailService.getValidAccessToken()

        let now = ISO8601DateFormatter().string(from: Date())
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(days) * 86400))
        let encoded = "timeMin=\(now)&timeMax=\(future)&maxResults=\(maxResults)&singleEvents=true&orderBy=startTime"

        let url = URL(string: "\(baseURL)/calendars/primary/events?\(encoded)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return "予定が見つかりませんでした。"
        }

        if items.isEmpty { return "今後\(days)日間に予定はありません。" }

        let results = items.map { formatEvent($0) }
        return results.joined(separator: "\n---\n")
    }

    /// Get today's events.
    static func listToday() async throws -> String {
        let token = try await GmailService.getValidAccessToken()

        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!

        let now = ISO8601DateFormatter().string(from: startOfDay)
        let end = ISO8601DateFormatter().string(from: endOfDay)

        let url = URL(string: "\(baseURL)/calendars/primary/events?timeMin=\(now)&timeMax=\(end)&singleEvents=true&orderBy=startTime")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return "今日の予定を取得できませんでした。"
        }

        if items.isEmpty { return "今日の予定はありません。" }

        let results = items.map { formatEvent($0) }
        return results.joined(separator: "\n---\n")
    }

    /// Search events by keyword.
    static func searchEvents(query: String, maxResults: Int = 10) async throws -> String {
        let token = try await GmailService.getValidAccessToken()
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let url = URL(string: "\(baseURL)/calendars/primary/events?q=\(encoded)&maxResults=\(maxResults)&singleEvents=true&orderBy=startTime")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return "該当する予定が見つかりませんでした。"
        }

        if items.isEmpty { return "「\(query)」に該当する予定は見つかりませんでした。" }

        let results = items.map { formatEvent($0) }
        return results.joined(separator: "\n---\n")
    }

    /// Create a new calendar event.
    static func createEvent(
        summary: String,
        startDateTime: String,
        endDateTime: String,
        description: String? = nil,
        location: String? = nil
    ) async throws -> String {
        let token = try await GmailService.getValidAccessToken()

        let url = URL(string: "\(baseURL)/calendars/primary/events")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var event: [String: Any] = [
            "summary": summary,
            "start": ["dateTime": startDateTime, "timeZone": TimeZone.current.identifier],
            "end": ["dateTime": endDateTime, "timeZone": TimeZone.current.identifier],
        ]
        if let desc = description { event["description"] = desc }
        if let loc = location { event["location"] = loc }

        request.httpBody = try JSONSerialization.data(withJSONObject: event)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw CalendarError.createFailed(detail: detail)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = json["htmlLink"] as? String else {
            return "予定を作成しましたが、リンクを取得できませんでした。"
        }

        return "予定「\(summary)」を作成しました。\n\(link)"
    }

    // MARK: - Formatting

    private static func formatEvent(_ event: [String: Any]) -> String {
        let summary = event["summary"] as? String ?? "(タイトルなし)"
        let location = event["location"] as? String
        let description = event["description"] as? String

        let startStr: String
        if let start = event["start"] as? [String: Any] {
            if let dt = start["dateTime"] as? String {
                startStr = formatDateTime(dt)
            } else if let d = start["date"] as? String {
                startStr = d + " (終日)"
            } else {
                startStr = "?"
            }
        } else {
            startStr = "?"
        }

        let endStr: String
        if let end = event["end"] as? [String: Any] {
            if let dt = end["dateTime"] as? String {
                endStr = formatDateTime(dt)
            } else {
                endStr = ""
            }
        } else {
            endStr = ""
        }

        var result = "\(summary)\n  \(startStr)"
        if !endStr.isEmpty { result += " 〜 \(endStr)" }
        if let loc = location, !loc.isEmpty { result += "\n  場所: \(loc)" }
        if let desc = description, !desc.isEmpty { result += "\n  メモ: \(String(desc.prefix(200)))" }

        return result
    }

    private static func formatDateTime(_ isoString: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        guard let date = isoFormatter.date(from: isoString) else { return isoString }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ja_JP")
        fmt.dateFormat = "M/d (E) HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Errors

    enum CalendarError: LocalizedError {
        case createFailed(detail: String)

        var errorDescription: String? {
            switch self {
            case .createFailed(let d): return "Calendar event creation failed: \(d)"
            }
        }
    }
}
