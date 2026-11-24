//
//  UnlockLog.swift
//  glance
//
//  Shared structured OSLog handle for lock-screen trigger, credential, and injection diagnostics.
//  Never log password bytes, key material, or sensitive user text through this logger.
//

import OSLog

enum UnlockLog {
    nonisolated static let logger = Logger(subsystem: "com.pearleseed.glance", category: "unlock")
}
