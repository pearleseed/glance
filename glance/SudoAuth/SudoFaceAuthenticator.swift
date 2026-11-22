//
//  SudoFaceAuthenticator.swift
//  glance
//
//  On-device face authentication for sudo PAM requests.
//  Reuses the shared FaceRecognitionPipeline, enforces Heavy Liveness unconditionally,
//  preserves Phase 1 identity-bound liveness ordering, and drives NotchOverlayController
//  within a bounded budget safely below SudoAuthServer's 28s timeout.
//

import CoreGraphics
import Foundation
import os

@MainActor
final class SudoFaceAuthenticator {
    private enum SingleScanOutcome {
        case matched
        case failed
        case hardFailure
        case cancelled
    }

    private let pipeline: FaceRecognitionPipeline
    private let camera = CameraManager()

    private var isAuthenticating = false
    private var scanGeneration: UInt64 = 0

    private let totalBudget: Duration = .seconds(24)
    private let minimumRetryBudget: Duration = .seconds(2)
    private let framePollInterval: Duration = .milliseconds(5)
    private let wrongFaceGraceDuration: Duration = .seconds(2)

    private static let log = Logger(subsystem: "com.jonathan.glance", category: "SudoFaceAuthenticator")

    init(pipeline: FaceRecognitionPipeline) {
        self.pipeline = pipeline
    }

    func stop() {
        scanGeneration &+= 1
        camera.stop()
        if isAuthenticating {
            dismissOverlayIfOwned()
        }
    }

    private func dismissOverlayIfOwned() {
        guard !NotchOverlayController.shared.isArmed,
              NotchOverlayController.shared.phase != .onboarding
        else { return }
        NotchOverlayController.shared.dismissImmediately()
    }

