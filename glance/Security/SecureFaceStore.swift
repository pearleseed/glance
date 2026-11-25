//
//  SecureFaceStore.swift
//  glance
//
//  Low-level encrypted persistence for enrolled face identities — AES-GCM under the same session key SecureCredentialManager
//  uses for the Mac password, rather than a second key. `FaceEnrollmentStore` delegates its load/save here; no plaintext fallback.
//

import Foundation

enum SecureFaceStoreError: LocalizedError {
    case sessionLocked

    var errorDescription: String? {
        switch self {
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID to access enrolled faces."
        }
    }
}

nonisolated enum SecureFaceStore {
    /// Distinct filename/extension so plaintext can never be mistaken for ciphertext.
    static let defaultFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("glance", isDirectory: true)
        return directory.appendingPathComponent("face-identities.enc")
    }()

    /// True if a store exists on disk, regardless of whether the session is currently unlocked enough to read it.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: defaultFileURL.path)
    }

    /// Throws `.sessionLocked` rather than returning an empty array, so callers can distinguish "nothing enrolled" from "enrolled, but locked".
    /// Missing files return `[]`; all other read, permission, decryption, and JSON decoding errors propagate to the caller.
    static func load(
        from url: URL = defaultFileURL,
        isSessionUnlocked: () -> Bool = { SecureCredentialManager.isSessionUnlocked },
        decrypt: (Data) throws -> Data = { try SecureCredentialManager.decrypt($0) }
    ) throws -> [FaceIdentity] {
        guard isSessionUnlocked() else { throw SecureFaceStoreError.sessionLocked }
        let ciphertext: Data
        do {
            ciphertext = try Data(contentsOf: url)
        } catch {
            if isFileNotFoundError(error) {
                return []
            }
            throw error
        }
        let plaintext = try decrypt(ciphertext)
        return try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
    }

    static func save(
        _ identities: [FaceIdentity],
        to url: URL = defaultFileURL,
        isSessionUnlocked: () -> Bool = { SecureCredentialManager.isSessionUnlocked },
        encrypt: (Data) throws -> Data = { try SecureCredentialManager.encrypt($0) }
    ) throws {
        guard isSessionUnlocked() else { throw SecureFaceStoreError.sessionLocked }
        let plaintext = try JSONEncoder().encode(identities)
        let ciphertext = try encrypt(plaintext)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ciphertext.write(to: url, options: .atomic)
    }

    static func deleteAll(at url: URL = defaultFileURL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if isFileNotFoundError(error) {
                return
            }
            throw error
        }
    }

    private static func isFileNotFoundError(_ error: Error) -> Bool {
        var current: Error? = error
        for _ in 0..<8 {
            guard let err = current else { return false }
            if let cocoaError = err as? CocoaError,
                cocoaError.code == .fileReadNoSuchFile || cocoaError.code == .fileNoSuchFile
            {
                return true
            }
            if let posixError = err as? POSIXError, posixError.code == .ENOENT {
                return true
            }
            current = (err as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }
}
