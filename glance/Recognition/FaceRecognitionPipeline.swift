//
//  FaceRecognitionPipeline.swift
//  glance
//
//  Only place that should construct a FaceEmbedder — keeps all consumers in sync.
//

import CoreGraphics
import Foundation
import Observation
import os

nonisolated struct FaceRecognitionResult {
    let embedding: [Float]
    /// What was actually fed to the embedder, for debug UIs to inspect.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let quality: Float?
    let face: DetectedFace
    /// Phase-2 native-resolution crop (`paddingFraction = 0.5`, `maxEdge = 512`) and its
    /// clipped working-frame rect, plus the detected crop face (carrying high-res landmarks),
    /// so liveness can zero-copy slice glare crops and reuse Pass-2 landmarks.
    let nativeCrop: CGImage?
    let nativeCropWorkingRect: CGRect?
    let nativeCropFace: DetectedFace?

    init(
        embedding: [Float],
        alignedImage: CGImage,
        alignmentTier: AlignmentTier,
        quality: Float?,
        face: DetectedFace,
        nativeCrop: CGImage? = nil,
        nativeCropWorkingRect: CGRect? = nil,
        nativeCropFace: DetectedFace? = nil
    ) {
        self.embedding = embedding
        self.alignedImage = alignedImage
        self.alignmentTier = alignmentTier
        self.quality = quality
        self.face = face
        self.nativeCrop = nativeCrop
        self.nativeCropWorkingRect = nativeCropWorkingRect
        self.nativeCropFace = nativeCropFace
    }
}

nonisolated enum FaceRecognitionPipelineError: LocalizedError {
    case noFaceDetected
    case alignmentFailed

    var errorDescription: String? {
        switch self {
        case .noFaceDetected: return "No face detected in frame."
        case .alignmentFailed: return "Could not align the detected face."
        }
    }
}

/// `@Observable` so Settings and Face Lab can observe model load progress and which embedder is active.
@Observable
@MainActor
final class FaceRecognitionPipeline {
    nonisolated enum LoadState: Equatable, Sendable {
        case loading
        case ready
        case fallback(String)
    }

    private struct PipelineState: Sendable {
        var embedder: FaceEmbedder
        var usingFallbackEmbedder: Bool
        var fallbackReason: String?
        var loadState: LoadState
        var loadTask: Task<Void, Never>?
    }

    @ObservationIgnored
    private nonisolated let stateLock: OSAllocatedUnfairLock<PipelineState>

    nonisolated var loadState: LoadState {
        access(keyPath: \.loadState)
        return stateLock.withLock { $0.loadState }
    }

    nonisolated var embedder: FaceEmbedder {
        access(keyPath: \.loadState)
        return currentEmbedder()
    }

    /// Set when ArcFace failed to load (see tools/convert_arcface.py) and the weaker Vision feature-print embedder is in use instead.
    nonisolated var usingFallbackEmbedder: Bool {
        access(keyPath: \.loadState)
        return stateLock.withLock { $0.usingFallbackEmbedder }
    }

    nonisolated var fallbackReason: String? {
        access(keyPath: \.loadState)
        return stateLock.withLock { $0.fallbackReason }
    }

    /// True only when loading finished and a face-discriminative model (not the Vision fallback) is active and eligible to gate unlock.
    nonisolated var isUnlockCapable: Bool {
        access(keyPath: \.loadState)
        return stateLock.withLock { state in
            state.loadState == .ready && !state.usingFallbackEmbedder && state.embedder.isUnlockCapable
        }
    }

    nonisolated func currentEmbedder() -> FaceEmbedder {
        stateLock.withLock { $0.embedder }
    }

    /// Suspends until any background model load finishes; safe for multiple concurrent callers.
    nonisolated func waitUntilReady() async {
        let task = stateLock.withLock { $0.loadTask }
        await task?.value
    }

