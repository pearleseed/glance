//
//  SudoPAMStatus.swift
//  glance
//
//  Filesystem probe and reusable status/command row views for `SudoSettingsPage`.
//

import Darwin
import Foundation
import SwiftUI

struct SudoStatusRow: View {
    let title: String
    let path: String
    let badgeText: String
    let badgeColor: Color

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                Text(badgeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(SettingsMetrics.optionPreviewFill)
            .overlay(
                Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .clipShape(Capsule())
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 9)
    }
}

struct SudoCommandRow: View {
    let title: String
    let subtitle: String
    let command: String
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: onCopy) {
                    Text(isCopied ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(SettingsMetrics.neutralButtonFill)
                        .overlay(
                            Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SettingsMetrics.textSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsMetrics.optionPreviewFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 10)
    }
}

struct SudoPAMStatus: Equatable {
    nonisolated static let pamModulePath = "/usr/local/lib/pam/pam_glance.so"
    nonisolated static let pamConfigPath = "/etc/pam.d/sudo_local"
    nonisolated static let trustedExecutablePath = "/Applications/Glance.app/Contents/MacOS/glance"

    enum ModuleState: Equatable {
        case installed
        case unsafePermissions
        case notInstalled

        var label: String {
            switch self {
            case .installed: return "Installed"
            case .unsafePermissions: return "Unsafe permissions"
            case .notInstalled: return "Not installed"
            }
        }

        var color: Color {
            switch self {
            case .installed: return SettingsMetrics.qualityGoodColor
            case .unsafePermissions: return SettingsMetrics.qualityPoorColor
            case .notInstalled: return SettingsMetrics.textTertiary
            }
        }
    }

    enum ConfigState: Equatable {
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

        var color: Color {
            switch self {
            case .configured: return SettingsMetrics.qualityGoodColor
            case .configuredAfterTouchID: return SettingsMetrics.qualityFairColor
            case .notConfigured: return SettingsMetrics.textTertiary
            }
        }
    }

    enum BinaryState: Equatable {
        case verified
        case wrongCasing
        case notRootOwned
        case missing

        var label: String {
            switch self {
            case .verified: return "Root-owned"
            case .wrongCasing: return "Wrong casing"
            case .notRootOwned: return "Not root-owned"
            case .missing: return "Not in /Applications"
            }
        }

        var color: Color {
            switch self {
            case .verified: return SettingsMetrics.qualityGoodColor
            case .wrongCasing, .notRootOwned: return SettingsMetrics.qualityFairColor
            case .missing: return SettingsMetrics.textTertiary
            }
        }
    }

    let module: ModuleState
    let config: ConfigState
    let trustedBinary: BinaryState

    nonisolated static func probe() -> SudoPAMStatus {
        SudoPAMStatus(
            module: probeModule(),
            config: probeConfig(),
            trustedBinary: probeTrustedBinary()
        )
    }

    private nonisolated static func probeModule() -> ModuleState {
        var fileStat = stat()
        guard Darwin.lstat(pamModulePath, &fileStat) == 0 else {
            return .notInstalled
        }
        let isRegular = (fileStat.st_mode & S_IFMT) == S_IFREG
        let isRootOwned = fileStat.st_uid == 0
        let notWritableByGroupOrOther = (fileStat.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
        return (isRegular && isRootOwned && notWritableByGroupOrOther) ? .installed : .unsafePermissions
    }

    private nonisolated static func probeConfig() -> ConfigState {
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
            if glanceIndex == nil, moduleToken == pamModulePath || moduleToken.hasSuffix("/pam_glance.so") {
                glanceIndex = index
            } else if tidIndex == nil, moduleToken == "pam_tid.so" || moduleToken.hasSuffix("/pam_tid.so") {
                tidIndex = index
            }
        }

        guard let glanceIndex else { return .notConfigured }
        if let tidIndex, glanceIndex > tidIndex {
            return .configuredAfterTouchID
        }
        return .configured
    }

    private nonisolated static func probeTrustedBinary() -> BinaryState {
        var dirStat = stat()
        let requiredDirs = [
            "/Applications/Glance.app",
            "/Applications/Glance.app/Contents",
            "/Applications/Glance.app/Contents/MacOS"
        ]
        for dir in requiredDirs {
            guard Darwin.lstat(dir, &dirStat) == 0 else {
                return .missing
            }
            let isDir = (dirStat.st_mode & S_IFMT) == S_IFDIR
            let isRootOwned = dirStat.st_uid == 0
            let notWritableByGroupOrOther = (dirStat.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
            guard isDir && isRootOwned && notWritableByGroupOrOther else {
                return .notRootOwned
            }
        }

        var binStat = stat()
        guard Darwin.lstat(trustedExecutablePath, &binStat) == 0 else {
            return .missing
        }
        let isRegular = (binStat.st_mode & S_IFMT) == S_IFREG
        let isRootOwned = binStat.st_uid == 0
        let notWritableByGroupOrOther = (binStat.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
        guard isRegular && isRootOwned && notWritableByGroupOrOther else {
            return .notRootOwned
        }

        // pam_glance.c compares proc_pidpath byte-for-byte against /Applications/Glance.app/Contents/MacOS/glance,
        // whereas case-insensitive APFS lets lstat succeed on /Applications/glance.app.
        let canonicalPath =
            (try? URL(fileURLWithPath: trustedExecutablePath)
            .resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        guard canonicalPath == trustedExecutablePath else {
            return .wrongCasing
        }
        return .verified
    }
}
