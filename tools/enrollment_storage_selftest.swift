//
//  enrollment_storage_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for transactional enrollment storage contracts:
//    1. Keychain existence & orphan classification (`KeychainExistence`, `OrphanedDataClassification`)
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

@main
struct EnrollmentStorageSelfTest {
    static func main() {
        testKeychainExistenceAndOrphanClassification()
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
    }
}
