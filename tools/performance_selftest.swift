//
//  performance_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for Glance v2.1 performance & model upgrade contracts:
//    1. `ArcFaceEmbedder.floatVector(from:)` Float16 fast-path accuracy & parity with `MLMultiArray` subscripting
//    2. `ArcFaceEmbedder.preferredComputeUnits()` architecture-aware selection (`.cpuAndNeuralEngine` on arm64, `.cpuOnly` on x86_64)
//    3. `FaceIdentity.isStale(comparedTo:)` migration from `arcface-w600k_mbf-v1` to `arcface-w600k_r50-v1`
//    4. `FaceRecognitionPipeline` non-blocking background model load & concurrent `waitUntilReady()`
//    5. `FaceRecognitionPipeline` async loader failure fails closed to `VisionFeaturePrintEmbedder`
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/performance_selftest \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Camera/CameraFrame.swift \
//        glance/Recognition/FaceAligner.swift \
//        glance/Recognition/FaceDetector.swift \
//        glance/Recognition/FaceEmbedder.swift \
//        glance/Recognition/ArcFaceEmbedder.swift \
//        glance/Recognition/FaceRecognitionPipeline.swift \
//        glance/Recognition/FaceEnrollmentStore.swift \
//        glance/Security/KeychainManager.swift \
//        glance/Security/SecureCredentialManager.swift \
//        glance/Security/SecureFaceStore.swift \
//        tools/performance_selftest.swift \
//      && /tmp/performance_selftest
//

import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Observation
import os

private struct MockR50Embedder: FaceEmbedder {
    nonisolated let name = ArcFaceEmbedder.name
    nonisolated let modelIdentifier = ArcFaceEmbedder.modelIdentifier
    nonisolated let embeddingDimension = 512
    nonisolated let requiresAlignment = true
    nonisolated let isUnlockCapable = true

    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        [Float](repeating: 0, count: embeddingDimension)
    }
}

private enum MockPipelineLoadError: LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        "Simulated model load failure"
    }
}

@main
struct PerformanceSelfTest {
    @MainActor
    static func main() async throws {
        try testArcFaceFloat16Extraction()
        testArcFaceComputeUnitsForArchitecture()
        testStaleMigrationFromW600kMbf()
        try await testAsyncPipelineInitDoesNotBlockAndWaitsCleanly()
        await testAsyncPipelineFailureFailsClosed()
        print("\nAll performance self-tests passed.")
    }

    private static func testArcFaceFloat16Extraction() throws {
        let count = 512
        let multiArray = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float16)

        // Seed deterministic values covering positive, negative, zero, and Float16 boundary values.
        var seedFloats = [Float](repeating: 0, count: count)
        seedFloats[0] = 0.0
        seedFloats[1] = -0.0
        seedFloats[2] = 1.0
        seedFloats[3] = -1.0
        seedFloats[4] = 0.125
        seedFloats[5] = -0.375
        seedFloats[6] = 65504.0          // Float16.greatestFiniteMagnitude
        seedFloats[7] = -65504.0         // -Float16.greatestFiniteMagnitude
        seedFloats[8] = 0.00006103515625 // Float16.leastNormalMagnitude (2^-14)
        seedFloats[9] = -0.00006103515625
        for index in 10..<count {
            let phase = Float(index) * 0.137
            seedFloats[index] = sin(phase) * 1.5
        }

        var expected = [Float](repeating: 0, count: count)
        #if arch(arm64)
        let fp16Pointer = multiArray.dataPointer.bindMemory(to: Float16.self, capacity: count)
        for index in 0..<count {
            let value = Float16(seedFloats[index])
            fp16Pointer[index] = value
            expected[index] = Float(value)
        }
        #else
        seedFloats.withUnsafeMutableBytes { srcBytes in
            var srcBuffer = vImage_Buffer(
                data: srcBytes.baseAddress!,
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<Float>.stride
            )
            var dstBuffer = vImage_Buffer(
                data: multiArray.dataPointer,
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<UInt16>.stride
            )
            let err = vImageConvert_PlanarFtoPlanar16F(&srcBuffer, &dstBuffer, 0)
            precondition(err == kvImageNoError, "FAIL: vImage Float->Float16 test setup failed: \(err)")
        }
        for index in 0..<count {
            expected[index] = multiArray[index].floatValue
        }
        #endif

        let extracted = ArcFaceEmbedder.floatVector(from: multiArray)
        precondition(extracted.count == count, "FAIL: expected \(count) elements, got \(extracted.count)")

