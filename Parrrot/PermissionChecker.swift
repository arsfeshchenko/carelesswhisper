import AppKit
import AVFoundation

enum PermissionChecker {

    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    static func isInputMonitoringGranted() -> Bool {
        // IOHIDCheckAccess(kIOHIDRequestTypeListenEvent=1) → 0 means approved
        typealias IOHIDCheckAccessFunc = @convention(c) (UInt32) -> UInt32
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sym = dlsym(iokit, "IOHIDCheckAccess") else {
            return false
        }
        let check = unsafeBitCast(sym, to: IOHIDCheckAccessFunc.self)
        let result = check(1)
        dlclose(iokit)
        return result == 0
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
