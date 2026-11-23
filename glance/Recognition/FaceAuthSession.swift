//
//  FaceAuthSession.swift
//  glance
//
//  Shared identity-bound face recognition + liveness evaluation state machine used by
//  Lock Screen Face Unlock, App Lock, and Sudo PAM authentication so Phase-1 security
//  ordering (match before confirm-liveness, identity-change reset, unmatched deny cues,
//  and wrong-face grace window) stays identical across all three flows.
//

import CoreGraphics
import Foundation

nonisolated struct ExtractedAuthFrame: @unchecked Sendable {
    let luminance: Double?
    let recognition: FaceRecognitionResult?
    let livenessFrame: LivenessFrame?
}

enum FaceAuthStepOutcome {
    case pending
    case matched(ScoredIdentity, confirmingCue: LivenessCue?)
    case spoofDenied(reason: String?)
    case wrongFaceTimedOut
}

@MainActor
final class FaceAuthEvaluator {
    private let pipeline: FaceRecognitionPipeline
    private let livenessEnabled: Bool
    private let liveness: LivenessAnalyzer
    private let wrongFaceGraceDuration: Duration

    private var wrongFaceStartedAt: ContinuousClock.Instant?
    private var readyMatch: ScoredIdentity?
    private var matchedIdentityID: UUID?
    private var livenessConfirmed: Bool
    private(set) var lastFaceBoundingBox: CGRect?

    init(
        pipeline: FaceRecognitionPipeline,
        livenessEnabled: Bool,
        livenessModeProvider: @escaping () -> LivenessMode,
        wrongFaceGraceDuration: Duration = .seconds(2)
    ) {
        self.pipeline = pipeline
        self.livenessEnabled = livenessEnabled
        let analyzer = LivenessAnalyzer()
        analyzer.modeProvider = livenessModeProvider
        self.liveness = analyzer
        self.livenessConfirmed = !livenessEnabled
        self.wrongFaceGraceDuration = wrongFaceGraceDuration
    }

    /// Runs Vision detection, alignment, ArcFace embedding, and liveness feature extraction off `@MainActor`.
    nonisolated static func extractFrame(
        from frame: CameraFrame,
        pipeline: FaceRecognitionPipeline,
        previousBoundingBox: CGRect?,
        nightBoostEnabled: Bool = false
    ) async -> ExtractedAuthFrame {
        await Task.detached(priority: .userInitiated) {
            let measuredLuminance = nightBoostEnabled ? SceneLuminance.meanLuminance(of: frame.image) : nil
            let recognitionResult: FaceRecognitionResult?
            if let measuredLuminance, measuredLuminance < SceneLuminance.enhanceThreshold {
                // Only the 640px working frame is lifted for Vision/ArcFace; liveness and glare cues
                // continue to inspect the unenhanced original frame and native sensor crop below.
                let enhancedImage = LowLightEnhancer.enhance(frame.image, meanLuminance: measuredLuminance)
                recognitionResult = try? pipeline.recognize(
                    in: enhancedImage,
                    preferNear: previousBoundingBox,
                    includeQuality: false
                )
            } else {
                recognitionResult = try? pipeline.recognize(
                    in: frame,
                    preferNear: previousBoundingBox,
                    includeQuality: false
                )
            }
            guard let result = recognitionResult else {
                return ExtractedAuthFrame(luminance: measuredLuminance, recognition: nil, livenessFrame: nil)
            }
            let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
            let livenessFrame = LivenessFeatureExtractor.extract(
                from: result,
                frame: frame.image,
                faceCrop: faceCrop
            )
            return ExtractedAuthFrame(
                luminance: measuredLuminance,
                recognition: result,
                livenessFrame: livenessFrame
            )
        }.value
    }

    /// Evaluates one freshly extracted frame while preserving identity-bound liveness invariants.
    func evaluate(
        _ extracted: ExtractedAuthFrame,
        activeIdentities: [FaceIdentity],
        threshold: Float,
        now: ContinuousClock.Instant = .now
    ) -> FaceAuthStepOutcome {
        guard let result = extracted.recognition, let livenessFrame = extracted.livenessFrame else {
            wrongFaceStartedAt = nil
            lastFaceBoundingBox = nil
            resetIdentityLivenessState()
            return .pending
        }

        lastFaceBoundingBox = result.face.normalizedBoundingBox

        // Score & match BEFORE updating confirm-liveness, binding confirmation to `matchedIdentityID`.
        let scored = pipeline.score(result.embedding, against: activeIdentities)
        let matched = pipeline.bestMatch(in: scored, threshold: threshold)

        if let matched {
            return evaluateMatched(matched, livenessFrame: livenessFrame)
        }
        return evaluateUnmatched(livenessFrame: livenessFrame, now: now)
    }

    private func evaluateMatched(
        _ matched: ScoredIdentity,
        livenessFrame: LivenessFrame
    ) -> FaceAuthStepOutcome {
        wrongFaceStartedAt = nil
        if matchedIdentityID != matched.identity.id {
            resetIdentityLivenessState(to: matched.identity.id)
        }
        readyMatch = matched

        var confirmingCue: LivenessCue?
        if livenessEnabled {
            let snapshot = liveness.observe(livenessFrame)
            switch snapshot.decision {
            case .denied:
                return .spoofDenied(reason: snapshot.decision.denialReason)
            case .confirmed(let cue):
                livenessConfirmed = true
                confirmingCue = cue
            case .pending:
                break
            }
        }

        if let readyMatch, livenessConfirmed {
            return .matched(readyMatch, confirmingCue: confirmingCue)
        }
        return .pending
    }

    private func evaluateUnmatched(
        livenessFrame: LivenessFrame,
        now: ContinuousClock.Instant
    ) -> FaceAuthStepOutcome {
        resetIdentityLivenessState()
        if livenessEnabled {
            let snapshot = liveness.observeUnmatched(livenessFrame)
            if case .denied = snapshot.decision {
                return .spoofDenied(reason: snapshot.decision.denialReason)
            }
        }

        let start = wrongFaceStartedAt ?? now
        wrongFaceStartedAt = start
        if now - start >= wrongFaceGraceDuration {
            return .wrongFaceTimedOut
        }
        return .pending
    }

    private func resetIdentityLivenessState(to newIdentityID: UUID? = nil) {
        readyMatch = nil
        matchedIdentityID = newIdentityID
        livenessConfirmed = !livenessEnabled
        if livenessEnabled {
            liveness.resetConfirmations()
        }
    }
}
