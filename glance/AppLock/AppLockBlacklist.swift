//
//  AppLockBlacklist.swift
//  glance
//

import Foundation

/// Prevents Glance from locking itself or critical macOS recovery tools, and flags apps that deserve a caution banner.
nonisolated enum AppLockBlacklist: Sendable {  // swiftlint:disable:this inclusive_language
    /// System and recovery applications that are hard-blocked from App Lock.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.SystemSettings",
        "com.apple.systempreferences",
        "com.apple.Terminal",
        "com.apple.ActivityMonitor"
    ]

    /// Third-party terminals and IDEs that are allowed to be locked but show a recovery caution note in Settings.
    static let cautionBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode"
    ]

    private static let protectedLowercased = Set(protectedBundleIDs.map { $0.lowercased() })
    private static let cautionLowercased = Set(cautionBundleIDs.map { $0.lowercased() })

    /// Returns `true` when `bundleID` is a protected system/recovery app or matches `ownBundleID`.
    static func isProtected(_ bundleID: String, ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        let normalized = normalize(bundleID)
        guard !normalized.isEmpty else { return false }
        if let ownBundleID {
            let normalizedOwn = normalize(ownBundleID)
            if !normalizedOwn.isEmpty, normalized == normalizedOwn {
                return true
            }
        }
        return protectedLowercased.contains(normalized)
    }

    /// Returns `true` when locking `bundleID` is permitted but warrants a caution warning.
    static func isCautionApp(_ bundleID: String) -> Bool {
        let normalized = normalize(bundleID)
        guard !normalized.isEmpty else { return false }
        return cautionLowercased.contains(normalized)
    }

    private static func normalize(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