        for index in 0..<count {
            let subscriptValue = multiArray[index].floatValue
            let diffFromExpected = abs(extracted[index] - expected[index])
            precondition(
                diffFromExpected < 1e-3,
                "FAIL: Float16 extraction mismatch at \(index): got \(extracted[index]), expected \(expected[index])"
            )
            precondition(
                extracted[index] == subscriptValue,
                "FAIL: Float16 fast-path diverged from subscript at \(index): \(extracted[index]) vs \(subscriptValue)"
            )
            if index >= 10 {
                let diffFromSeed = abs(extracted[index] - seedFloats[index])
                precondition(
                    diffFromSeed < 1e-3,
                    "FAIL: Float16 quantization error exceeded 1e-3 at \(index): \(diffFromSeed)"
                )
            }
        }

        // Also validate non-contiguous Float16 fallback produces identical values.
        let backing = UnsafeMutablePointer<UInt16>.allocate(capacity: count * 2)
        defer { backing.deallocate() }
        backing.initialize(repeating: 0, count: count * 2)
        let rawSource = multiArray.dataPointer.assumingMemoryBound(to: UInt16.self)
        for index in 0..<count {
            backing[index * 2] = rawSource[index]
        }
        let stridedExtracted: [Float]
        do {
            let stridedArray = try MLMultiArray(
                dataPointer: backing,
                shape: [1, NSNumber(value: count)],
                dataType: .float16,
                strides: [NSNumber(value: count * 2), 2]
            )
            stridedExtracted = ArcFaceEmbedder.floatVector(from: stridedArray)
        }
        precondition(stridedExtracted == extracted, "FAIL: non-contiguous Float16 fallback diverged from fast-path")

