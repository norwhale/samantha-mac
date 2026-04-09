//
//  AudioService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import AVFoundation
import Foundation

@Observable
final class AudioService: NSObject, AVAudioPlayerDelegate {
    private let openAIKey: String = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String ?? ""

    // MARK: - Observable state

    var isRecording = false
    var isSpeaking = false

    // MARK: - Private

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?

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
            recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder?.record()
            isRecording = true
            print("[Audio] Recording started")
        } catch {
            print("[Audio] Failed to start recording: \(error)")
        }
    }

    /// Stop recording and transcribe via Whisper. Returns the transcribed text.
    func stopRecordingAndTranscribe() async throws -> String {
        recorder?.stop()
        recorder = nil
        isRecording = false
        print("[Audio] Recording stopped")

        let data = try Data(contentsOf: recordingURL)
        print("[Audio] Audio file size: \(data.count) bytes")

        return try await transcribe(audioData: data)
    }

    private func transcribe(audioData: Data) async throws -> String {
        let boundary = UUID().uuidString
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // model field
        body.appendMultipart(boundary: boundary, name: "model", value: "whisper-1")
        // language hint
        body.appendMultipart(boundary: boundary, name: "language", value: "ja")
        // audio file
        body.appendMultipartFile(boundary: boundary, name: "file", filename: "audio.m4a", mimeType: "audio/m4a", data: audioData)
        // closing boundary
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
        // Truncate very long text to avoid huge TTS requests
        let truncated = String(text.prefix(4096))

        let url = URL(string: "https://api.openai.com/v1/audio/speech")!

        struct TTSRequest: Encodable {
            let model: String
            let input: String
            let voice: String
            let response_format: String
        }

        let body = TTSRequest(model: "tts-1", input: truncated, voice: "nova", response_format: "mp3")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw AudioError.ttsFailed(status: status, detail: detail)
        }

        print("[Audio] TTS audio received: \(data.count) bytes")

        // Play the MP3 data and wait for completion
        isSpeaking = true
        defer { isSpeaking = false }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                player = try AVAudioPlayer(data: data)
                player?.delegate = self
                playbackContinuation = CheckedContinuation<Void, Never>?.none  // clear

                // Store a non-throwing wrapper so delegate can resume
                let wrappedContinuation = continuation
                _speakContinuation = wrappedContinuation

                player?.play()
                print("[Audio] Playback started")
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // Store the continuation for the delegate callback
    private var _speakContinuation: CheckedContinuation<Void, Error>?

    // AVAudioPlayerDelegate
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            print("[Audio] Playback finished")
            _speakContinuation?.resume(returning: ())
            _speakContinuation = nil
        }
    }

    // MARK: - Errors

    enum AudioError: LocalizedError {
        case sttFailed(status: Int, detail: String)
        case ttsFailed(status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .sttFailed(let status, let detail):
                return "STT error (\(status)): \(detail)"
            case .ttsFailed(let status, let detail):
                return "TTS error (\(status)): \(detail)"
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
