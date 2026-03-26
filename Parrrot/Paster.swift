import AppKit
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.parrrot", category: "Paster")

final class Paster {
    private static let keyV: UInt16 = 9
    private static let keyReturn: UInt16 = 36
    private static let clipboardRestoreDelay: TimeInterval = 1.5

    func paste(text: String, autoSubmit: Bool) {
        let pb = NSPasteboard.general

        // Save current clipboard
        let previousContent = pb.string(forType: .string)

        // Set new content
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Post Cmd+V after small delay to let clipboard settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.postCmdV()

            // Optional Enter for auto-submit
            if autoSubmit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.postEnter()
                }
            }
        }

        // Restore clipboard after delay (no clearContents — avoids triggering app clipboard listeners)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardRestoreDelay) {
            if let previous = previousContent {
                pb.setString(previous, forType: .string)
            } else {
                pb.clearContents()
            }
            log.debug("Clipboard restored")
        }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postEnter() {
        // Use nil source so no modifier state is inherited at all
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyReturn, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyReturn, keyDown: false) else { return }
        down.flags = CGEventFlags(rawValue: 0)
        up.flags   = CGEventFlags(rawValue: 0)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log.debug("Enter posted")
    }
}