    func authenticate() async -> Bool {
        guard !isAuthenticating else {
            Self.log.info("Rejecting concurrent sudo face authentication request.")
            return false
        }
        guard canAuthenticateNow(), NotchOverlayController.shared.phase != .scanning else {
            return false
        }

        isAuthenticating = true
        scanGeneration &+= 1
        let generation = scanGeneration
        let showsUI = GlanceSettings.shared.showUnlockAnimation
        var didPresentOverlay = false

        defer {
            isAuthenticating = false
            if generation == scanGeneration {
                camera.stop()
            }
            if didPresentOverlay && (Task.isCancelled || generation != scanGeneration || !canAuthenticateNow() || NotchOverlayController.shared.phase == .scanning) {
                dismissOverlayIfOwned()
            }
        }

        let totalDeadline = ContinuousClock.now + totalBudget
        let retryGate = RetryGate()
        var didAutoRetry = false
        var needsPresent = true

        while ContinuousClock.now < totalDeadline,
              !Task.isCancelled,
              generation == scanGeneration,
              canAuthenticateNow() {
            if showsUI && needsPresent {
                didPresentOverlay = true
                NotchOverlayController.shared.present(onRetry: { [weak retryGate] in
                    if let retryGate, retryGate.signalRetryIfWaiting() {
                        return
                    }
                    Task { @MainActor in
                        await NotchOverlayController.shared.collapse()
                    }
                })
                await yieldMainQueue()
                guard !Task.isCancelled, generation == scanGeneration, canAuthenticateNow() else {
                    return false
                }
                needsPresent = false
            }

            let configuredSeconds = max(TimeInterval(GlanceSettings.shared.faceDetectionSeconds), 1.0)
            let remaining = ContinuousClock.now.duration(to: totalDeadline)
            let attemptDuration = min(Duration.seconds(configuredSeconds), remaining)
            guard attemptDuration >= .milliseconds(500) else { break }

            let attemptDeadline = ContinuousClock.now + attemptDuration
            let outcome = await runSingleScan(
                generation: generation,
                deadline: attemptDeadline,
                requireOverlayScanning: showsUI
            )

            if generation == scanGeneration {
                camera.stop()
            }

            switch outcome {
            case .matched:
                guard !Task.isCancelled, generation == scanGeneration, canAuthenticateNow() else {
                    if showsUI {
                        dismissOverlayIfOwned()
                    }
                    return false
                }
                if showsUI {
                    NotchOverlayController.shared.finish(success: true)
                }
                return true

            case .cancelled, .hardFailure:
                if showsUI {
                    dismissOverlayIfOwned()
                }
                return false

            case .failed:
                guard !Task.isCancelled, generation == scanGeneration, canAuthenticateNow() else {
                    if showsUI {
                        dismissOverlayIfOwned()
                    }
                    return false
                }
                if showsUI {
                    NotchOverlayController.shared.finish(success: false)
                }

                let canHoverRetry = showsUI && GlanceSettings.shared.retryOnHover
                let canAutoRetry = GlanceSettings.shared.autoRetryOnce && !didAutoRetry

                guard (canHoverRetry || canAutoRetry),
                      ContinuousClock.now.duration(to: totalDeadline) >= minimumRetryBudget
                else {
                    return false
                }

                if showsUI {
                    let waitDeadline = totalDeadline - .milliseconds(1500)
                    let hoverTriggered = await waitForHoverRetryOrFailureEnd(
                        retryGate: retryGate,
                        deadline: waitDeadline,
                        generation: generation
                    )
                    guard !Task.isCancelled, generation == scanGeneration, canAuthenticateNow() else {
                        return false
                    }
                    if hoverTriggered {
                        // NotchOverlayController.activate() already transitioned phase to .scanning.
                        needsPresent = false
                        continue
                    }

                    if canAutoRetry, ContinuousClock.now.duration(to: totalDeadline) >= minimumRetryBudget {
                        await waitForOverlayClosed(
                            deadline: totalDeadline - .milliseconds(1500),
                            generation: generation
                        )
                        guard !Task.isCancelled, generation == scanGeneration, canAuthenticateNow() else {
                            return false
                        }
                        didAutoRetry = true
                        needsPresent = true
                        continue
                    }
                    return false
                } else {
                    guard canAutoRetry else { return false }
                    didAutoRetry = true
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            }
        }

        return false
    }

    // MARK: - Preflight Security Gates

    private var hasUnlockCapableEmbedder: Bool {
        !pipeline.usingFallbackEmbedder && pipeline.embedder.isUnlockCapable
    }

    private func canAuthenticateNow() -> Bool {
        let settings = GlanceSettings.shared
        guard settings.sudoFaceAuthEnabled,
              settings.hasCompletedOnboarding,
              settings.hasAcknowledgedSecurityNotice,
              SecureCredentialManager.isSessionUnlocked,
              hasUnlockCapableEmbedder,
              !LockMonitor.isScreenActuallyLocked(),
              !NotchOverlayController.shared.isArmed,
              NotchOverlayController.shared.phase != .onboarding
        else {
            return false
        }

        if FaceEnrollmentStore.shared.isLocked {
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }
        return !FaceEnrollmentStore.shared.activeIdentities.isEmpty
    }

    // MARK: - Single Scan Attempt (Heavy Liveness Enforced)

    private func runSingleScan(
        generation: UInt64,
        deadline: ContinuousClock.Instant,
        requireOverlayScanning: Bool
    ) async -> SingleScanOutcome {
        guard canAuthenticateNow() else { return .hardFailure }

        await camera.start()
        defer {
            if generation == scanGeneration {
                camera.stop()
            }
        }

        guard !Task.isCancelled, generation == scanGeneration else {
            return .cancelled
        }
        guard canAuthenticateNow() else {
            return .hardFailure
        }
        if let cameraError = camera.errorMessage {
            Self.log.error("Sudo face auth camera error: \(cameraError, privacy: .public)")
            return .hardFailure
        }

        // Always enforce Heavy Liveness for sudo regardless of user's lock-screen liveness preferences.
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { .heavy }

        var wrongFaceStartedAt: ContinuousClock.Instant?
        var readyMatch: ScoredIdentity?
        var matchedIdentityID: UUID?
        var livenessConfirmed = false
        var lastFaceBoundingBox: CGRect?
        var lastProcessedFrameID: UInt64?

        func resetIdentityLivenessState(to newIdentityID: UUID? = nil) {
            readyMatch = nil
            matchedIdentityID = newIdentityID
            livenessConfirmed = false
            liveness.resetConfirmations()
        }

        while ContinuousClock.now < deadline,
              !Task.isCancelled,
              generation == scanGeneration,
              (!requireOverlayScanning || NotchOverlayController.shared.phase == .scanning) {
            guard canAuthenticateNow() else {
                return .hardFailure
            }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(for: framePollInterval)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let extracted = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame, preferNear: previousBoundingBox, includeQuality: false) else {
                    return nil
                }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard !Task.isCancelled, generation == scanGeneration else {
                return .cancelled
            }
            guard canAuthenticateNow() else {
                return .hardFailure
            }

            guard let (result, livenessFrame) = extracted else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                resetIdentityLivenessState()
                continue
            }

            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Phase 1 identity-bound liveness: score & match first, then update confirmations for that identity only.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: GlanceSettings.shared.matchThreshold)

