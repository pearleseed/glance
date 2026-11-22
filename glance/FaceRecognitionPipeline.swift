//
//  FaceRecognitionPipeline.swift
//  glance
//
//  Only place that should construct a FaceEmbedder — keeps all consumers in sync.
//

import Foundation
import CoreGraphics
import Observation

nonisolated struct FaceRecognitionResult {
    let embedding: [Float]
    /// What was actually fed to the embedder, for debug UIs to inspect.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let quality: Float?
    let face: DetectedFace
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

/// `@Observable` so the debug UI can surface which embedder is active.
@Observable
@MainActor
final class FaceRecognitionPipeline {
    nonisolated let embedder: FaceEmbedder

    /// Set when ArcFace failed to load (see tools/convert_arcface.py) and the weaker Vision feature-print embedder is in use instead.
    nonisolated let usingFallbackEmbedder: Bool
    nonisolated let fallbackReason: String?

    init(embedder: FaceEmbedder, usingFallbackEmbedder: Bool, fallbackReason: String?) {
        self.embedder = embedder
        self.usingFallbackEmbedder = usingFallbackEmbedder
        self.fallbackReason = fallbackReason
    }

    convenience init() {
        do {
            self.init(embedder: try ArcFaceEmbedder(), usingFallbackEmbedder: false, fallbackReason: nil)
        } catch {
            self.init(embedder: VisionFeaturePrintEmbedder(), usingFallbackEmbedder: true, fallbackReason: error.localizedDescription)
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
        let willAttemptNativeCrop = workingWidth > 0 && (frame.sourceSize.width / workingWidth) > Self.nativeUpscaleThreshold
        // Skip quality on the 640px pass when we expect to evaluate quality on the high-res crop.
        let faces = try FaceDetector.detectFaces(
            in: frame.image,
            includeQuality: willAttemptNativeCrop ? false : includeQuality
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
        let upscale = workingWidth > 0 ? frame.sourceSize.width / workingWidth : 1

        if upscale > Self.nativeUpscaleThreshold,
           let nativeCrop = frame.renderCrop(
               imageRect: face.boundingBox,
               paddingFraction: Self.nativeCropPadding,
               maxEdge: Self.nativeCropMaxEdge
           ),
           let cropFaces = try? FaceDetector.detectFaces(in: nativeCrop, includeQuality: includeQuality),
           let cropFace = Self.selectCropFace(
               in: cropFaces,
               correspondingTo: face,
               inWorkingSize: CGSize(width: frame.image.width, height: frame.image.height)
           ),
           let cropResult = try? recognize(cropFace, in: nativeCrop) {
            let quality = includeQuality ? cropFace.quality : nil
            return FaceRecognitionResult(
                embedding: cropResult.embedding,
                alignedImage: cropResult.alignedImage,
                alignmentTier: cropResult.alignmentTier,
                quality: quality,
                face: face.withQuality(quality)
            )
        }

        let resolvedFace = faceWithQualityIfNeeded(face, in: frame.image, includeQuality: includeQuality)
        return try recognize(resolvedFace, in: frame.image)
    }

    /// Aligns and embeds an already-chosen face; enrollment uses this to bypass the prominence filter so a too-small face reads as "move closer" rather than "nobody there".
    nonisolated func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult {
        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
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

        let embedding = try embedder.embedding(for: inputImage)
        return FaceRecognitionResult(embedding: embedding, alignedImage: inputImage, alignmentTier: tier, quality: face.quality, face: face)
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
    nonisolated static func selectDominantFace(in faces: [DetectedFace], preferNear previousBoundingBox: CGRect? = nil) -> DetectedFace? {
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
            if let nearest = candidates.min(by: { distance(from: $0, to: previousCenter) < distance(from: $1, to: previousCenter) }),
               distance(from: nearest, to: previousCenter) < continuityDistanceTolerance {
                return nearest
            }
        }

        return candidates.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    nonisolated private func faceWithQualityIfNeeded(_ face: DetectedFace, in image: CGImage, includeQuality: Bool) -> DetectedFace {
        guard includeQuality else {
            return face.quality == nil ? face : face.withQuality(nil)
        }
        guard face.quality == nil else { return face }
        let targetCenter = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        guard let faces = try? FaceDetector.detectFaces(in: image, includeQuality: true),
              let matched = faces.min(by: { Self.distance(from: $0, to: targetCenter) < Self.distance(from: $1, to: targetCenter) }) else {
            return face
        }
        return face.withQuality(matched.quality)
    }

    nonisolated private static func selectCropFace(
        in cropFaces: [DetectedFace],
        correspondingTo workingFace: DetectedFace,
        inWorkingSize workingSize: CGSize
    ) -> DetectedFace? {
        guard !cropFaces.isEmpty else { return nil }
        if cropFaces.count == 1 { return cropFaces[0] }

        let expanded = workingFace.boundingBox.insetBy(
            dx: -workingFace.boundingBox.width * nativeCropPadding,
            dy: -workingFace.boundingBox.height * nativeCropPadding
        )
        let clipped = expanded.intersection(CGRect(origin: .zero, size: workingSize))
        guard clipped.width > 0, clipped.height > 0 else {
            return largestFace(in: cropFaces)
        }

        let expectedCenter = CGPoint(
            x: (workingFace.boundingBox.midX - clipped.minX) / clipped.width,
            y: (workingFace.boundingBox.midY - clipped.minY) / clipped.height
        )
        return cropFaces.min { lhs, rhs in
            let lc = CGPoint(
                x: lhs.boundingBox.midX / max(lhs.imageSize.width, 1),
                y: lhs.boundingBox.midY / max(lhs.imageSize.height, 1)
            )
            let rc = CGPoint(
                x: rhs.boundingBox.midX / max(rhs.imageSize.width, 1),
                y: rhs.boundingBox.midY / max(rhs.imageSize.height, 1)
            )
            return hypot(lc.x - expectedCenter.x, lc.y - expectedCenter.y)
                < hypot(rc.x - expectedCenter.x, rc.y - expectedCenter.y)
        }
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
            let maxSim = identity.samples
                .map { FaceEmbedding.cosineSimilarity(embedding, $0.embedding) }
                .max() ?? centroidSim
            return ScoredIdentity(identity: identity, centroidSimilarity: centroidSim, maxSampleSimilarity: maxSim)
        }.sorted { $0.centroidSimilarity > $1.centroidSimilarity }
    }

    /// Shared by Face Lab and FaceUnlockCoordinator so tuning stays consistent. No runner-up margin check: the same person can be enrolled multiple times under different appearances, so two of their own profiles legitimately score close together — a margin check can't tell that apart from two different people colliding.
    nonisolated func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        guard !usingFallbackEmbedder, embedder.isUnlockCapable else { return nil }
        return scored.first { candidate in
            !candidate.identity.isStale(comparedTo: embedder)
                && candidate.centroidSimilarity >= threshold
                && candidate.maxSampleSimilarity >= threshold
        }
    }
}
