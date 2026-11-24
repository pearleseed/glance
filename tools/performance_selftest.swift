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
//    6. `CameraFrameWaiter` event-driven wakeup (`nextFrame(after:until:)`)
//    7. `CameraFrameWaiter` cancellation on `stop()`, timeout expiry, external `Task.cancel()`, and `start -> stop -> start` isolation
//    8. `PendingCameraFrameState` preview-only (`publishesFrames: false`) & `isConsumerBusy` backpressure gating
//    9. `ObservationWaiter` & `ObservationSignal` event-driven `@Observable` waiting, timeout, and cancellation
//   10. Task 5: native crop edge landmark remapping, cached `FaceIdentity.template`, glare integer pre-filter, `GeometryLiveness` early-exit, and zero-alloc homography equivalence
//   11. Task 8: direct `Contents/Info.plist` app metadata parsing (`InstalledApps.readAppMetadata(at:)`) & TTL `refreshIfNeeded(maxAge:)`
//   12. Task 10: `NotchShape` cached continuous-corner Bézier fast path & clamped fallback equivalence
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/performance_selftest \
//        glance/Core/ObservationWaiter.swift \
//        glance/AppLock/RelockPolicy.swift \
//        glance/AppLock/AppLockBlacklist.swift \
//        glance/AppLock/LockedApp.swift \
//        glance/AppLock/InstalledApps.swift \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/GeometryLiveness.swift \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/GlareFaceRegion.swift \
//        glance/Liveness/GlareCueExtractor.swift \
//        glance/Liveness/LivenessCues.swift \
//        glance/Liveness/LivenessScoring.swift \
//        glance/Liveness/LivenessAnalyzer.swift \
//        glance/Camera/SharedCoreImageContext.swift \
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
//        glance/NotchOverlay/NotchPanelStyle.swift \
//        glance/NotchOverlay/NotchGeometry.swift \
//        glance/NotchOverlay/NotchShape.swift \
//        tools/performance_selftest.swift \
//      && /tmp/performance_selftest
//

import Accelerate
import CoreGraphics
import CoreImage
import CoreML
import Foundation
import Observation
import os
import SwiftUI

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

@Observable
@MainActor
private final class MockOverlayState {
    enum Phase: Equatable {
        case failure
        case collapsing
        case closed
        case scanning
    }

