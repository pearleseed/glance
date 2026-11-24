//
//  SudoSettingsPage.swift
//  glance
//
//  Settings tab for opt-in Face-for-sudo PAM authentication: toggle (default false),
//  live detection of /usr/local/lib/pam/pam_glance.so, /etc/pam.d/sudo_local, and the
//  trusted Glance binary, 1-click setup/repair/update/uninstall, collapsed manual
//  Terminal commands, and 2D camera security caveat.
//

import AppKit
import SwiftUI

private enum SudoRunningAction {
    case installOrRepair
    case uninstall
}

private struct SudoStatusWarningCaptions: View {
    let authError: String?
    let sudoServerError: String?
    let isWrongCasing: Bool
    let isSessionUnlocked: Bool
    let hasActiveIdentities: Bool
    let hasUnlockCapableEmbedder: Bool

    var body: some View {
        if let authError {
            SettingsCaption(text: authError)
        } else if let sudoServerError {
            SettingsCaption(text: "Socket listener error: \(sudoServerError)")
        }
        if isWrongCasing {
            SettingsCaption(
                text:
                    "Bundle path casing mismatch: pam_glance.so requires the exact path "
                    + "/Applications/Glance.app (capital G). Rename or install /Applications/glance.app "
                    + "as /Applications/Glance.app."
            )
        }
        if !isSessionUnlocked {
            SettingsCaption(
                text:
                    "Glance session is locked — Face-for-sudo is paused until you unlock your session "
                    + "on Face or Password. Touch ID and password still work in Terminal."
            )
        } else if !hasActiveIdentities {
            SettingsCaption(
                text: "No active enrolled face — enroll or enable a face on the Face tab before using Face-for-sudo."
            )
        } else if !hasUnlockCapableEmbedder {
            SettingsCaption(text: "Discriminative face model unavailable — Face-for-sudo is disabled for safety.")
        }
    }
}

private struct SudoSecurityNoticeView: View {
    var body: some View {
        SudoNoticeBanner(
            systemImage: "exclamationmark.triangle.fill",
            iconColor: SettingsMetrics.qualityFairColor,
            text:
                "2D Camera Security Warning: Glance uses a standard 2D RGB webcam rather than infrared "
                + "depth hardware. Even with Heavy Liveness enforced, a 2D camera cannot reliably defeat "
                + "a high-resolution video replay attack. Leave Face-for-sudo off unless you accept this "
                + "risk for local convenience."
        )

        SettingsCaption(
            text:
                "Heavy Liveness is always enforced for sudo regardless of your Recognition settings. "
                + "SSH/remote sessions and root (uid 0) are always refused, and sudo falls back "
                + "automatically to Touch ID or password whenever face verification does not pass."
        )
        .padding(.top, 2)
    }
}

struct SudoSettingsPage: View {
    let environment: AppEnvironment
    @Bindable private var settings = GlanceSettings.shared
    @Bindable private var enrollmentStore = FaceEnrollmentStore.shared

    @State private var pamStatus: SudoPAMStatus?
    @State private var probeGeneration: UInt64 = 0
    @State private var isAuthenticating = false
    @State private var isUnlockingSession = false
    @State private var authError: String?
    @State private var runningAction: SudoRunningAction?
    @State private var activePhase: SudoPAMInstaller.ProgressPhase?
    @State private var actionMessage: String?
    @State private var actionError: String?
    @State private var needsAppManagementPermission = false
    @State private var showManualCommands = false
    @State private var copiedCommandID: String?

    private var isRunningAction: Bool { runningAction != nil }
    private var isBusy: Bool { isRunningAction || isAuthenticating || isUnlockingSession }