        // And validate Float32 contiguous fast-path.
        let float32Array = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)
        let fp32Pointer = float32Array.dataPointer.bindMemory(to: Float.self, capacity: count)
        for index in 0..<count {
            fp32Pointer[index] = seedFloats[index]
        }
        let extracted32 = ArcFaceEmbedder.floatVector(from: float32Array)
        precondition(extracted32 == seedFloats, "FAIL: Float32 fast-path mismatch")

        print("PASS: ArcFace Float16/Float32 vector extraction")
    }

    private static func testArcFaceComputeUnitsForArchitecture() {
        let units = ArcFaceEmbedder.preferredComputeUnits()
        #if arch(arm64)
        precondition(units == .cpuAndNeuralEngine, "FAIL: arm64 must prefer .cpuAndNeuralEngine, got \(units)")
        #elseif arch(x86_64)
        precondition(units == .cpuOnly, "FAIL: x86_64 must prefer .cpuOnly, got \(units)")
        #endif
        print("PASS: ArcFace architecture-aware computeUnits")
    }

    private static func testStaleMigrationFromW600kMbf() {
        precondition(
            ArcFaceEmbedder.name == "ArcFace (w600k_r50)",
            "FAIL: expected ArcFaceEmbedder.name == 'ArcFace (w600k_r50)', got '\(ArcFaceEmbedder.name)'"
        )
        precondition(
            ArcFaceEmbedder.modelIdentifier == "arcface-w600k_r50-v1",
            "FAIL: expected ArcFaceEmbedder.modelIdentifier == 'arcface-w600k_r50-v1', got '\(ArcFaceEmbedder.modelIdentifier)'"
        )

        let r50Embedder = MockR50Embedder()
        let legacyIdentity = FaceIdentity(
            id: UUID(),
            name: "Legacy v2.0.0 Owner",
            samples: [
                FaceSample(
                    embedding: [Float](repeating: 1.0 / sqrt(512.0), count: 512),
                    pose: "center",
                    capturedAt: Date(),
                    quality: 0.9
                )
            ],
            modelIdentifier: "arcface-w600k_mbf-v1",
            embeddingDimension: 512,
            createdAt: Date()
        )
        precondition(
            legacyIdentity.isStale(comparedTo: r50Embedder),
            "FAIL: w600k_mbf identity must be stale compared to arcface-w600k_r50-v1"
        )

        let currentIdentity = FaceIdentity(
            id: UUID(),
            name: "v2.1 Owner",
            samples: legacyIdentity.samples,
            modelIdentifier: ArcFaceEmbedder.modelIdentifier,
            embeddingDimension: 512,
            createdAt: Date()
        )
        precondition(
            !currentIdentity.isStale(comparedTo: r50Embedder),
            "FAIL: arcface-w600k_r50-v1 identity must not be stale"
        )

        print("PASS: stale migration from arcface-w600k_mbf-v1 to arcface-w600k_r50-v1")
    }

    @MainActor
    private static func testAsyncPipelineInitDoesNotBlockAndWaitsCleanly() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let pipeline = FaceRecognitionPipeline(asyncLoad: true) {
            Thread.sleep(forTimeInterval: 0.15)
            return MockR50Embedder()
        }
        let initElapsed = clock.now - start

        precondition(
            initElapsed < .milliseconds(20),
            "FAIL: async FaceRecognitionPipeline init blocked caller for \(initElapsed)"
        )
        precondition(
            pipeline.loadState == .loading,
            "FAIL: expected initial loadState == .loading, got \(pipeline.loadState)"
        )
        precondition(
            !pipeline.isUnlockCapable,
            "FAIL: pipeline must not be unlock-capable while .loading"
        )
        precondition(
            pipeline.usingFallbackEmbedder,
            "FAIL: pipeline must fail closed to fallback placeholder while .loading"
        )

        let observedChange = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = pipeline.loadState
        } onChange: {
            observedChange.withLock { $0 = true }
        }

        let waiterA = Task { @MainActor in
            await pipeline.waitUntilReady()
            return (
                pipeline.loadState,
                pipeline.isUnlockCapable,
                pipeline.usingFallbackEmbedder,
                pipeline.currentEmbedder().modelIdentifier
            )
        }
        let waiterB = Task.detached {
            await pipeline.waitUntilReady()
            return (
                pipeline.loadState,
                pipeline.isUnlockCapable,
                pipeline.usingFallbackEmbedder,
                pipeline.currentEmbedder().modelIdentifier
            )
        }

        let resultA = await waiterA.value
        let resultB = await waiterB.value
        let totalElapsed = clock.now - start

        for (label, result) in [("main-actor waiter", resultA), ("detached waiter", resultB)] {
            precondition(
                result.0 == .ready,
                "FAIL: \(label) saw loadState == \(result.0) after waitUntilReady()"
            )
            precondition(
                result.1,
                "FAIL: \(label) saw isUnlockCapable == false after ready"
            )
            precondition(
                !result.2,
                "FAIL: \(label) saw usingFallbackEmbedder == true after ready"
            )
            precondition(
                result.3 == ArcFaceEmbedder.modelIdentifier,
                "FAIL: \(label) saw unexpected embedder \(result.3)"
            )
        }
        precondition(
            totalElapsed >= .milliseconds(130),
            "FAIL: waitUntilReady() returned before simulated 150ms loader completed (\(totalElapsed))"
        )
        precondition(
            observedChange.withLock { $0 },
            "FAIL: @Observable onChange did not fire when loadState transitioned to .ready"
        )

        print("PASS: async FaceRecognitionPipeline non-blocking init & concurrent waitUntilReady()")
    }

    @MainActor
    private static func testAsyncPipelineFailureFailsClosed() async {
        let pipeline = FaceRecognitionPipeline(asyncLoad: true) {
            Thread.sleep(forTimeInterval: 0.03)
            throw MockPipelineLoadError.simulatedFailure
        }

        await pipeline.waitUntilReady()

        precondition(
            pipeline.usingFallbackEmbedder,
            "FAIL: failed async loader must set usingFallbackEmbedder == true"
        )
        precondition(
            !pipeline.isUnlockCapable,
            "FAIL: failed async loader must keep isUnlockCapable == false"
        )
        guard case .fallback(let reason) = pipeline.loadState else {
            fatalError("FAIL: expected .fallback loadState after loader error, got \(pipeline.loadState)")
        }
        precondition(!reason.isEmpty, "FAIL: fallback loadState reason must not be empty")
        precondition(
            pipeline.fallbackReason == reason,
            "FAIL: fallbackReason mismatch (\(String(describing: pipeline.fallbackReason)) vs \(reason))"
        )
        let fallbackEmbedder = pipeline.currentEmbedder()
        precondition(
            !fallbackEmbedder.isUnlockCapable,
            "FAIL: fallback embedder must not be unlock-capable"
        )

        let fakeFallbackIdentity = FaceIdentity(
            id: UUID(),
            name: "Fallback Test",
            samples: [FaceSample(embedding: [1, 0], pose: "center", capturedAt: Date(), quality: 0.9)],
            modelIdentifier: fallbackEmbedder.modelIdentifier,
            embeddingDimension: 2,
            createdAt: Date()
        )
        let scored = pipeline.score([1, 0], against: [fakeFallbackIdentity])
        precondition(
            pipeline.bestMatch(in: scored, threshold: 0.50) == nil,
            "FAIL: failed pipeline must never match in bestMatch"
        )

        print("PASS: async FaceRecognitionPipeline loader failure fails closed")
    }
}
