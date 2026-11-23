//
//  KeychainManager.swift
//  glance
//
//  Thin, password-agnostic wrapper around Keychain Services — save/read/delete/exists by account, plus a Touch-ID access control helper.
//

import Foundation
import LocalAuthentication
import Security

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessControlFailed(String)
    case authenticationFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Keychain item not found."
        case .unexpectedData:
            return "Keychain item had an unexpected format."
        case .accessControlFailed(let msg):
            return "Couldn't create Keychain access control: \(msg)"
        case .authenticationFailed:
            return "Authentication was cancelled or failed."
        case .osStatus(let status):
            if status == errSecMissingEntitlement {
                return
                    "Keychain access requires a signed build with keychain entitlements "
                    + "(errSecMissingEntitlement, -34018)."
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

enum KeychainManager {
    nonisolated static let service = "com.pearleseed.glance"

    nonisolated private static func baseQuery(account: String, dataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    nonisolated private static func exists(account: String, dataProtection: Bool) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    nonisolated static func existsInDataProtection(account: String) -> Bool {
        exists(account: account, dataProtection: true)
    }

    nonisolated static func existsInLegacy(account: String) -> Bool {
        exists(account: account, dataProtection: false)
    }

    /// Attributes-only existence check — never prompts, even for access-controlled items.
    nonisolated static func exists(account: String) -> Bool {
        existsInDataProtection(account: account) || existsInLegacy(account: account)
    }

    /// Prompts Touch ID, Apple Watch, or Mac login password via LocalAuthentication.
    /// Used to gate legacy Login Keychain reads/writes on ad-hoc / unsigned builds where
    /// Data Protection Keychain entitlements (`-34018`) are unavailable.
    nonisolated static func authenticateUser(reason: String) async throws {
        let context = LAContext()
        defer { context.invalidate() }

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw KeychainError.authenticationFailed
        }

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard authenticated else { throw KeychainError.authenticationFailed }
        } catch {
            throw KeychainError.authenticationFailed
        }
    }

    nonisolated static func readDataProtection(account: String, context: LAContext? = nil) throws -> Data {
        let (status, item) = rawRead(account: account, context: context, dataProtection: true)
        return try unwrapReadResult(status: status, item: item)
    }

    nonisolated static func readLegacy(account: String) throws -> Data {
        let (status, item) = rawRead(account: account, context: nil, dataProtection: false)
        return try unwrapReadResult(status: status, item: item)
    }

    /// Saves an ungated item directly to the legacy Login Keychain (used on ad-hoc / unsigned builds).
    nonisolated static func saveLegacy(
        account: String,
        data: Data,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) throws {
        try saveSingle(
            account: account,
            data: data,
            accessControl: nil,
            accessible: accessible,
            dataProtection: false
        )
    }

    nonisolated private static func rawRead(
        account: String,
        context: LAContext?,
        dataProtection: Bool
    ) -> (OSStatus, CFTypeRef?) {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }

    nonisolated private static func unwrapReadResult(status: OSStatus, item: CFTypeRef?) throws -> Data {
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        // Handles v1.2 upgraded items and unsigned builds when the item lives only in the legacy keychain,
        // and prevents double-prompting if a cancelled Data Protection `.userPresence` read reports `errSecItemNotFound`.
        if context != nil,
            !exists(account: account, dataProtection: true),
            exists(account: account, dataProtection: false)
        {
            let (legacyStatus, legacyItem) = rawRead(account: account, context: context, dataProtection: false)
            return try unwrapReadResult(status: legacyStatus, item: legacyItem)
        }

        let (status, item) = rawRead(account: account, context: context, dataProtection: true)
        if status == errSecMissingEntitlement || (status == errSecItemNotFound && context == nil) {
            let (legacyStatus, legacyItem) = rawRead(account: account, context: context, dataProtection: false)
            return try unwrapReadResult(status: legacyStatus, item: legacyItem)
        }
        return try unwrapReadResult(status: status, item: item)
    }

    /// Stores an item, updating its data in place when it already exists. Updating
    /// avoids the delete/add gap that can race with a second submit and produce
    /// `errSecDuplicateItem`. Existing access-control attributes are preserved;
    /// this method's access-control/accessible argument applies when adding a new item.
    /// Falls back to the legacy keychain on `errSecMissingEntitlement` only for ungated
    /// items (`accessControl == nil`) so unsigned local builds surface `-34018` cleanly.
    nonisolated static func save(
        account: String,
        data: Data,
        accessControl: SecAccessControl? = nil,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) throws {
        do {
            try saveSingle(
                account: account,
                data: data,
                accessControl: accessControl,
                accessible: accessible,
                dataProtection: true
            )
        } catch KeychainError.osStatus(errSecMissingEntitlement) where accessControl == nil {
            try saveSingle(
                account: account,
                data: data,
                accessControl: nil,
                accessible: accessible,
                dataProtection: false
            )
        }
    }

    nonisolated private static func saveSingle(
        account: String,
        data: Data,
        accessControl: SecAccessControl?,
        accessible: CFString,
        dataProtection: Bool
    ) throws {
        let itemQuery = baseQuery(account: account, dataProtection: dataProtection)

        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break  // Add below.
        default:
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery = itemQuery
        addQuery[kSecValueData as String] = data
        if let accessControl {
            addQuery[kSecAttrAccessControl as String] = accessControl
        } else {
            addQuery[kSecAttrAccessible as String] = accessible
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return }
        // Another save may have added the item after our update reported
        // not-found. Complete that competing replacement with an update instead
        // of surfacing an avoidable “item already exists” error.
        if status == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                itemQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else { throw KeychainError.osStatus(retryStatus) }
            return
        }
        throw KeychainError.osStatus(status)
    }

    nonisolated static func delete(account: String) throws {
        let dpStatus = SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        guard dpStatus == errSecSuccess || dpStatus == errSecItemNotFound || dpStatus == errSecMissingEntitlement else {
            throw KeychainError.osStatus(dpStatus)
        }

        let legacyStatus = SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw KeychainError.osStatus(legacyStatus)
        }
    }

    /// Updates `kSecAttrAccessible` on an existing Data Protection item, migrating from legacy if needed.
    /// Gracefully no-ops (`false`) on unsigned builds where Data Protection returns `errSecMissingEntitlement`.
    @discardableResult
    nonisolated static func setAccessibility(account: String, to accessible: CFString) -> Bool {
        let query = baseQuery(account: account, dataProtection: true)
        let update = [kSecAttrAccessible as String: accessible] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            migrateLegacyItem(account: account, accessible: accessible)
            return exists(account: account, dataProtection: true)
        default:
            return false
        }
    }

    /// Migrates an ungated legacy-keychain item into the Data Protection Keychain with `accessible`.
    /// Deletes the legacy copy only after reading back from Data Protection and verifying byte-for-byte equality.
    nonisolated static func migrateLegacyItem(account: String, accessible: CFString) {
        guard !exists(account: account, dataProtection: true),
            exists(account: account, dataProtection: false)
        else { return }

        let nonInteractive = LAContext()
        nonInteractive.interactionNotAllowed = true
        let (readStatus, legacyItem) = rawRead(account: account, context: nonInteractive, dataProtection: false)
        guard readStatus == errSecSuccess, let legacyData = legacyItem as? Data else { return }

        do {
            try saveSingle(
                account: account,
                data: legacyData,
                accessControl: nil,
                accessible: accessible,
                dataProtection: true
            )
        } catch {
            return
        }

        let (verifyStatus, dpItem) = rawRead(account: account, context: nonInteractive, dataProtection: true)
        guard verifyStatus == errSecSuccess,
            let dpData = dpItem as? Data,
            dpData == legacyData
        else { return }

        SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
    }

    /// `.userPresence` requires Touch ID or device password, with no separate no-hardware handling needed.
    nonisolated static func makeUserPresenceAccessControl() throws -> SecAccessControl {
        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &accessError
            )
        else {
            let msg = (accessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw KeychainError.accessControlFailed(msg)
        }
        return access
    }
}
