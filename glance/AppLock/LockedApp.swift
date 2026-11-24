//
//  LockedApp.swift
//  glance
//
//  Persisted user entry for an application guarded by App Lock.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

nonisolated struct LockedApp: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var name: String
    var path: String?
    var relockPolicyOverride: RelockPolicy?

    init(
        bundleIdentifier: String,
        name: String,
        path: String? = nil,
        relockPolicyOverride: RelockPolicy? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.relockPolicyOverride = relockPolicyOverride
    }

    static func canLock(bundleIdentifier: String) -> Bool {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.caseInsensitiveCompare("com.pearleseed.glance") == .orderedSame {
            return false
        }
        return !AppLockBlacklist.isProtected(trimmed)
    }

    var isCautionApp: Bool {
        AppLockBlacklist.isCautionApp(bundleIdentifier)
    }

    /// Reads bundle metadata from an `.app` URL via `Contents/Info.plist`, returning `nil` if invalid or protected.
    static func fromBundle(at url: URL) -> LockedApp? {
        guard let info = infoDictionary(at: url),
            let rawID = info["CFBundleIdentifier"] as? String
        else { return nil }
        let bundleID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canLock(bundleIdentifier: bundleID) else { return nil }

        let displayName = displayName(from: info, url: url)
        return LockedApp(bundleIdentifier: bundleID, name: displayName, path: url.path)
    }

    /// Reads `Contents/Info.plist` directly via `PropertyListSerialization` to avoid `Bundle(url:)` cache retention.
    static func infoDictionary(at url: URL) -> [String: Any]? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let candidates = resolvedURL == url ? [url] : [resolvedURL, url]
        for baseURL in candidates {
            let plistURL =
                baseURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist", isDirectory: false)
            if let data = try? Data(contentsOf: plistURL),
                let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                let dict = plist as? [String: Any]
            {
                return dict
            }
        }
        return nil
    }

    static func displayName(from info: [String: Any], url: URL) -> String {
        if let display = (info["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !display.isEmpty
        {
            return display
        }
        if let name = (info["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

@MainActor
extension LockedApp {
    /// Resolves the app icon from disk, LaunchServices, running process, or fallback symbol.
    func resolvedIcon() -> NSImage {
        if let path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let runningIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?
            .icon
        {
            return runningIcon
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
