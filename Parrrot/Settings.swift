import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.parrrot", category: "Settings")

private let keychainService = "com.arsfeshchenko.parrrot"

@propertyWrapper
struct Setting<T> {
    let key: String
    let defaultValue: T

    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum Settings {
    static var apiKey: String {
        get {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: "apiKey",
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else { return "" }
            return string
        }
        set {
            if newValue.isEmpty {
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: keychainService,
                    kSecAttrAccount: "apiKey"
                ]
                SecItemDelete(query as CFDictionary)
                return
            }
            guard let data = newValue.data(using: .utf8) else { return }
            // Delete any existing item first (avoids ACL mismatch from prior builds)
            let deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: "apiKey"
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            // Create with nil trusted-apps list so any build of this app can read it
            var access: SecAccess?
            SecAccessCreate("parrrot apiKey" as CFString, nil, &access)
            var addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: "apiKey",
                kSecValueData: data
            ]
            if let access { addQuery[kSecAttrAccess] = access }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    @Setting(key: "whisperModel", defaultValue: "whisper-1")
    static var whisperModel: String

    @Setting(key: "soundStart", defaultValue: "Tink")
    static var soundStart: String

    @Setting(key: "soundStop", defaultValue: "Pop")
    static var soundStop: String

    @Setting(key: "soundError", defaultValue: "Basso")
    static var soundError: String

    @Setting(key: "soundSuccess", defaultValue: "Glass")
    static var soundSuccess: String

    @Setting(key: "soundRetranscribe", defaultValue: "Morse")
    static var soundRetranscribe: String

    @Setting(key: "autoSubmit", defaultValue: false)
    static var autoSubmit: Bool

    @Setting(key: "minRecordingSeconds", defaultValue: 0.3)
    static var minRecordingSeconds: Double

    @Setting(key: "maxRecordingSeconds", defaultValue: 300.0)
    static var maxRecordingSeconds: Double

    @Setting(key: "soundsEnabled", defaultValue: true)
    static var soundsEnabled: Bool
}
