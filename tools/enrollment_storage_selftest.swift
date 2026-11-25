//
//  enrollment_storage_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for transactional enrollment storage contracts:
//    1. Keychain existence & orphan classification (`KeychainExistence`, `OrphanedDataClassification`)
//    2. `SecureFaceStore` error propagation, legacy decoding, and file deletion semantics
//    3. `FaceEnrollmentStore` transactional load states, write guards, rollback preservation, and explicit reset
//
//  Compile and run from repo root:
//      swiftc -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility -O \
//        -o /tmp/enrollment_storage_selftest \
//        glance/Recognition/FaceEmbedder.swift \
//        glance/Recognition/FaceEnrollmentStore.swift \
//        glance/Security/KeychainManager.swift \
//        glance/Security/SecureFaceStore.swift \
//        glance/Security/SecureCredentialManager.swift \
//        tools/enrollment_storage_selftest.swift \
//      && /tmp/enrollment_storage_selftest
//

import CoreGraphics
import CryptoKit
import Foundation
import Security

private var passed = 0
private var failed = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "Assertion failed",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL (\(file):\(line)): \(message)\n", stderr)
    }
}

private func expectThrows(
    _ message: String = "Expected call to throw",
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: (Error) -> Bool = { _ in true },
    _ body: () throws -> Void
) {
    do {
        try body()
        failed += 1
        fputs("FAIL (\(file):\(line)): \(message)\n", stderr)
    } catch {
        if verify(error) {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL (\(file):\(line)): \(message) (unexpected error: \(error))\n", stderr)
        }
    }
}

private nonisolated struct MockEmbedder: FaceEmbedder {
    let name = "Mock ArcFace"
    let modelIdentifier = "mock-arcface-v1"
    let embeddingDimension = 2
    let requiresAlignment = true
    let isUnlockCapable = true

    func embedding(for face: CGImage) throws -> [Float] { [1, 0] }
}

private nonisolated struct LegacyFaceIdentity: Encodable {
    let id: UUID
    let name: String
    let samples: [FaceSample]
    let modelIdentifier: String
    let embeddingDimension: Int
    let createdAt: Date
}

private nonisolated func sealAESGCM(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
    let sealed = try AES.GCM.seal(plaintext, using: key)
    guard let combined = sealed.combined else {
        throw SecureCredentialError.encryptionFailed
    }
    return combined
}

private nonisolated func openAESGCM(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
    do {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    } catch {
        throw SecureCredentialError.decryptionFailed
    }
}

private nonisolated final class StorageSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _isUnlocked: Bool
    private var _saveCount = 0
    private var _loadError: Error?
    private var _saveError: Error?
    private var _deleteAllError: Error?

    let fileURL: URL
    private let key: SymmetricKey

    init(fileURL: URL, key: SymmetricKey, isUnlocked: Bool = true) {
        self.fileURL = fileURL
        self.key = key
        self._isUnlocked = isUnlocked
    }

    var isUnlocked: Bool {
        get { lock.withLock { _isUnlocked } }
        set { lock.withLock { _isUnlocked = newValue } }
    }

    var saveCount: Int {
        lock.withLock { _saveCount }
    }

    var loadError: Error? {
        get { lock.withLock { _loadError } }
        set { lock.withLock { _loadError = newValue } }
    }

    var saveError: Error? {
        get { lock.withLock { _saveError } }
        set { lock.withLock { _saveError = newValue } }
    }

    var deleteAllError: Error? {
        get { lock.withLock { _deleteAllError } }
        set { lock.withLock { _deleteAllError = newValue } }
    }

    var storage: FaceEnrollmentStore.Storage {
        let key = self.key
        let fileURL = self.fileURL
        return FaceEnrollmentStore.Storage(
            isSessionUnlocked: { self.isUnlocked },
            load: {
                if let error = self.loadError {
                    throw error
                }
                return try SecureFaceStore.load(
                    from: fileURL,
                    isSessionUnlocked: { self.isUnlocked },
                    decrypt: { try openAESGCM($0, using: key) }
                )
            },
            save: { identities in
                self.lock.withLock { self._saveCount += 1 }
                if let error = self.saveError {
                    throw error
                }
                try SecureFaceStore.save(
                    identities,
                    to: fileURL,
                    isSessionUnlocked: { self.isUnlocked },
                    encrypt: { try sealAESGCM($0, using: key) }
                )
            },
            deleteAll: {
                if let error = self.deleteAllError {
                    throw error
                }
                try SecureFaceStore.deleteAll(at: fileURL)
            }
        )
    }
}

