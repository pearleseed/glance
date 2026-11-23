//
//  OnboardingController+Flow.swift
//  glance
//
//  Step navigation, permission polling, naming validation, password persistence,
//  and completion dismissal for `OnboardingController`.
//

import AVFoundation
import AppKit
import Foundation
import SwiftUI

extension OnboardingController {
    // MARK: - Navigation

    func advance() {
        navDirection = .forward
        let leavingStep = step
        withAnimation(OnboardingMetrics.stepAnimation) {
            if isPostUpdateNotice {
                step = .complete
            } else if let nextStep = step.nextLinearStep {
                step = nextStep
            }
        }
        if leavingStep == .permissions {
            stopPermissionsPolling()
        }
        handleEnteredStep()
    }

    private func handleEnteredStep() {
        switch step {
        case .permissions:
            startPermissionsPolling()
        case .enroll:
            // Deferred a tick so the heavy camera start doesn't land in the same runloop
            // turn as the panel-resize transition, stealing frames from the spring animation.
            Task { @MainActor [weak self] in self?.beginEnrollment() }
        case .complete where isPostUpdateNotice:
            GlanceSettings.shared.hasAcknowledgedSecurityNotice = true
            scheduleCompletionDismiss()
        default:
            break
        }
    }

    /// "No thanks" on the post-update notice. Declining isn't a real option — the app
    /// requires acknowledgment before it'll run — so this quits rather than dismissing back
    /// into use.
    func declinePostUpdateNotice() {
        NSApp.terminate(nil)
    }

    /// Steps backward. The enroll close control also lands here: a retreat to camera selection
    /// in the full setup flow, a cancel in add/recapture.
    func back() {
        navDirection = .backward
        if isPasswordOnly {
            cancelOnboarding()
            return
        }
        switch step {
        case .enroll where isEnrollmentOnly, .name where isEnrollmentOnly:
            cancelOnboarding()
        case .enroll:
            resetEnrollmentState()
            camera.stop()
            sweepWindow.dismiss()
            withAnimation(OnboardingMetrics.stepAnimation) { step = .selectCamera }
        case .password:
            // Deliberately *without* resetting: samples and typed name survive so a typo
            // fix doesn't mean re-doing nine poses.
            nameError = nil
            withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
        case .name:
            resetEnrollmentState()
            withAnimation(OnboardingMetrics.stepAnimation) { step = .selectCamera }
        default:
            guard let previous = step.previous else { return }
            withAnimation(OnboardingMetrics.stepAnimation) { step = previous }
            if step == .permissions {
                startPermissionsPolling()
            }
        }
    }

    private func cancelOnboarding() {
        teardown()
        NotchOverlayController.shared.dismissOnboarding()
    }

    // MARK: - Permissions

    func startPermissionsPolling() {
        refreshPermissions()
        permissionsPollTask?.cancel()
        permissionsPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.refreshPermissions()
            }
        }
    }

    func stopPermissionsPolling() {
        permissionsPollTask?.cancel()
        permissionsPollTask = nil
    }

    private func refreshPermissions() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraPermission = .granted
        case .notDetermined: cameraPermission = .notDetermined
        default: cameraPermission = .denied
        }
    }

    func grantAccessibility() {
        guard !hasPromptedAccessibility else {
            openSystemSettings(pane: "Privacy_Accessibility")
            return
        }
        hasPromptedAccessibility = true
        KeystrokeInjector.promptForAccessibility()
        refreshPermissions()
    }

    func grantCamera() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                refreshPermissions()
            } else {
                openSystemSettings(pane: "Privacy_Camera")
            }
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Naming

    func confirmName() {
        let trimmed = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = "Enter a name."
            return
        }
        guard !store.nameIsTaken(trimmed, excluding: enrollmentTarget.identityID) else {
            nameError = "A face named \"\(trimmed)\" is already enrolled."
            return
        }
        nameError = nil

        guard isEnrollmentOnly else {
            navDirection = .forward
            withAnimation(OnboardingMetrics.stepAnimation) { step = .password }
            return
        }

        store.reloadIfUnlocked()
        do {
            try commitEnrollment(name: trimmed)
        } catch {
            nameError = error.localizedDescription
            return
        }
        navDirection = .forward
        withAnimation(OnboardingMetrics.stepAnimation) { step = .complete }
        scheduleCompletionDismiss()
    }

    private func commitEnrollment(name: String) throws {
        let samples = collectedSamples.map {
            FaceSample(embedding: $0.embedding, pose: $0.pose.name, capturedAt: $0.capturedAt, quality: $0.quality)
        }
        try store.commitEnrollment(
            replacing: enrollmentTarget.identityID,
            name: name,
            samples: samples,
            embedder: pipeline.embedder
        )
    }

    // MARK: - Password

    func finish(password: String) async -> Bool {
        guard !isSavingPassword else { return false }
        let trimmed = password
        guard !trimmed.isEmpty else {
            passwordError = "Enter a password."
            return false
        }
        isSavingPassword = true
        defer { isSavingPassword = false }

        do {
            try await unlockSessionAndClearOrphans()
            guard try commitPendingEnrollmentIfNeeded() else { return false }
            try await persistPassword(trimmed)
            passwordError = nil
            navDirection = .forward
            withAnimation(OnboardingMetrics.stepAnimation) { step = .complete }
            scheduleCompletionDismiss()
            return true
        } catch {
            passwordError = error.localizedDescription
            return false
        }
    }

    private func unlockSessionAndClearOrphans() async throws {
        let hadOrphanedData = try await Task.detached(priority: .userInitiated) {
            guard SecureCredentialManager.isSessionKeyMissingWithOrphanedData else { return false }
            try SecureCredentialManager.deletePassword()
            return true
        }.value
        if hadOrphanedData {
            store.deleteAll()
        }
        try await SecureCredentialManager.unlockSession(reason: "Set up Glance")
        store.reloadIfUnlocked()
    }

    private func commitPendingEnrollmentIfNeeded() throws -> Bool {
        guard !collectedSamples.isEmpty else { return true }
        let name = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !store.nameIsTaken(name, excluding: enrollmentTarget.identityID) else {
            nameError = "A face named \"\(name)\" is already enrolled."
            navDirection = .backward
            withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
            return false
        }
        try commitEnrollment(name: name)
        return true
    }

    private func persistPassword(_ plaintext: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard var bytes = plaintext.data(using: .utf8) else {
                throw SecureCredentialError.emptyPassword
            }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            try SecureCredentialManager.savePassword(bytes)
        }.value
    }

    /// The "You're all set" screen has no controls — it dismisses itself, then hands off
    /// to `onFirstRunComplete` once the notch is gone, for first-run and the post-update
    /// notice alike.
    func scheduleCompletionDismiss() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.completeScreenDismissDelay))
            guard let self else { return }
            let shouldFireCompletion = self.isFirstRunFlow || self.isPostUpdateNotice
            let onComplete = self.onFirstRunComplete
            self.teardown()
            NotchOverlayController.shared.dismissOnboarding()
            if shouldFireCompletion {
                onComplete?()
            }
        }
    }
}
