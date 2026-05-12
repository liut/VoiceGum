import Foundation
import Security

public actor KeychainManager {
    public static let shared = KeychainManager()

    private let service = "com.voicegum.llm"

    public enum KeychainError: Error {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
    }

    public init() {}

    public func save(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            try update(key: key, data: data)
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func read(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.itemNotFound
        }

        return data
    }

    public func update(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func saveAPIKey(_ apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else { return }
        try save(key: "apiKey", data: data)
    }

    public func readAPIKey() throws -> String {
        let data = try read(key: "apiKey")
        guard let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }
        return apiKey
    }

    public func deleteAPIKey() throws {
        try delete(key: "apiKey")
    }

    public func saveASRAPIKey(_ apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else { return }
        try save(key: "asrApiKey", data: data)
    }

    public func readASRAPIKey() throws -> String {
        let data = try read(key: "asrApiKey")
        guard let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }
        return apiKey
    }

    public func deleteASRAPIKey() throws {
        try delete(key: "asrApiKey")
    }
}
