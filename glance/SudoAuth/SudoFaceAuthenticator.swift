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
    private var _camera: CameraManager?
    private let stopSignal = ObservationSignal()

    private var isAuthenticating = false
    private var scanGeneration: UInt64 = 0

    private let totalBudget: Duration = .seconds(24)
    private let minimumRetryBudget: Duration = .seconds(2)
    private let wrongFaceGraceDuration: Duration = .seconds(2)

    private static let log = Logger(subsystem: "com.pearleseed.glance", category: "SudoFaceAuthenticator")

    init(pipeline: FaceRecognitionPipeline) {
        self.pipeline = pipeline
    }

    private func getOrCreateCamera() -> CameraManager {
        if let _camera { return _camera }
        let camera = CameraManager()
        _camera = camera
        return camera
    }

    func stop() {
        scanGeneration &+= 1
        stopSignal.signal()
        _camera?.stop()
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

        isAuthenticating = true
        scanGeneration &+= 1
        let generation = scanGeneration
        let totalDeadline = ContinuousClock.now + totalBudget
        var didPresentOverlay = false
        var didStartCamera = false

        defer {
            isAuthenticating = false
            if didStartCamera && generation == scanGeneration {
                _camera?.stop()
            }
            if didPresentOverlay
                && (Task.isCancelled || generation != scanGeneration || !canAuthenticateNow()
                    || NotchOverlayController.shared.phase == .scanning)
            {
                dismissOverlayIfOwned()
            }
        }

        if pipeline.loadState == .loading {
            await pipeline.waitUntilReady()
            guard !Task.isCancelled, generation == scanGeneration else {
                return false
            }
        }

        guard canAuthenticateNow(), NotchOverlayController.shared.phase != .scanning else {
            return false
        }

        didStartCamera = true
        let showsUI = GlanceSettings.shared.showUnlockAnimation
        return await runAttemptLoop(
            generation: generation,
            showsUI: showsUI,
            totalDeadline: totalDeadline,
            didPresentOverlay: &didPresentOverlay
        )
    }

    private func runAttemptLoop(
        generation: UInt64,
        showsUI: Bool,
        totalDeadline: ContinuousClock.Instant,
        didPresentOverlay: inout Bool
    ) async -> Bool {
        let retryGate = RetryGate()
        var didAutoRetry = false
        var needsPresent = true

        while ContinuousClock.now < totalDeadline, isAttemptValid(generation: generation) {
            if showsUI && needsPresent {
                didPresentOverlay = true
                guard await presentOverlayForAttempt(retryGate: retryGate, generation: generation) else {
                    return false
                }
                needsPresent = false
            }

            let configuredSeconds = max(TimeInterval(GlanceSettings.shared.faceDetectionSeconds), 1.0)
            let remaining = ContinuousClock.now.duration(to: totalDeadline)
            let attemptDuration = min(Duration.seconds(configuredSeconds), remaining)
            guard attemptDuration >= .milliseconds(500) else { break }

            let outcome = await runSingleScan(
                generation: generation,
                deadline: ContinuousClock.now + attemptDuration,
                requireOverlayScanning: showsUI
            )
            if generation == scanGeneration {
                _camera?.stop()
            }

            switch outcome {
            case .matched:
                return finishMatchedAttempt(generation: generation, showsUI: showsUI)
            case .cancelled, .hardFailure:
                if showsUI { dismissOverlayIfOwned() }
                return false
            case .failed:
                let retryAction = await handleFailedAttempt(
                    generation: generation,
                    showsUI: showsUI,
                    retryGate: retryGate,
                    totalDeadline: totalDeadline,
                    didAutoRetry: &didAutoRetry
                )
                switch retryAction {
                case .stop: return false
                case .retry(let shouldPresent): needsPresent = shouldPresent
                }
            }
        }

        return false
    }

    private enum RetryAction {
        case stop
        case retry(needsPresent: Bool)
    }

    private func isAttemptValid(generation: UInt64) -> Bool {
        !Task.isCancelled && generation == scanGeneration && canAuthenticateNow()
    }

    private func presentOverlayForAttempt(retryGate: RetryGate, generation: UInt64) async -> Bool {
        NotchOverlayController.shared.present(onRetry: { [weak retryGate] in
            if let retryGate, retryGate.signalRetryIfWaiting() {
                return
            }
            Task { @MainActor in
                await NotchOverlayController.shared.collapse()
            }
        })
        await yieldMainQueue()
        return isAttemptValid(generation: generation)
    }

    private func finishMatchedAttempt(generation: UInt64, showsUI: Bool) -> Bool {
        guard isAttemptValid(generation: generation) else {
            if showsUI { dismissOverlayIfOwned() }
            return false
        }
        if showsUI {
            NotchOverlayController.shared.finish(success: true)
        }
        return true
    }

    private func handleFailedAttempt(
        generation: UInt64,
        showsUI: Bool,
        retryGate: RetryGate,
        totalDeadline: ContinuousClock.Instant,
        didAutoRetry: inout Bool
    ) async -> RetryAction {
        guard isAttemptValid(generation: generation) else {
            if showsUI { dismissOverlayIfOwned() }
            return .stop
        }
        if showsUI {
            NotchOverlayController.shared.finish(success: false)
        }

        let canHoverRetry = showsUI && GlanceSettings.shared.retryOnHover
        let canAutoRetry = GlanceSettings.shared.autoRetryOnce && !didAutoRetry
        guard canHoverRetry || canAutoRetry,
            ContinuousClock.now.duration(to: totalDeadline) >= minimumRetryBudget
        else {
            return .stop
        }

        guard showsUI else {
            guard canAutoRetry else { return .stop }
            didAutoRetry = true
            try? await Task.sleep(for: .seconds(1))
            return .retry(needsPresent: false)
        }

        let waitDeadline = totalDeadline - .milliseconds(1500)
        let hoverTriggered = await waitForHoverRetryOrFailureEnd(
            retryGate: retryGate,
            deadline: waitDeadline,
            generation: generation
        )
        guard isAttemptValid(generation: generation) else { return .stop }
        if hoverTriggered {
            // NotchOverlayController.activate() already transitioned phase to .scanning.
            return .retry(needsPresent: false)
        }

        guard canAutoRetry, ContinuousClock.now.duration(to: totalDeadline) >= minimumRetryBudget else {
            return .stop
        }
        await waitForOverlayClosed(deadline: waitDeadline, generation: generation)
        guard isAttemptValid(generation: generation) else { return .stop }
        didAutoRetry = true
        return .retry(needsPresent: true)
    }

    // MARK: - Preflight Security Gates

    private func canAuthenticateNow() -> Bool {
        let settings = GlanceSettings.shared
        guard settings.sudoFaceAuthEnabled,
            settings.hasCompletedOnboarding,
            settings.hasAcknowledgedSecurityNotice,
            SecureCredentialManager.isSessionUnlocked,
            pipeline.isUnlockCapable,
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

        let camera = getOrCreateCamera()
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
        let evaluator = FaceAuthEvaluator(
            pipeline: pipeline,
            livenessEnabled: true,
            livenessModeProvider: { .heavy },
            wrongFaceGraceDuration: wrongFaceGraceDuration
        )
        var lastProcessedFrameID: UInt64?

        while ContinuousClock.now < deadline,
            !Task.isCancelled,
            generation == scanGeneration,
            !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning
        {
            guard let frame = await camera.nextFrame(after: lastProcessedFrameID, until: deadline) else {
                break
            }
            lastProcessedFrameID = frame.id

            guard !Task.isCancelled, generation == scanGeneration else { return .cancelled }
            guard !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning else {
                break
            }
            guard canAuthenticateNow() else { return .hardFailure }

            let extracted: ExtractedAuthFrame
            do {
                camera.setConsumerBusy(true)
                defer {
                    if generation == scanGeneration {
                        camera.setConsumerBusy(false)
                    }
                }
                extracted = await FaceAuthEvaluator.extractFrame(
                    from: frame,
                    pipeline: pipeline,
                    previousBoundingBox: evaluator.lastFaceBoundingBox
                )
            }

            guard !Task.isCancelled, generation == scanGeneration else { return .cancelled }
            guard !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning else {
                break
            }
            guard canAuthenticateNow() else { return .hardFailure }

            let step = evaluator.evaluate(
                extracted,
                activeIdentities: FaceEnrollmentStore.shared.activeIdentities,
                threshold: GlanceSettings.shared.matchThreshold
            )
            switch step {
            case .pending:
                continue
            case .matched(let readyMatch, _):
                Self.log.info(
                    "Sudo face auth matched identity \(readyMatch.identity.name, privacy: .private) (\(String(format: "%.3f", readyMatch.centroidSimilarity), privacy: .public))"
                )
                return .matched
            case .spoofDenied(let reason):
                Self.log.info("Sudo face auth liveness denied: \(reason ?? "spoof", privacy: .public)")
                return .failed
            case .wrongFaceTimedOut:
                return .failed
            }
        }

        return (Task.isCancelled || generation != scanGeneration) ? .cancelled : .failed
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
        guard !Task.isCancelled, generation == scanGeneration else {
            return false
        }
        let watcher = Task { @MainActor [weak self, weak retryGate] in
            await ObservationWaiter.waitWhile(until: deadline) {
                guard let self else { return false }
                _ = self.stopSignal.version
                return generation == self.scanGeneration
                    && NotchOverlayController.shared.phase == .failure
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
        await ObservationWaiter.waitWhile(until: deadline) { [weak self] in
            guard let self else { return false }
            _ = self.stopSignal.version
            return generation == self.scanGeneration
                && NotchOverlayController.shared.phase != .closed
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
