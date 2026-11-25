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
    let precomputedGeometry: GeometryLivenessResult?
    let geometryGeneration: UInt64?

    init(
        luminance: Double?,
        recognition: FaceRecognitionResult?,
        livenessFrame: LivenessFrame?,
        precomputedGeometry: GeometryLivenessResult? = nil,
        geometryGeneration: UInt64? = nil
    ) {
        self.luminance = luminance
        self.recognition = recognition
        self.livenessFrame = livenessFrame
        self.precomputedGeometry = precomputedGeometry
        self.geometryGeneration = geometryGeneration
    }
}

enum FaceAuthStepOutcome {
    case pending
    case matched(ScoredIdentity, confirmingCue: LivenessCue?)
    case spoofDenied(reason: String?)
    case wrongFaceTimedOut
}

@MainActor
protocol FrameBackpressureTarget: AnyObject {
    func setConsumerBusy(_ busy: Bool)
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

    /// Snapshots the rolling liveness window when Heavy geometry needs to run off `@MainActor`.
    func geometryContextIfNeeded() -> LivenessAnalyzer.GeometryEvaluationContext? {
        guard livenessEnabled else { return nil }
        return liveness.heavyGeometryContextIfNeeded()
    }

    /// Zero-copy slices the `padding 0.15` glare crop out of Phase-2 `nativeCrop` when present,
    /// falling back to `CameraManager.renderCrop` when `nativeCrop` is unavailable or slicing fails.
    nonisolated static func glareCrop(from frame: CameraFrame, recognition result: FaceRecognitionResult) -> CGImage? {
        if let nativeCrop = result.nativeCrop,
            let nativeCropWorkingRect = result.nativeCropWorkingRect,
            let sliced = CameraFrame.sliceGlareCrop(
                from: nativeCrop,
                nativeCropWorkingRect: nativeCropWorkingRect,
                faceBoundingBox: result.face.boundingBox,
                workingSize: result.face.imageSize
            )
        {
            return sliced
        }
        return CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
    }

    /// Runs Vision detection, alignment, ArcFace embedding, and optional liveness + Heavy geometry extraction off `@MainActor`.
    nonisolated static func extractFrame(
        from frame: CameraFrame,
        pipeline: FaceRecognitionPipeline,
        previousBoundingBox: CGRect?,
        strictCloseRangeOnly: Bool,
        livenessEnabled: Bool = true,
        nightBoostEnabled: Bool = false,
        geometryContext: LivenessAnalyzer.GeometryEvaluationContext? = nil
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
                    includeQuality: false,
                    strictCloseRangeOnly: strictCloseRangeOnly
                )
            } else {
                recognitionResult = try? pipeline.recognize(
                    in: frame,
                    preferNear: previousBoundingBox,
                    includeQuality: false,
                    strictCloseRangeOnly: strictCloseRangeOnly
                )
            }
            guard let result = recognitionResult else {
                return ExtractedAuthFrame(luminance: measuredLuminance, recognition: nil, livenessFrame: nil)
            }
            guard livenessEnabled else {
                return ExtractedAuthFrame(luminance: measuredLuminance, recognition: result, livenessFrame: nil)
            }
            let faceCrop = glareCrop(from: frame, recognition: result)
            let livenessFrame = LivenessFeatureExtractor.extract(
                from: result,
                frame: frame.image,
                faceCrop: faceCrop
            )
            let precomputedGeometry = geometryContext?.computeGeometry(appending: livenessFrame)
            return ExtractedAuthFrame(
                luminance: measuredLuminance,
                recognition: result,
                livenessFrame: livenessFrame,
                precomputedGeometry: precomputedGeometry,
                geometryGeneration: geometryContext?.generation
            )
        }.value
    }

    /// Runs `extract` with camera consumer backpressure active, clearing the busy flag only if
    /// this call is still the active generation when `extract` finishes or cancels.
    func extractFrameWithBackpressure(
        camera: any FrameBackpressureTarget,
        isCurrentGeneration: () -> Bool,
        extract: @escaping @Sendable () async -> ExtractedAuthFrame
    ) async -> ExtractedAuthFrame {
        camera.setConsumerBusy(true)
        defer {
            if isCurrentGeneration() {
                camera.setConsumerBusy(false)
            }
        }
        return await extract()
    }

    /// Extracts features and optional liveness from `frame` while managing camera backpressure
    /// for the caller's scan generation.
    func extractFrameWithBackpressure(
        from frame: CameraFrame,
        camera: any FrameBackpressureTarget,
        strictCloseRangeOnly: Bool,
        nightBoostEnabled: Bool = false,
        isCurrentGeneration: () -> Bool
    ) async -> ExtractedAuthFrame {
        let pipeline = self.pipeline
        let previousBoundingBox = self.lastFaceBoundingBox
        let livenessEnabled = self.livenessEnabled
        let geometryContext = self.geometryContextIfNeeded()
        return await extractFrameWithBackpressure(
            camera: camera,
            isCurrentGeneration: isCurrentGeneration
        ) {
            await Self.extractFrame(
                from: frame,
                pipeline: pipeline,
                previousBoundingBox: previousBoundingBox,
                strictCloseRangeOnly: strictCloseRangeOnly,
                livenessEnabled: livenessEnabled,
                nightBoostEnabled: nightBoostEnabled,
                geometryContext: geometryContext
            )
        }
    }

    /// Evaluates one freshly extracted frame while preserving identity-bound liveness invariants.
    func evaluate(
        _ extracted: ExtractedAuthFrame,
        activeIdentities: [FaceIdentity],
        threshold: Float,
        now: ContinuousClock.Instant = .now
    ) -> FaceAuthStepOutcome {
        guard let result = extracted.recognition else {
            wrongFaceStartedAt = nil
            lastFaceBoundingBox = nil
            resetIdentityLivenessState()
            return .pending
        }
        if livenessEnabled, extracted.livenessFrame == nil {
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
            return evaluateMatched(
                matched,
                livenessFrame: extracted.livenessFrame,
                precomputedGeometry: extracted.precomputedGeometry,
                geometryGeneration: extracted.geometryGeneration
            )
        }
        return evaluateUnmatched(livenessFrame: extracted.livenessFrame, now: now)
    }

    private func evaluateMatched(
        _ matched: ScoredIdentity,
        livenessFrame: LivenessFrame?,
        precomputedGeometry: GeometryLivenessResult?,
        geometryGeneration: UInt64?
    ) -> FaceAuthStepOutcome {
        wrongFaceStartedAt = nil
        if matchedIdentityID != matched.identity.id {
            resetIdentityLivenessState(to: matched.identity.id)
        }
        readyMatch = matched

        var confirmingCue: LivenessCue?
        if livenessEnabled {
            guard let livenessFrame else { return .pending }
            let snapshot = liveness.observe(
                livenessFrame,
                precomputedGeometry: precomputedGeometry,
                sourceGeneration: geometryGeneration
            )
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
        livenessFrame: LivenessFrame?,
        now: ContinuousClock.Instant
    ) -> FaceAuthStepOutcome {
        resetIdentityLivenessState()
        if livenessEnabled {
            guard let livenessFrame else { return .pending }
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
