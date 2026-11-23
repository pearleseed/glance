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
//    6. Adaptive seated face selection (`selectDominantFace` + `strictCloseRangeOnly`), pose-aware `qualityTier(of:)`, `CameraFrame.renderCrop`, and `includeQuality` equivalence
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/security_selftest \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/DeviceBezelDetector.swift \
//        glance/Camera/CameraFrame.swift \
//        glance/Recognition/FaceDetector.swift \
//        glance/Recognition/FaceAligner.swift \
//        glance/Recognition/FaceEmbedder.swift \
//        glance/Recognition/ArcFaceEmbedder.swift \
//        glance/Recognition/FaceRecognitionPipeline.swift \
//        glance/Recognition/FaceEnrollmentStore.swift \
//        glance/Security/SecureFaceStore.swift \
//        glance/Security/SecureCredentialManager.swift \
//        glance/Security/KeychainManager.swift \
//        glance/Unlock/LockMonitor.swift \
//        glance/Unlock/KeystrokeInjector.swift \
//        tools/security_selftest.swift \
//      && /tmp/security_selftest
//

import Foundation
import CoreGraphics
import CoreImage
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
        runSeatedDetectionAndQualityTests()
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

        // Combining diacritic (NFD Vietnamese 'e' + circumflex + acute) straddling boundary 20 must stay together.
        let nfd = String(repeating: "a", count: 19) + "e\u{0302}\u{0301}" + "z"
        let nfdUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(nfd.utf8))!
        let nfdRanges = KeystrokeInjector.splitUTF16BatchRanges(nfdUTF16, maxBatchLength: 20)
        precondition(nfdRanges == [0..<19, 19..<23], "FAIL: combining diacritics split across batches: \(nfdRanges)")

        // Emoji ZWJ family cluster ("👨‍👩‍👧") straddling boundary 20 must stay together (on ZWJ and mid-emoji).
        let zwjOnJoiner = String(repeating: "a", count: 17) + "👨‍👩‍👧" + "z"
        let zwjJoinerUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(zwjOnJoiner.utf8))!
        let zwjJoinerRanges = KeystrokeInjector.splitUTF16BatchRanges(zwjJoinerUTF16, maxBatchLength: 20)
        precondition(zwjJoinerRanges == [0..<17, 17..<26], "FAIL: ZWJ family split at joiner boundary: \(zwjJoinerRanges)")

        let zwjMidCluster = String(repeating: "a", count: 15) + "👨‍👩‍👧" + "z"
        let zwjMidUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(zwjMidCluster.utf8))!
        let zwjMidRanges = KeystrokeInjector.splitUTF16BatchRanges(zwjMidUTF16, maxBatchLength: 20)
        precondition(zwjMidRanges == [0..<15, 15..<24], "FAIL: ZWJ family split mid-cluster: \(zwjMidRanges)")

        // Variation selector + ZWJ ("🏳️‍🌈") and skin-tone modifier + ZWJ ("👩🏽‍🔬") straddling boundary 20.
        let flag = String(repeating: "a", count: 17) + "🏳️‍🌈" + "z"
        let flagUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(flag.utf8))!
        let flagRanges = KeystrokeInjector.splitUTF16BatchRanges(flagUTF16, maxBatchLength: 20)
        precondition(flagRanges == [0..<17, 17..<24], "FAIL: variation-selector ZWJ emoji split: \(flagRanges)")

        let scientist = String(repeating: "a", count: 17) + "👩🏽‍🔬" + "z"
        let scientistUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(scientist.utf8))!
        let scientistRanges = KeystrokeInjector.splitUTF16BatchRanges(scientistUTF16, maxBatchLength: 20)
        precondition(scientistRanges == [0..<17, 17..<25], "FAIL: skin-tone ZWJ emoji split: \(scientistRanges)")

        // Regional-indicator flag pair ("🇺🇸") straddling boundary 20 must stay together.
        let riFlag = String(repeating: "a", count: 18) + "🇺🇸" + "z"
        let riFlagUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(riFlag.utf8))!
        let riFlagRanges = KeystrokeInjector.splitUTF16BatchRanges(riFlagUTF16, maxBatchLength: 20)
        precondition(riFlagRanges == [0..<18, 18..<23], "FAIL: regional-indicator flag split: \(riFlagRanges)")

        // Oversized single grapheme cluster (> maxBatchLength) must make forward progress without splitting surrogates.
        let hugeCombining = "e" + String(repeating: "\u{0301}", count: 25) + "z"
        let hugeCombiningUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(hugeCombining.utf8))!
        let hugeCombiningRanges = KeystrokeInjector.splitUTF16BatchRanges(hugeCombiningUTF16, maxBatchLength: 20)
        precondition(hugeCombiningRanges == [0..<20, 20..<27], "FAIL: oversized combining cluster unexpected split: \(hugeCombiningRanges)")

        let hugeZWJCluster = String(repeating: "👨\u{200D}", count: 9) + "👨"
        let hugeZWJUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(hugeZWJCluster.utf8))!
        let hugeZWJRanges = KeystrokeInjector.splitUTF16BatchRanges(hugeZWJUTF16, maxBatchLength: 19)
        precondition(hugeZWJRanges == [0..<18, 18..<29], "FAIL: oversized ZWJ cluster split surrogate pair or failed forward progress: \(hugeZWJRanges)")
        for range in hugeZWJRanges {
            precondition(!range.isEmpty && range.count <= 19, "FAIL: invalid oversized batch range: \(range)")
            precondition(!(0xD800...0xDBFF).contains(hugeZWJUTF16[range.upperBound - 1]), "FAIL: batch ended on high surrogate")
            precondition(!(0xDC00...0xDFFF).contains(hugeZWJUTF16[range.lowerBound]), "FAIL: batch started on low surrogate")
        }

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

    private struct PixelFingerprintEmbedder: FaceEmbedder {
        nonisolated let name = "Pixel Fingerprint Mock"
        nonisolated let modelIdentifier = "arcface-w600k_mbf-v1"
        nonisolated let embeddingDimension = 4
        nonisolated let requiresAlignment = true
        nonisolated let isUnlockCapable = true

        nonisolated func embedding(for face: CGImage) throws -> [Float] {
            guard let data = face.dataProvider?.data,
                  let bytes = CFDataGetBytePtr(data) else {
                return [0, 0, 0, 0]
            }
            let count = CFDataGetLength(data)
            var buckets: [Float] = [0, 0, 0, 0]
            for i in 0..<count {
                buckets[i & 3] += Float(bytes[i])
            }
            let norm = sqrt(buckets.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? buckets.map { $0 / norm } : buckets
        }
    }

    private static func makeSyntheticImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                pixels[idx] = UInt8((x * 255) / max(width - 1, 1))
                pixels[idx + 1] = UInt8((y * 255) / max(height - 1, 1))
                pixels[idx + 2] = UInt8(((x + y) * 127) / max(width + height - 2, 1))
                pixels[idx + 3] = 255
            }
        }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    @MainActor
    private static func runSeatedDetectionAndQualityTests() {
        // 1. Seated user at 14% width on 640px frame (90px >= 64px) must be accepted,
        // while a bystander at 45px (< 60% of 90px and < 64px) is dropped.
        let imageSize = CGSize(width: 640, height: 360)
        let seated = DetectedFace(
            boundingBox: CGRect(x: 270, y: 120, width: 90, height: 90),
            normalizedBoundingBox: CGRect(x: 270.0 / 640.0, y: 120.0 / 360.0, width: 90.0 / 640.0, height: 90.0 / 360.0),
            quality: nil, yaw: 0, roll: 0, pitch: 0, landmarks: nil, imageSize: imageSize
        )
        let smallBystander = DetectedFace(
            boundingBox: CGRect(x: 40, y: 150, width: 45, height: 45),
            normalizedBoundingBox: CGRect(x: 40.0 / 640.0, y: 150.0 / 360.0, width: 45.0 / 640.0, height: 45.0 / 360.0),
            quality: nil, yaw: 0, roll: 0, pitch: 0, landmarks: nil, imageSize: imageSize
        )
        let picked = FaceRecognitionPipeline.selectDominantFace(in: [smallBystander, seated])
        precondition(picked?.boundingBox == seated.boundingBox, "FAIL: seated 14% face rejected")

        // 2. Bystander >= 64px (80px) must still be rejected if < 60% of widest (200px), even with preferNear.
        let mainUser = DetectedFace(
            boundingBox: CGRect(x: 240, y: 80, width: 200, height: 200),
            normalizedBoundingBox: CGRect(x: 240.0 / 640.0, y: 80.0 / 360.0, width: 200.0 / 640.0, height: 200.0 / 360.0),
            quality: nil, yaw: 0, roll: 0, pitch: 0, landmarks: nil, imageSize: imageSize
        )
        let midBystander = DetectedFace(
            boundingBox: CGRect(x: 40, y: 120, width: 80, height: 80),
            normalizedBoundingBox: CGRect(x: 40.0 / 640.0, y: 120.0 / 360.0, width: 80.0 / 640.0, height: 80.0 / 360.0),
            quality: nil, yaw: 0, roll: 0, pitch: 0, landmarks: nil, imageSize: imageSize
        )
        let pickedMain = FaceRecognitionPipeline.selectDominantFace(
            in: [midBystander, mainUser],
            preferNear: midBystander.normalizedBoundingBox
        )
        precondition(pickedMain?.boundingBox == mainUser.boundingBox, "FAIL: bystander below 60% relative cutoff selected")

        // 3. strictCloseRangeOnly rejects < 18% (90px/640px = 0.14) while accepting >= 18% (120px/640px = 0.1875).
        FaceRecognitionPipeline.strictCloseRangeOnly = true
        defer { FaceRecognitionPipeline.strictCloseRangeOnly = false }
        precondition(
            FaceRecognitionPipeline.selectDominantFace(in: [seated]) == nil,
            "FAIL: strictCloseRangeOnly accepted 14% face"
        )
        let closeUser = DetectedFace(
            boundingBox: CGRect(x: 260, y: 100, width: 120, height: 120),
            normalizedBoundingBox: CGRect(x: 260.0 / 640.0, y: 100.0 / 360.0, width: 120.0 / 640.0, height: 120.0 / 360.0),
            quality: nil, yaw: 0, roll: 0, pitch: 0, landmarks: nil, imageSize: imageSize
        )
        precondition(
            FaceRecognitionPipeline.selectDominantFace(in: [closeUser])?.boundingBox == closeUser.boundingBox,
            "FAIL: strictCloseRangeOnly rejected 18.75% face"
        )
        FaceRecognitionPipeline.strictCloseRangeOnly = false

        // 4. Pose-aware quality grading: frontal median 0.50 -> turned 0.36 (72%) .good, 0.30 (60%) .fair, 0.20 (40%) .poor
        let frontalA = FaceSample(embedding: [1, 0], pose: "center", capturedAt: Date(), quality: 0.40)
        let frontalB = FaceSample(embedding: [1, 0], pose: nil, capturedAt: Date(), quality: 0.60)
        let turnedGood = FaceSample(embedding: [1, 0], pose: "right", capturedAt: Date(), quality: 0.36)
        let turnedFair = FaceSample(embedding: [1, 0], pose: "left", capturedAt: Date(), quality: 0.30)
        let turnedPoor = FaceSample(embedding: [1, 0], pose: "bottom_left", capturedAt: Date(), quality: 0.20)
        let unrated = FaceSample(embedding: [1, 0], pose: "top", capturedAt: Date(), quality: nil)
        let identity = FaceIdentity(
            id: UUID(), name: "SeatedUser",
            samples: [frontalA, frontalB, turnedGood, turnedFair, turnedPoor, unrated],
            modelIdentifier: "arcface-w600k_mbf-v1", embeddingDimension: 2, createdAt: Date()
        )
        precondition(frontalA.isFrontal && frontalB.isFrontal && !turnedGood.isFrontal, "FAIL: isFrontal classification")
        precondition(identity.frontalQualityReference == 0.50, "FAIL: frontalQualityReference median mismatch")
        precondition(identity.qualityTier(of: turnedGood) == .good, "FAIL: turned sample unfairly downgraded")
        precondition(identity.qualityTier(of: turnedFair) == .fair, "FAIL: turned fair sample tier mismatch")
        precondition(identity.qualityTier(of: turnedPoor) == .poor, "FAIL: turned poor sample tier mismatch")
        precondition(identity.qualityTier(of: unrated) == .unrated, "FAIL: unrated sample should remain unrated")
        precondition(identity.poorQualitySampleCount == 1, "FAIL: poorQualitySampleCount expected 1")

        let noFrontalIdentity = FaceIdentity(
            id: UUID(), name: "TurnedOnly", samples: [turnedGood],
            modelIdentifier: "arcface-w600k_mbf-v1", embeddingDimension: 2, createdAt: Date()
        )
        precondition(noFrontalIdentity.frontalQualityReference == nil, "FAIL: frontalQualityReference should be nil")
        precondition(noFrontalIdentity.qualityTier(of: turnedGood) == .poor, "FAIL: without frontal ref, 0.36 should fall back to absolute < 0.4")

        // 5. CameraFrame.renderCrop, FaceDetector(includeQuality:), and includeQuality true vs false embedding equality
        let nativeImage = makeSyntheticImage(width: 1920, height: 1080)
        let workingImage = makeSyntheticImage(width: 640, height: 360)
        let frame = CameraFrame(
            id: 1,
            image: workingImage,
            source: CIImage(cgImage: nativeImage),
            sourceSize: CGSize(width: 1920, height: 1080)
        )
        let nativeCrop = frame.renderCrop(imageRect: seated.boundingBox, paddingFraction: 0.5, maxEdge: 512)
        precondition(nativeCrop != nil, "FAIL: CameraFrame.renderCrop returned nil")
        if let nativeCrop {
            precondition(max(nativeCrop.width, nativeCrop.height) <= 512, "FAIL: native crop exceeded maxEdge 512")
            precondition(nativeCrop.width == 512, "FAIL: native crop should render at maxEdge 512 from 1080p source")
        }
        let glareCrop = frame.renderCrop(imageRect: seated.boundingBox)
        precondition(glareCrop != nil && max(glareCrop!.width, glareCrop!.height) <= 448, "FAIL: default glare crop contract")

        let detectedNoQuality = try! FaceDetector.detectFaces(in: workingImage, includeQuality: false)
        let detectedWithQuality = try! FaceDetector.detectFaces(in: workingImage, includeQuality: true)
        precondition(detectedNoQuality.count == detectedWithQuality.count, "FAIL: includeQuality altered detection count")

        let fpPipeline = FaceRecognitionPipeline(embedder: PixelFingerprintEmbedder(), usingFallbackEmbedder: false, fallbackReason: nil)
        let resWithQuality = try! fpPipeline.recognize(seated, in: frame, includeQuality: true)
        let resWithoutQuality = try! fpPipeline.recognize(seated, in: frame, includeQuality: false)
        precondition(resWithQuality.embedding == resWithoutQuality.embedding, "FAIL: includeQuality changed embedding")
        precondition(resWithoutQuality.quality == nil && resWithoutQuality.face.quality == nil, "FAIL: includeQuality: false emitted quality")
        precondition(resWithQuality.face.boundingBox == seated.boundingBox, "FAIL: result.face left working-frame coordinates")

        print("PASS: adaptive seated detection, pose-aware quality grading & includeQuality equivalence")
    }
}