    private var hasUnlockCapableEmbedder: Bool {
        let pipeline = environment.recognitionPipeline
        return pipeline.loadState == .loading || pipeline.isUnlockCapable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            toggleGroup

            SudoStatusWarningCaptions(
                authError: authError,
                sudoServerError: environment.sudoServerError,
                isWrongCasing: pamStatus?.trustedBinary == .wrongCasing,
                isSessionUnlocked: environment.pocController.isSessionUnlocked,
                hasActiveIdentities: !enrollmentStore.activeIdentities.isEmpty,
                hasUnlockCapableEmbedder: hasUnlockCapableEmbedder
            )

            SudoSystemStatusSection(
                pamStatus: pamStatus,
                listenerStatusLabel: listenerStatus.label,
                listenerStatusColor: listenerStatus.color,
                isRefreshDisabled: isBusy,
                onRefresh: triggerRefreshStatus
            )

            SettingsSectionTitle(text: "Setup")
                .padding(.bottom, -6)
            setupGroup

            SudoSetupFeedbackView(
                showMissingHelpersWarning: pamStatus.map { !$0.hasBundledHelpers && $0.setupAction != .ready } ?? false,
                needsAppManagementPermission: needsAppManagementPermission,
                actionError: actionError,
                actionMessage: actionMessage,
                onOpenAppManagement: SudoPAMInstaller.openAppManagementSettings
            )

            SudoManualCommandsSection(
                isExpanded: $showManualCommands,
                requiresRelocation: pamStatus?.requiresRelocation == true,
                installCommand: SudoPAMInstaller.manualInstallCommand,
                uninstallCommand: SudoPAMInstaller.manualUninstallCommand,
                copiedCommandID: copiedCommandID,
                onCopy: copyCommand
            )

            SudoSecurityNoticeView()
        }
        .onAppear {
            environment.pocController.refreshCredentialStatus()
            enrollmentStore.reloadIfUnlocked()
        }
        .task { await refreshStatus() }
        .onChange(of: environment.pocController.isSessionUnlocked) { _, isUnlocked in
            if isUnlocked { enrollmentStore.reloadIfUnlocked() }
            environment.syncSudoAuthServer()
        }
        .onDisappear { authError = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !isBusy else { return }
            environment.pocController.refreshCredentialStatus()
            triggerRefreshStatus()
        }
    }

    private var toggleGroup: some View {
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
                        set: { handleToggleChange($0) }
                    )
                )
                .disabled(isBusy)
            }
        }
    }

    private var setupGroup: some View {
        SettingsGroup {
            if let status = pamStatus {
                primarySetupRow(for: status)
                if status.canUninstall {
                    SettingsGroupDivider()
                    uninstallRow
                }
            } else {
                SettingsRowContent(
                    title: "Checking setup status…",
                    subtitle: "Inspecting PAM module, configuration, and /Applications/Glance.app.",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func primarySetupRow(for status: SudoPAMStatus) -> some View {
        let descriptor = SudoSetupDescriptor.resolve(
            for: SudoSetupDescriptor.Context(
                status: status,
                isSessionUnlocked: environment.pocController.isSessionUnlocked,
                isUnlockingSession: isUnlockingSession,
                hasActiveIdentities: !enrollmentStore.activeIdentities.isEmpty,
                hasUnlockCapableEmbedder: hasUnlockCapableEmbedder,
                sudoFaceAuthEnabled: settings.sudoFaceAuthEnabled
            )
        )

        return SettingsRowContent(
            title: descriptor.title,
            subtitle: descriptor.subtitle,
            subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
        ) {
            primarySetupTrailing(for: descriptor, hasBundledHelpers: status.hasBundledHelpers)
        }
    }

    @ViewBuilder
    private func primarySetupTrailing(
        for descriptor: SudoSetupDescriptor,
        hasBundledHelpers: Bool
    ) -> some View {
        if runningAction == .installOrRepair {
            SudoPhaseProgressView(label: activePhase?.label ?? "Preparing…")
        } else {
            switch descriptor.trailing {
            case .primaryButton(let title, let isSetupAction):
                SettingsPrimaryButton(
                    title: title,
                    isEnabled: isSetupAction ? (!isBusy && hasBundledHelpers) : !isBusy,
                    compact: true
                ) {
                    if isSetupAction {
                        runInstallOrRepair()
                    } else {
                        unlockSessionForSudo()
                    }
                }
            case .symbol(let name, let color):
                Image(systemName: name)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
            }
        }
    }

    private var uninstallRow: some View {
        SettingsRowContent(
            title: "Uninstall PAM module",
            subtitle:
                "Removes pam_glance.so, cleans /etc/pam.d/sudo_local, "
                + "and restores normal ownership on Glance.app.",
            subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
        ) {
            if runningAction == .uninstall {
                SudoPhaseProgressView(label: activePhase?.label ?? "Preparing…")
            } else {
                SudoSecondaryButton(title: "Uninstall", isEnabled: !isBusy, action: runUninstall)
            }
        }
    }

    private var listenerStatus: (label: String, color: Color) {
        if environment.isSudoServerListening {
            return ("Listening", SettingsMetrics.qualityGoodColor)
        }
        if settings.sudoFaceAuthEnabled && environment.sudoServerError != nil {
            return ("Error", SettingsMetrics.qualityPoorColor)
        }
        return ("Off", SettingsMetrics.textTertiary)
    }

    private func triggerRefreshStatus() {
        guard !isBusy else { return }
        Task { await refreshStatus() }
    }

    private func refreshStatus() async {
        probeGeneration &+= 1
        let token = probeGeneration
        environment.syncSudoAuthServer()
        let probed = await Task.detached(priority: .utility) { SudoPAMStatus.probe() }.value
        guard !Task.isCancelled, token == probeGeneration else { return }
        let previousStatus = pamStatus
        pamStatus = probed
        if probed.setupAction == .ready {
            needsAppManagementPermission = false
            actionError = nil
        }
        if let previousStatus, probed != previousStatus {
            actionMessage = nil
        }
    }

    private func runInstallOrRepair() {
        runPrivilegedAction(.installOrRepair) {
            let outcome = await SudoPAMInstaller.installOrRepair { activePhase = $0 }
            await handleActionOutcome(outcome, isInstall: true)
        }
    }

    private func runUninstall() {
        runPrivilegedAction(.uninstall) {
            let outcome = await SudoPAMInstaller.uninstall { activePhase = $0 }
            await handleActionOutcome(outcome, isInstall: false)
        }
    }

    private func runPrivilegedAction(
        _ action: SudoRunningAction,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard !isBusy else { return }
        runningAction = action
        activePhase = .preparing
        actionMessage = nil
        actionError = nil
        needsAppManagementPermission = false
        Task { await operation() }
    }

    private func handleActionOutcome(_ outcome: SudoPAMInstallOutcome, isInstall: Bool) async {
        switch outcome {
        case .succeeded(let requiresRelaunch):
            if isInstall {
                await finishInstallSuccess(requiresRelaunch: requiresRelaunch)
            } else {
                settings.sudoFaceAuthEnabled = false
                environment.syncSudoAuthServer()
                await refreshStatus()
                finishAction()
                actionMessage = "Face-for-sudo PAM module removed."
            }
        case .cancelled:
            finishAction()
        case .needsAppManagementPermission(let detail):
            await refreshStatus()
            finishAction()
            needsAppManagementPermission = true
            actionError = detail
            showManualCommands = true
        case .failed(let detail):
            await refreshStatus()
            finishAction()
            actionError = detail
        }
    }

    private func finishInstallSuccess(requiresRelaunch: Bool) async {
        if environment.pocController.isSessionUnlocked,
            !enrollmentStore.activeIdentities.isEmpty,
            hasUnlockCapableEmbedder
        {
            settings.sudoFaceAuthEnabled = true
        }

        if requiresRelaunch {
            activePhase = .restarting
            if SudoPAMInstaller.relaunchInstalledApp(openTab: .sudo) {
                return
            }
            environment.syncSudoAuthServer()
            await refreshStatus()
            finishAction()
            actionMessage = "Setup complete. Quit this copy and open /Applications/Glance.app to finish."
            return
        }

        environment.syncSudoAuthServer()
        await refreshStatus()
        finishAction()
        actionMessage = "Face-for-sudo is installed and ready."
    }

    private func finishAction() {
        runningAction = nil
        activePhase = nil
    }

    private func unlockSessionForSudo() {
        guard !isBusy else { return }
        isUnlockingSession = true
        actionError = nil
        Task {
            await environment.pocController.unlockSession()
            enrollmentStore.reloadIfUnlocked()
            environment.syncSudoAuthServer()
            if let sessionError = environment.pocController.sessionError {
                actionError = sessionError
            }
            isUnlockingSession = false
        }
    }

    private func handleToggleChange(_ enable: Bool) {
        guard !isBusy else { return }
        authError = nil
        if !enable {
            settings.sudoFaceAuthEnabled = false
            environment.syncSudoAuthServer()
            return
        }

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
            if copiedCommandID == id { copiedCommandID = nil }
        }
    }
}
