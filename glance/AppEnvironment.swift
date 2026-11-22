//
//  AppEnvironment.swift
//  glance
//
//  Owns app-wide, long-lived controllers so Settings pages share one instance instead of racing duplicates.
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let pocController = POCController()
    let faceUnlockCoordinator: FaceUnlockCoordinator
    /// Held, not just constructed — owns a repeating timer that would silently stop enforcing auto-lock if deallocated.
    let sessionAutoLocker: SessionAutoLocker
    let appLockCoordinator: AppLockCoordinator
    let sudoAuthServer = SudoAuthServer()
    let sudoFaceAuthenticator: SudoFaceAuthenticator
    /// Constructed here (not started) so the About page and `AppDelegate` share one instance; `AppDelegate` calls `updater.start()`.
    let updater = UpdaterController()

    /// Revealed by tapping the app icon 5 times on the About page. Plain in-memory `var` so it resets on every relaunch.
    var isDebugSectionRevealed = false
    private(set) var isSudoServerListening = false
    private(set) var sudoServerError: String?

    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private let observerBox = ObserverBox()

    init() {
        faceUnlockCoordinator = FaceUnlockCoordinator(pocController: pocController)
        sessionAutoLocker = SessionAutoLocker(pocController: pocController)
        appLockCoordinator = AppLockCoordinator(pipeline: faceUnlockCoordinator.pipeline)
        sudoFaceAuthenticator = SudoFaceAuthenticator(pipeline: faceUnlockCoordinator.pipeline)

        registerTerminationObserver()
        observeSudoSettings()
        syncSudoAuthServer()
    }

    func syncSudoAuthServer() {
        let settings = GlanceSettings.shared
        let shouldListen = !isTerminating
            && settings.hasCompletedOnboarding
            && settings.hasAcknowledgedSecurityNotice
            && settings.sudoFaceAuthEnabled

        if shouldListen {
            if !sudoAuthServer.isListening {
                let authenticator = sudoFaceAuthenticator
                _ = sudoAuthServer.start {
                    await authenticator.authenticate()
                }
            }
        } else {
            sudoFaceAuthenticator.stop()
            sudoAuthServer.stop()
        }

        isSudoServerListening = sudoAuthServer.isListening
        sudoServerError = sudoAuthServer.lastError
    }

    private func observeSudoSettings() {
        withObservationTracking {
            let settings = GlanceSettings.shared
            _ = settings.hasCompletedOnboarding
            _ = settings.hasAcknowledgedSecurityNotice
            _ = settings.sudoFaceAuthEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSudoSettings()
                self.syncSudoAuthServer()
            }
        }
    }

    private func registerTerminationObserver() {
        let center = NotificationCenter.default
        observerBox.add(center, token: center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let shutdown: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.isTerminating = true
                self.sudoFaceAuthenticator.stop()
                self.sudoAuthServer.stop()
                self.isSudoServerListening = false
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(shutdown)
            } else {
                Task { @MainActor in
                    shutdown()
                }
            }
        })
    }

    /// Owns `NotificationCenter` tokens outside actor isolation so `deinit` can unregister safely under Swift 6.
    nonisolated private final class ObserverBox: @unchecked Sendable {
        private var entries: [(center: NotificationCenter, token: NSObjectProtocol)] = []

        func add(_ center: NotificationCenter, token: NSObjectProtocol) {
            entries.append((center, token))
        }

        deinit {
            for entry in entries {
                entry.center.removeObserver(entry.token)
            }
        }
    }
}
