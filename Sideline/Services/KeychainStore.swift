import Foundation
import Security

enum KeychainStore {
    enum Key: String {
        case mflUserCookie = "sideline.mfl.userCookie"
        case mflUsername = "sideline.mfl.username"
        case sleeperUsername = "sideline.sleeper.username"
        case sleeperUserId = "sideline.sleeper.userId"
        case llmOpenAI = "sideline.llm.openai"
        case llmAnthropic = "sideline.llm.anthropic"
        case llmGoogle = "sideline.llm.google"
        case llmOpenRouter = "sideline.llm.openrouter"
        case llmTypeSafe = "sideline.llm.typesafe"
        case appleUserID = "sideline.auth.appleUserID"
        case appleDisplayName = "sideline.auth.displayName"
    }

    static func set(_ value: String?, for key: Key) {
        let account = key.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: Key) {
        set(nil, for: key)
    }
}
