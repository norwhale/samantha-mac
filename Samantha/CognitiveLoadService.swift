//
//  CognitiveLoadService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/10.
//
//  Estimates the user's cognitive load (0-10) from system signals.
//  Designed to be BCI-ready: the `LoadSource` protocol can later be
//  implemented by an EEG device provider without changing the UI.
//

import Foundation

// MARK: - Data structures

struct LoadSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let score: Double          // 0.0 - 10.0 overall
    let signals: Signals

    struct Signals {
        var systemLoad: Double      // load average / CPU pressure
        var runningApps: Double     // app count
        var focusApp: Double        // current front app weight
        var timeOfDay: Double       // circadian factor
        var uptime: Double          // consecutive running days
        var recentActivity: Double  // conversation frequency
    }
}

// MARK: - Abstract source (swap for EEG later)

protocol LoadSource {
    func sample() async -> LoadSample
}

// MARK: - Service

@Observable
@MainActor
final class CognitiveLoadService {

    // Observable state
    var history: [LoadSample] = []
    var currentScore: Double = 0.0
    var isMonitoring: Bool = false

    // Configuration
    private let sampleInterval: Duration = .seconds(30)
    private let maxHistory: Int = 120   // 60 minutes at 30s intervals
    private var monitoringTask: Task<Void, Never>?
    private var lastHighLoadAction: Date = .distantPast
    private let actionCooldown: TimeInterval = 900  // 15 minutes

    // Source (swappable)
    private let source: LoadSource

    init(source: LoadSource = SystemSignalSource()) {
        self.source = source
    }

    // MARK: - Lifecycle

