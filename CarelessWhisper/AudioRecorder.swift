import AVFoundation
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "Audio")

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var startTime: Date?
    private(set) var isRecording = false

    private let desiredSampleRate: Double = 16000
    private let desiredChannels: AVAudioChannelCount = 1

    func start() throws {
        guard !isRecording else { return }

        let tempDir = NSTemporaryDirectory()
        let fileName = "carelesswhisper_\(UUID().uuidString).wav"
        let url = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)
        recordingURL = url

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: desiredSampleRate,
            channels: desiredChannels,
            interleaved: true
        )!

        audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.converterFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.desiredSampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0 else { return }

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error = error {
                log.error("Conversion error: \(error.localizedDescription)")
                return
            }

            do {
                try self.audioFile?.write(from: convertedBuffer)
            } catch {
                log.error("Write error: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        startTime = Date()
        log.info("Recording started")
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        guard isRecording else { return nil }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        startTime = nil
        log.info("Recording stopped, duration: \(String(format: "%.1f", duration))s")

        guard let url = recordingURL else { return nil }
        return (url, duration)
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        startTime = nil
        cleanup()
        log.info("Recording cancelled")
    }

    func cleanup() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    func checkDeviceAvailable() -> Bool {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0
    }

    enum RecorderError: Error {
        case converterFailed
    }
}