@main
struct EnrollmentStorageSelfTest {
    static func main() {
        testKeychainExistenceAndOrphanClassification()
        testSecureFaceStoreFirstRunMissingFileReturnsEmpty()
        testSecureFaceStorePropagatesPermissionAndIOErrors()
        testSecureFaceStoreLegacyDecodingDefaultsIsEnabledTrue()
        testReloadFailureAfterSuccessfulLoadBlocksAllWritesAndPreservesCiphertext()
        testWriteFailurePreservesPublishedIdentitiesForAllMutations()
        testExplicitDeleteAllPropagatesErrorAndResetsOnlyOnSuccess()
        print("Passed \(passed) assertions, \(failed) failed.")
        if failed > 0 {
            exit(1)
        }
    }

    private static func testKeychainExistenceAndOrphanClassification() {
        // 1. Single-backend classification
        expect(KeychainManager.classifyExistence(status: errSecSuccess) == .present)
        expect(KeychainManager.classifyExistence(status: errSecInteractionNotAllowed) == .present)
        expect(KeychainManager.classifyExistence(status: errSecItemNotFound) == .absent)
        expect(KeychainManager.classifyExistence(status: errSecIO) == .indeterminate(errSecIO))
        expect(
            KeychainManager.classifyExistence(status: errSecMissingEntitlement)
                == .indeterminate(errSecMissingEntitlement)
        )

        // 2. Dual-backend combination (signed + ad-hoc)
        expect(KeychainManager.combineExistence(dataProtection: errSecSuccess, legacy: errSecIO) == .present)
        expect(
            KeychainManager.combineExistence(
                dataProtection: errSecMissingEntitlement,
                legacy: errSecInteractionNotAllowed
            ) == .present
        )
        expect(
            KeychainManager.combineExistence(dataProtection: errSecItemNotFound, legacy: errSecItemNotFound)
                == .absent
        )
        expect(
            KeychainManager.combineExistence(dataProtection: errSecMissingEntitlement, legacy: errSecItemNotFound)
                == .absent
        )
        expect(
            KeychainManager.combineExistence(dataProtection: errSecIO, legacy: errSecItemNotFound)
                == .indeterminate(errSecIO)
        )
        expect(
            KeychainManager.combineExistence(dataProtection: errSecMissingEntitlement, legacy: errSecAuthFailed)
                == .indeterminate(errSecAuthFailed)
        )
        expect(
            KeychainManager.combineExistence(dataProtection: errSecItemNotFound, legacy: errSecUserCanceled)
                == .indeterminate(errSecUserCanceled)
        )

        // 3. Orphan classification
        expect(
            SecureCredentialManager.classifyOrphanedData(sessionKeyExistence: .absent, hasEncryptedData: false)
                == .noEncryptedData
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(sessionKeyExistence: .present, hasEncryptedData: true)
                == .keyPresent
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(sessionKeyExistence: .absent, hasEncryptedData: true)
                == .confirmedOrphaned
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .indeterminate(errSecIO),
                hasEncryptedData: true
            ) == .indeterminate(errSecIO)
        )

