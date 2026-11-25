//
//  SessionAutoLocker.swift
//  glance
//
//  Enforces `GlanceSettings.autoLockInterval`: re-locks the session once idle past the user's chosen limit.
//

import AppKit
import Foundation

@MainActor
final class SessionAutoLocker {
    private let pocController: POCController
    private let checkTaskBox = CancellableTaskBox()
    private let observerBox = NotificationObserverBox()

    /// Coarse on purpose — the shortest selectable limit is a full day, and the decision compares timestamps, not ticks.
    private let checkInterval: Duration = .seconds(5 * 60)

    init(pocController: POCController) {
        self.pocController = pocController
        let interval = checkInterval
        checkTaskBox.replace(
            with: Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval, tolerance: .seconds(30))
                    guard !Task.isCancelled, let self else { return }
                    self.evaluate()
                }
            }
        )

        // Also evaluate on wake: no timer fires during sleep, but the elapsed time still counts as idle once compared.
        observerBox.observe(
            center: NSWorkspace.shared.notificationCenter,
            forName: NSWorkspace.didWakeNotification,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        evaluate()
    }

    /// Routed through `POCController.lockSession()` rather than `SecureCredentialManager` directly, so the Settings UI's
    /// `isSessionUnlocked` flag doesn't go stale.
    func evaluate() {
        guard SecureCredentialManager.isSessionUnlocked,
            let lastActivityAt = SecureCredentialManager.lastActivityAt
        else { return }

        // A "Never" preference still loses the in-memory session key on app
        // relaunch; it only disables the idle-timeout lock while Glance runs.
        guard let idleLimit = GlanceSettings.shared.autoLockInterval.duration else { return }
        guard Date().timeIntervalSince(lastActivityAt) >= idleLimit else { return }

        pocController.lockSession()
    }
}
