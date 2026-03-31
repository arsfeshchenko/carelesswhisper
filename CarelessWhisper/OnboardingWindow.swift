import AppKit
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "Onboarding")

final class OnboardingWindow: NSObject {
    private var window: NSWindow?

    private var stepLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var descLabel: NSTextField!
    private var openButton: NSButton!
    private var nextButton: NSButton!
    private var statusLabel: NSTextField!

    private var currentStep = 0
    var onComplete: (() -> Void)?

    func showIfNeeded() {
        let micOK = PermissionChecker.isMicrophoneGranted()
        let accOK = PermissionChecker.isAccessibilityGranted()
        let apiOK = !Settings.apiKey.isEmpty

        if micOK && accOK && apiOK { onComplete?(); return }

        if !micOK { currentStep = 0 }
        else if !accOK { currentStep = 1 }
        else { currentStep = 2 }

        buildWindow()
        renderStep()
    }

    private func buildWindow() {
        NSApp.activate(ignoringOtherApps: true)

        let w: CGFloat = 420, h: CGFloat = 230
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Welcome to CarelessWhisper"
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        let v = win.contentView!

        stepLabel = NSTextField(labelWithString: "")
        stepLabel.frame = NSRect(x: 20, y: h - 36, width: w - 40, height: 16)
        stepLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stepLabel.textColor = .secondaryLabelColor
        v.addSubview(stepLabel)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.frame = NSRect(x: 20, y: h - 68, width: w - 40, height: 26)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        v.addSubview(titleLabel)

        descLabel = NSTextField(wrappingLabelWithString: "")
        descLabel.frame = NSRect(x: 20, y: 76, width: w - 40, height: 72)
        descLabel.font = .systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabelColor
        v.addSubview(descLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 52, width: w - 40, height: 16)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .systemRed
        v.addSubview(statusLabel)

        openButton = NSButton(frame: NSRect(x: 20, y: 14, width: 180, height: 32))
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(onOpen)
        v.addSubview(openButton)

        nextButton = NSButton(frame: NSRect(x: w - 110, y: 14, width: 90, height: 32))
        nextButton.bezelStyle = .rounded
        nextButton.title = "Next →"
        nextButton.target = self
        nextButton.action = #selector(onNext)
        nextButton.keyEquivalent = "\r"
        v.addSubview(nextButton)

        self.window = win
        win.makeKeyAndOrderFront(nil)
    }

    private func renderStep() {
        statusLabel.stringValue = ""
        stepLabel.stringValue = "Step \(currentStep + 1) of 3"

        switch currentStep {
        case 0:
            titleLabel.stringValue = "🎙  Enable Microphone"
            descLabel.stringValue = "CarelessWhisper needs microphone access to record your voice for transcription."
            let denied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            openButton.title = denied ? "Open Microphone Settings" : "Grant Microphone Access"
        case 1:
            titleLabel.stringValue = "🔐  Enable Accessibility"
            descLabel.stringValue = "Accessibility is required to detect the right Option key and paste transcribed text."
            openButton.title = "Open Accessibility Settings"
        case 2:
            titleLabel.stringValue = "🔑  Set Your API Key"
            descLabel.stringValue = "Enter your OpenAI API key for Whisper transcription. Stored locally, never shared."
            openButton.title = "Enter API Key"
        default: break
        }
    }

    @objc private func onOpen() {
        switch currentStep {
        case 0:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                PermissionChecker.requestMicrophoneAccess { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self?.renderStep()
                        self?.window?.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            } else {
                PermissionChecker.openMicrophoneSettings()
            }
        case 1:
            PermissionChecker.openAccessibilitySettings()
        case 2:
            showAPIKeyInput()
        default: break
        }
    }

    @objc private func onNext() {
        let ok: Bool
        switch currentStep {
        case 0: ok = PermissionChecker.isMicrophoneGranted()
        case 1: ok = PermissionChecker.isAccessibilityGranted()
        case 2: ok = !Settings.apiKey.isEmpty
        default: ok = false
        }

        if !ok {
            let msg: String
            switch currentStep {
            case 0: msg = "⚠  Microphone access not granted yet"
            case 1: msg = "⚠  Accessibility not enabled yet"
            case 2: msg = "⚠  API key not set yet"
            default: msg = ""
            }
            statusLabel.stringValue = msg
            return
        }

        currentStep += 1

        if currentStep >= 3 {
            finish()
        } else {
            renderStep()
        }
    }

    private func showAPIKeyInput() {
        let alert = NSAlert()
        alert.messageText = "Enter OpenAI API Key"
        alert.informativeText = "Your API key is stored locally and used only for Whisper transcription."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 64))
        tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.placeholderString = "sk-..."
        tf.isEditable = true
        tf.usesSingleLineMode = false
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        alert.accessoryView = tf
        alert.layout()
        alert.window.initialFirstResponder = tf

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        guard key.hasPrefix("sk-") else {
            let err = NSAlert()
            err.messageText = "Invalid Key"
            err.informativeText = "OpenAI keys must start with 'sk-'."
            err.addButton(withTitle: "Try Again")
            err.runModal()
            showAPIKeyInput()
            return
        }

        Settings.apiKey = key
        log.info("API key set via onboarding")
        renderStep()
    }

    private func finish() {
        window?.close()
        window = nil
        log.info("Onboarding complete")
        onComplete?()
    }
}
