//
//  AudioService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import AVFoundation
import Foundation

/// Audio service for STT (Whisper) and TTS (OpenAI).
/// Playback runs entirely off MainActor to prevent UI freezes.
@MainActor
@Observable
final class AudioService: NSObject {
    private let openAIKey: String = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String ?? ""

    // MARK: - Observable state (MainActor)

    var isRecording = false
    var isSpeaking = false

    // MARK: - Private

    private var recorder: AVAudioRecorder?
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

    func stopRecordingAndTranscribe() async throws -> String {
        guard recorder != nil else {
            throw AudioError.noRecordingInProgress
        }

        recorder?.stop()
        recorder = nil
        isRecording = false
        print("[Audio] Recording stopped")

        let url = recordingURL
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
        print("[Audio] Audio file size: \(data.count) bytes")

        return try await Self.transcribe(audioData: data, apiKey: validatedAPIKey())
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

    /// Fetch TTS audio and play it. All heavy work runs off MainActor.
    func speak(_ text: String) async throws {
        let truncated = String(text.prefix(500))
        let token = UUID()
        self.playbackToken = token

        let apiKey = try validatedAPIKey()

        // API call runs off MainActor
        let data = try await Self.requestSpeechAudio(text: truncated, apiKey: apiKey)
        try Task.checkCancellation()
        guard self.playbackToken == token else { throw CancellationError() }

        print("[Audio] TTS audio received: \(data.count) bytes")

        // Decode audio data off MainActor (can be slow for large MP3s)
        let audioPlayer = try await Task.detached(priority: .userInitiated) {
            try AVAudioPlayer(data: data)
        }.value

        guard self.playbackToken == token else { throw CancellationError() }
        guard audioPlayer.prepareToPlay(), audioPlayer.play() else {
            throw AudioError.playbackFailed
        }
        isSpeaking = true
        let duration = audioPlayer.duration
        print("[Audio] Playback started (\(String(format: "%.1f", duration))s)")

        // Poll on a DETACHED task (NOT MainActor) to keep UI responsive
        await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(duration + 5)
            while audioPlayer.isPlaying && Date() < deadline {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }.value

        // Cleanup on MainActor
        if audioPlayer.isPlaying { audioPlayer.stop() }
        isSpeaking = false
        print("[Audio] Playback finished")
    }

    /// Stop any current playback immediately.
    func stopSpeaking() {
        playbackToken = UUID()
        isSpeaking = false
        // Note: The detached polling task will see isPlaying=false or
        // isCancelled and exit on next iteration
    }

    // MARK: - Private helpers

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

    // MARK: - Errors

    enum AudioError: LocalizedError {
        case missingAPIKey
        case noRecordingInProgress
        case recordingFailed
        case sttFailed(status: Int, detail: String)
        case ttsFailed(status: Int, detail: String)
        case playbackFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "OpenAI API key is missing"
            case .noRecordingInProgress: return "No active recording to stop"
            case .recordingFailed: return "Failed to start recording"
            case .sttFailed(let s, let d): return "STT error (\(s)): \(d)"
            case .ttsFailed(let s, let d): return "TTS error (\(s)): \(d)"
            case .playbackFailed: return "Failed to play audio"
            }
        }
    }
}

// MARK: - Data helpers for multipart form

private extension Data {
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