    private init(
        embedder: FaceEmbedder,
        usingFallbackEmbedder: Bool,
        fallbackReason: String?,
        initialLoadState: LoadState
    ) {
        self.stateLock = OSAllocatedUnfairLock(
            initialState: PipelineState(
                embedder: embedder,
                usingFallbackEmbedder: usingFallbackEmbedder,
                fallbackReason: fallbackReason,
                loadState: initialLoadState,
                loadTask: nil
            )
        )
    }

    convenience init(embedder: FaceEmbedder, usingFallbackEmbedder: Bool, fallbackReason: String?) {
        let resolvedState: LoadState = usingFallbackEmbedder ? .fallback(fallbackReason ?? "Fallback") : .ready
        self.init(
            embedder: embedder,
            usingFallbackEmbedder: usingFallbackEmbedder,
            fallbackReason: fallbackReason,
            initialLoadState: resolvedState
        )
    }

    convenience init(
        asyncLoad: Bool = true,
        loader: @escaping @Sendable () throws -> FaceEmbedder = { try ArcFaceEmbedder() }
    ) {
        if !asyncLoad {
            do {
                let loaded = try loader()
                self.init(embedder: loaded, usingFallbackEmbedder: false, fallbackReason: nil)
            } catch {
                self.init(
                    embedder: VisionFeaturePrintEmbedder(),
                    usingFallbackEmbedder: true,
                    fallbackReason: error.localizedDescription
                )
            }
            return
        }

        // Fail closed while ArcFace compiles/loads off `@MainActor`.
        self.init(
            embedder: VisionFeaturePrintEmbedder(),
            usingFallbackEmbedder: true,
            fallbackReason: "Face recognition model is still loading.",
            initialLoadState: .loading
        )

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: (embedder: FaceEmbedder, usingFallback: Bool, reason: String?, loadState: LoadState)
            do {
                let loaded = try loader()
                outcome = (loaded, false, nil, .ready)
            } catch {
                let reason = error.localizedDescription
                outcome = (VisionFeaturePrintEmbedder(), true, reason, .fallback(reason))
            }
            guard let self else { return }
            await self.finishAsyncLoad(
                embedder: outcome.embedder,
                usingFallbackEmbedder: outcome.usingFallback,
                fallbackReason: outcome.reason,
                loadState: outcome.loadState
            )
        }
        stateLock.withLock { $0.loadTask = task }
    }

    private nonisolated func finishAsyncLoad(
        embedder: FaceEmbedder,
        usingFallbackEmbedder: Bool,
        fallbackReason: String?,
        loadState: LoadState
    ) async {
        stateLock.withLock { state in
            state.embedder = embedder
            state.usingFallbackEmbedder = usingFallbackEmbedder
            state.fallbackReason = fallbackReason
            state.loadState = loadState
        }
        await MainActor.run { [weak self] in
            self?.withMutation(keyPath: \.loadState) {}
        }
    }

    /// `nonisolated` so callers can run detect/align/embed from a background task instead of blocking the main actor.
    /// - Parameter previousBoundingBox: previous frame's selected box, if any — lets a continuous scanner keep selection "stuck" to the same person instead of re-picking every frame.
    nonisolated func recognize(
        in frame: CGImage,
        preferNear previousBoundingBox: CGRect? = nil,
        includeQuality: Bool = true
    ) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame, includeQuality: includeQuality)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame)
    }

    /// Two-phase recognition on a `CameraFrame`: detects faces in the 640px working frame, then (when
    /// the camera's native sensor exceeds `nativeUpscaleThreshold`) re-detects, aligns, and embeds from
    /// a native-resolution padded crop (`512px` max edge) while keeping `result.face` in working-frame
    /// coordinates so liveness and frame-to-frame continuity tracking remain unchanged.
    nonisolated func recognize(
        in frame: CameraFrame,
        preferNear previousBoundingBox: CGRect? = nil,
        includeQuality: Bool = true
    ) throws -> FaceRecognitionResult {
        let workingWidth = CGFloat(frame.image.width)
        let willAttemptNativeCrop =
            workingWidth > 0 && (frame.sourceSize.width / workingWidth) > Self.nativeUpscaleThreshold
        // Skip quality and landmarks on the 640px pass when Phase 2 will run both on the 512px native crop.
        let faces = try FaceDetector.detectFaces(
            in: frame.image,
            includeQuality: willAttemptNativeCrop ? false : includeQuality,
            includeLandmarks: !willAttemptNativeCrop
        )
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame, includeQuality: includeQuality)
    }

    /// Aligns and embeds an already-chosen face from a `CameraFrame`, using a native-resolution crop when
    /// `frame.sourceSize` is sufficiently larger than `frame.image`, and falling back cleanly to `frame.image`.
    nonisolated func recognize(
        _ face: DetectedFace,
        in frame: CameraFrame,
        includeQuality: Bool = true
    ) throws -> FaceRecognitionResult {
        let workingWidth = CGFloat(frame.image.width)
        let workingSize = CGSize(width: workingWidth, height: CGFloat(frame.image.height))
        let upscale = workingWidth > 0 ? frame.sourceSize.width / workingWidth : 1

        if upscale > Self.nativeUpscaleThreshold,
            let clippedWorkingRect = Self.nativeCropWorkingRect(
                for: face.boundingBox,
                paddingFraction: Self.nativeCropPadding,
                inWorkingSize: workingSize
            ),
            let nativeCrop = frame.renderCrop(
                imageRect: face.boundingBox,
                paddingFraction: Self.nativeCropPadding,
                maxEdge: Self.nativeCropMaxEdge
            ),
            let cropFaces = try? FaceDetector.detectFaces(in: nativeCrop, includeQuality: includeQuality),
            let cropFace = Self.selectCropFace(
                in: cropFaces,
                correspondingTo: face,
                clippedWorkingRect: clippedWorkingRect
            ),
            let cropResult = try? recognize(cropFace, in: nativeCrop)
        {
            let quality = includeQuality ? cropFace.quality : nil
            return FaceRecognitionResult(
                embedding: cropResult.embedding,
                alignedImage: cropResult.alignedImage,
                alignmentTier: cropResult.alignmentTier,
                quality: quality,
                face: face.withQuality(quality),
                nativeCrop: nativeCrop,
                nativeCropWorkingRect: clippedWorkingRect,
                nativeCropFace: cropFace
            )
        }

        let resolvedFace = resolveFaceForWorkingFrame(face, in: frame.image, includeQuality: includeQuality)
        return try recognize(resolvedFace, in: frame.image)
    }

    /// Aligns and embeds an already-chosen face; enrollment uses this to bypass the prominence filter so a too-small face reads as "move closer" rather than "nobody there".
    nonisolated func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult {
        // Snapshot the embedder once so alignment and inference always match the same model.
        let activeEmbedder = currentEmbedder()
        let inputImage: CGImage
        let tier: AlignmentTier
        if activeEmbedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            guard let cropped = FaceDetector.crop(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = cropped
            tier = .paddedCrop
        }

        let embedding = try activeEmbedder.embedding(for: inputImage)
        return FaceRecognitionResult(
            embedding: embedding, alignedImage: inputImage, alignmentTier: tier, quality: face.quality, face: face)
    }

    /// Largest face by area with no prominence cutoff — unlike `selectDominantFace`, so enrollment can tell "too far" apart from "no face".
    nonisolated static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Padding around `face.boundingBox` when rendering the Phase-2 native-resolution recognition crop.
    nonisolated private static let nativeCropPadding: CGFloat = 0.5
    /// Max long edge (in pixels) for the Phase-2 native-resolution recognition crop.
    nonisolated private static let nativeCropMaxEdge: CGFloat = 512
    /// Only re-crop from `frame.source` when native width exceeds working width by more than 25%.
    nonisolated private static let nativeUpscaleThreshold: CGFloat = 1.25

    /// Absolute minimum face width in working-frame pixels (~64px at 640px working width) so wide-angle
    /// webcams at natural seating distance (~14% of frame) work without lowering the floor into tiny background noise.
    nonisolated static let minimumFacePixelWidth: CGFloat = 64
    /// Secondary faces narrower than 60% of the widest face are treated as bystanders rather than continuity targets.
    nonisolated static let bystanderRelativeWidth: CGFloat = 0.6
    /// Minimum normalized width enforced when `strictCloseRangeOnly` is enabled (busy/open-plan spaces).
    nonisolated static let strictCloseRangeMinimumWidth: CGFloat = 0.18
    /// Mirrored from `GlanceSettings.strictCloseRangeOnly` so background scans can read it without hopping to `@MainActor`.
    nonisolated(unsafe) static var strictCloseRangeOnly: Bool = false

    /// Max normalized-coordinate drift between frames still counted as "the same person".
    nonisolated private static let continuityDistanceTolerance: CGFloat = 0.3

    /// Picks the person actually at the camera, not a bystander: keeps faces at least `minimumFacePixelWidth`
    /// wide and at least `bystanderRelativeWidth` of the widest face (plus `strictCloseRangeMinimumWidth` when
    /// `strictCloseRangeOnly` is active), then prefers continuity with `previousBoundingBox` over raw largest-by-area
    /// so two similarly-sized faces can't flip-flop frame to frame.
    nonisolated static func selectDominantFace(in faces: [DetectedFace], preferNear previousBoundingBox: CGRect? = nil)
        -> DetectedFace?
    {
        guard let widest = faces.map(\.boundingBox.width).max() else { return nil }
        let relativeFloor = widest * bystanderRelativeWidth
        let candidates = faces.filter { face in
            face.boundingBox.width >= minimumFacePixelWidth
                && face.boundingBox.width >= relativeFloor
                && (!strictCloseRangeOnly || face.normalizedBoundingBox.width >= strictCloseRangeMinimumWidth)
        }
        guard !candidates.isEmpty else { return nil }

        if let previous = previousBoundingBox {
            let previousCenter = CGPoint(x: previous.midX, y: previous.midY)
            if let nearest = candidates.min(by: {
                distance(from: $0, to: previousCenter) < distance(from: $1, to: previousCenter)
            }),
                distance(from: nearest, to: previousCenter) < continuityDistanceTolerance
            {
                return nearest
            }
        }

        return candidates.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
    }

    nonisolated private func resolveFaceForWorkingFrame(
        _ face: DetectedFace,
        in image: CGImage,
        includeQuality: Bool
    ) -> DetectedFace {
        let needsQuality = includeQuality && face.quality == nil
        let needsLandmarks = face.landmarks == nil
        guard needsQuality || needsLandmarks else {
            return (!includeQuality && face.quality != nil) ? face.withQuality(nil) : face
        }
        let targetCenter = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        guard let faces = try? FaceDetector.detectFaces(
            in: image,
            includeQuality: needsQuality,
            includeLandmarks: needsLandmarks
        ),
            let matched = faces.min(by: {
                Self.distance(from: $0, to: targetCenter) < Self.distance(from: $1, to: targetCenter)
            })
        else {
            return (!includeQuality && face.quality != nil) ? face.withQuality(nil) : face
        }
        return DetectedFace(
            boundingBox: face.boundingBox,
            normalizedBoundingBox: face.normalizedBoundingBox,
            quality: includeQuality ? (face.quality ?? matched.quality) : nil,
            yaw: face.yaw ?? matched.yaw,
            roll: face.roll ?? matched.roll,
            pitch: face.pitch ?? matched.pitch,
            landmarks: face.landmarks ?? matched.landmarks,
            imageSize: face.imageSize
        )
    }

    /// Computes the working-frame rectangle (`top-left/y-down`) covered by a padded crop of `boundingBox`,
    /// clamped by `intersection` with `CGRect(origin: .zero, size: workingSize)`.
    nonisolated static func nativeCropWorkingRect(
        for boundingBox: CGRect,
        paddingFraction: CGFloat = nativeCropPadding,
        inWorkingSize workingSize: CGSize
    ) -> CGRect? {
        guard workingSize.width > 0, workingSize.height > 0,
            boundingBox.width > 0, boundingBox.height > 0
        else { return nil }
        let expanded = boundingBox.insetBy(
            dx: -boundingBox.width * paddingFraction,
            dy: -boundingBox.height * paddingFraction
        )
        let clipped = expanded.intersection(CGRect(origin: .zero, size: workingSize))
        guard !clipped.isNull, !clipped.isEmpty, clipped.width > 0, clipped.height > 0 else { return nil }
        return clipped
    }

    /// Max normalized distance from `expectedCenter` in `nativeCrop` for a re-detected face to still match `workingFace`.
    nonisolated private static let maxCropFaceCenterDistance: CGFloat = 0.45

    nonisolated private static func selectCropFace(
        in cropFaces: [DetectedFace],
        correspondingTo workingFace: DetectedFace,
        clippedWorkingRect: CGRect
    ) -> DetectedFace? {
        guard !cropFaces.isEmpty, clippedWorkingRect.width > 0, clippedWorkingRect.height > 0 else { return nil }

        let expectedCenter = CGPoint(
            x: (workingFace.boundingBox.midX - clippedWorkingRect.minX) / clippedWorkingRect.width,
            y: (workingFace.boundingBox.midY - clippedWorkingRect.minY) / clippedWorkingRect.height
        )
        let nearest =
            cropFaces
            .map { face -> (face: DetectedFace, distance: CGFloat) in
                let center = CGPoint(
                    x: face.boundingBox.midX / max(face.imageSize.width, 1),
                    y: face.boundingBox.midY / max(face.imageSize.height, 1)
                )
                return (face, hypot(center.x - expectedCenter.x, center.y - expectedCenter.y))
            }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= maxCropFaceCenterDistance else { return nil }
        return nearest.face
    }

    nonisolated private static func distance(from face: DetectedFace, to point: CGPoint) -> CGFloat {
        let center = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        return hypot(center.x - point.x, center.y - point.y)
    }
}

