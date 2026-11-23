//
//  PasswordSettingsPage.swift
//  glance
//

import SwiftUI

struct PasswordSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?
    @State private var statusMessage: String?

    /// Read from `POCController`, not a local copy — `SessionAutoLocker` can
    /// lock the session from outside this view.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    /// "No password stored" takes priority over lock state entirely, so
    /// removal doesn't fall back to an "unlock session" prompt for a
    /// session that no longer protects anything.
    private enum PageState: Equatable {
        case noPassword
        case locked
        case unlocked
    }

    private var pageState: PageState {
        guard pocController.hasStoredPassword else { return .noPassword }
        return isSessionUnlocked ? .unlocked : .locked
    }

    var body: some View {
        ZStack(alignment: .top) {
            noPasswordState
                .opacity(pageState == .noPassword ? 1 : 0)
                // Hidden from hit-testing and accessibility while faded out.
                .allowsHitTesting(pageState == .noPassword)
                .accessibilityHidden(pageState != .noPassword)

            lockedState
                .opacity(pageState == .locked ? 1 : 0)
                .allowsHitTesting(pageState == .locked)
                .accessibilityHidden(pageState != .locked)

            unlockedState
                .opacity(pageState == .unlocked ? 1 : 0)
                .allowsHitTesting(pageState == .unlocked)
                .accessibilityHidden(pageState != .unlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: pageState)
        .onAppear { pocController.refreshCredentialStatus() }
        // The onboarding password step runs in the notch, outside this
        // view's hierarchy, so nothing else prompts a re-check once it closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
            if pocController.hasStoredPassword {
                statusMessage = nil
            }
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }
    }

    // MARK: - No password stored

    private var noPasswordState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Set up a password",
            buttonTitle: "Set password",
            caption: statusMessage,
            action: { OnboardingController.startPasswordOnly() }
        )
    }

    // MARK: - Locked

    private var lockedState: some View {
        let missingSessionKey = SecureCredentialManager.isSessionKeyMissingWithOrphanedData
        return VStack(spacing: SettingsMetrics.emptyStateSpacing) {
            Image(systemName: "lock.fill")
                .font(.system(size: SettingsMetrics.emptyStateIconSize, weight: .regular))
                .foregroundStyle(SettingsMetrics.textTertiary)

            Text("Session locked")
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textSecondary)

            SettingsPrimaryButton(
                title: isUnlocking ? "Authenticating…" : "Unlock session",
                isEnabled: !isUnlocking,
                action: unlock
            )

            if let sessionError {
                SettingsCaption(text: sessionError)
                    .multilineTextAlignment(.center)
            } else if missingSessionKey {
                SettingsCaption(
                    text:
                        "The session key is missing, so stored encrypted data can no longer be unlocked. "
                        + "Hold below to reset stored data and start fresh."
                )
                .multilineTextAlignment(.center)
            }

            if sessionError != nil || missingSessionKey {
                HoldToConfirmButton(title: "Reset stored data", action: removePassword)
            }

            if let statusMessage {
                SettingsCaption(text: statusMessage)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(title: "Password encrypted") {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }

                SettingsGroupDivider()

                SettingsSteppedSliderRowContent(
                    title: "Auto lock session",
                    valueLabel: settings.autoLockInterval.title,
                    index: Binding(
                        get: { settings.autoLockInterval.sliderIndex },
                        set: { settings.autoLockInterval = .from(sliderIndex: $0) }
                    ),
                    stopCount: AutoLockInterval.allCases.count
                )

                SettingsGroupDivider()

                SettingsRowContent(
                    title: "Unlock session at login",
                    info:
                        "Automatically unlocks Glance when you log in so you don't need Touch ID on every launch. "
                        + "Tradeoff: stores a copy of the session key in your Keychain without a Touch ID prompt."
                ) {
                    GlanceToggle(
                        isOn: Binding(
                            get: { pocController.unlocksAtLogin },
                            set: { newValue in
                                do {
                                    try pocController.setUnlockAtLogin(newValue)
                                    statusMessage = nil
                                } catch {
                                    statusMessage = "Couldn't update login unlock: \(error.localizedDescription)"
                                }
                            }
                        ))
                }

                SettingsGroupDivider()

                SettingsRowContent(title: "Change password") {
                    SettingsPrimaryButton(title: "Change", compact: true) {
                        OnboardingController.startPasswordOnly()
                    }
                }

                SettingsGroupDivider()

                SettingsRowContent(title: "Remove password") {
                    HoldToConfirmButton(title: "Remove", action: removePassword)
                }
            }

            if let statusMessage {
                SettingsCaption(text: statusMessage)
            }
        }
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        statusMessage = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            // Face store is encrypted under the same session key, so reload
            // it now rather than leaving Your Face stuck showing "locked".
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            isUnlocking = false
        }
    }

    /// Delete Keychain items before wiping `FaceEnrollmentStore` so a Keychain failure
    /// cannot destroy face enrollments on its own (`deleteAll()` removes the encrypted
    /// file directly and does not require an unlocked session).
    private func removePassword() {
        do {
            try SecureCredentialManager.deletePassword()
            FaceEnrollmentStore.shared.deleteAll()
            sessionError = nil
            pocController.sessionError = nil
            pocController.refreshCredentialStatus()
            statusMessage = "Password and face enrollment removed."
        } catch {
            statusMessage = "Couldn't remove: \(error.localizedDescription)"
        }
    }
}
