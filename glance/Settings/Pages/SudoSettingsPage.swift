//
//  SudoSettingsPage.swift
//  glance
//
//  Settings tab for opt-in Face-for-sudo PAM authentication: toggle (default false),
//  live detection of /usr/local/lib/pam/pam_glance.so, /etc/pam.d/sudo_local, and the
//  root-owned Glance binary, one-line install/uninstall commands, and 2D camera caveat.
//

import AppKit
import Darwin
import SwiftUI

struct SudoSettingsPage: View {
    let environment: AppEnvironment
    @Bindable private var settings = GlanceSettings.shared
    @Bindable private var enrollmentStore = FaceEnrollmentStore.shared

    @State private var pamStatus = SudoPAMStatus.probe()
    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var copiedCommandID: String?

    private static let installCommand = "sudo bash sudo-support/install.sh"
    private static let chownCommand = "sudo chown -R root:wheel /Applications/Glance.app"
    private static let uninstallCommand = "sudo bash sudo-support/uninstall.sh"

    private var hasUnlockCapableEmbedder: Bool {
        let pipeline = environment.faceUnlockCoordinator.pipeline
        return !pipeline.usingFallbackEmbedder && pipeline.embedder.isUnlockCapable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(
                    title: "Face authentication for sudo",
                    subtitle: "Authorize local sudo commands with your face and Heavy Liveness before Touch ID or password.",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    GlanceToggle(isOn: Binding(
                        get: { settings.sudoFaceAuthEnabled },
                        set: { newValue in
                            handleToggleChange(newValue)
                        }
                    ))
                }
            }

            if let authError {
                SettingsCaption(text: authError)
            } else if let serverError = environment.sudoServerError {
                SettingsCaption(text: "Socket listener error: \(serverError)")
            }

            if !environment.pocController.isSessionUnlocked {
                SettingsCaption(text: "Glance session is locked — Face-for-sudo is paused until you unlock your session on Face or Password. Touch ID and password still work in Terminal.")
            } else if enrollmentStore.activeIdentities.isEmpty {
                SettingsCaption(text: "No active enrolled face — enroll or enable a face on the Face tab before using Face-for-sudo.")
            } else if !hasUnlockCapableEmbedder {
                SettingsCaption(text: "Discriminative face model unavailable — Face-for-sudo is disabled for safety.")
            }

            statusHeader
                .padding(.bottom, -6)

            SettingsGroup {
                SudoStatusRow(
                    title: "PAM module",
                    path: SudoPAMStatus.pamModulePath,
                    badgeText: pamStatus.module.label,
                    badgeColor: pamStatus.module.color
                )

                SettingsGroupDivider()

                SudoStatusRow(
                    title: "PAM configuration",
                    path: SudoPAMStatus.pamConfigPath,
                    badgeText: pamStatus.config.label,
                    badgeColor: pamStatus.config.color
                )

                SettingsGroupDivider()

                SudoStatusRow(
                    title: "Trusted app binary",
                    path: SudoPAMStatus.trustedExecutablePath,
                    badgeText: pamStatus.trustedBinary.label,
                    badgeColor: pamStatus.trustedBinary.color
                )

                SettingsGroupDivider()

                SudoStatusRow(
                    title: "Local socket listener",
                    path: "~/Library/Application Support/glance-sudo/glance-sudo.sock",
                    badgeText: listenerStatusLabel,
                    badgeColor: listenerStatusColor
                )
            }

            SettingsSectionTitle(text: "Setup Commands")
                .padding(.bottom, -6)

            SettingsGroup {
                SudoCommandRow(
                    title: "Install PAM module",
                    subtitle: "Run from the Glance repository root to compile and configure /etc/pam.d/sudo_local.",
                    command: Self.installCommand,
                    isCopied: copiedCommandID == "install",
                    onCopy: { copyCommand(Self.installCommand, id: "install") }
                )

                SettingsGroupDivider()

                SudoCommandRow(
                    title: "Grant root ownership to Glance.app",
                    subtitle: "Required so pam_glance.so trusts /Applications/Glance.app/Contents/MacOS/glance.",
                    command: Self.chownCommand,
                    isCopied: copiedCommandID == "chown",
                    onCopy: { copyCommand(Self.chownCommand, id: "chown") }
                )

                SettingsGroupDivider()

                SudoCommandRow(
                    title: "Uninstall PAM module",
                    subtitle: "Removes pam_glance.so and cleans /etc/pam.d/sudo_local while preserving Touch ID.",
                    command: Self.uninstallCommand,
                    isCopied: copiedCommandID == "uninstall",
                    onCopy: { copyCommand(Self.uninstallCommand, id: "uninstall") }
                )
            }

