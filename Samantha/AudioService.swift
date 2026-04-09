//
//  AudioService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import AVFoundation
import Foundation

@MainActor
@Observable
final class AudioService: NSObject {
    private let openAIKey: String = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String ?? ""

    // MARK: - Observable state

    var isRecording = false
    var isSpeaking = false

    // MARK: - Private

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var playbackToken = UUID()

    private var recordingURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("samantha_recording.m4a")
    }

    // MARK: - STT (Recording → Whisper)

    func startRecording() {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            stopSpeaking()
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                try? FileManager.default.removeItem(at: recordingURL)
            }

            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            guard recorder.prepareToRecord(), recorder.record() else {
                throw AudioError.recordingFailed
            }

            self.recorder = recorder
            isRecording = true
            print("[Audio] Recording started")
        } catch {
            print("[Audio] Failed to start recording: \(error)")
        }
    }

    /// Stop recording and transcribe via Whisper. Returns the transcribed text.
    func stopRecordingAndTranscribe() async throws -> String {
        guard recorder != nil else {
            throw AudioError.noRecordingInProgress
        }

        recorder?.stop()
        recorder = nil
        isRecording = false
        print("[Audio] Recording stopped")

        let data = try await Self.loadRecordingData(from: recordingURL)
        print("[Audio] Audio file size: \(data.count) bytes")

        return try await Self.transcribe(audioData: data, apiKey: validatedAPIKey())
    }

    private static func loadRecordingData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }

    nonisolated private static func transcribe(audioData: Data, apiKey: String) async throws -> String {
        let boundary = UUID().uuidString
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipart(boundary: boundary, name: "model", value: "whisper-1")
        body.appendMultipart(boundary: boundary, name: "language", value: "ja")
        body.appendMultipartFile(boundary: boundary, name: "file", filename: "audio.m4a", mimeType: "audio/m4a", data: audioData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: responseData, encoding: .utf8) ?? "unknown"
            throw AudioError.sttFailed(status: status, detail: detail)
        }

        struct WhisperResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: responseData)
        print("[Audio] Transcribed: \(decoded.text)")
        return decoded.text
    }

    // MARK: - TTS (Text → Speech)

    func speak(_ text: String) async throws {
        // Keep TTS short (~30s max) to avoid long playback freezes
        let truncated = String(text.prefix(500))
        let playbackToken = UUID()
        self.playbackToken = playbackToken
        let data = try await Self.requestSpeechAudio(text: truncated, apiKey: validatedAPIKey())
        try Task.checkCancellation()

        guard self.playbackToken == playbackToken else {
            throw CancellationError()
        }

        print("[Audio] TTS audio received: \(data.count) bytes")

        isSpeaking = true
        defer { isSpeaking = false }

        let audioPlayer = try AVAudioPlayer(data: data)
        player = audioPlayer
        guard audioPlayer.prepareToPlay(), audioPlayer.play() else {
            player = nil
            throw AudioError.playbackFailed
        }
        print("[Audio] Playback started (\(String(format: "%.1f", audioPlayer.duration))s)")

        // Poll until finished or timeout (duration + 5s safety margin)
        let deadline = Date().addingTimeInterval(audioPlayer.duration + 5)
        while audioPlayer.isPlaying && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }

        if audioPlayer.isPlaying {
            audioPlayer.stop()
            player = nil
            throw AudioError.playbackTimedOut
        }

        player = nil
        print("[Audio] Playback finished")
    }

    /// Stop any current playback immediately.
    func stopSpeaking() {
        playbackToken = UUID()
        player?.stop()
        player = nil
        isSpeaking = false
    }

    // MARK: - Errors

    private func validatedAPIKey() throws -> String {
        let trimmed = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            throw AudioError.missingAPIKey
        }
        return trimmed
    }

    nonisolated private static func requestSpeechAudio(text: String, apiKey: String) async throws -> Data {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!

        struct TTSRequest: Encodable {
            let model: String
            let input: String
            let voice: String
            let response_format: String
        }

        let body = TTSRequest(model: "tts-1", input: text, voice: "nova", response_format: "mp3")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw AudioError.ttsFailed(status: status, detail: detail)
        }

        return data
    }

    enum AudioError: LocalizedError {
        case missingAPIKey
        case noRecordingInProgress
        case recordingFailed
        case sttFailed(status: Int, detail: String)
        case ttsFailed(status: Int, detail: String)
        case playbackFailed
        case playbackTimedOut

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API key is missing or unresolved"
            case .noRecordingInProgress:
                return "No active recording to stop"
            case .recordingFailed:
                return "Failed to start recording"
            case .sttFailed(let status, let detail):
                return "STT error (\(status)): \(detail)"
            case .ttsFailed(let status, let detail):
                return "TTS error (\(status)): \(detail)"
            case .playbackFailed:
                return "Audio playback could not be started"
            case .playbackTimedOut:
                return "Audio playback timed out"
            }
        }
    }
}

// MARK: - Data helpers for multipart form

nonisolated private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
