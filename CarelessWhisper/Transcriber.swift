import Foundation
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "Transcriber")

struct TranscriptionResult {
    let text: String
    let wasRetranscribed: Bool
}

final class Transcriber {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    // Whisper's translate endpoint renders any spoken language as English.
    private let translateEndpoint = URL(string: "https://api.openai.com/v1/audio/translations")!
    private let okLanguages: Set<String> = ["english", "ukrainian"]

    func transcribe(wavURL: URL, skipTranslation: Bool = false) async throws -> TranscriptionResult {
        let apiKey = Settings.apiKey
        guard !apiKey.isEmpty else {
            throw TranscriberError.noAPIKey
        }

        switch Settings.outputLanguage {
        case "en":
            // Always English: Whisper's translations endpoint does speech → English.
            let (text, _) = try await sendRequest(
                wavURL: wavURL,
                apiKey: apiKey,
                responseFormat: "text",
                language: nil,
                endpoint: translateEndpoint
            )
            log.info("Forced English output")
            return TranscriptionResult(text: cleanText(text), wasRetranscribed: false)

        case "uk":
            // Always Ukrainian: transcribe in the spoken language, then translate
            // to Ukrainian via GPT unless it already came back as Ukrainian.
            let (text, language) = try await sendRequest(
                wavURL: wavURL,
                apiKey: apiKey,
                responseFormat: "verbose_json",
                language: nil
            )
            log.info("Forced Ukrainian output (detected '\(language ?? "nil")')")
            if let lang = language, lang.lowercased() == "ukrainian" {
                return TranscriptionResult(text: cleanText(text), wasRetranscribed: false)
            }
            let translated = try await translateToUkrainian(text: text, apiKey: apiKey)
            return TranscriptionResult(text: cleanText(translated), wasRetranscribed: false)

        default:
            // Auto (smart): detect language; translate non-EN/UK clips to Ukrainian.
            // No vocab prompt here — it would bias language detection.
            let (text, language) = try await sendRequest(
                wavURL: wavURL,
                apiKey: apiKey,
                responseFormat: "verbose_json",
                language: nil,
                includeVocab: false
            )

            log.info("Detected language: '\(language ?? "nil")'")

            // If language not in allowed set, translate to Ukrainian via GPT (unless skipped)
            if !skipTranslation, let lang = language, !okLanguages.contains(lang.lowercased()) {
                log.info("Detected language '\(lang)', translating to Ukrainian")
                let translated = try await translateToUkrainian(text: text, apiKey: apiKey)
                return TranscriptionResult(text: cleanText(translated), wasRetranscribed: true)
            }

            return TranscriptionResult(text: cleanText(text), wasRetranscribed: false)
        }
    }

    private func sendRequest(
        wavURL: URL,
        apiKey: String,
        responseFormat: String,
        language: String?,
        endpoint: URL? = nil,
        includeVocab: Bool = true
    ) async throws -> (text: String, language: String?) {
        let endpoint = endpoint ?? self.endpoint
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

        // vocabulary biasing (optional) — nudges Whisper toward custom spellings.
        // Skipped during Auto-mode detection: a non-English term in the prompt
        // biases Whisper's language detection (false-positive Ukrainian).
        let vocab = Settings.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeVocab && !vocab.isEmpty {
            body.appendMultipart(boundary: boundary, name: "prompt", value: vocab)
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
        request.timeoutInterval = 60

        // The body is built once above — retries reuse it as-is, so the recorded
        // audio is never lost to a transient network blip.
        let data = try await withRetry(label: "Whisper") {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriberError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                log.error("API error \(httpResponse.statusCode): \(errorBody)")
                throw TranscriberError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
            }
            return data
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

    /// Retries a network operation on transient failures (timeouts, dropped
    /// connections, 429s, 5xx) with short backoff. Tuned faster than the file
    /// path's since push-to-talk is interactive — worst case ~3s before failing.
    /// Cancellation (the menu's Cancel item) breaks out immediately.
    private func withRetry<T>(
        maxAttempts: Int = 3,
        label: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await operation()
            } catch {
                try Task.checkCancellation()
                guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                let delaySec = Double(attempt)  // 1s, then 2s
                log.warning("\(label) failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription) — retrying in \(Int(delaySec))s")
                try await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
                 .secureConnectionFailed, .requestBodyStreamExhausted:
                return true
            default:
                return false
            }
        }
        switch error as? TranscriberError {
        case .apiError(let code, let body):
            // Out of credits won't resolve by retrying — fail fast instead.
            if code == 429, body.contains("insufficient_quota") { return false }
            return code == 429 || (500...599).contains(code)
        case .invalidResponse:
            return true
        default:
            return false
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
        request.timeoutInterval = 30  // small JSON payload — no reason to hang for a minute

        // Translation is a best-effort enhancement: if it fails even after
        // retries, fall back to the untranscribed original rather than losing
        // the whole dictation. Cancellation still propagates.
        let data: Data
        do {
            data = try await withRetry(label: "GPT translate") {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                    throw TranscriberError.apiError(statusCode: http.statusCode, message: errorBody)
                }
                return data
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warning("Translation failed, returning original text: \(error.localizedDescription)")
            return text
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let translated = ((json as? [String: Any])?["choices"] as? [[String: Any]])?.first
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
            case .noAPIKey:
                return "No API key configured. Set your OpenAI key from the menu."
            case .invalidResponse:
                return "Got an invalid response from OpenAI. Try again."
            case .apiError(let code, let rawBody):
                return Self.humanize(statusCode: code, rawBody: rawBody)
            }
        }

        /// Turns OpenAI's JSON error body into a sentence a human can act on.
        private static func humanize(statusCode: Int, rawBody: String) -> String {
            // Pull "error.message" / "error.code" out of the JSON body if present.
            var apiMessage = ""
            var apiCode = ""
            if let data = rawBody.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any] {
                apiMessage = (err["message"] as? String) ?? ""
                apiCode = (err["code"] as? String) ?? ""
            }

            switch statusCode {
            case 401:
                return "Your OpenAI API key was rejected (401). Check that it's valid in the menu."
            case 429 where apiCode == "insufficient_quota":
                return "Your OpenAI account is out of credits. Add billing at platform.openai.com to keep transcribing."
            case 429:
                return "OpenAI is rate-limiting your requests (429). Wait a few seconds and try again."
            case 500...599:
                return "OpenAI had a server error (\(statusCode)). This is on their side — try again shortly."
            default:
                let detail = apiMessage.isEmpty ? rawBody : apiMessage
                return "OpenAI request failed (\(statusCode)): \(detail)"
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

