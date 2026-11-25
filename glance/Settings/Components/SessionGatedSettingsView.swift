//
//  SessionGatedSettingsView.swift
//  glance
//

import SwiftUI

/// Shared locked/unlocked container for settings pages that gate their
/// controls behind Touch ID session unlock.
struct SessionGatedSettingsView<Content: View>: View {
    @Bindable var pocController: POCController
    var onAppear: (() -> Void)?
    var onSessionLock: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — `SessionAutoLocker` can
    /// lock the session from outside this view.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            content()
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear {
            pocController.refreshCredentialStatus()
            onAppear?()
        }
        .onChange(of: isSessionUnlocked) { _, unlocked in
            guard !unlocked else { return }
            onSessionLock?()
        }
        // Flows like password setup or face enrollment run in the notch, outside
        // this window, so nothing else prompts a re-check once one closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}
