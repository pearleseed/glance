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

    @State private var pamStatus: SudoPAMStatus?
    @State private var probeGeneration: UInt64 = 0
    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var copiedCommandID: String?

    private static let installCommand = "sudo bash sudo-support/install.sh"
    private static let chownCommand = "sudo chown -R root:wheel /Applications/Glance.app"
    private static let uninstallCommand = "sudo bash sudo-support/uninstall.sh"

    private var hasUnlockCapableEmbedder: Bool {
        let pipeline = environment.recognitionPipeline
        return pipeline.loadState == .loading || pipeline.isUnlockCapable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(
                    title: "Face authentication for sudo",
                    subtitle:
                        "Authorize local sudo commands with your face and Heavy Liveness before Touch ID or password.",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    GlanceToggle(
                        isOn: Binding(
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

            if pamStatus?.trustedBinary == .wrongCasing {
                SettingsCaption(
                    text:
                        "Bundle path casing mismatch: pam_glance.so requires the exact path "
                        + "/Applications/Glance.app (capital G). Rename or install /Applications/glance.app "
                        + "as /Applications/Glance.app."
                )
            }

            if !environment.pocController.isSessionUnlocked {
                SettingsCaption(
                    text:
                        "Glance session is locked — Face-for-sudo is paused until you unlock your session "
                        + "on Face or Password. Touch ID and password still work in Terminal."
                )
            } else if enrollmentStore.activeIdentities.isEmpty {
                SettingsCaption(
                    text:
                        "No active enrolled face — enroll or enable a face on the Face tab before using Face-for-sudo.")
            } else if !hasUnlockCapableEmbedder {
                SettingsCaption(text: "Discriminative face model unavailable — Face-for-sudo is disabled for safety.")
            }

            statusHeader
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
                text:
                    "Heavy Liveness is always enforced for sudo regardless of your Recognition settings. "
                    + "SSH/remote sessions and root (uid 0) are always refused, and sudo falls back "
                    + "automatically to Touch ID or password whenever face verification does not pass."
            )
            .padding(.top, 2)
        }
        .onAppear {
            environment.pocController.refreshCredentialStatus()
            enrollmentStore.reloadIfUnlocked()
        }
        .task {
            await refreshStatus()
        }
        .onDisappear {
            authError = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            triggerRefreshStatus()
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 0) {
            SettingsSectionTitle(text: "System Status")

            Button {
                triggerRefreshStatus()
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

                Text(
                    "2D Camera Security Warning: Glance uses a standard 2D RGB webcam rather than infrared "
                        + "depth hardware. Even with Heavy Liveness enforced, a 2D camera cannot reliably defeat "
                        + "a high-resolution video replay attack. Leave Face-for-sudo off unless you accept this "
                        + "risk for local convenience."
                )
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

    private func triggerRefreshStatus() {
        Task {
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        probeGeneration &+= 1
        let token = probeGeneration
        environment.syncSudoAuthServer()

        let probed = await Task.detached(priority: .utility) {
            SudoPAMStatus.probe()
        }.value

        guard !Task.isCancelled, token == probeGeneration else { return }
        pamStatus = probed
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
