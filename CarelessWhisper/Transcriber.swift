import Foundation
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "Transcriber")

struct TranscriptionResult {
    let text: String
    let wasRetranscribed: Bool
}

final class Transcriber {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let okLanguages: Set<String> = ["english", "ukrainian"]

    func transcribe(wavURL: URL) async throws -> TranscriptionResult {
        let apiKey = Settings.apiKey
        guard !apiKey.isEmpty else {
            throw TranscriberError.noAPIKey
        }

        // First pass: verbose_json to get language
        let (text, language) = try await sendRequest(
            wavURL: wavURL,
            apiKey: apiKey,
            responseFormat: "verbose_json",
            language: nil
        )

        log.info("Detected language: '\(language ?? "nil")'")

        // If language not in allowed set, translate to Ukrainian via GPT
        if let lang = language, !okLanguages.contains(lang.lowercased()) {
            log.info("Detected language '\(lang)', translating to Ukrainian")
            let translated = try await translateToUkrainian(text: text, apiKey: apiKey)
            return TranscriptionResult(text: cleanText(translated), wasRetranscribed: true)
        }

        return TranscriptionResult(text: cleanText(text), wasRetranscribed: false)
    }

    private func sendRequest(
        wavURL: URL,
        apiKey: String,
        responseFormat: String,
        language: String?
    ) async throws -> (text: String, language: String?) {
        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let wavData = try Data(contentsOf: wavURL)

        // model field
        body.appendMultipart(boundary: boundary, name: "model", value: Settings.whisperModel)

        // response_format field
        body.appendMultipart(boundary: boundary, name: "response_format", value: responseFormat)

        // language field (optional)
        if let language = language {
            body.appendMultipart(boundary: boundary, name: "language", value: language)
        }

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriberError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            log.error("API error \(httpResponse.statusCode): \(errorBody)")
            throw TranscriberError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        if responseFormat == "verbose_json" {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let text = json?["text"] as? String ?? ""
            let language = json?["language"] as? String
            return (text, language)
        } else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return (text, nil)
        }
    }

    private func translateToUkrainian(text: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "Translate the following text to Ukrainian. Return only the translated text, nothing else."],
                ["role": "user", "content": text]
            ],
            "temperature": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let translated = (json?["choices"] as? [[String: Any]])?.first
            .flatMap { $0["message"] as? [String: Any] }
            .flatMap { $0["content"] as? String } ?? text
        return translated
    }

    private func cleanText(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(".") {
            t = String(t.dropLast())
        }
        return t
    }

    enum TranscriberError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case apiError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No API key configured"
            case .invalidResponse: return "Invalid response from API"
            case .apiError(let code, let msg): return "API error \(code): \(msg)"
            }
        }
    }
}

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}

