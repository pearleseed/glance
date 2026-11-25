//
//  SecureCredentialManager.swift
//  glance
//
//  Two-tier storage on KeychainManager: a Touch-ID-gated session key (unwrapped once per launch) wraps an ungated encrypted
//  password blob, safe to read anytime — including the lock screen, where no app UI exists to host a Touch ID prompt.
//  Touch ID authorizes the session; nothing yet authorizes each individual unlock beyond that (face recognition will).
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed
    case sessionKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Password cannot be empty."
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID before storing or using the password."
        case .encryptionFailed:
            return "Encryption failed."
        case .decryptionFailed:
            return "Decryption failed. The stored credential may be corrupted."
        case .sessionKeyUnavailable:
            return
                "The session key is missing, but encrypted data still exists that only it could read. "
                + "Nothing has been deleted. Remove the stored password on the Password tab to clear "
                + "both and start fresh."
        }
    }
}

extension Notification.Name {
    /// Fires whenever the cached session key changes, so anything encrypted under it (e.g. `FaceEnrollmentStore`) can reload
    /// itself instead of relying on each call site to remember to — a past bug had the sidebar's unlock forget this, leaving
    /// face unlock silently running on stale pre-unlock data.
    nonisolated static let secureCredentialSessionDidChange = Notification.Name(
        "SecureCredentialManager.sessionDidChange")
}

enum LoginKeyUnlockResult: Equatable, Sendable {
    case unlocked
    case notConfigured
    case transientFailure
    case invalidated
}