        // 4. Password-blob + face-store combined orphan classification
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .absent,
                passwordBlobExistence: .indeterminate(errSecIO),
                hasFaceStore: false
            ) == .indeterminate(errSecIO)
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .present,
                passwordBlobExistence: .indeterminate(errSecAuthFailed),
                hasFaceStore: false
            ) == .indeterminate(errSecAuthFailed)
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .absent,
                passwordBlobExistence: .indeterminate(errSecIO),
                hasFaceStore: true
            ) == .confirmedOrphaned
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .present,
                passwordBlobExistence: .indeterminate(errSecIO),
                hasFaceStore: true
            ) == .keyPresent
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .absent,
                passwordBlobExistence: .absent,
                hasFaceStore: false
            ) == .noEncryptedData
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .absent,
                passwordBlobExistence: .present,
                hasFaceStore: false
            ) == .confirmedOrphaned
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .present,
                passwordBlobExistence: .present,
                hasFaceStore: false
            ) == .keyPresent
        )
        expect(
            SecureCredentialManager.classifyOrphanedData(
                sessionKeyExistence: .indeterminate(errSecUserCanceled),
                passwordBlobExistence: .present,
                hasFaceStore: false
            ) == .indeterminate(errSecUserCanceled)
        )
    }

    private static func withTemporaryDirectory(_ body: (URL) throws -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-enrollment-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            expect(false, "Failed to create temp directory: \(error)")
            return
        }
        defer {
            restorePermissionsRecursively(at: dir)
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            try body(dir)
        } catch {
            expect(false, "Unexpected error in temp test: \(error)")
        }
    }

    private static func restorePermissionsRecursively(at root: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? fm.setAttributes([.posixPermissions: isDir ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    private static func makeIdentity(name: String, isEnabled: Bool = true) -> FaceIdentity {
        let sample = FaceSample(
            embedding: [1, 0],
            pose: "center",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            quality: 0.9
        )
        return FaceIdentity(
            id: UUID(),
            name: name,
            samples: [sample],
            modelIdentifier: MockEmbedder().modelIdentifier,
            embeddingDimension: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isEnabled: isEnabled
        )
    }

    private static func isStoreUnreadable(_ error: Error) -> Bool {
        if case FaceEnrollmentStoreError.storeUnreadable = error {
            return true
        }
        return false
    }

    private static func isFailedLoadState(_ state: FaceEnrollmentStore.LoadState) -> Bool {
        if case .failed(let message) = state {
            return !message.isEmpty
        }
        return false
    }

    private static func testSecureFaceStoreFirstRunMissingFileReturnsEmpty() {
        withTemporaryDirectory { tempDir in
            let missingFile = tempDir.appendingPathComponent("missing.enc")
            let loaded = try SecureFaceStore.load(
                from: missingFile,
                isSessionUnlocked: { true },
                decrypt: { _ in
                    expect(false, "decrypt should not be called when file does not exist")
                    return Data()
                }
            )
            expect(loaded.isEmpty, "Missing file on first run should return []")

            let missingNested = tempDir.appendingPathComponent("nested/missing.enc")
            let loadedNested = try SecureFaceStore.load(
                from: missingNested,
                isSessionUnlocked: { true },
                decrypt: { _ in Data() }
            )
            expect(loadedNested.isEmpty, "Missing file in missing directory should return []")
        }
    }

    private static func testSecureFaceStorePropagatesPermissionAndIOErrors() {
        withTemporaryDirectory { tempDir in
            let unreadableFile = tempDir.appendingPathComponent("unreadable.enc")
            try Data("ciphertext".utf8).write(to: unreadableFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableFile.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableFile.path)
            }

            expectThrows("load() on chmod 000 file must throw") {
                _ = try SecureFaceStore.load(
                    from: unreadableFile,
                    isSessionUnlocked: { true },
                    decrypt: { $0 }
                )
            }

            let dirAsFile = tempDir.appendingPathComponent("directory-not-file", isDirectory: true)
            try FileManager.default.createDirectory(at: dirAsFile, withIntermediateDirectories: true)
            expectThrows("load() on directory path must throw") {
                _ = try SecureFaceStore.load(
                    from: dirAsFile,
                    isSessionUnlocked: { true },
                    decrypt: { $0 }
                )
            }

            let readOnlyDir = tempDir.appendingPathComponent("readonly-dir", isDirectory: true)
            try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
            let protectedFile = readOnlyDir.appendingPathComponent("locked.enc")
            try Data("ciphertext".utf8).write(to: protectedFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path)
            }

            expectThrows("deleteAll() inside chmod 0555 directory must throw") {
                try SecureFaceStore.deleteAll(at: protectedFile)
            }
            expect(
                FileManager.default.fileExists(atPath: protectedFile.path),
                "File in read-only directory should still exist after failed deleteAll()"
            )

            let missingFile = tempDir.appendingPathComponent("never-created.enc")
            do {
                try SecureFaceStore.deleteAll(at: missingFile)
                expect(true)
            } catch {
                expect(false, "deleteAll() on missing file must not throw, got: \(error)")
            }
        }
    }

    private static func testSecureFaceStoreLegacyDecodingDefaultsIsEnabledTrue() {
        withTemporaryDirectory { tempDir in
            let legacyURL = tempDir.appendingPathComponent("legacy-identities.enc")
            let key = SymmetricKey(size: .bits256)
            let sample = FaceSample(
                embedding: [1, 0],
                pose: "center",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                quality: 0.85
            )
            let legacy = LegacyFaceIdentity(
                id: UUID(),
                name: "LegacyAlice",
                samples: [sample],
                modelIdentifier: MockEmbedder().modelIdentifier,
                embeddingDimension: 2,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let plaintext = try JSONEncoder().encode([legacy])
            let jsonString = String(data: plaintext, encoding: .utf8) ?? ""
            expect(!jsonString.contains("isEnabled"), "Legacy fixture must omit isEnabled key")

            let ciphertext = try sealAESGCM(plaintext, using: key)
            try ciphertext.write(to: legacyURL, options: .atomic)

            let loaded = try SecureFaceStore.load(
                from: legacyURL,
                isSessionUnlocked: { true },
                decrypt: { try openAESGCM($0, using: key) }
            )
            expect(loaded.count == 1, "Legacy file should decode 1 identity")
            expect(loaded.first?.id == legacy.id)
            expect(loaded.first?.name == legacy.name)
            expect(loaded.first?.isEnabled == true, "Missing isEnabled must default to true")
        }
    }

    private static func testReloadFailureAfterSuccessfulLoadBlocksAllWritesAndPreservesCiphertext() {
        withTemporaryDirectory { tempDir in
            let fileURL = tempDir.appendingPathComponent("face-identities.enc")
            let key = SymmetricKey(size: .bits256)
            let alice = makeIdentity(name: "Alice")
            try SecureFaceStore.save(
                [alice],
                to: fileURL,
                isSessionUnlocked: { true },
                encrypt: { try sealAESGCM($0, using: key) }
            )
            let originalCiphertext = try Data(contentsOf: fileURL)

            let spy = StorageSpy(fileURL: fileURL, key: key, isUnlocked: true)
            let store = FaceEnrollmentStore(storage: spy.storage, observeSessionNotifications: false)

            expect(store.loadState == .ready, "Initial load should reach .ready")
            expect(store.isLocked == false)
            expect(store.loadFailure == nil)
            expect(store.identities == [alice])

            spy.loadError = SecureCredentialError.decryptionFailed
            store.reloadIfUnlocked()

            expect(isFailedLoadState(store.loadState), "Reload failure after .ready must move loadState to .failed")
            expect(store.isLocked == false, "Failed state must report isLocked == false")
            expect(store.loadFailure != nil)
            expect(store.identities.isEmpty, "Failed reload must clear published identities")

            let embedder = MockEmbedder()
            let sample = FaceSample(embedding: [0, 1], pose: "center", capturedAt: Date(), quality: 0.9)

            expectThrows("addSample must throw storeUnreadable when failed", verify: isStoreUnreadable) {
                try store.addSample(name: "Bob", embedding: [0, 1], embedder: embedder)
            }

            expectThrows("commitEnrollment(nil) must throw storeUnreadable when failed", verify: isStoreUnreadable) {
                try store.commitEnrollment(replacing: nil, name: "Bob", samples: [sample], embedder: embedder)
            }

            expectThrows(
                "commitEnrollment(existingID) must throw storeUnreadable",
                verify: isStoreUnreadable
            ) {
                try store.commitEnrollment(replacing: alice.id, name: "Alice", samples: [sample], embedder: embedder)
            }

            expectThrows("setEnabled must throw storeUnreadable when failed", verify: isStoreUnreadable) {
                try store.setEnabled(false, for: alice.id)
            }

            expectThrows("delete must throw storeUnreadable when failed", verify: isStoreUnreadable) {
                try store.delete(alice)
            }

            expect(spy.saveCount == 0, "Zero save calls must happen while loadState is .failed")
            let diskAfter = try Data(contentsOf: fileURL)
            expect(diskAfter == originalCiphertext, "Original ciphertext on disk must remain untouched")

            // Also confirm real 1-byte corruption on disk transitions a ready store to .failed on reload
            let corruptURL = tempDir.appendingPathComponent("corrupt.enc")
            try originalCiphertext.write(to: corruptURL, options: .atomic)
            let corruptSpy = StorageSpy(fileURL: corruptURL, key: key, isUnlocked: true)
            let corruptStore = FaceEnrollmentStore(storage: corruptSpy.storage, observeSessionNotifications: false)
            expect(corruptStore.loadState == .ready)
            var tampered = originalCiphertext
            tampered[tampered.count - 1] ^= 0xFF
            try tampered.write(to: corruptURL, options: .atomic)
            corruptStore.reloadIfUnlocked()
            expect(isFailedLoadState(corruptStore.loadState), "Corrupted ciphertext reload must enter .failed")
            expect(corruptStore.identities.isEmpty)
        }
    }

    private static func testWriteFailurePreservesPublishedIdentitiesForAllMutations() {
        withTemporaryDirectory { tempDir in
            let fileURL = tempDir.appendingPathComponent("face-identities.enc")
            let key = SymmetricKey(size: .bits256)
            let alice = makeIdentity(name: "Alice", isEnabled: true)
            try SecureFaceStore.save(
                [alice],
                to: fileURL,
                isSessionUnlocked: { true },
                encrypt: { try sealAESGCM($0, using: key) }
            )

            let spy = StorageSpy(fileURL: fileURL, key: key, isUnlocked: true)
            let store = FaceEnrollmentStore(storage: spy.storage, observeSessionNotifications: false)
            expect(store.loadState == .ready)
            expect(store.identities == [alice])

            spy.saveError = CocoaError(.fileWriteOutOfSpace)
            let embedder = MockEmbedder()
            let sample = FaceSample(embedding: [0, 1], pose: "left", capturedAt: Date(), quality: 0.8)

            expectThrows("addSample on existing identity must propagate write error") {
                try store.addSample(name: "Alice", embedding: [0, 1], embedder: embedder)
            }
            expect(store.identities == [alice], "addSample failure must preserve identities")

            expectThrows("addSample on new identity must propagate write error") {
                try store.addSample(name: "Bob", embedding: [0, 1], embedder: embedder)
            }
            expect(store.identities == [alice], "addSample new identity failure must preserve identities")

            expectThrows("commitEnrollment(replacing: nil) must propagate write error") {
                try store.commitEnrollment(replacing: nil, name: "Bob", samples: [sample], embedder: embedder)
            }
            expect(store.identities == [alice], "commitEnrollment add failure must preserve identities")

            expectThrows("commitEnrollment(replacing: alice.id) must propagate write error") {
                try store.commitEnrollment(replacing: alice.id, name: "Alice 2", samples: [sample], embedder: embedder)
            }
            expect(store.identities == [alice], "commitEnrollment recapture failure must preserve identities")

            expectThrows("setEnabled must propagate write error") {
                try store.setEnabled(false, for: alice.id)
            }
            expect(store.identities == [alice], "setEnabled failure must preserve identities and isEnabled == true")

            expectThrows("delete must propagate write error") {
                try store.delete(alice)
            }
            expect(store.identities == [alice], "delete failure must preserve identities")
        }
    }

    private static func testExplicitDeleteAllPropagatesErrorAndResetsOnlyOnSuccess() {
        withTemporaryDirectory { tempDir in
            let fileURL = tempDir.appendingPathComponent("face-identities.enc")
            let key = SymmetricKey(size: .bits256)
            let alice = makeIdentity(name: "Alice")
            try SecureFaceStore.save(
                [alice],
                to: fileURL,
                isSessionUnlocked: { true },
                encrypt: { try sealAESGCM($0, using: key) }
            )

            let spy = StorageSpy(fileURL: fileURL, key: key, isUnlocked: true)
            let store = FaceEnrollmentStore(storage: spy.storage, observeSessionNotifications: false)
            expect(store.loadState == .ready)
            expect(store.identities == [alice])

            spy.deleteAllError = CocoaError(.fileWriteNoPermission)
            expectThrows("deleteAll failure while ready must throw") {
                try store.deleteAll()
            }
            expect(store.identities == [alice], "Failed deleteAll must not clear identities")
            expect(store.loadState == .ready, "Failed deleteAll must keep loadState == .ready")

            spy.loadError = SecureCredentialError.decryptionFailed
            store.reloadIfUnlocked()
            expect(isFailedLoadState(store.loadState))

            expectThrows("deleteAll failure while failed must throw") {
                try store.deleteAll()
            }
            expect(isFailedLoadState(store.loadState), "Failed deleteAll must not reset loadState to .ready")

            spy.deleteAllError = nil
            spy.loadError = nil
            do {
                try store.deleteAll()
                expect(store.identities.isEmpty, "Successful deleteAll must clear identities")
                expect(store.loadState == .ready, "Successful deleteAll while unlocked must set loadState to .ready")
                expect(store.loadFailure == nil)
                expect(store.isLocked == false)
            } catch {
                expect(false, "Successful deleteAll while unlocked should not throw: \(error)")
            }

            // Re-seed failure and verify deleteAll transitions to .locked when session is locked
            try SecureFaceStore.save(
                [alice],
                to: fileURL,
                isSessionUnlocked: { true },
                encrypt: { try sealAESGCM($0, using: key) }
            )
            spy.loadError = SecureCredentialError.decryptionFailed
            store.reloadIfUnlocked()
            expect(isFailedLoadState(store.loadState))

            spy.isUnlocked = false
            spy.loadError = nil
            do {
                try store.deleteAll()
                expect(store.identities.isEmpty)
                expect(store.loadState == .locked, "Successful deleteAll while locked must set loadState to .locked")
                expect(store.isLocked == true)
                expect(store.loadFailure == nil)
            } catch {
                expect(false, "Successful deleteAll while locked should not throw: \(error)")
            }
        }
    }
}
