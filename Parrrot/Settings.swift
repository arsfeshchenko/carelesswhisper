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
                kSecMatchLimit: kSecMatchLimitOne,
                kSecUseDataProtectionKeychain: true
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else { return "" }
            return string
        }
        set {
            // Delete from both old (ACL-based) and new (data protection) keychain
            let deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: "apiKey"
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            let deleteQueryDP: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: "apiKey",
                kSecUseDataProtectionKeychain: true
            ]
            SecItemDelete(deleteQueryDP as CFDictionary)

            if newValue.isEmpty { return }
            guard let data = newValue.data(using: .utf8) else { return }

            // Use data protection keychain — no ACL, no binary-hash binding, survives rebuilds
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: "apiKey",
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
                kSecUseDataProtectionKeychain: true
            ]
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