nonisolated enum OrphanedDataClassification: Equatable, Sendable {
    case noEncryptedData
    case keyPresent
    case confirmedOrphaned
    case indeterminate(OSStatus)
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let loginKeyAccount = "sessionKeyAtLogin"
    nonisolated private static let passwordBlobAccount = "encryptedPassword"
    nonisolated private static let passwordBlobAccessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Runs once (thread-safe via Swift `static let` dispatch-once initialization) to move
    /// pre-v1.3 password blobs from the legacy keychain into the Data Protection Keychain
    /// with lock-screen readability.
    nonisolated private static let legacyMigration: Void = {
        KeychainManager.migrateLegacyItem(account: passwordBlobAccount, accessible: passwordBlobAccessible)
    }()

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    /// AES-GCM ciphertext of the stored password, cached alongside `_cachedKey` while the session is unlocked
    /// so lock-screen unlock never depends on live Keychain IPC (which can fail on legacy ACLs or locked keychains).
    /// Plaintext is NEVER cached; this holds only the encrypted blob and is cleared on `lockSession()`.
    nonisolated(unsafe) private static var _cachedPasswordCiphertext: Data?
    /// Last unlock or successful `readPassword` — what `SessionAutoLocker` compares against the idle limit. Guarded by
    /// `sessionLock` alongside the key so the two can never be observed out of step.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    /// `nil` whenever the session is locked — there is no activity to age.
    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func cachedSessionSnapshot() -> (SymmetricKey?, Data?) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return (_cachedKey, _cachedPasswordCiphertext)
    }

    nonisolated private static func setCachedPasswordCiphertext(_ ciphertext: Data?) {
        sessionLock.lock()
        if _cachedKey != nil || ciphertext == nil {
            _cachedPasswordCiphertext = ciphertext
        }
        sessionLock.unlock()
    }

    nonisolated private static func makePasswordBlobReadableWhileLocked() {
        _ = legacyMigration
        _ = KeychainManager.setAccessibility(account: passwordBlobAccount, to: passwordBlobAccessible)
    }

    /// Populates `_cachedPasswordCiphertext` while the session is unlocked so lock-screen reads stay pure in-memory AES-GCM.
    nonisolated private static func warmPasswordCiphertextCacheIfNeeded() {
        let (_, existing) = cachedSessionSnapshot()
        guard existing == nil else { return }
        guard let ciphertext = try? KeychainManager.read(account: passwordBlobAccount, nonInteractive: true),
            !ciphertext.isEmpty
        else { return }
        setCachedPasswordCiphertext(ciphertext)
    }

    nonisolated private static func setCachedKey(_ key: SymmetricKey?, passwordCiphertext: Data? = nil) {
        sessionLock.lock()
        let changed = (key != nil) != (_cachedKey != nil)
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        if key == nil {
            _cachedPasswordCiphertext = nil
        } else if let passwordCiphertext {
            _cachedPasswordCiphertext = passwordCiphertext
        }
        sessionLock.unlock()
        if key != nil {
            makePasswordBlobReadableWhileLocked()
            if passwordCiphertext == nil {
                warmPasswordCiphertextCacheIfNeeded()
            }
        }
        // Posted after releasing the lock — observers may call back into `isSessionUnlocked` (re-acquiring it) from a
        // background thread, so posting while still locked risks a real self-deadlock, not a theoretical one.
        guard changed else { return }
        NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
    }

    /// Resets the idle countdown on each successful use, so an actively-used session never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    // MARK: - Generic session-key crypto (shared by passwords here and face embeddings in SecureFaceStore; requires an unlocked session)

    nonisolated static func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw SecureCredentialError.encryptionFailed }
            return combined
        } catch {
            throw SecureCredentialError.encryptionFailed
        }
    }

    nonisolated private static func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureCredentialError.decryptionFailed
        }
    }

    nonisolated static func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        return try decrypt(ciphertext, using: key)
    }

    // MARK: - Public API

    nonisolated static func hasStoredPassword() -> Bool {
        if cachedSessionSnapshot().1 != nil {
            return true
        }
        _ = legacyMigration
        return KeychainManager.exists(account: passwordBlobAccount)
    }

    /// Prompts Touch ID (or Mac password) and unwraps the session key, creating it on first run.
    /// Prefers the macOS Data Protection Keychain (`.userPresence` hardware/OS gate) on signed builds,
    /// and falls back cleanly to `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` + the legacy
    /// Login Keychain when `errSecMissingEntitlement` (-34018) occurs on ad-hoc / unsigned builds.
    /// Must succeed before `savePassword`/`readPassword`.
    nonisolated static func unlockSession(reason: String) async throws {
        _ = legacyMigration
        if cachedKey() != nil { return }

        // The existence check, not the read, decides whether a key gets created (load-bearing): a cancelled Touch ID prompt on
        // a user-presence item reports `errSecItemNotFound`, indistinguishable from no key — deciding on the read's error would
        // mint a fresh key (destroying the one that decrypts existing data) on every mis-tap.
        if await runKeychainIO({ KeychainManager.existsInDataProtection(account: sessionKeyAccount) }) {
            try await runKeychainIO {
                let context = LAContext()
                context.localizedReason = reason
                var data = try KeychainManager.readDataProtection(account: sessionKeyAccount, context: context)
                defer { data.resetBytes(in: 0..<data.count) }
                setCachedKey(SymmetricKey(data: data))
            }
            return
        }

        if await runKeychainIO({ KeychainManager.existsInLegacy(account: sessionKeyAccount) }) {
            try await KeychainManager.authenticateUser(reason: reason)
            try await runKeychainIO {
                var data = try KeychainManager.readLegacy(account: sessionKeyAccount)
                defer { data.resetBytes(in: 0..<data.count) }
                setCachedKey(SymmetricKey(data: data))
            }
            return
        }

        // No key at all, but minting one is still destructive if data is already encrypted under a previous key (e.g. a
        // re-signed dev build) — refuse rather than silently render it unreadable forever.
        guard await !runKeychainIO({ hasSessionEncryptedData }) else {
            throw SecureCredentialError.sessionKeyUnavailable
        }

        if try await createDataProtectionSessionKey(reason: reason) { return }
        try await createLegacySessionKey(reason: reason)
    }

    nonisolated private static func runKeychainIO<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    nonisolated private static func runKeychainIO<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated, operation: operation).value
    }

    /// Attempts to mint and read back a `.userPresence`-gated key in the Data Protection Keychain.
    /// Returns `false` only on `errSecMissingEntitlement` (-34018) so ad-hoc builds can fall back cleanly.
    nonisolated private static func createDataProtectionSessionKey(reason: String) async throws -> Bool {
        try await runKeychainIO {
            try? KeychainManager.delete(account: loginKeyAccount)

            let key = SymmetricKey(size: .bits256)
            let access = try KeychainManager.makeUserPresenceAccessControl()
            var keyData = key.withUnsafeBytes { Data($0) }
            defer { keyData.resetBytes(in: 0..<keyData.count) }
            do {
                try KeychainManager.save(
                    account: sessionKeyAccount,
                    data: keyData,
                    accessControl: access
                )
            } catch KeychainError.osStatus(errSecMissingEntitlement) {
                return false
            }

            // Read back through the gated path rather than trusting the write — only a real read proves auth happened.
            let readBackContext = LAContext()
            readBackContext.localizedReason = reason
            var data = try KeychainManager.readDataProtection(account: sessionKeyAccount, context: readBackContext)
            defer { data.resetBytes(in: 0..<data.count) }
            setCachedKey(SymmetricKey(data: data))
            return true
        }
    }

    /// Ad-hoc / unsigned fallback: authenticates with Touch ID / Mac password BEFORE persisting a key
    /// in the legacy Login Keychain so cancelling the prompt never leaves an orphaned key behind.
    nonisolated private static func createLegacySessionKey(reason: String) async throws {
        try await KeychainManager.authenticateUser(reason: reason)
        try await runKeychainIO {
            if cachedKey() != nil { return }
            if KeychainManager.existsInLegacy(account: sessionKeyAccount) {
                var existing = try KeychainManager.readLegacy(account: sessionKeyAccount)
                defer { existing.resetBytes(in: 0..<existing.count) }
                setCachedKey(SymmetricKey(data: existing))
                return
            }

            let key = SymmetricKey(size: .bits256)
            var keyData = key.withUnsafeBytes { Data($0) }
            defer { keyData.resetBytes(in: 0..<keyData.count) }
            try KeychainManager.saveLegacy(account: sessionKeyAccount, data: keyData)

            var verified = try KeychainManager.readLegacy(account: sessionKeyAccount)
            defer { verified.resetBytes(in: 0..<verified.count) }
            setCachedKey(SymmetricKey(data: verified))
        }
    }

    /// Checked without needing the key itself, so this stays answerable precisely when the key can't be read.
    nonisolated static var hasSessionEncryptedData: Bool {
        _ = legacyMigration
        return KeychainManager.exists(account: passwordBlobAccount) || SecureFaceStore.exists
    }

    nonisolated static func classifyOrphanedData(
        sessionKeyExistence: KeychainExistence,
        hasEncryptedData: Bool
    ) -> OrphanedDataClassification {
        guard hasEncryptedData else { return .noEncryptedData }
        switch sessionKeyExistence {
        case .present:
            return .keyPresent
        case .absent:
            return .confirmedOrphaned
        case .indeterminate(let status):
            return .indeterminate(status)
        }
    }

    nonisolated static func orphanedDataClassification() -> OrphanedDataClassification {
        _ = legacyMigration
        guard hasSessionEncryptedData else { return .noEncryptedData }
        return classifyOrphanedData(
            sessionKeyExistence: KeychainManager.existence(account: sessionKeyAccount),
            hasEncryptedData: true
        )
    }

    /// True when encrypted password/face data exists on disk or in Keychain, and the session key is confirmed absent.
    nonisolated static var isSessionKeyMissingWithOrphanedData: Bool {
        orphanedDataClassification() == .confirmedOrphaned
    }

    // MARK: - Opt-in unlock at login

    nonisolated static var unlocksAtLogin: Bool {
        _ = legacyMigration
        return KeychainManager.exists(account: loginKeyAccount)
    }

    /// Stores or deletes an ungated copy of the current session key so launch can unlock without Touch ID.
    nonisolated static func setUnlockAtLogin(_ enabled: Bool) throws {
        _ = legacyMigration
        if enabled {
            guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
            var keyData = key.withUnsafeBytes { Data($0) }
            defer { keyData.resetBytes(in: 0..<keyData.count) }
            try KeychainManager.save(account: loginKeyAccount, data: keyData)
        } else {
            try KeychainManager.delete(account: loginKeyAccount)
        }
    }

    /// True only when the stored password item is genuinely gone — transient/ACL Keychain errors
    /// must not wipe the user's opt-in login key.
    nonisolated static func shouldInvalidateLoginKey(afterPasswordReadError error: Error) -> Bool {
        if case KeychainError.itemNotFound = error { return true }
        return false
    }

    /// Attempts a non-interactive session unlock using the opt-in login key.
    /// Verifies decryption of the stored password blob before caching the key + ciphertext,
    /// preserves `loginKeyAccount` on transient/ACL Keychain errors, and zeroizes all plaintext bytes.
    nonisolated static func unlockSessionFromLoginKeyResult() -> LoginKeyUnlockResult {
        _ = legacyMigration
        if cachedKey() != nil { return .unlocked }
        guard KeychainManager.exists(account: loginKeyAccount) else { return .notConfigured }

        guard var keyData = try? KeychainManager.read(account: loginKeyAccount, nonInteractive: true) else {
            return .transientFailure
        }
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        let candidateKey = SymmetricKey(data: keyData)

        let ciphertext: Data
        do {
            ciphertext = try KeychainManager.read(account: passwordBlobAccount, nonInteractive: true)
        } catch {
            if shouldInvalidateLoginKey(afterPasswordReadError: error) {
                try? KeychainManager.delete(account: loginKeyAccount)
                return .invalidated
            }
            return .transientFailure
        }

        do {
            var plaintext = try decrypt(ciphertext, using: candidateKey)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            guard !plaintext.isEmpty else {
                try? KeychainManager.delete(account: loginKeyAccount)
                return .invalidated
            }
        } catch {
            try? KeychainManager.delete(account: loginKeyAccount)
            return .invalidated
        }

        setCachedKey(candidateKey, passwordCiphertext: ciphertext)
        return .unlocked
    }

    nonisolated static func unlockSessionFromLoginKey() -> Bool {
        unlockSessionFromLoginKeyResult() == .unlocked
    }

    /// Clears the cached session key and encrypted password blob. Next save/read requires Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session —
    /// call `unlockSession(reason:)` first. Blocking; call from a background task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        _ = legacyMigration
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let combined = try encrypt(passwordBytes)
        try KeychainManager.save(
            account: passwordBlobAccount,
            data: combined,
            accessible: passwordBlobAccessible
        )
        setCachedPasswordCiphertext(combined)
        makePasswordBlobReadableWhileLocked()
    }

    /// Decrypts the stored password using the in-memory encrypted blob when cached (zero Keychain IPC
    /// on the lock screen), falling back to Keychain only if the cache wasn't populated yet.
    /// Caller MUST zero the returned bytes via `.resetBytes(in:)` after use.
    nonisolated static func readPassword(nonInteractiveKeychainFallback: Bool = false) throws -> Data {
        _ = legacyMigration
        let (key, cachedCiphertext) = cachedSessionSnapshot()
        guard let key else { throw SecureCredentialError.sessionLocked }
        let ciphertext: Data
        if let cachedCiphertext {
            ciphertext = cachedCiphertext
        } else {
            let loaded = try KeychainManager.read(
                account: passwordBlobAccount,
                nonInteractive: nonInteractiveKeychainFallback
            )
            setCachedPasswordCiphertext(loaded)
            ciphertext = loaded
        }
        let plaintext = try decrypt(ciphertext, using: key)
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Deletes all Keychain items and clears the cached session key.
    nonisolated static func deletePassword() throws {
        _ = legacyMigration
        try KeychainManager.delete(account: loginKeyAccount)
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
