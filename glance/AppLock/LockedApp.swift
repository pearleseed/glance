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
        return !AppLockBlacklist.isProtected(trimmed)
    }

    var isCautionApp: Bool {
        AppLockBlacklist.isCautionApp(bundleIdentifier)
    }

    /// Reads bundle metadata from an `.app` URL, returning `nil` if the bundle lacks an ID or is protected.
    static func fromBundle(at url: URL) -> LockedApp? {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let bundle = Bundle(url: resolvedURL) ?? Bundle(url: url),
              let bundleID = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              canLock(bundleIdentifier: bundleID)
        else { return nil }

        let displayName = displayName(for: bundle, url: url)
        return LockedApp(bundleIdentifier: bundleID, name: displayName, path: url.path)
    }

    static func displayName(for bundle: Bundle, url: URL) -> String {
        let info = bundle.infoDictionary
        if let localized = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String, !localized.isEmpty {
            return localized
        }
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty {
            return display
        }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty {
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
        if let runningIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.icon {
            return runningIcon
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
