//
//  InstalledApps.swift
//  glance
//
//  Asynchronously discovers lockable macOS applications for instant picker search.
//

import Foundation
import Observation

nonisolated struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let path: String

    var isCautionApp: Bool {
        AppLockBlacklist.isCautionApp(bundleIdentifier)
    }

    func toLockedApp() -> LockedApp {
        LockedApp(bundleIdentifier: bundleIdentifier, name: name, path: path)
    }
}

@Observable
@MainActor
final class InstalledApps {
    static let shared = InstalledApps()

    private(set) var apps: [InstalledApp] = []
    private(set) var isScanning = false
    private var scanGeneration: UInt64 = 0
    private var lastRefreshedAt: ContinuousClock.Instant?

    init() {}

    /// Refreshes the discovered app list only when empty, unscanned, or older than `maxAge`.
    func refreshIfNeeded(maxAge: TimeInterval = 60) async {
        if !apps.isEmpty,
            let lastRefreshedAt,
            ContinuousClock.now - lastRefreshedAt < .seconds(maxAge)
        {
            return
        }
        await refresh()
    }

    /// Rescans `/Applications`, `/System/Applications`, and `~/Applications` off the main actor.
    func refresh() async {
        scanGeneration &+= 1
        let token = scanGeneration
        isScanning = true

        let discovered = await Task.detached(priority: .userInitiated) {
            Self.scanInstalledApplications()
        }.value

        guard token == scanGeneration else { return }
        apps = discovered
        lastRefreshedAt = ContinuousClock.now
        isScanning = false
    }

    /// Filters discovered applications by localized name or bundle identifier.
    func search(_ query: String) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Reads app metadata directly from `Contents/Info.plist` without allocating a `Bundle(url:)`.
    nonisolated static func readAppMetadata(at url: URL) -> InstalledApp? {
        guard let info = LockedApp.infoDictionary(at: url),
            let rawBundleID = (info["CFBundleIdentifier"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            LockedApp.canLock(bundleIdentifier: rawBundleID),
            !isBackgroundOnlyOrAgent(info)
        else { return nil }

        let name = LockedApp.displayName(from: info, url: url)
        return InstalledApp(
            bundleIdentifier: rawBundleID,
            name: name,
            path: url.path
        )
    }

    nonisolated private static func scanInstalledApplications() -> [InstalledApp] {
        let fileManager = FileManager.default
        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var byLowerBundleID: [String: InstalledApp] = [:]
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]

        for root in searchRoots {
            guard fileManager.fileExists(atPath: root.path),
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                    let app = readAppMetadata(at: url)
                else { continue }

                let dedupKey = app.bundleIdentifier.lowercased()
                if byLowerBundleID[dedupKey] != nil { continue }
                byLowerBundleID[dedupKey] = app
            }
        }

        return byLowerBundleID.values.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.bundleIdentifier < rhs.bundleIdentifier
        }
    }

    nonisolated private static func isBackgroundOnlyOrAgent(_ info: [String: Any]) -> Bool {
        isTruthyPlistFlag(info["LSBackgroundOnly"]) || isTruthyPlistFlag(info["LSUIElement"])
    }

    nonisolated private static func isTruthyPlistFlag(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        }
        return false
    }
}