    func start() {
        guard monitoringTask == nil else { return }
        isMonitoring = true
        print("[CognitiveLoad] Monitoring started")

        monitoringTask = Task.detached(priority: .utility) { [weak self] in
            // Small initial delay
            try? await Task.sleep(for: .seconds(5))

            while !Task.isCancelled {
                guard let self else { return }
                let sample = await self.source.sample()

                await MainActor.run {
                    self.appendSample(sample)
                }

                // Check for autonomous actions
                if sample.score >= 7.0 {
                    await self.handleHighLoad(sample: sample)
                }

                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
    }

    // MARK: - State update

    private func appendSample(_ sample: LoadSample) {
        history.append(sample)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        currentScore = sample.score
    }

    // MARK: - Autonomous actions

    private nonisolated func handleHighLoad(sample: LoadSample) async {
        let cooldown = actionCooldown
        let canAct = await MainActor.run {
            Date().timeIntervalSince(lastHighLoadAction) > cooldown
        }
        guard canAct else { return }

        if sample.score >= 9.0 {
            AppLogger.shared.log("[CognitiveLoad] CRITICAL (\(String(format: "%.1f", sample.score))/10) — auto focus mode", isError: false)

            // Enable macOS Do Not Disturb via shortcut
            _ = await runShell("osascript -e 'tell application \"System Events\" to keystroke \"d\" using {command down, option down, control down}'")

            // Lower Spotify volume
            _ = await runShell("osascript -e 'tell application \"Spotify\" to set sound volume to 25' 2>/dev/null || true")

            await MainActor.run {
                lastHighLoadAction = Date()
            }
        } else if sample.score >= 7.0 {
            AppLogger.shared.log("[CognitiveLoad] HIGH (\(String(format: "%.1f", sample.score))/10) — light suggestion")
            await MainActor.run {
                lastHighLoadAction = Date()
            }
        }
    }

    // MARK: - Shell helper (simple)

    private nonisolated func runShell(_ command: String) async -> String {
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

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

// MARK: - System Signal Source (default, no BCI needed)

struct SystemSignalSource: LoadSource {

    // Apps that indicate deep cognitive work
    private let heavyWorkApps: Set<String> = [
        "Xcode", "Terminal", "iTerm2", "Visual Studio Code", "Cursor",
        "Notion", "Obsidian", "Anki", "Preview", "Safari", "Google Chrome",
    ]

    func sample() async -> LoadSample {
        async let loadAvg = readLoadAverage()
        async let apps = readRunningApps()
        async let frontApp = readFrontApp()
        async let uptimeDays = readUptimeDays()

        let load = await loadAvg
        let appList = await apps
        let front = await frontApp
        let uptime = await uptimeDays

        // 1. System load → 0-10
        // load average ~2 = normal, ~5 = high, ~8+ = critical
        let systemLoad = min(10.0, load * 1.6)

        // 2. Running apps → 0-10
        // 15 apps = 2, 25 apps = 5, 40+ apps = 10
        let appCount = Double(appList.count)
        let appsScore = max(0.0, min(10.0, (appCount - 10.0) / 3.0))

        // 3. Focus app → 0-10
        // Heavy work apps (Xcode, Terminal, etc.) boost the score
        let focusScore: Double = heavyWorkApps.contains(front) ? 8.0 : 5.0

        // 4. Time of day → 0-10
        // Late night (0-5) and very early morning are cognitive deficit
        let hour = Calendar.current.component(.hour, from: Date())
        let timeScore: Double = switch hour {
        case 0..<5:   9.0   // deep night — major deficit
        case 5..<7:   7.0   // early morning
        case 23..<24: 7.0   // late night
        case 22..<23: 6.0   // night
        case 9..<12, 14..<17: 3.0  // optimal productivity
        default:      4.5   // general daytime
        }

        // 5. Uptime → 0-10
        // System running for many days indicates no restart/rest
        let uptimeScore = min(10.0, uptime * 0.6)

        // 6. Recent activity → 0-10
        // Derived from ActivityLogger: more messages/tool calls = more cognitive effort
        let recentScore = await recentActivityScore()

        // Weighted overall score
        let overall = (
            systemLoad * 0.15 +
            appsScore  * 0.15 +
            focusScore * 0.20 +
            timeScore  * 0.25 +
            uptimeScore * 0.10 +
            recentScore * 0.15
        )

        let clamped = min(10.0, max(0.0, overall))

        let signals = LoadSample.Signals(
            systemLoad: systemLoad,
            runningApps: appsScore,
            focusApp: focusScore,
            timeOfDay: timeScore,
            uptime: uptimeScore,
            recentActivity: recentScore
        )

        return LoadSample(timestamp: Date(), score: clamped, signals: signals)
    }

    // MARK: - Signal readers

    private func readLoadAverage() async -> Double {
        let output = await shell("uptime | awk -F'load averages?:' '{print $2}' | awk '{print $1}' | tr -d ','")
        return Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 2.0
    }

    private func readRunningApps() async -> [String] {
        let output = await shell("osascript -e 'tell application \"System Events\" to get name of every process whose background only is false'")
        return output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ", ")
            .filter { !$0.isEmpty }
    }

    private func readFrontApp() async -> String {
        let output = await shell("osascript -e 'tell application \"System Events\" to get name of first process whose frontmost is true'")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readUptimeDays() async -> Double {
        let output = await shell("uptime | sed 's/.*up //' | awk '{print $1}'")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed) ?? 1.0
    }

    private func recentActivityScore() async -> Double {
        let entries = await ActivityLoggerStore.shared.recentCount(minutes: 30)
        // 0 msgs = 0, 5 msgs = 3, 15 msgs = 7, 25+ msgs = 10
        return min(10.0, Double(entries) * 0.4)
    }

    private func shell(_ command: String) async -> String {
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

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

// MARK: - Activity counter helper

/// Lightweight read-only view into ActivityLogger for cognitive load scoring.
actor ActivityLoggerStore {
    static let shared = ActivityLoggerStore()

    func recentCount(minutes: Int) async -> Int {
        let entries = await ActivityLogger.recentEntriesCount(minutes: minutes)
        return entries
    }
}