    var phase: Phase = .failure
    var stepCount: Int = 0
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
        try await testFrameDeliveryWakesImmediately()
        try await testFrameWaiterCancelledOnStopAndTimeout()
        testCaptureBackpressureAndPreviewOnlyGate()
        try await testObservationWaiterTransitionsAndSignal()
        try await testObservationWaiterTimeoutCancellationAndRaces()
        testNativeCropLandmarkRemappingAtEdge()
        try testFaceIdentityCachedTemplateMatchesAverage()
        testGlareIntegerPrefilterMatchesReference()
        await testGeometryLivenessEarlyExitWhenStill()
        testZeroAllocHomographyNumericalEquivalence()
        try await testInfoPlistAppMetadataReadsSystemAndUserApp()
        testNotchShapePathMatchesReferenceContinuousCorner()
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
            #if arch(arm64)
            if index >= 10 {
                let diffFromSeed = abs(extracted[index] - seedFloats[index])
                precondition(
                    diffFromSeed < 1e-3,
                    "FAIL: Float16 quantization error exceeded 1e-3 at \(index): \(diffFromSeed)"
                )
            }
            #else
            let diffFromSeed = abs(extracted[index] - seedFloats[index])
            precondition(
                diffFromSeed < 1e-3,
                "FAIL: Float16 quantization error exceeded 1e-3 at \(index): \(diffFromSeed)"
            )
            #endif
        }

        // Also validate non-contiguous Float16 fallback produces identical values.
        let backing = UnsafeMutablePointer<UInt16>.allocate(capacity: count * 2)
        defer { backing.deallocate() }
        backing.initialize(repeating: 0, count: count * 2)
        multiArray.withUnsafeBytes { bytes in
            for index in 0..<count {
                backing[index * 2] = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UInt16>.stride,
                    as: UInt16.self
                )
            }
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

        // Also validate unaligned contiguous Float16/Float32 custom MLMultiArray never traps.
        let unalignedBytes = count * MemoryLayout<UInt16>.stride + 1
        let unalignedRaw = UnsafeMutableRawPointer.allocate(byteCount: unalignedBytes, alignment: 16)
        defer { unalignedRaw.deallocate() }
        let unalignedPtr = unalignedRaw.advanced(by: 1)
        multiArray.withUnsafeBytes { bytes in
            unalignedPtr.copyMemory(from: bytes.baseAddress!, byteCount: count * MemoryLayout<UInt16>.stride)
        }
        let unalignedFp16Array = try MLMultiArray(
            dataPointer: unalignedPtr,
            shape: [1, NSNumber(value: count)],
            dataType: .float16,
            strides: [NSNumber(value: count), 1]
        )
        let unalignedExtracted = ArcFaceEmbedder.floatVector(from: unalignedFp16Array)
        precondition(unalignedExtracted == extracted, "FAIL: unaligned Float16 extraction diverged")

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

    private static func makeDummyCameraFrame(id: UInt64) -> CameraFrame {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel: [UInt8] = [128, 128, 128, 255]
        let cgImage = pixel.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
        return CameraFrame(
            id: id,
            image: cgImage,
            source: CIImage(cgImage: cgImage),
            sourceSize: CGSize(width: 1, height: 1)
        )
    }

    @MainActor
    private static func testFrameDeliveryWakesImmediately() async throws {
        let clock = ContinuousClock()
        let waiter = CameraFrameWaiter()
        let frame1 = makeDummyCameraFrame(id: 1)
        let frame2 = makeDummyCameraFrame(id: 2)

        let deliverTask = Task {
            try await Task.sleep(for: .milliseconds(15))
            waiter.deliver(frame1)
        }

        let start1 = clock.now
        let received1 = await waiter.nextFrame(after: nil, until: start1 + .seconds(1))
        let elapsed1 = clock.now - start1
        try await deliverTask.value

        precondition(
            received1?.id == frame1.id,
            "FAIL: expected frame1 (id 1), got \(String(describing: received1?.id))"
        )
        precondition(
            elapsed1 < .milliseconds(250),
            "FAIL: waiter took too long to wake on delivery: \(elapsed1)"
        )

        // Waiting after frame1 must suspend until frame2 arrives.
        let deliverTask2 = Task {
            try await Task.sleep(for: .milliseconds(10))
            waiter.deliver(frame2)
        }
        let start2 = clock.now
        let received2 = await waiter.nextFrame(after: frame1.id, until: start2 + .seconds(1))
        let elapsed2 = clock.now - start2
        try await deliverTask2.value

        precondition(
            received2?.id == frame2.id,
            "FAIL: expected frame2 (id 2), got \(String(describing: received2?.id))"
        )
        precondition(
            elapsed2 < .milliseconds(250),
            "FAIL: waiter took too long to wake on frame2 delivery: \(elapsed2)"
        )

        // Immediate return if a newer frame is already present.
        let start3 = clock.now
        let cached = await waiter.nextFrame(after: frame1.id, until: start3 + .seconds(1))
        let elapsed3 = clock.now - start3
        precondition(cached?.id == frame2.id, "FAIL: expected cached frame2 immediately")
        precondition(elapsed3 < .milliseconds(50), "FAIL: cached frame return took \(elapsed3)")

        print("PASS: CameraFrameWaiter wakes immediately on frame delivery")
    }

    @MainActor
    private static func testFrameWaiterCancelledOnStopAndTimeout() async throws {
        let clock = ContinuousClock()
        let waiter = CameraFrameWaiter()

        // 1. stop() while waiting must wake immediately with nil.
        let stopTask = Task {
            try await Task.sleep(for: .milliseconds(12))
            waiter.stop()
        }
        let stopStart = clock.now
        let afterStop = await waiter.nextFrame(after: nil, until: stopStart + .seconds(2))
        let stopElapsed = clock.now - stopStart
        try await stopTask.value

        precondition(afterStop == nil, "FAIL: expected nil when stop() cancels waiting nextFrame")
        precondition(stopElapsed < .milliseconds(200), "FAIL: stop() took too long to wake waiter: \(stopElapsed)")

        // Calling nextFrame while stopped must immediately return nil.
        let stoppedNow = clock.now
        let whileStopped = await waiter.nextFrame(after: nil, until: stoppedNow + .seconds(1))
        precondition(whileStopped == nil, "FAIL: expected nil when waiter is stopped")
        precondition(clock.now - stoppedNow < .milliseconds(50), "FAIL: stopped waiter suspended")

        // 2. Deadline expiry with no frame delivered returns nil on time.
        waiter.start()
        let timeoutStart = clock.now
        let timedOut = await waiter.nextFrame(after: nil, until: timeoutStart + .milliseconds(35))
        let timeoutElapsed = clock.now - timeoutStart
        precondition(timedOut == nil, "FAIL: expected nil on deadline expiry")
        precondition(
            timeoutElapsed >= .milliseconds(25) && timeoutElapsed < .milliseconds(250),
            "FAIL: timeout elapsed out of expected range: \(timeoutElapsed)"
        )

        // 3. External Task.cancel() releases continuation cleanly.
        let cancelStart = clock.now
        let waitingTask = Task {
            await waiter.nextFrame(after: nil, until: cancelStart + .seconds(2))
        }
        try await Task.sleep(for: .milliseconds(12))
        waitingTask.cancel()
        let cancelledResult = await waitingTask.value
        let cancelElapsed = clock.now - cancelStart
        precondition(cancelledResult == nil, "FAIL: expected nil when waiting task is cancelled")
        precondition(cancelElapsed < .milliseconds(200), "FAIL: task cancellation took too long: \(cancelElapsed)")

        // 4. Stale-frame isolation across start -> deliver -> stop -> start.
        let oldFrame = makeDummyCameraFrame(id: 100)
        waiter.deliver(oldFrame)
        waiter.stop()
        waiter.start()
        let staleCheck = await waiter.nextFrame(after: nil, until: clock.now + .milliseconds(25))
        precondition(staleCheck == nil, "FAIL: stale frame leaked across stop() -> start()")

        // 4b. Stale expectedEpoch (stop/start across actor hop) returns nil immediately even if active with a frame.
        let staleEpoch = waiter.currentEpoch
        waiter.stop()
        waiter.start()
        waiter.deliver(makeDummyCameraFrame(id: 102))
        let staleEpochResult = await waiter.nextFrame(
            after: nil,
            until: clock.now + .seconds(1),
            expectedEpoch: staleEpoch
        )
        precondition(staleEpochResult == nil, "FAIL: stale expectedEpoch must return nil immediately")
        waiter.start()

        // Subsequent delivery after restart still wakes normally.
        let freshFrame = makeDummyCameraFrame(id: 101)
        let deliverFresh = Task {
            try await Task.sleep(for: .milliseconds(10))
            waiter.deliver(freshFrame)
        }
        let freshResult = await waiter.nextFrame(after: nil, until: clock.now + .seconds(1))
        try await deliverFresh.value
        precondition(freshResult?.id == freshFrame.id, "FAIL: expected freshFrame after restart")

        // 5. Stress rapid stop/start/deliver/cancel races (both pre-suspend and post-suspend) to confirm
        // every continuation resumes exactly once without leaking or trapping.
        for iteration in 0..<40 {
            waiter.start()
            let iterFrame = makeDummyCameraFrame(id: UInt64(200 + iteration))
            let raceTask = Task.detached {
                await waiter.nextFrame(after: nil, until: clock.now + .milliseconds(20))
            }
            if iteration.isMultiple(of: 2) {
                await Task.yield()
            }
            if iteration % 3 == 0 {
                waiter.deliver(iterFrame)
                waiter.stop()
            } else if iteration % 3 == 1 {
                waiter.stop()
            } else {
                raceTask.cancel()
            }
            let raceResult = await raceTask.value
            if iteration % 3 != 0 {
                precondition(raceResult == nil, "FAIL: expected nil in race iteration \(iteration)")
            } else if let raceResult {
                precondition(raceResult.id == iterFrame.id, "FAIL: unexpected frame id \(raceResult.id) in race iteration \(iteration)")
            }
        }

        print("PASS: CameraFrameWaiter cancellation on stop, timeout, Task.cancel, and restart isolation")
    }

    private static func testCaptureBackpressureAndPreviewOnlyGate() {
        let dummy1 = makeDummyCameraFrame(id: 1)
        let dummy2 = makeDummyCameraFrame(id: 2)

        // Preview-only mode (`publishesFrames: false`) never renders or schedules frames.
        var previewState = PendingCameraFrameState(publishesFrames: false, isCapturing: true)
        precondition(!previewState.shouldRenderSample, "FAIL: preview-only mode must skip rendering")
        let genPreview = previewState.captureGeneration
        precondition(
            !previewState.enqueueIfActive(dummy1, generation: genPreview),
            "FAIL: preview-only mode must not schedule delivery"
        )
        precondition(previewState.drainPending() == nil, "FAIL: preview-only pendingFrame must remain nil")

        // Capture mode (`publishesFrames: true`) gates on `isConsumerBusy` and coalesces newest frame.
        var captureState = PendingCameraFrameState(publishesFrames: true, isCapturing: true)
        precondition(captureState.shouldRenderSample, "FAIL: active capture mode should render")
        captureState.isConsumerBusy = true
        precondition(!captureState.shouldRenderSample, "FAIL: busy consumer must skip CIImage/CGImage rendering")
        captureState.isConsumerBusy = false
        precondition(captureState.shouldRenderSample, "FAIL: clearing busy flag must re-enable rendering")

        let gen1 = captureState.captureGeneration
        precondition(captureState.enqueueIfActive(dummy1, generation: gen1), "FAIL: first frame should schedule drain")
        precondition(!captureState.enqueueIfActive(dummy2, generation: gen1), "FAIL: second frame while scheduled should coalesce")
        precondition(captureState.drainPending()?.id == dummy2.id, "FAIL: drained frame must be newest coalesced frame")
        precondition(captureState.drainPending() == nil, "FAIL: second drain must be empty")

        // Stopping clears pending + resets isConsumerBusy while preserving publishesFrames and blocking stale generations.
        captureState.isConsumerBusy = true
        _ = captureState.enqueueIfActive(dummy1, generation: gen1)
        captureState.endCapture()
        precondition(!captureState.isCapturing, "FAIL: endCapture must set isCapturing = false")
        precondition(!captureState.isConsumerBusy, "FAIL: endCapture must reset isConsumerBusy = false")
        precondition(captureState.publishesFrames, "FAIL: endCapture must preserve publishesFrames")
        precondition(captureState.drainPending() == nil, "FAIL: endCapture must discard pending frame")

        captureState.beginCapture()
        precondition(
            !captureState.enqueueIfActive(dummy1, generation: gen1),
            "FAIL: stale generation frame from before stop() must be rejected"
        )

        print("PASS: PendingCameraFrameState preview-only and consumer backpressure gating")
    }

    @MainActor
    private static func testObservationWaiterTransitionsAndSignal() async throws {
        let clock = ContinuousClock()
        let state = MockOverlayState()
        let signal = ObservationSignal()

        // 1. Predicate already false returns immediately.
        let immediateStart = clock.now
        await ObservationWaiter.waitWhile(until: immediateStart + .seconds(2)) {
            state.phase == .closed
        }
        let immediateElapsed = clock.now - immediateStart
        precondition(immediateElapsed < .milliseconds(50), "FAIL: already-false wait suspended for \(immediateElapsed)")

        // 2. Wakes immediately when `@Observable` property changes away from `.failure`.
        state.phase = .failure
        let collapseTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(15))
            state.phase = .collapsing
        }
        let wait1Start = clock.now
        await ObservationWaiter.waitWhile(until: wait1Start + .seconds(2)) {
            state.phase == .failure
        }
        let wait1Elapsed = clock.now - wait1Start
        try await collapseTask.value
        precondition(state.phase == .collapsing, "FAIL: expected phase .collapsing")
        precondition(wait1Elapsed < .milliseconds(250), "FAIL: phase wake took too long: \(wait1Elapsed)")

        // 3. Intermediate changes keeping predicate true re-subscribe until final transition.
        state.stepCount = 0
        let stepsTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(10))
            state.stepCount = 1
            try await Task.sleep(for: .milliseconds(10))
            state.stepCount = 2
            try await Task.sleep(for: .milliseconds(10))
            state.stepCount = 3
        }
        let wait2Start = clock.now
        await ObservationWaiter.waitWhile(until: wait2Start + .seconds(2)) {
            state.stepCount < 3
        }
        let wait2Elapsed = clock.now - wait2Start
        try await stepsTask.value
        precondition(state.stepCount == 3, "FAIL: expected stepCount == 3")
        precondition(wait2Elapsed < .milliseconds(300), "FAIL: multi-step wait took too long: \(wait2Elapsed)")

        // 4. Non-observable stop flag wakes immediately via `ObservationSignal`.
        var activeGeneration: UInt64 = 1
        let signalTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(15))
            activeGeneration = 2
            signal.signal()
        }
        let wait3Start = clock.now
        await ObservationWaiter.waitWhile(until: wait3Start + .seconds(2)) {
            _ = signal.version
            return activeGeneration == 1 && state.phase == .collapsing
        }
        let wait3Elapsed = clock.now - wait3Start
        try await signalTask.value
        precondition(wait3Elapsed < .milliseconds(250), "FAIL: signal wake took too long: \(wait3Elapsed)")

        print("PASS: ObservationWaiter @Observable transitions & ObservationSignal wakeups")
    }

    @MainActor
    private static func testObservationWaiterTimeoutCancellationAndRaces() async throws {
        let clock = ContinuousClock()
        let state = MockOverlayState()
        state.phase = .failure

        // 1. Deadline expiry returns cleanly without change.
        let timeoutStart = clock.now
        await ObservationWaiter.waitWhile(until: timeoutStart + .milliseconds(35)) {
            state.phase == .failure
        }
        let timeoutElapsed = clock.now - timeoutStart
        precondition(
            timeoutElapsed >= .milliseconds(25) && timeoutElapsed < .milliseconds(250),
            "FAIL: observation timeout elapsed out of range: \(timeoutElapsed)"
        )

        // 2. External Task.cancel() returns promptly without leaking continuations.
        let cancelStart = clock.now
        let waitingTask = Task { @MainActor in
            await ObservationWaiter.waitWhile(until: cancelStart + .seconds(2)) {
                state.phase == .failure
            }
        }
        try await Task.sleep(for: .milliseconds(12))
        waitingTask.cancel()
        await waitingTask.value
        let cancelElapsed = clock.now - cancelStart
        precondition(cancelElapsed < .milliseconds(250), "FAIL: observation cancel took too long: \(cancelElapsed)")

        // 3. Stress rapid concurrent mutation / cancellation / timeout races.
        let signal = ObservationSignal()
        for iteration in 0..<40 {
            state.phase = .failure
            let task = Task { @MainActor in
                await ObservationWaiter.waitWhile(until: clock.now + .milliseconds(15)) {
                    _ = signal.version
                    return state.phase == .failure
                }
            }
            if iteration.isMultiple(of: 2) {
                await Task.yield()
            }
            if iteration % 3 == 0 {
                state.phase = .closed
            } else if iteration % 3 == 1 {
                signal.signal()
            } else {
                task.cancel()
            }
            await task.value
        }

        print("PASS: ObservationWaiter timeout, Task.cancel(), and race stress tests")
    }

    // MARK: - Task 5 Tests

    private static func makeMarkerImage(
        width: Int,
        height: Int,
        isWhite: (Int, Int) -> Bool
    ) -> CGImage {
        var pixels = [UInt8](repeating: 30, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                if isWhite(x, y) {
                    pixels[idx] = 255
                    pixels[idx + 1] = 255
                    pixels[idx + 2] = 255
                }
                pixels[idx + 3] = 255
            }
        }
        return pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private static func whitePixelCentroid(in image: CGImage) -> (centroid: CGPoint, count: Int) {
        let w = image.width
        let h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                if rgba[idx] > 200 && rgba[idx + 1] > 200 && rgba[idx + 2] > 200 {
                    sumX += Double(x) + 0.5
                    sumY += Double(y) + 0.5
                    count += 1
                }
            }
        }
        return (CGPoint(x: sumX / Double(max(count, 1)), y: sumY / Double(max(count, 1))), count)
    }

    private static func testNativeCropLandmarkRemappingAtEdge() {
        let workingSize = CGSize(width: 640, height: 360)
        let nativeSize = CGSize(width: 1920, height: 1080)
        let scale: CGFloat = 3.0

        // 1. Face clipped at top-left edge: expanded (-60, -58, 280, 280) -> clipped (0, 0, 220, 222)
        let topLeftFace = CGRect(x: 10, y: 12, width: 140, height: 140)
        let clippedTopLeft = FaceRecognitionPipeline.nativeCropWorkingRect(
            for: topLeftFace,
            inWorkingSize: workingSize
        )
        precondition(
            clippedTopLeft == CGRect(x: 0, y: 0, width: 220, height: 222),
            "FAIL: top-left clipped rect mismatch: \(String(describing: clippedTopLeft))"
        )

        // Marker centered at (60.0, 50.0) in working-frame top-left coordinates (inside face & 0.15 pad),
        // plus an outer margin marker at (200.0, 190.0) inside 0.5 pad but OUTSIDE 0.15 pad.
        let innerMarker = CGRect(x: 52, y: 42, width: 16, height: 16) // center (60, 50)
        let outerMarginMarker = CGRect(x: 192, y: 182, width: 16, height: 16) // center (200, 190), 0.15 pad ends at (171, 173)
        let nativeTopLeftImg = makeMarkerImage(width: Int(nativeSize.width), height: Int(nativeSize.height)) { x, y in
            let wx = CGFloat(x) / scale
            let wy = CGFloat(y) / scale
            return innerMarker.contains(CGPoint(x: wx, y: wy))
                || outerMarginMarker.contains(CGPoint(x: wx, y: wy))
        }
        let workingBg = makeMarkerImage(width: Int(workingSize.width), height: Int(workingSize.height)) { _, _ in false }
        let topLeftFrame = CameraFrame(
            id: 11,
            image: workingBg,
            source: CIImage(cgImage: nativeTopLeftImg),
            sourceSize: nativeSize
        )
        let nativeCropTL = topLeftFrame.renderCrop(imageRect: topLeftFace, paddingFraction: 0.5, maxEdge: 512)!

        // Measure inner marker center in nativeCropTL (exclude outerMarginMarker by scanning x < cropW*0.6)
        let glareCropTL = CameraFrame.sliceGlareCrop(
            from: nativeCropTL,
            nativeCropWorkingRect: clippedTopLeft!,
            faceBoundingBox: topLeftFace,
            workingSize: workingSize
        )!
        let (glareCentroid, glareWhiteCount) = whitePixelCentroid(in: glareCropTL)
        precondition(glareWhiteCount > 100, "FAIL: sliced glare crop missed inner marker (\(glareWhiteCount) px)")
        // Ensure outerMarginMarker was excluded from 0.15 glare slice
        let expectedGlareRect = topLeftFace.insetBy(dx: -topLeftFace.width * 0.15, dy: -topLeftFace.height * 0.15)
            .intersection(CGRect(origin: .zero, size: workingSize))
        let remappedFromGlare = LandmarkGeometry.mapPointFromCrop(
            glareCentroid,
            cropSize: CGSize(width: glareCropTL.width, height: glareCropTL.height),
            toWorkingRect: expectedGlareRect
        )
        let tlError = hypot(remappedFromGlare.x - innerMarker.midX, remappedFromGlare.y - innerMarker.midY)
        precondition(
            tlError < 0.5,
            "FAIL: top-left edge remapping error \(tlError) >= 0.5 px (got \(remappedFromGlare), expected \(CGPoint(x: innerMarker.midX, y: innerMarker.midY)))"
        )
        let maxPossibleInnerWhitePx = Int(ceil(16 * scale)) * Int(ceil(16 * scale))
        precondition(
            glareWhiteCount <= maxPossibleInnerWhitePx,
            "FAIL: outer 0.5-padding marker leaked into 0.15 glare slice (\(glareWhiteCount) > \(maxPossibleInnerWhitePx))"
        )

        // 2. Face clipped at bottom-right edge: expanded (450, 170, 240, 240) -> clipped (450, 170, 190, 190)
        let bottomRightFace = CGRect(x: 510, y: 230, width: 120, height: 120)
        let clippedBottomRight = FaceRecognitionPipeline.nativeCropWorkingRect(
            for: bottomRightFace,
            inWorkingSize: workingSize
        )
        precondition(
            clippedBottomRight == CGRect(x: 450, y: 170, width: 190, height: 190),
            "FAIL: bottom-right clipped rect mismatch: \(String(describing: clippedBottomRight))"
        )
        let brMarker = CGRect(x: 560, y: 280, width: 16, height: 16) // center (568, 288)
        let nativeBRImg = makeMarkerImage(width: Int(nativeSize.width), height: Int(nativeSize.height)) { x, y in
            let wx = CGFloat(x) / scale
            let wy = CGFloat(y) / scale
            return brMarker.contains(CGPoint(x: wx, y: wy))
        }
        let brFrame = CameraFrame(
            id: 12,
            image: workingBg,
            source: CIImage(cgImage: nativeBRImg),
            sourceSize: nativeSize
        )
        let nativeCropBR = brFrame.renderCrop(imageRect: bottomRightFace, paddingFraction: 0.5, maxEdge: 512)!
        let (brCropCentroid, brCount) = whitePixelCentroid(in: nativeCropBR)
        precondition(brCount > 100, "FAIL: bottom-right nativeCrop missing marker")
        let remappedBR = LandmarkGeometry.mapPointFromCrop(
            brCropCentroid,
            cropSize: CGSize(width: nativeCropBR.width, height: nativeCropBR.height),
            toWorkingRect: clippedBottomRight!
        )
        let brError = hypot(remappedBR.x - brMarker.midX, remappedBR.y - brMarker.midY)
        precondition(
            brError < 0.5,
            "FAIL: bottom-right edge remapping error \(brError) >= 0.5 px (got \(remappedBR), expected \(CGPoint(x: brMarker.midX, y: brMarker.midY)))"
        )

        print("PASS: nativeCrop edge landmark remapping & zero-copy glare slicing (< 0.5 px)")
    }

    private static func testFaceIdentityCachedTemplateMatchesAverage() throws {
        var samples: [FaceSample] = []
        for s in 0..<9 {
            var vec = [Float](repeating: 0, count: 512)
            let scale = Float(s + 1) * 0.37
            for i in 0..<512 {
                vec[i] = sin(Float(i) * 0.11 + Float(s) * 0.73) * scale
            }
            samples.append(FaceSample(embedding: vec, pose: "pose_\(s)", capturedAt: Date(), quality: 0.8))
        }

        var identity = FaceIdentity(
            id: UUID(),
            name: "Cached Template Owner",
            samples: samples,
            modelIdentifier: ArcFaceEmbedder.modelIdentifier,
            embeddingDimension: 512,
            createdAt: Date()
        )
        let expectedInitial = FaceEmbedding.average(samples.map(\.embedding))
        precondition(
            identity.template == expectedInitial && expectedInitial != nil,
            "FAIL: initial FaceIdentity.template diverged from FaceEmbedding.average"
        )

        // Append 10th sample -> didSet invalidates and recomputes cached template
        let extraVec = (0..<512).map { cos(Float($0) * 0.19) * 2.5 }
        let extraSample = FaceSample(embedding: extraVec, pose: "extra", capturedAt: Date(), quality: 0.9)
        identity.samples.append(extraSample)
        let expectedAfterAppend = FaceEmbedding.average(identity.samples.map(\.embedding))
        precondition(
            identity.template == expectedAfterAppend && identity.template != expectedInitial,
            "FAIL: FaceIdentity.template did not update on samples.append"
        )

        // Replace samples array -> didSet updates template
        let singleSample = [samples[0]]
        identity.samples = singleSample
        precondition(
            identity.template == FaceEmbedding.average(singleSample.map(\.embedding)),
            "FAIL: FaceIdentity.template did not update on samples replacement"
        )

        // Empty samples -> template nil
        identity.samples = []
        precondition(identity.template == nil, "FAIL: empty samples must produce nil template")

        // Restore 9 samples and verify Codable omits cachedTemplate from JSON while restoring template on decode
        identity.samples = samples
        let encoded = try JSONEncoder().encode(identity)
        let jsonString = String(data: encoded, encoding: .utf8) ?? ""
        precondition(!jsonString.contains("cachedTemplate"), "FAIL: cachedTemplate must not be serialized to JSON")
        let decoded = try JSONDecoder().decode(FaceIdentity.self, from: encoded)
        precondition(decoded.template == expectedInitial, "FAIL: decoded FaceIdentity.template mismatch")

        print("PASS: FaceIdentity cached template matches FaceEmbedding.average & invalidates on mutation")
    }

    private static func testGlareIntegerPrefilterMatchesReference() {
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let boundaryCases: [(UInt8, UInt8, UInt8)] = [
            (214, 255, 255),
            (255, 214, 255),
            (255, 255, 214),
            (215, 255, 255),
            (255, 215, 255),
            (255, 255, 215),
            (220, 235, 240),
            (230, 236, 238),
            (235, 235, 235),
            (245, 242, 240),
            (255, 255, 255),
            (255, 0, 0),
            (255, 255, 0),
            (0, 255, 255),
            (255, 210, 40),
            (255, 190, 210),
        ]

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let r: UInt8
                let g: UInt8
                let b: UInt8
                if y == 0 && x < boundaryCases.count {
                    (r, g, b) = boundaryCases[x]
                } else if x >= 16 && x < 32 && y >= 16 && y < 32 {
                    // Concentrated white specular cluster
                    (r, g, b) = (255, 254, 253)
                } else if x >= 64 && x < 96 && y >= 32 && y < 64 {
                    // Bright saturated yellow/orange/red region (high R/G, low B)
                    (r, g, b) = (255, x.isMultiple(of: 2) ? 240 : 40, 20)
                } else if x >= 96 && y >= 96 {
                    // Scattered near-white specular pixels
                    (r, g, b) = ((x + y) % 5 == 0) ? (246, 244, 242) : (40, 45, 50)
                } else {
                    // Dark background
                    (r, g, b) = (25, 30, 35)
                }
                pixels[idx] = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }

        let image = pixels.withUnsafeMutableBytes { buf in
            CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.makeImage()!
        }

        // Reference un-prefiltered BT.601 float computation
        func referenceExtract(mask: [UInt8]?) -> (fraction: Float, cluster: Float) {
            var drawn = [UInt8](repeating: 0, count: width * height * 4)
            drawn.withUnsafeMutableBytes { buf in
                let ctx = CGContext(
                    data: buf.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var grid = [Int](repeating: 0, count: 64)
            var spec = 0
            var total = 0
            for y in 0..<height {
                let gy = min(7, y * 8 / height)
                for x in 0..<width {
                    if let mask, mask[y * width + x] == 0 { continue }
                    total += 1
                    let off = (y * width + x) * 4
                    let r = Float(drawn[off])
                    let g = Float(drawn[off + 1])
                    let b = Float(drawn[off + 2])
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    guard luma >= 235 else { continue }
                    let cb = -0.168736 * r - 0.331264 * g + 0.5 * b
                    let cr = 0.5 * r - 0.418688 * g - 0.081312 * b
                    guard abs(cb) <= 10, abs(cr) <= 10 else { continue }
                    spec += 1
                    let gx = min(7, x * 8 / width)
                    grid[gy * 8 + gx] += 1
                }
            }
            let frac = Float(spec) / Float(total)
            let clus = spec > 0 ? Float(grid.max() ?? 0) / Float(spec) : 0
            return (frac, clus)
        }

        let extractedUnmasked = GlareCueExtractor.extract(faceCrop: image)!
        let refUnmasked = referenceExtract(mask: nil)
        precondition(extractedUnmasked.specularFraction > 0 && extractedUnmasked.specularFraction < 0.5, "FAIL: unexpected specularFraction \(extractedUnmasked.specularFraction)")
        precondition(
            extractedUnmasked.specularFraction == refUnmasked.fraction
                && extractedUnmasked.specularClusterRatio == refUnmasked.cluster,
            "FAIL: unmasked glare mismatch: got \(extractedUnmasked), ref \(refUnmasked)"
        )

        let poly = [
            CGPoint(x: 0.05, y: 0.05),
            CGPoint(x: 0.95, y: 0.05),
            CGPoint(x: 0.95, y: 0.95),
            CGPoint(x: 0.05, y: 0.95),
        ]
        let mask = GlareCueExtractor.regionMask(poly, width: width, height: height)!
        let extractedMasked = GlareCueExtractor.extract(faceCrop: image, faceRegion: poly)!
        let refMasked = referenceExtract(mask: mask)
        precondition(
            extractedMasked.specularFraction == refMasked.fraction
                && extractedMasked.specularClusterRatio == refMasked.cluster,
            "FAIL: masked glare mismatch: got \(extractedMasked), ref \(refMasked)"
        )

        print("PASS: GlareCueExtractor integer pre-filter matches float BT.601 reference bit-for-bit")
    }

    @MainActor
    private static func testGeometryLivenessEarlyExitWhenStill() async {
        let baseLandmarks: [LandmarkPoint] = [
            LandmarkPoint(point: CGPoint(x: 240, y: 150), region: .leftEye, indexInRegion: 0),
            LandmarkPoint(point: CGPoint(x: 260, y: 150), region: .leftEye, indexInRegion: 1),
            LandmarkPoint(point: CGPoint(x: 380, y: 150), region: .rightEye, indexInRegion: 0),
            LandmarkPoint(point: CGPoint(x: 400, y: 150), region: .rightEye, indexInRegion: 1),
            LandmarkPoint(point: CGPoint(x: 235, y: 125), region: .leftEyebrow, indexInRegion: 0),
            LandmarkPoint(point: CGPoint(x: 265, y: 125), region: .leftEyebrow, indexInRegion: 1),
            LandmarkPoint(point: CGPoint(x: 375, y: 125), region: .rightEyebrow, indexInRegion: 0),
            LandmarkPoint(point: CGPoint(x: 405, y: 125), region: .rightEyebrow, indexInRegion: 1),
            LandmarkPoint(point: CGPoint(x: 295, y: 245), region: .outerLips, indexInRegion: 0),
            LandmarkPoint(point: CGPoint(x: 320, y: 255), region: .outerLips, indexInRegion: 1),
            LandmarkPoint(point: CGPoint(x: 345, y: 245), region: .outerLips, indexInRegion: 2),
            LandmarkPoint(point: CGPoint(x: 320, y: 195), region: .nose, indexInRegion: 0),
            LandmarkPoint(point: CGPoint(x: 320, y: 210), region: .nose, indexInRegion: 1),
            LandmarkPoint(point: CGPoint(x: 320, y: 175), region: .noseCrest, indexInRegion: 0),
        ]

        // 15 frames with total yaw swing = 5 deg (< 12 deg gate) and non-zero 2D jitter/motion
        let stillWindow: [LivenessFrame] = (0..<15).map { i in
            let t = Double(i) / 14.0
            let yawDeg = -2.5 + 5.0 * t
            let yawRad = Float(yawDeg * .pi / 180.0)
            let dx = CGFloat(i) * 0.5
            let dy = CGFloat(sin(Double(i))) * 0.4
            let moved = baseLandmarks.map { lp in
                LandmarkPoint(
                    point: CGPoint(x: lp.point.x + dx, y: lp.point.y + dy),
                    region: lp.region,
                    indexInRegion: lp.indexInRegion
                )
            }
            return LivenessFrame(
                timestamp: Date(timeIntervalSince1970: Double(i) * 0.05),
                landmarks: moved,
                interocularDistance: 140,
                yaw: yawRad,
                leftEyeAspectRatio: 0.34,
                rightEyeAspectRatio: 0.34,
                noseOffsetRatio: 0.02,
                hasReliableLandmarks: true,
                deviceOverlapFraction: nil,
                glare: nil
            )
        }

        let fastResult = GeometryLiveness.evaluate(stillWindow, includeDiagnostics: false)
        precondition(fastResult.planarResidualScore == 0, "FAIL: expected planarResidualScore == 0 on still window")
        precondition(fastResult.planarConfidence == 0, "FAIL: expected planarConfidence == 0 on still window")
        precondition(
            fastResult.pairsAnalyzed == 0 && fastResult.rejectedPairCount == 0,
            "FAIL: expected early-exit with 0 pairs analyzed when yaw < 12 deg and includeDiagnostics == false, got pairsAnalyzed=\(fastResult.pairsAnalyzed)"
        )

        let diagResult = GeometryLiveness.evaluate(stillWindow, includeDiagnostics: true)
        precondition(diagResult.planarResidualScore == 0 && diagResult.planarConfidence == 0, "FAIL: diagnostics mode must still abstain when yaw < 12 deg")
        precondition(diagResult.pairsAnalyzed > 0, "FAIL: Face Lab includeDiagnostics: true should populate pair metrics even when yaw < 12 deg")

        // Verify off-@MainActor LivenessAnalyzer offloading & generation guard across resetConfirmations (identity swap)
        let analyzer = LivenessAnalyzer()
        analyzer.modeProvider = { .heavy }
        for i in 0..<4 {
            let ctx = analyzer.heavyGeometryContextIfNeeded()!
            let frame = stillWindow[i]
            let precomputed = await Task.detached {
                ctx.computeGeometry(appending: frame)
            }.value
            _ = analyzer.observe(frame, precomputedGeometry: precomputed, sourceGeneration: ctx.generation)
        }
        precondition(analyzer.lastGeometry.pairsAnalyzed == 0, "FAIL: off-actor Heavy geometry should preserve early exit")

        let staleCtx = analyzer.heavyGeometryContextIfNeeded()!
        let sentinelConfirmGeo = GeometryLivenessResult(
            planarResidualScore: 0.99,
            planarConfidence: 0.99,
            validLandmarkCount: 14,
            pairsAnalyzed: 10,
            rejectedPairCount: 0,
            medianFitResidual: 0.002,
            medianProbeResidual: 0.02,
            excessRatio: 10.0,
            coherence: 0.99,
            motionMagnitude: 0.05,
            diagnosticRatios: [:]
        )
        analyzer.resetConfirmations()
        let postResetSnap = analyzer.observe(
            stillWindow[5],
            precomputedGeometry: sentinelConfirmGeo,
            sourceGeneration: staleCtx.generation
        )
        precondition(
            analyzer.lastGeometry.planarResidualScore == 0 && !postResetSnap.decision.isConfirmed,
            "FAIL: stale precomputed Heavy geometry must be rejected after resetConfirmations()"
        )

        print("PASS: GeometryLiveness early-exits before homography loop when yaw < 12 deg and !includeDiagnostics")
    }

    private static func testZeroAllocHomographyNumericalEquivalence() {
        // Reference [[Double]] solver to cross-check zero-alloc flat-buffer solver
        func refSolveLinear(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
            let n = rhs.count
            var a = matrix
            var b = rhs
            for k in 0..<n {
                var pivot = k
                var maxVal = abs(a[k][k])
                if k + 1 < n {
                    for i in (k + 1)..<n where abs(a[i][k]) > maxVal {
                        maxVal = abs(a[i][k])
                        pivot = i
                    }
                }
                if maxVal < 1e-12 { return nil }
                if pivot != k {
                    a.swapAt(k, pivot)
                    b.swapAt(k, pivot)
                }
                let diag = a[k][k]
                if k + 1 < n {
                    for i in (k + 1)..<n {
                        let factor = a[i][k] / diag
                        for j in k..<n { a[i][j] -= factor * a[k][j] }
                        b[i] -= factor * b[k]
                    }
                }
            }
            var x = [Double](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) {
                var sum = b[i]
                if i + 1 < n {
                    for j in (i + 1)..<n { sum -= a[i][j] * x[j] }
                }
                guard abs(a[i][i]) > 1e-12 else { return nil }
                x[i] = sum / a[i][i]
            }
            return x
        }

        func refNorm(_ pts: [CGPoint]) -> (scale: Double, cx: Double, cy: Double) {
            let n = Double(pts.count)
            let cx = pts.reduce(0.0) { $0 + Double($1.x) } / n
            let cy = pts.reduce(0.0) { $0 + Double($1.y) } / n
            let md = pts.reduce(0.0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / n
            return (sqrt(2.0) / md, cx, cy)
        }

        func refSolveHomography(_ src: [CGPoint], _ dst: [CGPoint], weights: [Double]? = nil) -> LandmarkGeometry.Homography? {
            let sT = refNorm(src)
            let dT = refNorm(dst)
            var ata = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
            var atb = Array(repeating: 0.0, count: 8)
            for i in 0..<src.count {
                let x = sT.scale * (Double(src[i].x) - sT.cx)
                let y = sT.scale * (Double(src[i].y) - sT.cy)
                let u = dT.scale * (Double(dst[i].x) - dT.cx)
                let v = dT.scale * (Double(dst[i].y) - dT.cy)
                let w = sqrt(weights?[i] ?? 1.0)
                guard w > 0 else { continue }
                let row0 = [x * w, y * w, w, 0, 0, 0, -u * x * w, -u * y * w]
                let row1 = [0, 0, 0, x * w, y * w, w, -v * x * w, -v * y * w]
                for (row, rhs) in [(row0, u * w), (row1, v * w)] {
                    for r in 0..<8 {
                        atb[r] += row[r] * rhs
                        for c in 0..<8 { ata[r][c] += row[r] * row[c] }
                    }
                }
            }
            guard let h = refSolveLinear(ata, atb) else { return nil }
            // Denormalize: Tdst^-1 * Hnorm * Tsrc
            let a = [
                [1.0 / dT.scale, 0.0, dT.cx],
                [0.0, 1.0 / dT.scale, dT.cy],
                [0.0, 0.0, 1.0],
            ]
            let hn = [
                [h[0], h[1], h[2]],
                [h[3], h[4], h[5]],
                [h[6], h[7], 1.0],
            ]
            let b = [
                [sT.scale, 0.0, -sT.scale * sT.cx],
                [0.0, sT.scale, -sT.scale * sT.cy],
                [0.0, 0.0, 1.0],
            ]
            func mul(_ m1: [[Double]], _ m2: [[Double]]) -> [[Double]] {
                var out = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
                for r in 0..<3 {
                    for c in 0..<3 {
                        for k in 0..<3 { out[r][c] += m1[r][k] * m2[k][c] }
                    }
                }
                return out
            }
            let res = mul(a, mul(hn, b))
            return LandmarkGeometry.Homography(
                h11: res[0][0], h12: res[0][1], h13: res[0][2],
                h21: res[1][0], h22: res[1][1], h23: res[1][2],
                h31: res[2][0], h32: res[2][1], h33: res[2][2]
            )
        }

        let groundTruth = LandmarkGeometry.Homography(
            h11: 1.06, h12: -0.09, h13: 18.5,
            h21: 0.08, h22: 1.04, h23: -12.3,
            h31: 0.00035, h32: -0.00025, h33: 1.0
        )

        var src: [CGPoint] = []
        for gy in stride(from: -80.0, through: 80.0, by: 40.0) {
            for gx in stride(from: -75.0, through: 75.0, by: 50.0) {
                src.append(CGPoint(x: 320 + gx, y: 180 + gy))
            }
        }
        let dstExact = src.map { groundTruth.apply($0) }

        let hExact = LandmarkGeometry.solveHomography(from: src, to: dstExact)!
        for i in 0..<src.count {
            let p = hExact.apply(src[i])
            let err = hypot(p.x - dstExact[i].x, p.y - dstExact[i].y)
            precondition(err < 1e-8, "FAIL: exact homography reprojection error \(err)")
        }

        // Noisy + 1 outlier point to exercise both solveHomography and 2-pass IRLS solveRobustHomography
        var dstNoisy = dstExact.enumerated().map { idx, pt in
            CGPoint(
                x: pt.x + CGFloat(sin(Double(idx) * 1.7)) * 0.65,
                y: pt.y + CGFloat(cos(Double(idx) * 2.3)) * 0.55
            )
        }
        dstNoisy[5].x += 9.0
        dstNoisy[5].y -= 7.5

        let hNoisy = LandmarkGeometry.solveHomography(from: src, to: dstNoisy)!
        let refNoisy = refSolveHomography(src, dstNoisy)!
        for p in src {
            let a = hNoisy.apply(p)
            let b = refNoisy.apply(p)
            let diff = hypot(a.x - b.x, a.y - b.y)
            precondition(diff < 1e-6, "FAIL: solveHomography diverged from reference by \(diff)")
        }

        // Compare robust IRLS homography against reference IRLS
        var refRobust = refNoisy
        for _ in 0..<2 {
            let res = zip(src, dstNoisy).map { hypot($1.x - refRobust.apply($0).x, $1.y - refRobust.apply($0).y) }
            let scale = max(LandmarkGeometry.medianValue(res), 1e-4)
            let cutoff = 4.685 * 1.4826 * scale
            var w = res.map { r -> Double in
                let u = r / cutoff
                if u >= 1 { return 0 }
                let t = 1 - u * u
                return t * t
            }
            if w.filter({ $0 > 0 }).count < 6 { w = Array(repeating: 1, count: src.count) }
            if let refined = refSolveHomography(src, dstNoisy, weights: w) { refRobust = refined }
        }
        let hRobust = LandmarkGeometry.solveRobustHomography(from: src, to: dstNoisy)!
        for p in src {
            let a = hRobust.apply(p)
            let b = refRobust.apply(p)
            let diff = hypot(a.x - b.x, a.y - b.y)
            precondition(diff < 1e-6, "FAIL: solveRobustHomography diverged from reference by \(diff)")
        }

        // Degenerate / collinear points must return nil cleanly
        let collinear = (0..<6).map { CGPoint(x: Double($0) * 10, y: Double($0) * 20) }
        precondition(
            LandmarkGeometry.solveHomography(from: collinear, to: collinear) == nil,
            "FAIL: collinear points should fail singular matrix check"
        )

        print("PASS: zero-alloc flat-buffer homography matches reference (< 1e-6)")
    }

    // MARK: - Task 8 Tests

    @MainActor
    private static func testInfoPlistAppMetadataReadsSystemAndUserApp() async throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("glance-infoplist-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        func makeAppBundle(name: String, plist: [String: Any]) throws -> URL {
            let appURL = tempRoot.appendingPathComponent("\(name).app", isDirectory: true)
            let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contentsURL, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
            return appURL
        }

        // 1. Normal app with CFBundleIdentifier + CFBundleDisplayName
        let normalURL = try makeAppBundle(
            name: "SampleApp",
            plist: [
                "CFBundleIdentifier": "  com.example.SampleApp  ",
                "CFBundleDisplayName": "Sample Display Name",
                "CFBundleName": "Sample Bundle Name",
            ]
        )
        let normalMeta = InstalledApps.readAppMetadata(at: normalURL)
        precondition(normalMeta != nil, "FAIL: expected non-nil metadata for normal app")
        precondition(
            normalMeta?.bundleIdentifier == "com.example.SampleApp",
            "FAIL: unexpected bundleIdentifier \(String(describing: normalMeta?.bundleIdentifier))"
        )
        precondition(
            normalMeta?.name == "Sample Display Name",
            "FAIL: expected CFBundleDisplayName, got \(String(describing: normalMeta?.name))"
        )
        precondition(
            normalMeta?.path == normalURL.path,
            "FAIL: expected path \(normalURL.path), got \(String(describing: normalMeta?.path))"
        )

        // 2. Fallback display names: CFBundleName -> .app filename
        let bundleNameURL = try makeAppBundle(
            name: "RawFileName",
            plist: [
                "CFBundleIdentifier": "com.example.BundleNameOnly",
                "CFBundleName": "Fallback Bundle Name",
            ]
        )
        precondition(
            InstalledApps.readAppMetadata(at: bundleNameURL)?.name == "Fallback Bundle Name",
            "FAIL: expected fallback to CFBundleName"
        )

        let filenameOnlyURL = try makeAppBundle(
            name: "FilenameFallbackApp",
            plist: [
                "CFBundleIdentifier": "com.example.FilenameOnly",
            ]
        )
        precondition(
            InstalledApps.readAppMetadata(at: filenameOnlyURL)?.name == "FilenameFallbackApp",
            "FAIL: expected fallback to .app filename"
        )

        // 3. Agent / background apps rejected
        let agentURL = try makeAppBundle(
            name: "AgentApp",
            plist: [
                "CFBundleIdentifier": "com.example.AgentApp",
                "CFBundleDisplayName": "Agent",
                "LSUIElement": true,
            ]
        )
        precondition(InstalledApps.readAppMetadata(at: agentURL) == nil, "FAIL: LSUIElement app must return nil")

        let bgURL = try makeAppBundle(
            name: "BackgroundApp",
            plist: [
                "CFBundleIdentifier": "com.example.BackgroundApp",
                "CFBundleDisplayName": "Background",
                "LSBackgroundOnly": "1",
            ]
        )
        precondition(InstalledApps.readAppMetadata(at: bgURL) == nil, "FAIL: LSBackgroundOnly app must return nil")

        // 4. Blacklisted apps rejected (self bundle ID & system recovery app)
        let selfBlacklistedURL = try makeAppBundle(
            name: "GlanceCopy",
            plist: [
                "CFBundleIdentifier": "com.pearleseed.glance",
                "CFBundleDisplayName": "Glance",
            ]
        )
        precondition(
            InstalledApps.readAppMetadata(at: selfBlacklistedURL) == nil,
            "FAIL: blacklisted com.pearleseed.glance must return nil"
        )

        let terminalBlacklistedURL = try makeAppBundle(
            name: "TerminalCopy",
            plist: [
                "CFBundleIdentifier": "com.apple.Terminal",
                "CFBundleDisplayName": "Terminal",
            ]
        )
        precondition(
            InstalledApps.readAppMetadata(at: terminalBlacklistedURL) == nil,
            "FAIL: blacklisted com.apple.Terminal must return nil"
        )

        // 5. Real /Applications/Glance.app on disk (if present) must be rejected by blacklist
        let systemGlanceURL = URL(fileURLWithPath: "/Applications/Glance.app")
        if fm.fileExists(atPath: systemGlanceURL.path) {
            precondition(
                InstalledApps.readAppMetadata(at: systemGlanceURL) == nil,
                "FAIL: /Applications/Glance.app must return nil"
            )
        }

        // 6. TTL refreshIfNeeded skips redundant rescan within maxAge
        let store = InstalledApps()
        await store.refreshIfNeeded(maxAge: 60)
        let countAfterInitial = store.apps.count
        let clock = ContinuousClock()
        let secondStart = clock.now
        await store.refreshIfNeeded(maxAge: 60)
        let secondElapsed = clock.now - secondStart
        precondition(
            store.apps.count == countAfterInitial,
            "FAIL: refreshIfNeeded within TTL altered apps count"
        )
        precondition(
            secondElapsed < .milliseconds(5),
            "FAIL: refreshIfNeeded within TTL should skip disk scan, took \(secondElapsed)"
        )

        print("PASS: InstalledApps Info.plist metadata parsing & TTL refreshIfNeeded")
    }

    // MARK: - Task 10 Tests

    private static func cubicBezierPoint(
        p0: CGPoint,
        c1: CGPoint,
        c2: CGPoint,
        p3: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let u = 1 - t
        let uu = u * u
        let tt = t * t
        let w0 = uu * u
        let w1 = 3 * uu * t
        let w2 = 3 * u * tt
        let w3 = tt * t
        return CGPoint(
            x: w0 * p0.x + w1 * c1.x + w2 * c2.x + w3 * p3.x,
            y: w0 * p0.y + w1 * c1.y + w2 * c2.y + w3 * p3.y
        )
    }

    private static func testNotchShapePathMatchesReferenceContinuousCorner() {
        let fastRect = CGRect(x: 0, y: 0, width: 380, height: 260)
        let clampedHeightRect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let closedNotchRect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let translatedOpenRect = CGRect(x: 24, y: 12, width: 252, height: 200)
        let clampedWidthRect = CGRect(x: 0, y: 0, width: 120, height: 200)

        precondition(
            NotchShape.usesCachedUnitCornerFastPath(in: fastRect, topRadius: 16, bottomRadius: 42),
            "FAIL: 380x260 (16, 42) must use cached unit-corner fast path"
        )
        precondition(
            !NotchShape.usesCachedUnitCornerFastPath(in: clampedHeightRect, topRadius: 16, bottomRadius: 42),
            "FAIL: 200x32 (16, 42) exceeds vertical reach and must use clamped fallback"
        )
        precondition(
            NotchShape.usesCachedUnitCornerFastPath(in: closedNotchRect, topRadius: 8, bottomRadius: 12),
            "FAIL: 200x32 (8, 12) closed notch must use cached unit-corner fast path"
        )
        precondition(
            NotchShape.usesCachedUnitCornerFastPath(in: translatedOpenRect, topRadius: 16, bottomRadius: 60),
            "FAIL: 252x200 (16, 60) open notch must use cached unit-corner fast path"
        )
        precondition(
            !NotchShape.usesCachedUnitCornerFastPath(in: clampedWidthRect, topRadius: 16, bottomRadius: 42),
            "FAIL: 120x200 (16, 42) exceeds half body width and must use clamped fallback"
        )

        let cases: [(label: String, rect: CGRect, top: CGFloat, bottom: CGFloat)] = [
            ("open 380x260 fast-path", fastRect, 16, 42),
            ("small 200x32 clamped-height", clampedHeightRect, 16, 42),
            ("closed 200x32 fast-path", closedNotchRect, 8, 12),
            ("translated 252x200 fast-path", translatedOpenRect, 16, 60),
            ("narrow 120x200 clamped-width", clampedWidthRect, 16, 42),
        ]

        for (label, rect, topRadius, bottomRadius) in cases {
            let shapePath = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: .notch).path(in: rect)
            var shapeElements: [Path.Element] = []
            shapePath.forEach { shapeElements.append($0) }

            precondition(
                shapeElements.count == 13,
                "FAIL [\(label)]: expected 13 path elements, got \(shapeElements.count)"
            )
            guard
                case .move(let m0) = shapeElements[0],
                case .quadCurve(let q1To, let q1Ctrl) = shapeElements[1],
                case .line(let leftReach) = shapeElements[2],
                case .curve(let l1To, let l1c1, let l1c2) = shapeElements[3],
                case .curve(let l2To, let l2c1, let l2c2) = shapeElements[4],
                case .curve(let l3To, let l3c1, let l3c2) = shapeElements[5],
                case .line(let rightReach) = shapeElements[6],
                case .curve(let r1To, let r1c1, let r1c2) = shapeElements[7],
                case .curve(let r2To, let r2c1, let r2c2) = shapeElements[8],
                case .curve(let r3To, let r3c1, let r3c2) = shapeElements[9],
                case .line(let rightTop) = shapeElements[10],
                case .quadCurve(let q2To, let q2Ctrl) = shapeElements[11],
                case .closeSubpath = shapeElements[12]
            else {
                fatalError("FAIL [\(label)]: unexpected NotchShape element layout: \(shapeElements)")
            }

            let top = max(0, min(topRadius, rect.width / 2))
            let bottom = max(0, min(bottomRadius, min(rect.width / 2 - top, rect.height)))
            let bodyRect = CGRect(x: rect.minX + top, y: rect.minY, width: rect.width - 2 * top, height: rect.height)

            // Top flare & bounding parity
            precondition(hypot(m0.x - rect.minX, m0.y - rect.minY) < 1e-6, "FAIL [\(label)]: top-left start")
            precondition(hypot(q1To.x - (rect.minX + top), q1To.y - (rect.minY + top)) < 1e-6, "FAIL [\(label)]: top-left flare end")
            precondition(hypot(q1Ctrl.x - (rect.minX + top), q1Ctrl.y - rect.minY) < 1e-6, "FAIL [\(label)]: top-left flare control")
            precondition(hypot(rightTop.x - (rect.maxX - top), rightTop.y - (rect.minY + top)) < 1e-6, "FAIL [\(label)]: top-right flare start")
            precondition(hypot(q2To.x - rect.maxX, q2To.y - rect.minY) < 1e-6, "FAIL [\(label)]: top-right flare end")
            precondition(hypot(q2Ctrl.x - (rect.maxX - top), q2Ctrl.y - rect.minY) < 1e-6, "FAIL [\(label)]: top-right flare control")

            let refPath = UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: bottom,
                bottomTrailingRadius: bottom,
                topTrailingRadius: 0,
                style: .continuous
            ).path(in: bodyRect)
            var refElements: [Path.Element] = []
            refPath.forEach { refElements.append($0) }
            guard
                refElements.count >= 9,
                case .line(let p1) = refElements[1],
                case .curve(let p2, let c2a, let c2b) = refElements[2],
                case .curve(let p3, let c3a, let c3b) = refElements[3],
                case .curve(let p4, let c4a, let c4b) = refElements[4],
                case .line(let l5) = refElements[5],
                case .curve(let p6, let c6a, let c6b) = refElements[6],
                case .curve(let p7, let c7a, let c7b) = refElements[7],
                case .curve(let p8, let c8a, let c8b) = refElements[8]
            else {
                fatalError("FAIL [\(label)]: unexpected reference UnevenRoundedRectangle element layout")
            }

            // Sample all 6 continuous-corner cubic segments at 11 points each against reversed reference segments.
            let shapeSegments: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
                (leftReach, l1c1, l1c2, l1To),
                (l1To, l2c1, l2c2, l2To),
                (l2To, l3c1, l3c2, l3To),
                (rightReach, r1c1, r1c2, r1To),
                (r1To, r2c1, r2c2, r2To),
                (r2To, r3c1, r3c2, r3To),
            ]
            let refSegments: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
                (p8, c8b, c8a, p7),
                (p7, c7b, c7a, p6),
                (p6, c6b, c6a, l5),
                (p4, c4b, c4a, p3),
                (p3, c3b, c3a, p2),
                (p2, c2b, c2a, p1),
            ]

            for (segIdx, (sSeg, rSeg)) in zip(shapeSegments, refSegments).enumerated() {
                for step in 0...10 {
                    let t = CGFloat(step) / 10.0
                    let sp = cubicBezierPoint(p0: sSeg.0, c1: sSeg.1, c2: sSeg.2, p3: sSeg.3, t: t)
                    let rp = cubicBezierPoint(p0: rSeg.0, c1: rSeg.1, c2: rSeg.2, p3: rSeg.3, t: t)
                    let err = hypot(sp.x - rp.x, sp.y - rp.y)
                    precondition(
                        err < 0.5,
                        "FAIL [\(label)]: segment \(segIdx) t=\(t) contour error \(err) >= 0.5 pt (got \(sp), expected \(rp))"
                    )
                }
            }

            let bounds = shapePath.boundingRect
            precondition(
                abs(bounds.minX - rect.minX) < 0.5
                    && abs(bounds.maxX - rect.maxX) < 0.5
                    && abs(bounds.minY - rect.minY) < 0.5
                    && abs(bounds.maxY - rect.maxY) < 0.5,
                "FAIL [\(label)]: boundingRect \(bounds) diverged from rect \(rect)"
            )
        }

        // Zero bottom radius edge case
        let sharpRect = CGRect(x: 0, y: 0, width: 180, height: 60)
        let sharpPath = NotchShape(topRadius: 10, bottomRadius: 0, style: .notch).path(in: sharpRect)
        precondition(
            abs(sharpPath.boundingRect.width - 180) < 0.5 && abs(sharpPath.boundingRect.height - 60) < 0.5,
            "FAIL: zero bottom radius boundingRect mismatch: \(sharpPath.boundingRect)"
        )

        print("PASS: NotchShape cached continuous-corner fast path & clamped fallback match reference (< 0.5 pt)")
    }
}
