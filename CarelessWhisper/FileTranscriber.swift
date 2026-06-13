import AppKit
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "FileTranscriber")

/// Transcribes long audio files (m4a, mp3, wav, …) by splitting them into
/// Whisper-API-safe chunks, sending each, and concatenating the result.
final class FileTranscriber: NSObject, URLSessionTaskDelegate {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let chatEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let chunkSeconds: Double = 120  // 2 min per chunk → ~1.4 MB AAC, smaller requests avoid timeouts
    private let formatChunkChars = 6000     // input-side chunk size for GPT formatting pass

    /// Cancellation flag — set from the progress window to abort.
    var isCancelled = false

    /// Per-chunk upload progress sink. Set before sending a chunk, fired by URLSession delegate.
    private var currentUploadHandler: ((Double) -> Void)?

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let frac = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        currentUploadHandler?(min(1.0, frac))
    }

    struct Progress {
        let stage: String         // e.g. "Splitting", "Transcribing chunk 3/18"
        let fraction: Double      // 0…1
    }

    /// Returns the URL of the saved .txt transcript.
    func transcribe(
        sourceURL: URL,
        language: String,
        onProgress: @escaping (Progress) -> Void
    ) async throws -> URL {
        let apiKey = Settings.apiKey
        guard !apiKey.isEmpty else { throw FileTranscriberError.noAPIKey }

        // 1. Inspect duration.
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await loadDuration(asset)
        guard duration > 0 else { throw FileTranscriberError.invalidAudio }
        let chunkCount = max(1, Int(ceil(duration / chunkSeconds)))
        log.info("Source duration: \(String(format: "%.1f", duration))s → \(chunkCount) chunk(s)")

        // 2. Split into chunks (passthrough for m4a/mp4, re-encode otherwise).
        let chunkDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cw_chunks_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chunkDir) }

        var chunkURLs: [URL] = []
        for i in 0..<chunkCount {
            try checkCancelled()
            onProgress(Progress(
                stage: "Splitting chunk \(i + 1)/\(chunkCount)",
                fraction: Double(i) / Double(chunkCount) * 0.15  // splitting takes first 15%
            ))
            let start = Double(i) * chunkSeconds
            let end = min(Double(i + 1) * chunkSeconds, duration)
            let chunkURL = chunkDir.appendingPathComponent("chunk_\(i).m4a")
            try await exportChunk(asset: asset, source: sourceURL, start: start, end: end, to: chunkURL)
            chunkURLs.append(chunkURL)
        }

        // 3. Send each chunk to Whisper. (15% → 75% of total progress)
        var transcripts: [String] = []
        for (i, url) in chunkURLs.enumerated() {
            try checkCancelled()
            let baseFrac = 0.15 + (Double(i) / Double(chunkCount)) * 0.60
            let nextFrac = 0.15 + (Double(i + 1) / Double(chunkCount)) * 0.60
            let span = nextFrac - baseFrac

            // While the chunk is in flight, push smooth sub-progress:
            // upload phase covers 0→70% of span, processing covers 70→100% (estimated by timer).
            let progressActor = ChunkProgress(
                baseFrac: baseFrac,
                span: span,
                label: "chunk \(i + 1)/\(chunkCount)",
                push: { stage, frac in onProgress(Progress(stage: stage, fraction: frac)) }
            )
            progressActor.start()

            let text: String
            do {
                text = try await sendChunk(
                    url: url,
                    apiKey: apiKey,
                    language: language,
                    onUploadProgress: { frac in progressActor.uploadProgress(frac) }
                )
                progressActor.finish()
            } catch {
                progressActor.finish()
                throw error
            }
            transcripts.append(text)
        }

        let rawText = transcripts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. GPT pass — add paragraphs + speaker labels. (75% → 100%)
        let formatted = try await formatWithSpeakers(rawText, apiKey: apiKey) { stage, frac in
            onProgress(Progress(stage: stage, fraction: 0.75 + frac * 0.25))
        }

        // 5. Save.
        let outURL = sourceURL.deletingPathExtension().appendingPathExtension("txt")
        try formatted.write(to: outURL, atomically: true, encoding: .utf8)
        onProgress(Progress(stage: "Done", fraction: 1.0))
        log.info("Saved transcript to \(outURL.path)")
        return outURL
    }

    // MARK: - GPT formatting (paragraphs + speakers)

    private func formatWithSpeakers(
        _ raw: String,
        apiKey: String,
        onProgress: @escaping (String, Double) -> Void
    ) async throws -> String {
        let inputChunks = splitForFormatting(raw, maxChars: formatChunkChars)
        log.info("Formatting pass: \(inputChunks.count) chunk(s)")

        // Shuffle the bird pool once per session so each transcript gets a fresh cast.
        var availableBirds = Self.birdPool.shuffled()

        var output: [String] = []
        var previousTail = ""

        for (i, chunk) in inputChunks.enumerated() {
            try checkCancelled()
            onProgress("Formatting \(i + 1)/\(inputChunks.count)", Double(i) / Double(inputChunks.count))

            // Birds already used in earlier chunks — extracted from output so far.
            let assignedBirds = extractUsedBirds(in: output.joined(separator: "\n\n"))

            let formatted = try await formatChunkRequest(
                chunk: chunk,
                previousTail: previousTail,
                assignedBirds: assignedBirds,
                availableBirds: availableBirds.filter { !assignedBirds.contains($0) },
                apiKey: apiKey
            )
            output.append(formatted)
            previousTail = tailParagraphs(formatted, count: 2)
        }

        return output.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds every "Name:" label used at a paragraph start in the formatted text so far.
    private func extractUsedBirds(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var seen: [String] = []
        var seenSet: Set<String> = []
        // A "label" is the run of characters before the first ':' on a line, max ~30 chars.
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let label = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            // Skip if too long to plausibly be a speaker label, or empty.
            guard !label.isEmpty, label.count <= 30, !seenSet.contains(label) else { continue }
            seen.append(label)
            seenSet.insert(label)
        }
        return seen
    }

    /// Ukrainian bird names used as speaker labels. Shuffled at the start of each transcript.
    private static let birdPool: [String] = [
        "Сокіл", "Сова", "Орел", "Журавель", "Ластівка",
        "Лелека", "Снігур", "Дятел", "Шпак", "Зозуля",
        "Соловей", "Чайка", "Ворон", "Голуб", "Беркут",
        "Іволга", "Синиця", "Фламінго", "Пелікан", "Колібрі",
        "Фазан", "Павич", "Канарка", "Щиглик", "Стриж"
    ]

    private func splitForFormatting(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        // Split on sentence endings to avoid cutting mid-sentence.
        // Ukrainian uses . ? ! — same as English.
        var chunks: [String] = []
        var current = ""
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            if ".?!".contains(ch) {
                if current.count + buffer.count > maxChars && !current.isEmpty {
                    chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
                current += buffer
                buffer = ""
            }
        }
        current += buffer
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return chunks
    }

    private func tailParagraphs(_ text: String, count: Int) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        return paragraphs.suffix(count).joined(separator: "\n\n")
    }

    private func formatChunkRequest(
        chunk: String,
        previousTail: String,
        assignedBirds: [String],
        availableBirds: [String],
        apiKey: String
    ) async throws -> String {
        let assignedLine = assignedBirds.isEmpty
            ? "(none yet — all speakers in this chunk are new)"
            : assignedBirds.joined(separator: ", ")
        let availableLine = availableBirds.prefix(15).joined(separator: ", ")

        let systemPrompt = """
        You receive a raw Ukrainian transcript chunk from a multi-speaker conversation. Your job:

        1. Split the text into paragraphs at natural turn or topic boundaries.
        2. Label each turn with a speaker tag — but instead of "Speaker 1" / "Speaker 2", use BIRD NAMES from the list provided in the user message.
        3. CRITICAL: the same person must always get the same bird across the whole transcript. Birds already assigned to speakers in earlier chunks (listed in the user message) must be reused for the same speakers — recognise them from cues like question/answer flow, addressed names, topic continuity. If a new speaker appears whom you cannot match to an already-assigned bird, pick the next unused bird from the available list.
        4. Preserve the original text EXACTLY. Do NOT summarize, paraphrase, translate, fix grammar, or rewrite. Only add paragraph breaks and speaker labels.
        5. Output format: each turn as a paragraph starting with "BirdName:" (e.g. "Сокіл:"), separated by a single blank line.
        6. Output nothing but the formatted transcript. No headers, no commentary, no markdown, no notes about which bird is whom.
        """

        var userPrompt = """
        Birds already assigned to speakers in earlier chunks (REUSE these for the same speakers): \(assignedLine)
        Available unused birds for any NEW speakers (pick from this list, in order): \(availableLine)


        """

        if !previousTail.isEmpty {
            userPrompt += """
            This is a continuation. Use the same bird labels as in this previous context for the same speakers:

            ---
            \(previousTail)
            ---

            Continue formatting this next chunk:


            """
        }
        userPrompt += chunk

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.2
        ]

        let httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await withRetry(label: "GPT formatting") {
            var request = URLRequest(url: self.chatEndpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 300
            request.httpBody = httpBody

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FileTranscriberError.network("invalid response")
            }
            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "unknown"
                log.error("GPT error \(http.statusCode): \(msg)")
                throw FileTranscriberError.apiError(statusCode: http.statusCode, message: msg)
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = (json?["choices"] as? [[String: Any]])?.first
                .flatMap { $0["message"] as? [String: Any] }
                .flatMap { $0["content"] as? String } ?? ""
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Internal helpers

    private func checkCancelled() throws {
        if isCancelled { throw FileTranscriberError.cancelled }
    }

    private func loadDuration(_ asset: AVURLAsset) async throws -> Double {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
            asset.loadValuesAsynchronously(forKeys: ["duration"]) {
                var err: NSError?
                let status = asset.statusOfValue(forKey: "duration", error: &err)
                if status == .loaded {
                    cont.resume(returning: CMTimeGetSeconds(asset.duration))
                } else {
                    cont.resume(throwing: err ?? FileTranscriberError.invalidAudio)
                }
            }
        }
    }

    private func exportChunk(
        asset: AVURLAsset,
        source: URL,
        start: Double,
        end: Double,
        to outputURL: URL
    ) async throws {
        let ext = source.pathExtension.lowercased()
        let preset = (ext == "m4a" || ext == "mp4" || ext == "mov" || ext == "aac")
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetAppleM4A

        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FileTranscriberError.exportFailed("Could not create export session")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        let timescale: CMTimeScale = 1000
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            end: CMTime(seconds: end, preferredTimescale: timescale)
        )

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously {
                cont.resume()
            }
        }

        if exporter.status != .completed {
            let msg = exporter.error?.localizedDescription ?? "status=\(exporter.status.rawValue)"
            throw FileTranscriberError.exportFailed(msg)
        }
    }

    private func sendChunk(
        url: URL,
        apiKey: String,
        language: String,
        onUploadProgress: @escaping (Double) -> Void
    ) async throws -> String {
        // Build the multipart body once — it's identical across retry attempts.
        let boundary = UUID().uuidString
        var body = Data()
        let audioData = try Data(contentsOf: url)

        body.appendMultipart(boundary: boundary, name: "model", value: Settings.whisperModel)
        body.appendMultipart(boundary: boundary, name: "response_format", value: "text")
        body.appendMultipart(boundary: boundary, name: "language", value: language)

        // vocabulary biasing (optional) — same custom spellings as push-to-talk
        let vocab = Settings.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            body.appendMultipart(boundary: boundary, name: "prompt", value: vocab)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return try await withRetry(label: "Whisper chunk") {
            var request = URLRequest(url: self.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 300

            self.currentUploadHandler = onUploadProgress
            defer { self.currentUploadHandler = nil }

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            let (data, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else {
                throw FileTranscriberError.network("invalid response")
            }
            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "unknown"
                log.error("Whisper error \(http.statusCode): \(msg)")
                throw FileTranscriberError.apiError(statusCode: http.statusCode, message: msg)
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Retry

    /// Retries a network operation on transient failures (timeouts, dropped
    /// connections, 429s, 5xx) with exponential backoff. Honours cancellation.
    private func withRetry<T>(
        maxAttempts: Int = 4,
        label: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await operation()
            } catch {
                try checkCancelled()
                guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                let delaySec = pow(2.0, Double(attempt))  // 2s, 4s, 8s
                log.warning("\(label) failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription) — retrying in \(Int(delaySec))s")
                try await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        if let e = error as? FileTranscriberError, case .apiError(let code, _) = e {
            return code == 429 || (500...599).contains(code)
        }
        return false
    }

    enum FileTranscriberError: LocalizedError {
        case noAPIKey
        case invalidAudio
        case exportFailed(String)
        case network(String)
        case apiError(statusCode: Int, message: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No API key configured"
            case .invalidAudio: return "Could not read audio file"
            case .exportFailed(let m): return "Splitting failed: \(m)"
            case .network(let m): return "Network error: \(m)"
            case .apiError(let c, let m): return "API error \(c): \(m)"
            case .cancelled: return "Cancelled"
            }
        }
    }
}

// MARK: - Within-Chunk Progress

/// Smooths sub-chunk progress: upload phase 0→70%, then a slow creep 70→95%
/// while Whisper processes (we have no real signal), snapped to 100% on finish.
private final class ChunkProgress {
    private let baseFrac: Double
    private let span: Double
    private let label: String
    private let push: (String, Double) -> Void

    private var uploadFrac: Double = 0
    private var processingFrac: Double = 0  // 0…1 within the 70→100 sub-range
    private var processingTimer: Timer?
    private var phase: Phase = .uploading

    private enum Phase { case uploading, processing, done }

    init(baseFrac: Double, span: Double, label: String, push: @escaping (String, Double) -> Void) {
        self.baseFrac = baseFrac
        self.span = span
        self.label = label
        self.push = push
    }

    func start() {
        DispatchQueue.main.async { self.emit() }
    }

    func uploadProgress(_ frac: Double) {
        DispatchQueue.main.async {
            guard self.phase == .uploading else { return }
            self.uploadFrac = frac
            if frac >= 0.999 {
                self.phase = .processing
                self.startProcessingCreep()
            }
            self.emit()
        }
    }

    func finish() {
        DispatchQueue.main.async {
            self.phase = .done
            self.processingTimer?.invalidate()
            self.processingTimer = nil
            self.push("Transcribing \(self.label) — done", self.baseFrac + self.span)
        }
    }

    /// Must be called on main queue.
    private func startProcessingCreep() {
        let start = Date()
        let target: TimeInterval = 25
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(start)
            // Asymptotic — never reaches 1, caps around 0.92 so we never visually outrun the API.
            self.processingFrac = 1 - exp(-elapsed / target)
            self.emit()
        }
    }

    /// Must be called on main queue.
    private func emit() {
        let within: Double
        let stage: String
        switch phase {
        case .uploading:
            within = uploadFrac * 0.7
            stage = "Transcribing \(label) — uploading \(Int(uploadFrac * 100))%"
        case .processing:
            within = 0.7 + processingFrac * 0.25  // creeps 70→95
            stage = "Transcribing \(label) — processing"
        case .done:
            within = 1.0
            stage = "Transcribing \(label) — done"
        }
        push(stage, baseFrac + span * within)
    }
}

// MARK: - Progress Window

final class FileTranscribeProgressWindow {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "Starting…")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    var onCancel: (() -> Void)?

    init(title: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.autoresizingMask = [.width, .height]

        label.frame = NSRect(x: 20, y: 70, width: 340, height: 20)
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .left
        content.addSubview(label)

        progressBar.frame = NSRect(x: 20, y: 45, width: 340, height: 16)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        content.addSubview(progressBar)

        cancelButton.frame = NSRect(x: 280, y: 10, width: 80, height: 28)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        content.addSubview(cancelButton)

        window.contentView = content
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(stage: String, fraction: Double) {
        DispatchQueue.main.async {
            self.label.stringValue = stage
            self.progressBar.doubleValue = max(0, min(1, fraction))
        }
    }

    func close() {
        DispatchQueue.main.async { self.window.close() }
    }

    @objc private func handleCancel() {
        cancelButton.isEnabled = false
        label.stringValue = "Cancelling…"
        onCancel?()
    }
}

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
