//
//  SudoPAMStatus.swift
//  glance
//
//  Pure, SwiftUI-free filesystem and SHA-256 probe for Face-for-sudo PAM setup state.
//

import CryptoKit
import Darwin
import Foundation

/// Snapshot of the installed PAM module, `/etc/pam.d/sudo_local`, trusted bundle
/// location/ownership, and bundled helper availability for Face-for-sudo.
nonisolated struct SudoPAMStatus: Equatable, Sendable {
    static let pamModulePath = "/usr/local/lib/pam/pam_glance.so"
    static let pamConfigPath = "/etc/pam.d/sudo_local"
    static let trustedBundlePath = "/Applications/Glance.app"
    static let trustedExecutablePath = "/Applications/Glance.app/Contents/MacOS/glance"

    enum ModuleState: Equatable, Sendable {
        case installed
        case outdated
        case unsafePermissions
        case notInstalled

        var label: String {
            switch self {
            case .installed: return "Installed"
            case .outdated: return "Update available"
            case .unsafePermissions: return "Unsafe permissions"
            case .notInstalled: return "Not installed"
            }
        }
    }

    enum ConfigState: Equatable, Sendable {
        case configured
        case configuredAfterTouchID
        case notConfigured

        var label: String {
            switch self {
            case .configured: return "Configured"
            case .configuredAfterTouchID: return "After Touch ID"
            case .notConfigured: return "Not configured"
            }
        }
    }

    enum BinaryState: Equatable, Sendable {
        case verified
        case runningOutsideApplications
        case wrongCasing
        case notRootOwned
        case missing

        var label: String {
            switch self {
            case .verified: return "Root-owned"
            case .runningOutsideApplications: return "Outside /Applications"
            case .wrongCasing: return "Wrong casing"
            case .notRootOwned: return "Not root-owned"
            case .missing: return "Not in /Applications"
            }
        }
    }

    enum SetupAction: Equatable, Sendable {
        case installAndRelocate
        case install
        case repair
        case update
        case ready
    }

    let module: ModuleState
    let config: ConfigState
    let trustedBinary: BinaryState
    let hasBundledHelpers: Bool
    let isInstalledArtifactPresent: Bool
    let isApplicationRootOwned: Bool

    var setupAction: SetupAction {
        if module == .installed && config == .configured && trustedBinary == .verified {
            return .ready
        }
        if trustedBinary == .runningOutsideApplications || trustedBinary == .missing {
            return .installAndRelocate
        }
        if module == .outdated && config == .configured && trustedBinary == .verified {
            return .update
        }
        if module == .notInstalled && config == .notConfigured {
            return .install
        }
        return .repair
    }

    var canUninstall: Bool {
        isInstalledArtifactPresent || config != .notConfigured || isApplicationRootOwned
    }

    var requiresRelocation: Bool {
        trustedBinary == .runningOutsideApplications
            || trustedBinary == .wrongCasing
            || trustedBinary == .missing
    }

    static func bundledPAMURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/pam_glance.so")
    }

    static func bundledSetupScriptURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Resources/glance-sudo-setup.sh")
    }

    static func probe(
        pamModulePath: String = pamModulePath,
        pamConfigPath: String = pamConfigPath,
        trustedBundlePath: String = trustedBundlePath,
        runningBundleURL: URL = Bundle.main.bundleURL,
        requireRootOwnership: Bool = true
    ) -> SudoPAMStatus {
        let bundledPAM = bundledPAMURL(in: runningBundleURL)
        let bundledScript = bundledSetupScriptURL(in: runningBundleURL)
        let hasBundledHelpers =
            isRegularReadableFile(atPath: bundledPAM.path)
            && isRegularReadableFile(atPath: bundledScript.path)

        var pamStat = stat()
        let isInstalledArtifactPresent = Darwin.lstat(pamModulePath, &pamStat) == 0
        let isApplicationRootOwned = probeIsApplicationRootOwned(trustedBundlePath: trustedBundlePath)

        return SudoPAMStatus(
            module: probeModule(
                pamModulePath: pamModulePath,
                bundledPAMURL: bundledPAM,
                requireRootOwnership: requireRootOwnership
            ),
            config: probeConfig(pamConfigPath: pamConfigPath),
            trustedBinary: probeTrustedBinary(
                trustedBundlePath: trustedBundlePath,
                runningBundleURL: runningBundleURL,
                requireRootOwnership: requireRootOwnership
            ),
            hasBundledHelpers: hasBundledHelpers,
            isInstalledArtifactPresent: isInstalledArtifactPresent,
            isApplicationRootOwned: isApplicationRootOwned
        )
    }

    private static func probeModule(
        pamModulePath: String,
        bundledPAMURL: URL,
        requireRootOwnership: Bool
    ) -> ModuleState {
        var fileStat = stat()
        guard Darwin.lstat(pamModulePath, &fileStat) == 0 else {
            return .notInstalled
        }
        let isRegular = (fileStat.st_mode & S_IFMT) == S_IFREG
        let isOwnerValid = !requireRootOwnership || fileStat.st_uid == 0
        let notWritableByGroupOrOther = (fileStat.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
        guard isRegular && isOwnerValid && notWritableByGroupOrOther else {
            return .unsafePermissions
        }

        if let installedDigest = sha256Digest(at: URL(fileURLWithPath: pamModulePath)),
            let bundledDigest = sha256Digest(at: bundledPAMURL),
            installedDigest != bundledDigest
        {
            return .outdated
        }
        return .installed
    }

    private static func probeConfig(pamConfigPath: String) -> ConfigState {
        guard let contents = try? String(contentsOfFile: pamConfigPath, encoding: .utf8) else {
            return .notConfigured
        }

        var glanceIndex: Int?
        var tidIndex: Int?
        let lines = contents.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 3, tokens[0] == "auth" else { continue }
            let moduleToken = tokens[2]
            if glanceIndex == nil,
                moduleToken == pamModulePath
                    || moduleToken == "pam_glance.so"
                    || moduleToken.hasSuffix("/pam_glance.so")
            {
                glanceIndex = index
            } else if tidIndex == nil,
                moduleToken == "pam_tid.so" || moduleToken.hasSuffix("/pam_tid.so")
            {
                tidIndex = index
            }
        }

        guard let glanceIndex else { return .notConfigured }
        if let tidIndex, glanceIndex > tidIndex {
            return .configuredAfterTouchID
        }
        return .configured
    }

    private static func probeTrustedBinary(
        trustedBundlePath: String,
        runningBundleURL: URL,
        requireRootOwnership: Bool
    ) -> BinaryState {
        // Resolve the parent directory canonically while preserving the expected "Glance.app" casing
        // so case-insensitive APFS does not mask /Applications/glance.app during comparison.
        let expectedTrustedCanonicalPath = expectedCanonicalPathPreservingLeaf(for: trustedBundlePath)
        let runningCanonicalPath = canonicalPathReservingParents(for: runningBundleURL)

        if runningCanonicalPath != expectedTrustedCanonicalPath {
            if runningCanonicalPath.lowercased() == expectedTrustedCanonicalPath.lowercased() {
                return .wrongCasing
            }
            return .runningOutsideApplications
        }

        let trustedURL = URL(fileURLWithPath: trustedBundlePath, isDirectory: true)
        let requiredDirs = [
            trustedURL.path,
            trustedURL.appendingPathComponent("Contents", isDirectory: true).path,
            trustedURL.appendingPathComponent("Contents/MacOS", isDirectory: true).path
        ]
        var dirStat = stat()
        for dir in requiredDirs {
            guard Darwin.lstat(dir, &dirStat) == 0 else {
                return .missing
            }
            let isDir = (dirStat.st_mode & S_IFMT) == S_IFDIR
            let isOwnerValid = !requireRootOwnership || dirStat.st_uid == 0
            let notWritableByGroupOrOther = (dirStat.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
            guard isDir && isOwnerValid && notWritableByGroupOrOther else {
                return .notRootOwned
            }
        }

        let executableURL = trustedURL.appendingPathComponent("Contents/MacOS/glance")
        var binStat = stat()
        guard Darwin.lstat(executableURL.path, &binStat) == 0 else {
            return .missing
        }
        let isRegular = (binStat.st_mode & S_IFMT) == S_IFREG
        let isOwnerValid = !requireRootOwnership || binStat.st_uid == 0
        let notWritableByGroupOrOther = (binStat.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
        guard isRegular && isOwnerValid && notWritableByGroupOrOther else {
            return .notRootOwned
        }

        // pam_glance.c compares proc_pidpath byte-for-byte against /Applications/Glance.app/Contents/MacOS/glance.
        let canonicalExecutablePath = canonicalPathReservingParents(for: executableURL)
        let expectedExecutableCanonicalPath = expectedTrustedCanonicalPath + "/Contents/MacOS/glance"
        guard canonicalExecutablePath == expectedExecutableCanonicalPath else {
            return .wrongCasing
        }
        return .verified
    }

    private static func probeIsApplicationRootOwned(trustedBundlePath: String) -> Bool {
        var appStat = stat()
        guard Darwin.lstat(trustedBundlePath, &appStat) == 0 else {
            return false
        }
        return (appStat.st_mode & S_IFMT) == S_IFDIR && appStat.st_uid == 0
    }

    private static func isRegularReadableFile(atPath path: String) -> Bool {
        var fileStat = stat()
        guard Darwin.lstat(path, &fileStat) == 0 else {
            return false
        }
        return (fileStat.st_mode & S_IFMT) == S_IFREG && FileManager.default.isReadableFile(atPath: path)
    }

    private static func sha256Digest(at url: URL) -> SHA256.Digest? {
        guard isRegularReadableFile(atPath: url.path),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            return nil
        }
        return SHA256.hash(data: data)
    }

    private static func expectedCanonicalPathPreservingLeaf(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let leaf = url.lastPathComponent
        let resolvedParent = canonicalPathReservingParents(for: parent)
        return URL(fileURLWithPath: resolvedParent, isDirectory: true)
            .appendingPathComponent(leaf).path
    }

    private static func canonicalPathReservingParents(for url: URL) -> String {
        if let canonical = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return canonical
        }
        let parent = url.deletingLastPathComponent()
        let leaf = url.lastPathComponent
        if parent.path == url.path || leaf.isEmpty {
            return url.standardizedFileURL.path
        }
        let resolvedParent = canonicalPathReservingParents(for: parent)
        return URL(fileURLWithPath: resolvedParent, isDirectory: true)
            .appendingPathComponent(leaf).path
    }
}