            securityCaveatBanner

            SettingsCaption(
                text: "Heavy Liveness is always enforced for sudo regardless of your Recognition settings. SSH/remote sessions and root (uid 0) are always refused, and sudo falls back automatically to Touch ID or password whenever face verification does not pass."
            )
            .padding(.top, 2)
        }
        .onAppear {
            environment.pocController.refreshCredentialStatus()
            enrollmentStore.reloadIfUnlocked()
            refreshStatus()
        }
        .onDisappear {
            authError = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 0) {
            SettingsSectionTitle(text: "System Status")

            Button {
                refreshStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh PAM status")
            .padding(.trailing, SettingsMetrics.sectionTitleHorizontalInset)
            .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
        }
    }

    private var securityCaveatBanner: some View {
        SettingsGroup {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsMetrics.qualityFairColor)
                    .padding(.top, 1)

                Text("2D Camera Security Warning: Glance uses a standard 2D RGB webcam rather than infrared depth hardware. Even with Heavy Liveness enforced, a 2D camera cannot reliably defeat a high-resolution video replay attack. Leave Face-for-sudo off unless you accept this risk for local convenience.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, 10)
        }
    }

    private var listenerStatusLabel: String {
        if environment.isSudoServerListening {
            return "Listening"
        }
        if settings.sudoFaceAuthEnabled && environment.sudoServerError != nil {
            return "Error"
        }
        return "Off"
    }

    private var listenerStatusColor: Color {
        if environment.isSudoServerListening {
            return SettingsMetrics.qualityGoodColor
        }
        if settings.sudoFaceAuthEnabled && environment.sudoServerError != nil {
            return SettingsMetrics.qualityPoorColor
        }
        return SettingsMetrics.textTertiary
    }

    private func refreshStatus() {
        pamStatus = SudoPAMStatus.probe()
        environment.syncSudoAuthServer()
    }

    private func handleToggleChange(_ enable: Bool) {
        authError = nil
        if !enable {
            settings.sudoFaceAuthEnabled = false
            environment.syncSudoAuthServer()
            return
        }

        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let outcome = await SystemAuthentication.authenticate(
                reason: "Authenticate to enable Face authentication for sudo"
            )
            isAuthenticating = false
            switch outcome {
            case .authenticated:
                settings.sudoFaceAuthEnabled = true
                environment.syncSudoAuthServer()
            case .cancelled:
                break
            case .failed(let message):
                authError = message
            }
        }
    }

    private func copyCommand(_ command: String, id: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copiedCommandID = id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedCommandID == id {
                copiedCommandID = nil
            }
        }
    }
}

// MARK: - Subviews

private struct SudoStatusRow: View {
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

private struct SudoCommandRow: View {
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

// MARK: - PAM Status Probe

private struct SudoPAMStatus: Equatable {
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
        case notRootOwned
        case missing

        var label: String {
            switch self {
            case .verified: return "Root-owned"
            case .notRootOwned: return "Not root-owned"
            case .missing: return "Not in /Applications"
            }
        }

        var color: Color {
            switch self {
            case .verified: return SettingsMetrics.qualityGoodColor
            case .notRootOwned: return SettingsMetrics.qualityFairColor
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
        var st = stat()
        guard Darwin.lstat(pamModulePath, &st) == 0 else {
            return .notInstalled
        }
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG
        let isRootOwned = st.st_uid == 0
        let notWritableByGroupOrOther = (st.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
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
            "/Applications/Glance.app/Contents/MacOS",
        ]
        for dir in requiredDirs {
            guard Darwin.lstat(dir, &dirStat) == 0 else {
                return .missing
            }
            guard (dirStat.st_mode & S_IFMT) == S_IFDIR else {
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
        return (isRegular && isRootOwned && notWritableByGroupOrOther) ? .verified : .notRootOwned
    }
}
