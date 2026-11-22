//
//  security_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for Phase 1 v1.3 security hardening contracts:
//    1. Fallback embedder refusal (`isUnlockCapable` / `usingFallbackEmbedder`)
//    2. Multi-identity `bestMatch` skipping stale and blended top candidates
//    3. `VisionFeaturePrintEmbedder.floatVector` bounds, overflow, and unaligned slice safety
//    4. `KeystrokeInjector` zero-String UTF-8->UTF-16 decoding, surrogate-safe batching, and `memset_s` zeroization
//    5. `DeviceBezelDetector.bestCandidateOverlap` multi-candidate spoof bezel selection
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/security_selftest \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/DeviceBezelDetector.swift \
//        glance/FaceDetector.swift \
//        glance/FaceAligner.swift \
//        glance/FaceEmbedder.swift \
//        glance/ArcFaceEmbedder.swift \
//        glance/FaceRecognitionPipeline.swift \
//        glance/FaceEnrollmentStore.swift \
//        glance/SecureFaceStore.swift \
//        glance/SecureCredentialManager.swift \
//        glance/KeychainManager.swift \
//        glance/LockMonitor.swift \
//        glance/KeystrokeInjector.swift \
//        tools/security_selftest.swift \
//      && /tmp/security_selftest
//

import Foundation
import CoreGraphics
import Vision

private struct MockDiscriminativeEmbedder: FaceEmbedder {
    nonisolated let name = "Mock ArcFace"
    nonisolated let modelIdentifier = "arcface-w600k_mbf-v1"
    nonisolated let embeddingDimension = 2
    nonisolated let requiresAlignment = true
    nonisolated let isUnlockCapable = true

    nonisolated func embedding(for face: CGImage) throws -> [Float] { [1, 0] }
}

@main
struct SecuritySelfTest {
    @MainActor
    static func main() {
        runFallbackEmbedderRefusalTests()
        runMultiIdentityBestMatchTests()
        runVisionFeaturePrintBoundsTests()
        runUTF16KeystrokeHygieneTests()
        runDeviceBezelCandidateTests()
        print("\nAll security self-tests passed.")
    }

    @MainActor
    private static func runFallbackEmbedderRefusalTests() {
        let fallback = VisionFeaturePrintEmbedder()
        precondition(!fallback.isUnlockCapable, "FAIL: fallback embedder must not be unlock-capable")
        let pipeline = FaceRecognitionPipeline(embedder: fallback, usingFallbackEmbedder: true, fallbackReason: "test")
        let id = FaceIdentity(
            id: UUID(), name: "Owner",
            samples: [FaceSample(embedding: [1, 0], pose: "center", capturedAt: Date(), quality: 0.9)],
            modelIdentifier: fallback.modelIdentifier, embeddingDimension: 2, createdAt: Date()
        )
        let scored = pipeline.score([1, 0], against: [id])
        precondition(pipeline.bestMatch(in: scored, threshold: 0.50) == nil, "FAIL: fallback matched in bestMatch")

        // Even if usingFallbackEmbedder were false, a non-unlock-capable embedder must still be refused.
        let misconfiguredPipeline = FaceRecognitionPipeline(embedder: fallback, usingFallbackEmbedder: false, fallbackReason: nil)
        precondition(misconfiguredPipeline.bestMatch(in: scored, threshold: 0.50) == nil, "FAIL: non-unlock-capable embedder matched in bestMatch")
        print("PASS: fallback refusal")
    }

    @MainActor
    private static func runMultiIdentityBestMatchTests() {
        let embedder = MockDiscriminativeEmbedder()
        precondition(embedder.isUnlockCapable, "FAIL: mock discriminative embedder must be unlock-capable")
        let pipeline = FaceRecognitionPipeline(embedder: embedder, usingFallbackEmbedder: false, fallbackReason: nil)
        let staleTop = FaceIdentity(
            id: UUID(), name: "Stale",
            samples: [FaceSample(embedding: [1, 0], pose: "center", capturedAt: Date(), quality: 0.9)],
            modelIdentifier: "old-model", embeddingDimension: 2, createdAt: Date()
        )
        let blendedTop = FaceIdentity(
            id: UUID(), name: "Blended",
            samples: [
                FaceSample(embedding: [0.6, 0.8], pose: "left", capturedAt: Date(), quality: 0.9),
                FaceSample(embedding: [0.6, -0.8], pose: "right", capturedAt: Date(), quality: 0.9),
            ],
            modelIdentifier: embedder.modelIdentifier, embeddingDimension: 2, createdAt: Date()
        )
        let valid = FaceIdentity(
            id: UUID(), name: "Valid",
            samples: [FaceSample(embedding: [0.95, 0.31225], pose: "center", capturedAt: Date(), quality: 0.9)],
            modelIdentifier: embedder.modelIdentifier, embeddingDimension: 2, createdAt: Date()
        )
        let scored = pipeline.score([1, 0], against: [staleTop, blendedTop, valid])
        precondition(pipeline.bestMatch(in: scored, threshold: 0.63)?.identity.id == valid.id, "FAIL: skipped valid runner-up")
        print("PASS: multi-identity bestMatch")
    }

