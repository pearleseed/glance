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
    private let camera = CameraManager()

    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var activeChallengeID: UUID?

    private let framePollInterval: Duration = .milliseconds(5)
    private let wrongFaceGraceDuration: Duration = .seconds(2)

    private static let log = Logger(subsystem: "com.jonathan.glance", category: "AppLockFaceScanner")

    init(pipeline: FaceRecognitionPipeline) {
        self.pipeline = pipeline
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
        camera.stop()
    }

    private var hasUnlockCapableEmbedder: Bool {
        !pipeline.usingFallbackEmbedder && pipeline.embedder.isUnlockCapable
    }

    private func preflightGateFailure() -> String? {
        guard hasUnlockCapableEmbedder else {
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

    private func runScan(
        generation: UInt64,
        challengeID: UUID,
        onStatus: @escaping (String) -> Void
    ) async -> ScanOutcome {
        if let gateFailure = preflightGateFailure() {
            return .failed(gateFailure, canRetry: false)
        }

        onStatus("Starting camera…")
        await camera.start()

        defer {
            if generation == scanGeneration {
                camera.stop()
            }
        }

        guard !Task.isCancelled,
              generation == scanGeneration,
              activeChallengeID == challengeID
        else {
            return .cancelled
        }

        if let cameraError = camera.errorMessage {
            return .failed(cameraError, canRetry: true)
        }

        onStatus("Looking for your face…")

        let scanSeconds = max(TimeInterval(GlanceSettings.shared.faceDetectionSeconds), 1.0)
        let deadline = ContinuousClock.now + .seconds(scanSeconds)

        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { GlanceSettings.shared.livenessMode }

        var wrongFaceStartedAt: ContinuousClock.Instant?
        var readyMatch: ScoredIdentity?
        var matchedIdentityID: UUID?
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        var lastProcessedFrameID: UInt64?

        func resetIdentityLivenessState(to newIdentityID: UUID? = nil) {
            readyMatch = nil
            matchedIdentityID = newIdentityID
            livenessConfirmed = !livenessEnabled
            if livenessEnabled {
                liveness.resetConfirmations()
            }
        }

        while ContinuousClock.now < deadline,
              !Task.isCancelled,
              generation == scanGeneration,
              activeChallengeID == challengeID {
            if let gateFailure = preflightGateFailure() {
                return .failed(gateFailure, canRetry: false)
            }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(for: framePollInterval)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame, preferNear: previousBoundingBox, includeQuality: false) else {
                    return nil
                }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard !Task.isCancelled,
                  generation == scanGeneration,
                  activeChallengeID == challengeID
            else {
                return .cancelled
            }

            if let gateFailure = preflightGateFailure() {
                return .failed(gateFailure, canRetry: false)
            }

            guard let (result, livenessFrame) = outcome else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                resetIdentityLivenessState()
                continue
            }

            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Phase 1 ordering: score & match BEFORE updating confirm-liveness, and bind liveness to matchedIdentityID.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: GlanceSettings.shared.matchThreshold)

            if let matched {
                wrongFaceStartedAt = nil
                if matchedIdentityID != matched.identity.id {
                    resetIdentityLivenessState(to: matched.identity.id)
                }
                readyMatch = matched
                if livenessEnabled {
                    let snapshot = liveness.observe(livenessFrame)
                    switch snapshot.decision {
                    case .denied:
                        Self.log.info("App Lock liveness denied: \(snapshot.decision.denialReason ?? "spoof", privacy: .public)")
                        return .failed("Couldn’t confirm a live face.", canRetry: true)
                    case .confirmed:
                        livenessConfirmed = true
                    case .pending:
                        break
                    }
                }
            } else {
                resetIdentityLivenessState()
                if livenessEnabled {
                    let snapshot = liveness.observeUnmatched(livenessFrame)
                    if case .denied = snapshot.decision {
                        Self.log.info("App Lock unmatched liveness denied: \(snapshot.decision.denialReason ?? "spoof", privacy: .public)")
                        return .failed("Couldn’t confirm a live face.", canRetry: true)
                    }
                }
                if wrongFaceStartedAt == nil {
                    wrongFaceStartedAt = .now
                }
                if ContinuousClock.now - wrongFaceStartedAt! >= wrongFaceGraceDuration {
                    return .failed("Face not recognized.", canRetry: true)
                }
            }

            if let readyMatch, livenessConfirmed {
                Self.log.info("App Lock matched identity \(readyMatch.identity.name, privacy: .private) (\(String(format: "%.3f", readyMatch.centroidSimilarity), privacy: .public))")
                return .matched(identityName: readyMatch.identity.name)
            }
        }

        if Task.isCancelled || generation != scanGeneration || activeChallengeID != challengeID {
            return .cancelled
        }
        return .failed("No face detected.", canRetry: true)
    }
}
