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
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/performance_selftest \
//        glance/Core/ObservationWaiter.swift \
//        glance/Liveness/LandmarkGeometry.swift \
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
            elapsed1 < .milliseconds(50),
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
            elapsed2 < .milliseconds(50),
            "FAIL: waiter took too long to wake on frame2 delivery: \(elapsed2)"
        )

        // Immediate return if a newer frame is already present.
        let start3 = clock.now
        let cached = await waiter.nextFrame(after: frame1.id, until: start3 + .seconds(1))
        let elapsed3 = clock.now - start3
        precondition(cached?.id == frame2.id, "FAIL: expected cached frame2 immediately")
        precondition(elapsed3 < .milliseconds(10), "FAIL: cached frame return took \(elapsed3)")

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
        precondition(stopElapsed < .milliseconds(35), "FAIL: stop() took too long to wake waiter: \(stopElapsed)")

        // Calling nextFrame while stopped must immediately return nil.
        let stoppedNow = clock.now
        let whileStopped = await waiter.nextFrame(after: nil, until: stoppedNow + .seconds(1))
        precondition(whileStopped == nil, "FAIL: expected nil when waiter is stopped")
        precondition(clock.now - stoppedNow < .milliseconds(10), "FAIL: stopped waiter suspended")

        // 2. Deadline expiry with no frame delivered returns nil on time.
        waiter.start()
        let timeoutStart = clock.now
        let timedOut = await waiter.nextFrame(after: nil, until: timeoutStart + .milliseconds(35))
        let timeoutElapsed = clock.now - timeoutStart
        precondition(timedOut == nil, "FAIL: expected nil on deadline expiry")
        precondition(
            timeoutElapsed >= .milliseconds(25) && timeoutElapsed < .milliseconds(200),
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
        precondition(cancelElapsed < .milliseconds(35), "FAIL: task cancellation took too long: \(cancelElapsed)")

        // 4. Stale-frame isolation across start -> deliver -> stop -> start.
        let oldFrame = makeDummyCameraFrame(id: 100)
        waiter.deliver(oldFrame)
        waiter.stop()
        waiter.start()
        let staleCheck = await waiter.nextFrame(after: nil, until: clock.now + .milliseconds(25))
        precondition(staleCheck == nil, "FAIL: stale frame leaked across stop() -> start()")

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
        precondition(immediateElapsed < .milliseconds(15), "FAIL: already-false wait suspended for \(immediateElapsed)")

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
        precondition(wait1Elapsed < .milliseconds(60), "FAIL: phase wake took too long: \(wait1Elapsed)")

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
        precondition(wait2Elapsed < .milliseconds(100), "FAIL: multi-step wait took too long: \(wait2Elapsed)")

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
        precondition(wait3Elapsed < .milliseconds(60), "FAIL: signal wake took too long: \(wait3Elapsed)")

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
            timeoutElapsed >= .milliseconds(25) && timeoutElapsed < .milliseconds(200),
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
        precondition(cancelElapsed < .milliseconds(60), "FAIL: observation cancel took too long: \(cancelElapsed)")

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
}
