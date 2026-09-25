import Foundation
import Security

enum KeychainStore {
    enum Key: String, CaseIterable {
        case mflUserCookie = "sideline.mfl.userCookie"
        case mflUsername = "sideline.mfl.username"
        case sleeperUsername = "sideline.sleeper.username"
        case sleeperUserId = "sideline.sleeper.userId"
        case fantasyProsAPIKey = "sideline.fantasypros.apiKey"
        case oddsAPIKey = "sideline.odds.apiKey"
        case llmOpenAI = "sideline.llm.openai"
        case llmAnthropic = "sideline.llm.anthropic"
        case llmGoogle = "sideline.llm.google"
        case llmOpenRouter = "sideline.llm.openrouter"
        case llmTypeSafe = "sideline.llm.typesafe"
        case appleUserID = "sideline.auth.appleUserID"
        case appleDisplayName = "sideline.auth.displayName"
    }

    /// Scopes items so they don’t collide with other apps using the same account string.
    private static let service = "com.cpf32.sideline"

    static func deleteAll() {
        for key in Key.allCases {
            delete(key)
        }
    }

    @discardableResult
    static func set(_ value: String?, for key: Key) -> Bool {
        let account = key.rawValue
        // Remove both scoped and legacy (pre-service) rows.
        delete(key)

        guard let value, let data = value.data(using: .utf8) else { return true }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(_ key: Key) -> String? {
        if let value = read(account: key.rawValue, service: service) {
            return value
        }
        // Migrate legacy items that were stored without kSecAttrService.
        guard let legacy = read(account: key.rawValue, service: nil) else { return nil }
        _ = set(legacy, for: key)
        return legacy
    }

    static func delete(_ key: Key) {
        let account = key.rawValue
        let scoped: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(scoped as CFDictionary)
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(legacy as CFDictionary)
    }

    private static func read(account: String, service: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