nonisolated struct ScoredIdentity {
    let identity: FaceIdentity
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest individual sample — catches
    /// cases where averaging blurred together poses that shouldn't be
    /// blended.
    let maxSampleSimilarity: Float
}

extension FaceRecognitionPipeline {
    /// Sorted by centroid similarity descending; includes stale identities (different embedder) since `bestMatch` is what excludes them from actually matching.
    nonisolated func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        identities.compactMap { identity in
            guard let template = identity.template, !identity.samples.isEmpty else { return nil }
            let centroidSim = FaceEmbedding.cosineSimilarity(embedding, template)
            let maxSim =
                identity.samples
                .map { FaceEmbedding.cosineSimilarity(embedding, $0.embedding) }
                .max() ?? centroidSim
            return ScoredIdentity(identity: identity, centroidSimilarity: centroidSim, maxSampleSimilarity: maxSim)
        }.sorted { $0.centroidSimilarity > $1.centroidSimilarity }
    }

    /// Shared by Face Lab and FaceUnlockCoordinator so tuning stays consistent. No runner-up margin check: the same person can be enrolled multiple times under different appearances, so two of their own profiles legitimately score close together — a margin check can't tell that apart from two different people colliding.
    nonisolated func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        let snapshot = stateLock.withLock { state in
            (
                isUnlockCapable: state.loadState == .ready
                    && !state.usingFallbackEmbedder
                    && state.embedder.isUnlockCapable,
                embedder: state.embedder
            )
        }
        guard snapshot.isUnlockCapable else { return nil }
        return scored.first { candidate in
            !candidate.identity.isStale(comparedTo: snapshot.embedder)
                && candidate.centroidSimilarity >= threshold
                && candidate.maxSampleSimilarity >= threshold
        }
    }
}
