//
//  FaceUnlockCoordinator+Observers.swift
//  glance
//
//  Space-key lock-screen monitoring and settings / display / pipeline observers for `FaceUnlockCoordinator`.
//

import AppKit
import Foundation
import Observation

// MARK: - Space Key Monitoring

extension FaceUnlockCoordinator {
    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    func updateSpaceMonitor() {
        let shouldListen =
            isEnabled
            && GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current())
            && isOnboardingGateSatisfied
            && canArmWithPipeline
            && GlanceSettings.shared.unlockTriggers.contains(.onSpace)
            && LockMonitor.isScreenActuallyLocked()
            && SpaceKeyMonitor.hasInputMonitoringAccess()
        if shouldListen {
            spaceKeyMonitor.start()
        } else {
            spaceKeyMonitor.stop()
        }
    }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    func handleSpaceKeyPress() {
        guard isEnabled,
            !lockMonitor.isSleeping,
            GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current()),
            isOnboardingGateSatisfied,
            canArmWithPipeline,
            GlanceSettings.shared.unlockTriggers.contains(.onSpace),
            LockMonitor.isScreenActuallyLocked(),
            NotchGeometry.preferredScreen() != nil,
            SecureCredentialManager.isSessionUnlocked,
            SecureCredentialManager.hasStoredPassword(),
            KeystrokeInjector.isAccessibilityTrusted(),
            !FaceEnrollmentStore.shared.activeIdentities.isEmpty
        else { return }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            armTask?.cancel()
            armTask = nil
            arm(autoScan: true)
        }
    }
}

// MARK: - Settings & Pipeline Observers

extension FaceUnlockCoordinator {
    func observeDisplayContextSettings() {
        withObservationTracking {
            let settings = GlanceSettings.shared
            _ = settings.isFaceUnlockEnabledBuiltInOnly
            _ = settings.isFaceUnlockEnabledBuiltInAndExternal
            _ = settings.isFaceUnlockEnabledExternalOnly
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDisplayContextSettings()
                self.handleDisplayContextOrPreferenceChange()
            }
        }
    }

    func observeScreenParameters() {
        observerBox.observe(forName: NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDisplayContextOrPreferenceChange()
            }
        }
    }

    func handleDisplayContextOrPreferenceChange() {
        if !GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current()) {
            disarmOverlay()
            return
        }
        updateSpaceMonitor()
        guard LockMonitor.isScreenActuallyLocked(), !lockMonitor.isSleeping else { return }
        if NotchOverlayController.shared.isArmed {
            NotchOverlayController.shared.reassertLockScreenPresentation()
        } else if !hasArmedForCurrentLock {
            // Displays can come online ~0.5–1.2s after wake on multi-monitor setups;
            // re-evaluate once screen parameters settle so the overlay isn't skipped.
            displayRearmTask?.cancel()
            displayRearmTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.displayRearmTask = nil
                guard LockMonitor.isScreenActuallyLocked(), !self.lockMonitor.isSleeping, !self.hasArmedForCurrentLock
                else { return }
                let fallbackEvent: LockEventKind? =
                    self.requiredTrigger(for: self.lockMonitor.lastEvent) != nil ? nil : .wake
                self.evaluateTrigger(overrideEvent: fallbackEvent)
            }
        }
    }

    func observeToggleShortcut() {
        withObservationTracking {
            _ = GlanceSettings.shared.faceUnlockToggleShortcut
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeToggleShortcut()
                self.syncToggleHotKeyRegistration()
            }
        }
    }

    func observePipelineLoadState() {
        withObservationTracking {
            _ = pipeline.loadState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePipelineLoadState()
                self.handlePipelineLoadStateChange()
            }
        }
    }

    func handlePipelineLoadStateChange() {
        if case .fallback = pipeline.loadState {
            disarmOverlay()
        }
        updateSpaceMonitor()
    }
}