            if let matched {
                wrongFaceStartedAt = nil
                if matchedIdentityID != matched.identity.id {
                    resetIdentityLivenessState(to: matched.identity.id)
                }
                readyMatch = matched

                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    Self.log.info("Sudo face auth liveness denied: \(snapshot.decision.denialReason ?? "spoof", privacy: .public)")
                    return .failed
                case .confirmed:
                    livenessConfirmed = true
                case .pending:
                    break
                }
            } else {
                resetIdentityLivenessState()
                let snapshot = liveness.observeUnmatched(livenessFrame)
                if case .denied = snapshot.decision {
                    Self.log.info("Sudo face auth unmatched liveness denied: \(snapshot.decision.denialReason ?? "spoof", privacy: .public)")
                    return .failed
                }

                if wrongFaceStartedAt == nil {
                    wrongFaceStartedAt = .now
                }
                if ContinuousClock.now - wrongFaceStartedAt! >= wrongFaceGraceDuration {
                    return .failed
                }
            }

            if let readyMatch, livenessConfirmed {
                Self.log.info("Sudo face auth matched identity \(readyMatch.identity.name, privacy: .private) (\(String(format: "%.3f", readyMatch.centroidSimilarity), privacy: .public))")
                return .matched
            }
        }

        if Task.isCancelled || generation != scanGeneration {
            return .cancelled
        }
        return .failed
    }

    // MARK: - Overlay Coordination Helpers

    private func yieldMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func waitForHoverRetryOrFailureEnd(
        retryGate: RetryGate,
        deadline: ContinuousClock.Instant,
        generation: UInt64
    ) async -> Bool {
        let watcher = Task { @MainActor [weak retryGate] in
            while !Task.isCancelled,
                  ContinuousClock.now < deadline,
                  generation == self.scanGeneration,
                  NotchOverlayController.shared.phase == .failure {
                try? await Task.sleep(for: .milliseconds(50))
            }
            retryGate?.cancelWaiting()
        }

        let retried = await withTaskCancellationHandler {
            await retryGate.waitIfNeeded()
        } onCancel: {
            Task { @MainActor in
                retryGate.cancelWaiting()
            }
        }
        watcher.cancel()
        return retried
    }

    private func waitForOverlayClosed(
        deadline: ContinuousClock.Instant,
        generation: UInt64
    ) async {
        while !Task.isCancelled,
              ContinuousClock.now < deadline,
              generation == scanGeneration,
              NotchOverlayController.shared.phase != .closed {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
private final class RetryGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var isWaiting = false

    func signalRetryIfWaiting() -> Bool {
        guard isWaiting, let cont = continuation else {
            return false
        }
        isWaiting = false
        continuation = nil
        cont.resume(returning: true)
        return true
    }

    func cancelWaiting() {
        isWaiting = false
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: false)
        }
    }

    func waitIfNeeded() async -> Bool {
        await withCheckedContinuation { cont in
            isWaiting = true
            continuation = cont
        }
    }
}
