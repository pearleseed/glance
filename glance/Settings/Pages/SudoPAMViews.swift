//
//  SudoPAMViews.swift
//  glance
//
//  Reusable status/command row views and badge color mappings for `SudoSettingsPage`.
//

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

extension SudoPAMStatus.ModuleState {
    var color: Color {
        switch self {
        case .installed: return SettingsMetrics.qualityGoodColor
        case .outdated: return SettingsMetrics.qualityFairColor
        case .unsafePermissions: return SettingsMetrics.qualityPoorColor
        case .notInstalled: return SettingsMetrics.textTertiary
        }
    }
}

extension SudoPAMStatus.ConfigState {
    var color: Color {
        switch self {
        case .configured: return SettingsMetrics.qualityGoodColor
        case .configuredAfterTouchID: return SettingsMetrics.qualityFairColor
        case .notConfigured: return SettingsMetrics.textTertiary
        }
    }
}

extension SudoPAMStatus.BinaryState {
    var color: Color {
        switch self {
        case .verified: return SettingsMetrics.qualityGoodColor
        case .runningOutsideApplications, .wrongCasing, .notRootOwned:
            return SettingsMetrics.qualityFairColor
        case .missing: return SettingsMetrics.textTertiary
        }
    }
}

extension SudoPAMInstaller.ProgressPhase {
    var label: String {
        switch self {
        case .preparing: return "Preparing…"
        case .awaitingAuthorization: return "Waiting for permission…"
        case .restarting: return "Restarting…"
        }
    }
}

struct SudoSecondaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(SettingsMetrics.neutralButtonFill)
                .overlay(
                    Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

struct SudoPhaseProgressView: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsMetrics.textSecondary)
                .lineLimit(1)
        }
    }
}

struct SudoNoticeBanner<Footer: View>: View {
    let systemImage: String
    let iconColor: Color
    let text: String
    @ViewBuilder var footer: () -> Footer

    init(
        systemImage: String,
        iconColor: Color,
        text: String,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.text = text
        self.footer = footer
    }

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .foregroundStyle(iconColor)
                        .padding(.top, 1)

                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer()
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, 10)
        }
    }
}

struct SudoSystemStatusSection: View {
    let pamStatus: SudoPAMStatus?
    let listenerStatusLabel: String
    let listenerStatusColor: Color
    let isRefreshDisabled: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            HStack(spacing: 0) {
                SettingsSectionTitle(text: "System Status")

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshDisabled)
                .opacity(isRefreshDisabled ? 0.4 : 1)
                .help("Refresh PAM status")
                .padding(.trailing, SettingsMetrics.sectionTitleHorizontalInset)
                .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
            }
            .padding(.bottom, -6)

            SettingsGroup {
                SudoStatusRow(
                    title: "PAM module",
                    path: SudoPAMStatus.pamModulePath,
                    badgeText: pamStatus?.module.label ?? "Checking…",
                    badgeColor: pamStatus?.module.color ?? SettingsMetrics.textTertiary
                )
                SettingsGroupDivider()
                SudoStatusRow(
                    title: "PAM configuration",
                    path: SudoPAMStatus.pamConfigPath,
                    badgeText: pamStatus?.config.label ?? "Checking…",
                    badgeColor: pamStatus?.config.color ?? SettingsMetrics.textTertiary
                )
                SettingsGroupDivider()
                SudoStatusRow(
                    title: "Trusted app binary",
                    path: SudoPAMStatus.trustedExecutablePath,
                    badgeText: pamStatus?.trustedBinary.label ?? "Checking…",
                    badgeColor: pamStatus?.trustedBinary.color ?? SettingsMetrics.textTertiary
                )
                SettingsGroupDivider()
                SudoStatusRow(
                    title: "Local socket listener",
                    path: "~/Library/Application Support/glance-sudo/glance-sudo.sock",
                    badgeText: listenerStatusLabel,
                    badgeColor: listenerStatusColor
                )
            }
        }
    }
}

struct SudoManualCommandsSection: View {
    @Binding var isExpanded: Bool
    let requiresRelocation: Bool
    let installCommand: () -> String
    let uninstallCommand: () -> String
    let copiedCommandID: String?
    let onCopy: (String, String) -> Void

    @State private var cachedCommands: (install: String, uninstall: String)?

    private var installTitle: String {
        requiresRelocation ? "Install Glance & PAM module" : "Install PAM module"
    }

    private var installSubtitle: String {
        if requiresRelocation {
            return "Copies Glance to /Applications/Glance.app, installs pam_glance.so, "
                + "and configures /etc/pam.d/sudo_local."
        }
        return "Installs pam_glance.so, configures /etc/pam.d/sudo_local, "
            + "and secures /Applications/Glance.app."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Manual Terminal commands")
                        .font(SettingsMetrics.sectionTitleFont)
                    Spacer()
                }
                .foregroundStyle(SettingsMetrics.textTertiary)
                .padding(.horizontal, SettingsMetrics.sectionTitleHorizontalInset)
                .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                let install = cachedCommands?.install ?? installCommand()
                let uninstall = cachedCommands?.uninstall ?? uninstallCommand()
                SettingsGroup {
                    SudoCommandRow(
                        title: installTitle,
                        subtitle: installSubtitle,
                        command: install,
                        isCopied: copiedCommandID == "install",
                        onCopy: { onCopy(install, "install") }
                    )
                    SettingsGroupDivider()
                    SudoCommandRow(
                        title: "Uninstall PAM module",
                        subtitle:
                            "Removes pam_glance.so, cleans /etc/pam.d/sudo_local, "
                            + "and restores normal ownership on Glance.app.",
                        command: uninstall,
                        isCopied: copiedCommandID == "uninstall",
                        onCopy: { onCopy(uninstall, "uninstall") }
                    )
                }
                .onAppear {
                    if cachedCommands == nil {
                        cachedCommands = (install, uninstall)
                    }
                }
                .onDisappear {
                    cachedCommands = nil
                }
            }
        }
    }
}

struct SudoSetupFeedbackView: View {
    let showMissingHelpersWarning: Bool
    let needsAppManagementPermission: Bool
    let actionError: String?
    let actionMessage: String?
    let onOpenAppManagement: () -> Void

    var body: some View {
        if showMissingHelpersWarning {
            SettingsCaption(
                text:
                    "Bundled PAM helper files are missing from this Glance.app bundle. "
                    + "Reinstall Glance or build from source using the commands in sudo-support/README.md."
            )
        }
        if needsAppManagementPermission {
            SudoNoticeBanner(
                systemImage: "exclamationmark.shield.fill",
                iconColor: SettingsMetrics.qualityFairColor,
                text: actionError
                    ?? "macOS denied permission to update /Applications/Glance.app. "
                    + "Allow Glance under System Settings > Privacy & Security > App Management, "
                    + "or use the manual Terminal commands below."
            ) {
                Button("Open App Management Settings", action: onOpenAppManagement)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GlanceTheme.accent)
                    .padding(.leading, 23)
            }
        } else if let actionError {
            SettingsCaption(text: actionError)
        }
        if let actionMessage {
            SettingsCaption(text: actionMessage)
        }
    }
}
