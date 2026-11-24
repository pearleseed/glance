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
    /// Single shared recognition pipeline across the entire app, loading ArcFace off `@MainActor`.
    let recognitionPipeline = FaceRecognitionPipeline()
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
    /// Pending settings tab requested via `--open-settings-tab` launch argument.
    var requestedSettingsTab: SettingsTab?
    /// On macOS 14 (where `.defaultLaunchBehavior(.suppressed)` is unavailable),
    /// SwiftUI opens the initial `Window` scene at launch unless gated here.
    var allowsSettingsWindowPresentation: Bool = {
        if #available(macOS 15, *) {
            return true
        } else {
            return false
        }
    }()
    private(set) var isSudoServerListening = false
    private(set) var sudoServerError: String?

    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private let observerBox = NotificationObserverBox()

    init() {
        faceUnlockCoordinator = FaceUnlockCoordinator(pocController: pocController, pipeline: recognitionPipeline)
        sessionAutoLocker = SessionAutoLocker(pocController: pocController)
        appLockCoordinator = AppLockCoordinator(pipeline: recognitionPipeline)
        sudoFaceAuthenticator = SudoFaceAuthenticator(pipeline: recognitionPipeline)

        registerTerminationObserver()
        observeSudoSettings()
        syncSudoAuthServer()
    }

    func syncSudoAuthServer() {
        let settings = GlanceSettings.shared
        let shouldListen =
            !isTerminating
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
        observerBox.observe(forName: NSApplication.willTerminateNotification) { [weak self] _ in
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
        }
    }
}
