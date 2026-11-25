//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import AppKit
import Foundation
import OSLog
import Observation

enum UnlockInjectionFailure: LocalizedError, Equatable, Sendable {
    case accessibilityNotGranted
    case sessionLocked
    case screenNotLocked
    case credentialReadFailed(String)
    case keystrokeFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return
                "Accessibility permission not granted — enable Glance in "
                + "System Settings → Privacy & Security → Accessibility."
        case .sessionLocked:
            return "Session locked — authenticate with Touch ID first."
        case .screenNotLocked:
            return "Skipped: CGSession reports screen is not actually locked."
        case .credentialReadFailed(let message):
            return "Couldn't read stored password: \(message)"
        case .keystrokeFailed(let message):
            return "Password entry failed: \(message)"
        }
    }
}

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var unlocksAtLogin: Bool = SecureCredentialManager.unlocksAtLogin
    var sessionError: String?

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Idle"
    var lastInjectionError: UnlockInjectionFailure?

    @ObservationIgnored private let observerBox = NotificationObserverBox()
    @ObservationIgnored private var launchUnlockRetryTask: Task<Void, Never>?

    init() {
        observerBox.observe(forName: .secureCredentialSessionDidChange) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCredentialStatus()
            }
        }
        observerBox.observe(forName: NSApplication.didBecomeActiveNotification) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityStatus()
            }
        }
    }

    func refreshAccessibilityStatus() {
        let trusted = KeystrokeInjector.isAccessibilityTrusted()
        if accessibilityGranted != trusted {
            accessibilityGranted = trusted
        }
        if trusted, case .accessibilityNotGranted = lastInjectionError {
            lastInjectionError = nil
        }
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
        refreshAccessibilityStatus()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
        unlocksAtLogin = SecureCredentialManager.unlocksAtLogin
        if isSessionUnlocked, case .sessionLocked = lastInjectionError {
            lastInjectionError = nil
        }
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await SecureCredentialManager.unlockSession(reason: "Authenticate to set up or use glance")
            refreshCredentialStatus()
        } catch {
            refreshCredentialStatus()
            sessionError = error.localizedDescription
        }
    }

    /// Attempts a silent launch-time unlock when the user has opted into "Unlock session at login".
    /// Retries briefly on transient Keychain unavailability (e.g. Login Keychain still settling right at login).
    func unlockSessionAtLaunch() async {
        guard !isSessionUnlocked else { return }
        launchUnlockRetryTask?.cancel()
        launchUnlockRetryTask = nil

        let result = await attemptLoginKeyUnlockOnce()
        guard result == .transientFailure, !isSessionUnlocked else { return }

        UnlockLog.logger.warning("Launch login-key unlock hit transient Keychain failure — scheduling retries")
        launchUnlockRetryTask = Task { [weak self] in
            for delay in [Duration.seconds(2), Duration.seconds(6)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, !self.isSessionUnlocked else { return }
                let retryResult = await self.attemptLoginKeyUnlockOnce()
                if retryResult != .transientFailure { return }
            }
        }
    }

    private func attemptLoginKeyUnlockOnce() async -> LoginKeyUnlockResult {
        let result = await Task.detached(priority: .userInitiated) {
            SecureCredentialManager.unlockSessionFromLoginKeyResult()
        }.value
        refreshCredentialStatus()
        switch result {
        case .unlocked:
            sessionError = nil
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            UnlockLog.logger.info("Session unlocked silently from login key")
        case .notConfigured:
            UnlockLog.logger.info("Launch unlock skipped: login key not configured")
        case .transientFailure:
            UnlockLog.logger.warning("Launch unlock deferred: Keychain temporarily unavailable or ACL-gated")
        case .invalidated:
            UnlockLog.logger.error("Launch login key invalidated because stored password could not be decrypted")
        }
        return result
    }

    func setUnlockAtLogin(_ enabled: Bool) throws {
        try SecureCredentialManager.setUnlockAtLogin(enabled)
        refreshCredentialStatus()
    }

    func lockSession() {
        launchUnlockRetryTask?.cancel()
        launchUnlockRetryTask = nil
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Enter a password first."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Password saved and encrypted."
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    @discardableResult
    func injectStoredPassword(
        requireAuthoritativeLock: Bool = false,
        singleGraphemeMode: Bool = false
    ) async -> Result<Void, UnlockInjectionFailure> {
        let trusted = KeystrokeInjector.isAccessibilityTrusted()
        accessibilityGranted = trusted
        guard trusted else {
            return recordInjectionFailure(
                .accessibilityNotGranted,
                logMessage: "Password injection blocked: Accessibility not granted (check stale ad-hoc TCC entry)"
            )
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            return recordInjectionFailure(.sessionLocked, logMessage: "Password injection blocked: session is locked")
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                let failure = UnlockInjectionFailure.screenNotLocked
                statusMessage = failure.localizedDescription
                UnlockLog.logger.info("Password injection skipped: CGSession reports screen is not locked")
                return .failure(failure)
            }
        }

        statusMessage = "Injecting…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword(
                    nonInteractiveKeychainFallback: requireAuthoritativeLock
                )
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(
                    bytes,
                    requireLockedScreen: requireAuthoritativeLock,
                    singleGraphemeMode: singleGraphemeMode
                )
            }.value
            lastInjectionError = nil
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
            UnlockLog.logger.info("Injected stored password + Return on lock screen")
            return .success(())
        } catch KeystrokeError.screenUnlockedDuringInjection {
            lastInjectionError = nil
            statusMessage = "Screen unlocked during injection."
            UnlockLog.logger.info("Screen unlocked while password injection was in progress")
            return .success(())
        } catch let error as KeychainError {
            return recordInjectionFailure(
                .credentialReadFailed(error.localizedDescription),
                logMessage: "Password injection failed reading Keychain: \(error.localizedDescription)"
            )
        } catch let error as SecureCredentialError {
            return recordInjectionFailure(
                .credentialReadFailed(error.localizedDescription),
                logMessage: "Password injection failed decrypting credential: \(error.localizedDescription)"
            )
        } catch {
            return recordInjectionFailure(
                .keystrokeFailed(error.localizedDescription),
                logMessage: "Password injection failed posting keystrokes: \(error.localizedDescription)"
            )
        }
    }

    private func recordInjectionFailure(
        _ failure: UnlockInjectionFailure,
        logMessage: String
    ) -> Result<Void, UnlockInjectionFailure> {
        lastInjectionError = failure
        statusMessage = failure.localizedDescription
        UnlockLog.logger.error("\(logMessage, privacy: .public)")
        return .failure(failure)
    }
}
