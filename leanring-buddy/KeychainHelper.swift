//
//  KeychainHelper.swift
//  leanring-buddy
//
//  Minimal Keychain wrapper for storing API keys securely.
//  Uses kSecClassGenericPassword with a service prefix so all Clicky
//  secrets are grouped together in Keychain Access.
//

import Foundation
import Security

enum KeychainHelper {

    private static let servicePrefix = "com.clicky.app"

    /// Saves a string value to the Keychain under the given key.
    /// Overwrites any existing value for that key.
    static func save(_ value: String, forKey key: String) {
        let service = "\(servicePrefix).\(key)"
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // If the value is empty, just delete — don't store an empty entry
        guard !value.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ KeychainHelper: Failed to save \(key): \(status)")
        }
    }

    /// Reads a string value from the Keychain for the given key.
    /// Returns an empty string if the key doesn't exist.
    static func load(forKey key: String) -> String {
        let service = "\(servicePrefix).\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return "" }

        return string
    }

    /// Deletes a value from the Keychain for the given key.
    static func delete(forKey key: String) {
        let service = "\(servicePrefix).\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Migrates a value from UserDefaults to Keychain if it exists in UserDefaults
    /// but not in Keychain. Cleans up the UserDefaults entry after migration.
    static func migrateFromUserDefaultsIfNeeded(userDefaultsKey: String, keychainKey: String) {
        let keychainValue = load(forKey: keychainKey)
        guard keychainValue.isEmpty else { return } // Already in Keychain

        let userDefaultsValue = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        guard !userDefaultsValue.isEmpty else { return } // Nothing to migrate

        save(userDefaultsValue, forKey: keychainKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        print("🔑 KeychainHelper: Migrated \(userDefaultsKey) from UserDefaults to Keychain")
    }
}
