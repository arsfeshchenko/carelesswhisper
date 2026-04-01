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

    // Step 4 (auto-update) buttons — shown instead of open/next
    private var dontCheckButton: NSButton!
    private var checkAutoButton: NSButton!

    private var currentStep = 0  // 0=mic, 1=accessibility, 2=api key, 3=auto-updates
    var onComplete: (() -> Void)?

    func showIfNeeded() {
        let micOK = PermissionChecker.isMicrophoneGranted()
        let accOK = PermissionChecker.isAccessibilityGranted()
        let apiOK = !Settings.apiKey.isEmpty

        if micOK && accOK && apiOK && Settings.onboardingComplete {
            onComplete?()
            return
        }

        if !micOK { currentStep = 0 }
        else if !accOK { currentStep = 1 }
        else if !apiOK { currentStep = 2 }
        else { currentStep = 3 }

        buildWindow()
        renderStep()
    }

    private func buildWindow() {
        NSApp.activate(ignoringOtherApps: true)

        let w: CGFloat = 440, h: CGFloat = 240
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
        titleLabel.frame = NSRect(x: 20, y: h - 70, width: w - 40, height: 28)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        v.addSubview(titleLabel)

        descLabel = NSTextField(wrappingLabelWithString: "")
        descLabel.frame = NSRect(x: 20, y: 86, width: w - 40, height: 76)
        descLabel.font = .systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabelColor
        v.addSubview(descLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 62, width: w - 40, height: 16)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .systemRed
        v.addSubview(statusLabel)

        // Standard steps: open button + next button
        openButton = NSButton(frame: NSRect(x: 20, y: 16, width: 200, height: 32))
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(onOpen)
        v.addSubview(openButton)

        nextButton = NSButton(frame: NSRect(x: w - 120, y: 16, width: 100, height: 32))
        nextButton.bezelStyle = .rounded
        nextButton.title = "Next →"
        nextButton.target = self
        nextButton.action = #selector(onNext)
        nextButton.keyEquivalent = "\r"
        v.addSubview(nextButton)

        // Step 4 buttons (auto-update choice) — right-aligned, equal width
        let btnW: CGFloat = 180, btnH: CGFloat = 32, gap: CGFloat = 10
        checkAutoButton = NSButton(frame: NSRect(x: w - btnW - 20, y: 16, width: btnW, height: btnH))
        checkAutoButton.bezelStyle = .rounded
        checkAutoButton.title = "Check Automatically"
        checkAutoButton.target = self
        checkAutoButton.action = #selector(onCheckAuto)
        checkAutoButton.keyEquivalent = "\r"
        v.addSubview(checkAutoButton)

        dontCheckButton = NSButton(frame: NSRect(x: w - btnW * 2 - 20 - gap, y: 16, width: btnW, height: btnH))
        dontCheckButton.bezelStyle = .rounded
        dontCheckButton.title = "Don't Check"
        dontCheckButton.target = self
        dontCheckButton.action = #selector(onDontCheck)
        v.addSubview(dontCheckButton)

        self.window = win
        win.makeKeyAndOrderFront(nil)
    }

    private func renderStep() {
        statusLabel.stringValue = ""

        let isUpdateStep = currentStep == 3
        openButton.isHidden = isUpdateStep
        nextButton.isHidden = isUpdateStep
        dontCheckButton.isHidden = !isUpdateStep
        checkAutoButton.isHidden = !isUpdateStep

        if isUpdateStep {
            stepLabel.stringValue = "Step 4 of 4"
            titleLabel.stringValue = "🔄  Automatic Updates"
            descLabel.stringValue = "Should CarelessWhisper automatically check for updates on launch? You can always check manually from the menu bar."
        } else {
            stepLabel.stringValue = "Step \(currentStep + 1) of 4"
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

        guard ok else {
            switch currentStep {
            case 0: statusLabel.stringValue = "⚠  Microphone access not granted yet"
            case 1: statusLabel.stringValue = "⚠  Accessibility not enabled yet"
            case 2: statusLabel.stringValue = "⚠  API key not set yet"
            default: break
            }
            return
        }

        currentStep += 1
        renderStep()
    }

    @objc private func onDontCheck() {
        Settings.autoCheckUpdates = false
        finish()
    }

    @objc private func onCheckAuto() {
        Settings.autoCheckUpdates = true
        finish()
    }

    private func showAPIKeyInput() {
        let alert = NSAlert()
        alert.messageText = "Enter OpenAI API Key"
        alert.informativeText = "Your API key is stored locally and used only for Whisper transcription."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.placeholderString = "sk-..."
        tf.isEditable = true
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
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
        Settings.onboardingComplete = true
        window?.close()
        window = nil
        log.info("Onboarding complete, autoCheckUpdates=\(Settings.autoCheckUpdates)")
        onComplete?()
    }
}
