//
//  AppLockFaceScanner.swift
//  glance
//
//  Runs a face-recognition + identity-bound liveness scan for an active App Lock challenge.
//  Reuses the single shared FaceRecognitionPipeline (never constructing a second ArcFace model)
//  and owns a dedicated CameraManager started only while scanning.
//

import CoreGraphics
import Foundation
import os

@MainActor
final class AppLockFaceScanner {
    enum ScanOutcome: Equatable, Sendable {
        case matched(identityName: String)
        case failed(String, canRetry: Bool)
        case cancelled
    }

    private let pipeline: FaceRecognitionPipeline
    private var lazyCamera: CameraManager?

    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var activeChallengeID: UUID?

    private let wrongFaceGraceDuration: Duration = .seconds(2)

    private static let log = Logger(subsystem: "com.pearleseed.glance", category: "AppLockFaceScanner")

    init(pipeline: FaceRecognitionPipeline) {
        self.pipeline = pipeline
    }

    private func getOrCreateCamera() -> CameraManager {
        if let lazyCamera { return lazyCamera }
        let camera = CameraManager()
        lazyCamera = camera
        return camera
    }

    /// Starts scanning for `challengeID`. Any prior in-flight scan is superseded cleanly.
    func startScan(
        challengeID: UUID,
        onStatus: @escaping (String) -> Void,
        onOutcome: @escaping (UUID, ScanOutcome) -> Void
    ) {
        stop()
        scanGeneration &+= 1
        let generation = scanGeneration
        activeChallengeID = challengeID

        scanTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runScan(
                generation: generation,
                challengeID: challengeID,
                onStatus: onStatus
            )
            guard !Task.isCancelled,
                generation == self.scanGeneration,
                self.activeChallengeID == challengeID
            else { return }
            self.activeChallengeID = nil
            self.scanTask = nil
            onOutcome(challengeID, outcome)
        }
    }

    /// Stops any active scan and powers down the camera immediately.
    func stop(ifMatching challengeID: UUID? = nil) {
        if let challengeID, activeChallengeID != challengeID {
            return
        }
        scanGeneration &+= 1
        activeChallengeID = nil
        scanTask?.cancel()
        scanTask = nil
        lazyCamera?.stop()
    }

    private func preflightGateFailure() -> String? {
        guard pipeline.isUnlockCapable else {
            return "Face recognition unavailable — use Touch ID / Password."
        }
        guard !LockMonitor.isScreenActuallyLocked() else {
            return "Screen is locked."
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            return "Glance session locked — use Touch ID / Password."
        }
        if FaceEnrollmentStore.shared.isLocked {
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }
        guard !FaceEnrollmentStore.shared.activeIdentities.isEmpty else {
            return "No active enrolled face — use Touch ID / Password."
        }
        return nil
    }

    private func isScanActive(generation: UInt64, challengeID: UUID) -> Bool {
        !Task.isCancelled && generation == scanGeneration && activeChallengeID == challengeID
    }

    private func runScan(
        generation: UInt64,
        challengeID: UUID,
        onStatus: @escaping (String) -> Void
    ) async -> ScanOutcome {
        if pipeline.loadState == .loading {
            onStatus("Preparing face recognition…")
            await pipeline.waitUntilReady()
            guard isScanActive(generation: generation, challengeID: challengeID) else {
                return .cancelled
            }
        }

        if let gateFailure = preflightGateFailure() {
            return .failed(gateFailure, canRetry: false)
        }

        onStatus("Starting camera…")
        let camera = getOrCreateCamera()
        await camera.start()

        defer {
            if generation == scanGeneration {
                camera.stop()
            }
        }

        guard isScanActive(generation: generation, challengeID: challengeID) else {
            return .cancelled
        }
        if let cameraError = camera.errorMessage {
            return .failed(cameraError, canRetry: true)
        }

        onStatus("Looking for your face…")
        let scanSeconds = max(TimeInterval(GlanceSettings.shared.faceDetectionSeconds), 1.0)
        return await scanFrames(
            camera: camera,
            generation: generation,
            challengeID: challengeID,
            deadline: ContinuousClock.now + .seconds(scanSeconds)
        )
    }

    private func scanFrames(
        camera: CameraManager,
        generation: UInt64,
        challengeID: UUID,
        deadline: ContinuousClock.Instant
    ) async -> ScanOutcome {
        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        let evaluator = FaceAuthEvaluator(
            pipeline: pipeline,
            livenessEnabled: livenessEnabled,
            livenessModeProvider: { GlanceSettings.shared.livenessMode },
            wrongFaceGraceDuration: wrongFaceGraceDuration
        )
        var lastProcessedFrameID: UInt64?

        if let gateFailure = preflightGateFailure() {
            return .failed(gateFailure, canRetry: false)
        }

        while ContinuousClock.now < deadline, isScanActive(generation: generation, challengeID: challengeID) {
            guard let frame = await camera.nextFrame(after: lastProcessedFrameID, until: deadline) else {
                break
            }
            lastProcessedFrameID = frame.id

            guard isScanActive(generation: generation, challengeID: challengeID) else {
                return .cancelled
            }
            if let gateFailure = preflightGateFailure() {
                return .failed(gateFailure, canRetry: false)
            }

            let strictCloseRangeOnly = GlanceSettings.shared.strictCloseRangeOnly
            let extracted = await evaluator.extractFrameWithBackpressure(
                from: frame,
                camera: camera,
                strictCloseRangeOnly: strictCloseRangeOnly,
                isCurrentGeneration: { generation == self.scanGeneration }
            )

            guard isScanActive(generation: generation, challengeID: challengeID) else {
                return .cancelled
            }
            if let gateFailure = preflightGateFailure() {
                return .failed(gateFailure, canRetry: false)
            }

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
                    "App Lock matched identity \(readyMatch.identity.name, privacy: .private) (\(String(format: "%.3f", readyMatch.centroidSimilarity), privacy: .public))"
                )
                return .matched(identityName: readyMatch.identity.name)
            case .spoofDenied(let reason):
                Self.log.info("App Lock liveness denied: \(reason ?? "spoof", privacy: .public)")
                return .failed("Couldn’t confirm a live face.", canRetry: true)
            case .wrongFaceTimedOut:
                return .failed("Face not recognized.", canRetry: true)
            }
        }

        return isScanActive(generation: generation, challengeID: challengeID)
            ? .failed("No face detected.", canRetry: true)
            : .cancelled
    }
}