    private static func runVisionFeaturePrintBoundsTests() {
        let truncated = Data(repeating: 0, count: 12)
        do {
            _ = try VisionFeaturePrintEmbedder.floatVector(from: truncated, elementCount: 8, elementType: .float)
            fatalError("FAIL: truncated float buffer must throw")
        } catch FaceEmbedderError.corruptedObservationData {} catch {
            fatalError("FAIL: unexpected error \(error)")
        }

        do {
            _ = try VisionFeaturePrintEmbedder.floatVector(from: truncated, elementCount: -1, elementType: .float)
            fatalError("FAIL: negative elementCount must throw")
        } catch FaceEmbedderError.corruptedObservationData {} catch {
            fatalError("FAIL: unexpected error \(error)")
        }

        do {
            _ = try VisionFeaturePrintEmbedder.floatVector(from: truncated, elementCount: Int.max, elementType: .double)
            fatalError("FAIL: overflowing elementCount must throw")
        } catch FaceEmbedderError.corruptedObservationData {} catch {
            fatalError("FAIL: unexpected error \(error)")
        }

        do {
            _ = try VisionFeaturePrintEmbedder.floatVector(from: truncated, elementCount: 1, elementType: .unknown)
            fatalError("FAIL: unsupported elementType must throw")
        } catch FaceEmbedderError.unsupportedElementType {} catch {
            fatalError("FAIL: unexpected error \(error)")
        }

        let expected: [Float] = [0.25, -0.5, 1.75, 3.5]
        var bytes = Data([0xAA])
        expected.withUnsafeBytes { bytes.append(contentsOf: $0) }
        let decoded = try! VisionFeaturePrintEmbedder.floatVector(from: bytes.dropFirst(1), elementCount: 4, elementType: .float)
        precondition(decoded == expected, "FAIL: unaligned float decode mismatch")

        let expectedDoubles: [Double] = [0.25, -0.5, 1.75, 3.5]
        var doubleBytes = Data([0xAA, 0xBB, 0xCC])
        expectedDoubles.withUnsafeBytes { doubleBytes.append(contentsOf: $0) }
        let decodedDoubles = try! VisionFeaturePrintEmbedder.floatVector(from: doubleBytes.dropFirst(3), elementCount: 4, elementType: .double)
        precondition(decodedDoubles == expected, "FAIL: unaligned double decode mismatch")

        let emptyDecoded = try! VisionFeaturePrintEmbedder.floatVector(from: Data(), elementCount: 0, elementType: .float)
        precondition(emptyDecoded.isEmpty, "FAIL: zero elementCount should produce empty array")
        print("PASS: Vision feature-print bounds & alignment")
    }

    private static func runUTF16KeystrokeHygieneTests() {
        let pw = "S3cr3t!päss🔑wörd🔒1234567890"
        guard var utf16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(pw.utf8)) else {
            fatalError("FAIL: valid UTF-8 rejected")
        }
        precondition(utf16 == Array(pw.utf16), "FAIL: UTF-16 mismatch")

        let boundary = String(repeating: "a", count: 19) + "🔒" + "z"
        let bUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(boundary.utf8))!
        let ranges = KeystrokeInjector.splitUTF16BatchRanges(bUTF16, maxBatchLength: 20)
        precondition(ranges == [0..<19, 19..<22], "FAIL: surrogate pair split across batches: \(ranges)")

        let defaultRanges = KeystrokeInjector.splitUTF16BatchRanges(bUTF16)
        precondition(defaultRanges == [0..<19, 19..<22], "FAIL: default maxBatchLength split surrogate pair: \(defaultRanges)")

        precondition(KeystrokeInjector.decodeUTF8ToUTF16(Data()) == [], "FAIL: empty UTF-8 should decode to []")
        precondition(KeystrokeInjector.decodeUTF8ToUTF16(Data([0xC3, 0x28])) == nil, "FAIL: invalid UTF-8 accepted")
        precondition(KeystrokeInjector.decodeUTF8ToUTF16(Data([0xF0, 0x9F])) == nil, "FAIL: truncated UTF-8 accepted")
        precondition(KeystrokeInjector.decodeUTF8ToUTF16(Data([0xC0, 0xAF])) == nil, "FAIL: overlong UTF-8 accepted")

        KeystrokeInjector.zeroizeUTF16Buffer(&utf16)
        precondition(utf16.allSatisfy { $0 == 0 }, "FAIL: buffer not zeroized")
        print("PASS: UTF-16 keystroke hygiene")
    }

    private static func runDeviceBezelCandidateTests() {
        let faceBox = CGRect(x: 520, y: 150, width: 80, height: 80)
        let monitor = CGRect(x: 0, y: 0, width: 500, height: 400)
        let phone = CGRect(x: 500, y: 120, width: 120, height: 180)
        let obs = DeviceBezelDetector.bestCandidateOverlap(candidates: [monitor, phone], faceBoundingBox: faceBox)
        precondition((obs.faceOverlapFraction ?? 0) > 0.99, "FAIL: monitor masked phone bezel")
        print("PASS: DeviceBezelDetector multi-candidate overlap")
    }
}
