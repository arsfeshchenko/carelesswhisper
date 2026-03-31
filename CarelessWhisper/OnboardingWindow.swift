import AppKit
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "Onboarding")

final class OnboardingWindow: NSObject {
    private var window: NSWindow?
    private var pollTimer: Timer?

    // UI elements
    private var stepLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var descLabel: NSTextField!
    private var actionButton: NSButton!
    private var statusIcon: NSTextField!

    // Steps: 0=mic, 1=accessibility, 2=api key
    private var currentStep = 0
    var onComplete: (() -> Void)?

    func showIfNeeded() {
        let micOK = PermissionChecker.isMicrophoneGranted()
        let accOK = PermissionChecker.isAccessibilityGranted()
        let apiOK = !Settings.apiKey.isEmpty

        if micOK && accOK && apiOK {
            onComplete?()
            return
        }

        // Start at first incomplete step
        if !micOK { currentStep = 0 }
        else if !accOK { currentStep = 1 }
        else { currentStep = 2 }

        showWindow()
        updateUI()
        startPolling()
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)

        let w: CGFloat = 420
        let h: CGFloat = 220
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.title = "Welcome to CarelessWhisper"
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        let content = win.contentView!

        // Step indicator (e.g. "Step 1 of 3")
        stepLabel = NSTextField(labelWithString: "")
        stepLabel.frame = NSRect(x: 20, y: h - 40, width: w - 40, height: 18)
        stepLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        stepLabel.textColor = .secondaryLabelColor
        content.addSubview(stepLabel)

        // Status icon + title on same line
        statusIcon = NSTextField(labelWithString: "")
        statusIcon.frame = NSRect(x: 20, y: h - 72, width: 24, height: 24)
        statusIcon.font = NSFont.systemFont(ofSize: 18)
        statusIcon.alignment = .center
        content.addSubview(statusIcon)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.frame = NSRect(x: 48, y: h - 72, width: w - 68, height: 24)
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        content.addSubview(titleLabel)

        // Description
        descLabel = NSTextField(wrappingLabelWithString: "")
        descLabel.frame = NSRect(x: 20, y: 60, width: w - 40, height: 80)
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabelColor
        content.addSubview(descLabel)

        // Action button
        actionButton = NSButton(frame: NSRect(x: w - 200, y: 14, width: 180, height: 32))
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(onAction)
        actionButton.keyEquivalent = "\r"
        content.addSubview(actionButton)

        self.window = win
        win.makeKeyAndOrderFront(nil)
    }

    private func updateUI() {
        let micOK = PermissionChecker.isMicrophoneGranted()
        let accOK = PermissionChecker.isAccessibilityGranted()
        let apiOK = !Settings.apiKey.isEmpty

        // Recalculate current step based on actual state
        if !micOK { currentStep = 0 }
        else if !accOK { currentStep = 1 }
        else if !apiOK { currentStep = 2 }
        else {
            finish()
            return
        }

        stepLabel.stringValue = "Step \(currentStep + 1) of 3"

        switch currentStep {
        case 0:
            statusIcon.stringValue = "🎙"
            titleLabel.stringValue = "Enable Microphone"
            descLabel.stringValue = "CarelessWhisper needs microphone access to record your voice for transcription.\n\nClick the button below to grant access."
            actionButton.title = "Grant Microphone Access"
        case 1:
            statusIcon.stringValue = "🔐"
            titleLabel.stringValue = "Enable Accessibility"
            descLabel.stringValue = "Accessibility is required to detect the hotkey (right Option key) and paste transcribed text.\n\nClick the button to open System Settings, then add CarelessWhisper."
            actionButton.title = "Open Accessibility Settings"
        case 2:
            statusIcon.stringValue = "🔑"
            titleLabel.stringValue = "Set Your API Key"
            descLabel.stringValue = "Enter your OpenAI API key for Whisper transcription.\n\nYour key is stored locally and never shared."
            actionButton.title = "Enter API Key"
        default:
            break
        }
    }

    @objc private func onAction() {
        switch currentStep {
        case 0:
            PermissionChecker.requestMicrophoneAccess { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.updateUI()
                    }
                }
            }
        case 1:
            PermissionChecker.openAccessibilitySettings()
        case 2:
            showAPIKeyInput()
        default:
            break
        }
    }

    private func showAPIKeyInput() {
        let alert = NSAlert()
        alert.messageText = "Enter OpenAI API Key"
        alert.informativeText = "Your API key is stored locally and used only for Whisper transcription."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 64))
        textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.placeholderString = "sk-..."
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = false
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false

        alert.accessoryView = textField
        alert.layout()
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
        updateUI()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    private func finish() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.close()
        window = nil
        log.info("Onboarding complete")
        onComplete?()
    }
}
