//
//  FaceEmbedder.swift
//  glance
//
//  Two implementations: `VisionFeaturePrintEmbedder` (Apple's built-in, but only ~5-7% similarity gap between people —
//  too thin to gate unlock on) and `ArcFaceEmbedder` (real face-discriminative model).
//

import Accelerate
import CoreGraphics
import Vision

/// `nonisolated` so implementations can run on a background task despite the project's default main-actor isolation.
protocol FaceEmbedder: Sendable {
    /// Name shown in the debug UI so it's obvious which embedder produced a given saved sample.
    nonisolated var name: String { get }
    /// Persisted alongside every sample; `SecureFaceStore` uses it to refuse comparing across different embedders
    /// (which wouldn't error, just produce confident nonsense).
    nonisolated var modelIdentifier: String { get }
    /// Declared output length, for cross-model mismatch detection without running an embedding first.
    nonisolated var embeddingDimension: Int { get }
    /// Whether this embedder needs a canonically-aligned input (ArcFace) vs. tolerating a loose crop (Vision feature-print).
    nonisolated var requiresAlignment: Bool { get }
    /// True only for face-discriminative models suitable for gating unlock.
    nonisolated var isUnlockCapable: Bool { get }
    nonisolated func embedding(for face: CGImage) throws -> [Float]
}

enum FaceEmbedderError: LocalizedError {
    case noObservation
    case unsupportedElementType
    case corruptedObservationData

    var errorDescription: String? {
        switch self {
        case .noObservation:
            return "Vision did not produce a feature print for this image."
        case .unsupportedElementType:
            return "Feature print used an unexpected element type."
        case .corruptedObservationData:
            return "Feature print observation data was truncated or malformed."
        }
    }
}

struct VisionFeaturePrintEmbedder: FaceEmbedder {
    nonisolated let name = "Vision Feature Print"
    nonisolated let modelIdentifier = "vision-feature-print-v1"
    // Nominal hint only — `modelIdentifier` is the real discriminator `SecureFaceStore` relies on.
    nonisolated let embeddingDimension = 2048
    nonisolated let requiresAlignment = false
    nonisolated let isUnlockCapable = false

    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: face, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceEmbedderError.noObservation
        }
        return try Self.floatVector(from: observation)
    }

    /// Decodes Vision's raw bytes + element type into `[Float]` so it can persist as plain JSON and be averaged.
    nonisolated private static func floatVector(from observation: VNFeaturePrintObservation) throws -> [Float] {
        try floatVector(
            from: observation.data, elementCount: observation.elementCount, elementType: observation.elementType)
    }

    /// Bounds-checked, overflow-safe, unaligned-safe decoder for feature-print observation payloads.
    nonisolated static func floatVector(
        from data: Data,
        elementCount count: Int,
        elementType: VNElementType
    ) throws -> [Float] {
        guard count >= 0 else {
            throw FaceEmbedderError.corruptedObservationData
        }
        switch elementType {
        case .float:
            return try decodeElements(Float.self, from: data, count: count)
        case .double:
            return try decodeElements(Double.self, from: data, count: count).map(Float.init)
        default:
            throw FaceEmbedderError.unsupportedElementType
        }
    }

    nonisolated private static func decodeElements<Element: Numeric>(
        _ type: Element.Type,
        from data: Data,
        count: Int
    ) throws -> [Element] {
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        guard !overflow, data.count >= byteCount else {
            throw FaceEmbedderError.corruptedObservationData
        }
        guard count > 0 else { return [] }
        var result = [Element](repeating: .zero, count: count)
        let range = data.startIndex..<data.index(data.startIndex, offsetBy: byteCount)
        result.withUnsafeMutableBytes { dst in
            _ = data.copyBytes(to: dst, from: range)
        }
        return result
    }
}

nonisolated enum FaceEmbedding {
    /// Scales `vector` to unit length using SIMD-accelerated vDSP; matters once vectors are combined (see `average` below).
    static func l2Normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        var norm = sumSquares.squareRoot()
        guard norm > 0 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &norm, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Cosine similarity, range -1...1. The raw value ArcFace thresholds are quoted in (typical cutoffs ~0.28-0.40).
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let length = vDSP_Length(lhs.count)
        var dot: Float = 0
        var normLHS: Float = 0
        var normRHS: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, length)
        vDSP_svesq(lhs, 1, &normLHS, length)
        vDSP_svesq(rhs, 1, &normRHS, length)
        guard normLHS > 0, normRHS > 0 else { return 0 }
        return dot / (normLHS.squareRoot() * normRHS.squareRoot())
    }

    /// For the legacy Vision-feature-print UI only. Don't use to tune ArcFace thresholds — use `cosineSimilarity` directly.
    static func similarityPercent(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let similarity = cosineSimilarity(lhs, rhs)
        return Double((similarity + 1) / 2) * 100
    }

    /// Normalize each sample, average, then renormalize — a plain element-wise mean would let a larger-magnitude
    /// sample silently dominate.
    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let dimension = first.count
        let length = vDSP_Length(dimension)
        var sum = [Float](repeating: 0, count: dimension)
        for vector in vectors where vector.count == dimension {
            let normalized = l2Normalized(vector)
            vDSP_vadd(sum, 1, normalized, 1, &sum, 1, length)
        }
        var divisor = Float(vectors.count)
        var mean = [Float](repeating: 0, count: dimension)
        vDSP_vsdiv(sum, 1, &divisor, &mean, 1, length)
        return l2Normalized(mean)
    }
}
