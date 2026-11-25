//
//  lifecycle_concurrency_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for generation-aware lifecycle and concurrency guards across
//  `FaceAuthEvaluator`/`FrameBackpressureTarget`, `FaceLabController`, and `OnboardingController`.
//

import CoreGraphics
import CoreImage
import Foundation

@MainActor
private final class FakeBackpressureCamera: FrameBackpressureTarget {
    private(set) var isConsumerBusy = false
    private(set) var busyHistory: [Bool] = []

    func setConsumerBusy(_ busy: Bool) {
        isConsumerBusy = busy
        busyHistory.append(busy)
    }
}

@MainActor
private final class GenerationState {
    var current: Int

    init(current: Int = 1) {
        self.current = current
    }
}

@MainActor
private final class ExtractionGate<Output: Sendable> {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Output, Never>?
    private var entered = false
    private var releasedResult: Output?
    private(set) var observedCancelled = false

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func suspendExtraction() async -> Output {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if let result = releasedResult {
            observedCancelled = Task.isCancelled
            return result
        }
        let result = await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        observedCancelled = Task.isCancelled
        return result
    }

    func resumeExtraction(with result: Output) {
        if let continuation = releaseContinuation {
            releaseContinuation = nil
            continuation.resume(returning: result)
        } else {
            releasedResult = result
        }
    }
}

private func makePipeline() -> FaceRecognitionPipeline {
    FaceRecognitionPipeline(
        embedder: VisionFeaturePrintEmbedder(),
        usingFallbackEmbedder: true,
        fallbackReason: "lifecycle_concurrency_selftest"
    )
}

private func makeEvaluator() -> FaceAuthEvaluator {
    FaceAuthEvaluator(
        pipeline: makePipeline(),
        livenessEnabled: false,
        livenessModeProvider: { .light }
    )
}

private func makeSyntheticCGImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let cgImage = context.makeImage()
    else {
        fatalError("FAIL: failed to allocate synthetic CGImage")
    }
    return cgImage
}

private func makeSyntheticFrame(id: UInt64 = 1) -> CameraFrame {
    let cgImage = makeSyntheticCGImage()
    return CameraFrame(
        id: id,
        image: cgImage,
        source: CIImage(cgImage: cgImage),
        sourceSize: CGSize(width: 8, height: 8)
    )
}

private func makeExtractedLabFrame(embedding: [Float]) -> FaceLabController.ExtractedFrame {
    let cgImage = makeSyntheticCGImage()
    let face = DetectedFace(
        boundingBox: CGRect(x: 1, y: 1, width: 4, height: 4),
        normalizedBoundingBox: CGRect(x: 0.125, y: 0.125, width: 0.5, height: 0.5),
        quality: 0.9,
        yaw: 0.0,
        roll: 0.0,
        pitch: 0.0,
        landmarks: nil,
        imageSize: CGSize(width: 8, height: 8)
    )
    let recognition = FaceRecognitionResult(
        embedding: embedding,
        alignedImage: cgImage,
        alignmentTier: .fivePoint,
        quality: 0.9,
        face: face
    )
    let livenessFrame = LivenessFrame(
        timestamp: Date(),
        landmarks: [],
        interocularDistance: 20,
        yaw: 0.0,
        leftEyeAspectRatio: 0.3,
        rightEyeAspectRatio: 0.3,
        noseOffsetRatio: 0.0,
        hasReliableLandmarks: true,
        deviceOverlapFraction: nil
    )
    return FaceLabController.ExtractedFrame(
        result: recognition,
        livenessFrame: livenessFrame,
        precomputedGeometry: nil
    )
}

private func makeOfflineOnboardingController(
    onDismissOnboarding: @escaping @MainActor () -> Void = {},
    completionDismissDelay: Duration? = nil,
    enrollmentFinishTimings: OnboardingController.EnrollmentFinishTimings? = nil
) -> OnboardingController {
    let storage = FaceEnrollmentStore.Storage(
        isSessionUnlocked: { false },
        load: { [] },
        save: { _ in },
        deleteAll: {}
    )
    let store = FaceEnrollmentStore(storage: storage, observeSessionNotifications: false)
    let credentialService = OnboardingCredentialService(
        orphanedDataClassification: { .noEncryptedData },
        deletePassword: {},
        unlockSession: { _ in },
        savePassword: { _ in }
    )
    return OnboardingController(
        pipeline: makePipeline(),
        store: store,
        credentialService: credentialService,
        onDismissOnboarding: onDismissOnboarding,
        completionDismissDelay: completionDismissDelay,
        enrollmentFinishTimings: enrollmentFinishTimings
    )
}

private func withSavedOnboardingSettings(_ body: () async -> Void) async {
    let settings = GlanceSettings.shared
    let hadCompleted = settings.hasCompletedOnboarding
    let hadAcknowledged = settings.hasAcknowledgedSecurityNotice
    let resumeStep = settings.onboardingResumeStep
    defer {
        settings.hasCompletedOnboarding = hadCompleted
        settings.hasAcknowledgedSecurityNotice = hadAcknowledged
        settings.onboardingResumeStep = resumeStep
    }
    await body()
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError("FAIL: \(message)")
    }
}

@main
struct LifecycleConcurrencySelfTest {
    @MainActor
    static func main() async {
        await testSupersededExtractionDoesNotClearNewerRunsBusyState()
        await testCancelledCurrentGenerationStillClearsBusyState()
        await testConvenienceOverloadManagesBackpressureAndGeneration()
        testCameraManagerConformsToFrameBackpressureTarget()
        await testFaceLabStoppedRunCannotRepopulateAfterRestart()
        await testOnboardingTeardownDuringCompletionDismissSuppressesCallbacks()
        await testOnboardingTeardownDuringFinishEnrollmentDoesNotAdvanceToName()
        print("PASS: generation-aware lifecycle, Face Lab, and onboarding concurrency guards verified.")
    }

    /// Review Focus #4: Run 1 (gen = 1) completing after Run 2 (gen = 2) is already busy
    /// must NOT clear Run 2's `isConsumerBusy` flag.
    @MainActor
    private static func testSupersededExtractionDoesNotClearNewerRunsBusyState() async {
        let camera = FakeBackpressureCamera()
        let evaluator = makeEvaluator()
        let generation = GenerationState(current: 1)
        let gate1 = ExtractionGate<ExtractedAuthFrame>()
        let gate2 = ExtractionGate<ExtractedAuthFrame>()

        let task1 = Task { @MainActor in
            _ = await evaluator.extractFrameWithBackpressure(
                camera: camera,
                isCurrentGeneration: { generation.current == 1 },
                extract: { await gate1.suspendExtraction() }
            )
        }
        await gate1.waitUntilEntered()
        expect(camera.isConsumerBusy == true, "Run 1 must mark camera busy while suspended")
        expect(camera.busyHistory == [true], "Run 1 must record busy=true")

        generation.current = 2
        let task2 = Task { @MainActor in
            _ = await evaluator.extractFrameWithBackpressure(
                camera: camera,
                isCurrentGeneration: { generation.current == 2 },
                extract: { await gate2.suspendExtraction() }
            )
        }
        await gate2.waitUntilEntered()
        expect(camera.isConsumerBusy == true, "Run 2 must keep camera busy while suspended")
        expect(camera.busyHistory == [true, true], "Run 2 must record busy=true")

        gate1.resumeExtraction(
            with: ExtractedAuthFrame(luminance: nil, recognition: nil, livenessFrame: nil)
        )
        await task1.value
        expect(camera.isConsumerBusy == true, "Superseded Run 1 must NOT clear Run 2's busy flag")
        expect(camera.busyHistory == [true, true], "Superseded Run 1 must not emit busy=false")

        gate2.resumeExtraction(
            with: ExtractedAuthFrame(luminance: nil, recognition: nil, livenessFrame: nil)
        )
        await task2.value
        expect(camera.isConsumerBusy == false, "Current Run 2 finishing must clear busy flag")
        expect(camera.busyHistory == [true, true, false], "Current Run 2 must emit busy=false")
    }

    @MainActor
    private static func testCancelledCurrentGenerationStillClearsBusyState() async {
        let camera = FakeBackpressureCamera()
        let evaluator = makeEvaluator()
        let generation = GenerationState(current: 1)
        let gate = ExtractionGate<ExtractedAuthFrame>()

        let task = Task { @MainActor in
            _ = await evaluator.extractFrameWithBackpressure(
                camera: camera,
                isCurrentGeneration: { generation.current == 1 },
                extract: { await gate.suspendExtraction() }
            )
        }
        await gate.waitUntilEntered()
        expect(camera.isConsumerBusy == true, "Run 1 must mark camera busy before cancellation")

        task.cancel()
        gate.resumeExtraction(
            with: ExtractedAuthFrame(luminance: nil, recognition: nil, livenessFrame: nil)
        )
        await task.value

        expect(gate.observedCancelled == true, "Task must observe cancellation before cleanup")
        expect(camera.isConsumerBusy == false, "Cancelled current-generation extraction must still clear busy state")
        expect(camera.busyHistory == [true, false], "Cancelled current-generation run must record [true, false]")
    }

    @MainActor
    private static func testConvenienceOverloadManagesBackpressureAndGeneration() async {
        let frame = makeSyntheticFrame()

        let camera = FakeBackpressureCamera()
        let evaluator = makeEvaluator()

        let currentResult = await evaluator.extractFrameWithBackpressure(
            from: frame,
            camera: camera,
            strictCloseRangeOnly: true,
            nightBoostEnabled: true,
            isCurrentGeneration: { true }
        )
        expect(currentResult.luminance != nil, "Night-boost convenience extraction must measure luminance")
        expect(camera.isConsumerBusy == false, "Convenience overload must clear busy state when generation matches")
        expect(camera.busyHistory == [true, false], "Convenience overload must record [true, false]")

        let staleResult = await evaluator.extractFrameWithBackpressure(
            from: frame,
            camera: camera,
            strictCloseRangeOnly: false,
            isCurrentGeneration: { false }
        )
        expect(staleResult.luminance == nil, "Default nightBoostEnabled=false must skip luminance measurement")
        expect(camera.isConsumerBusy == true, "Convenience overload must preserve busy state when superseded")
        expect(camera.busyHistory == [true, false, true], "Superseded convenience run must not emit busy=false")
    }

    @MainActor
    private static func testCameraManagerConformsToFrameBackpressureTarget() {
        let camera = CameraManager(publishesFrames: false)
        let target: any FrameBackpressureTarget = camera
        target.setConsumerBusy(true)
        target.setConsumerBusy(false)
    }

    /// Review Focus #4: Delayed Face Lab extraction from a stopped run MUST NOT
    /// repopulate UI state after restart or block the restarted run's processing slot.
    @MainActor
    private static func testFaceLabStoppedRunCannotRepopulateAfterRestart() async {
        var cameraRunning = false
        var extractorCalls = 0
        let gate1 = ExtractionGate<Result<FaceLabController.ExtractedFrame, Error>>()
        let gate2 = ExtractionGate<Result<FaceLabController.ExtractedFrame, Error>>()

        let controller = FaceLabController(
            pipeline: makePipeline(),
            frameExtractor: { _, _, _ in
                extractorCalls += 1
                switch extractorCalls {
                case 1:
                    return try await gate1.suspendExtraction().get()
                case 2:
                    return try await gate2.suspendExtraction().get()
                default:
                    throw FaceRecognitionPipelineError.noFaceDetected
                }
            },
            isCameraRunning: { cameraRunning },
            startCamera: { cameraRunning = true },
            stopCamera: { cameraRunning = false }
        )
        defer { controller.stop() }

        await controller.start()
        let run1Generation = controller.captureGeneration
        expect(run1Generation == 1, "First start() must increment captureGeneration")

        let run1Task = Task { @MainActor in
            await controller.processFrame(makeSyntheticFrame(id: 1))
        }
        await gate1.waitUntilEntered()
        expect(extractorCalls == 1, "Run 1 must enter frame extraction")

        controller.stop()
        let stoppedGeneration = controller.captureGeneration
        expect(stoppedGeneration > run1Generation, "stop() must increment captureGeneration")

        await controller.start()
        let run2Generation = controller.captureGeneration
        expect(run2Generation > stoppedGeneration, "Restarted Run 2 must increment captureGeneration")

        let run2Task = Task { @MainActor in
            await controller.processFrame(makeSyntheticFrame(id: 2))
        }
        await gate2.waitUntilEntered()
        expect(extractorCalls == 2, "Run 2 must NOT be blocked by suspended Run 1")

        gate1.resumeExtraction(with: .success(makeExtractedLabFrame(embedding: [0.9, 0.1])))
        await run1Task.value

        expect(controller.detectedFaces.isEmpty, "Stopped Run 1 must not populate detectedFaces")
        expect(controller.currentResult == nil, "Stopped Run 1 must not populate currentResult")
        expect(controller.lastLivenessFrame == nil, "Stopped Run 1 must not populate lastLivenessFrame")
        expect(controller.currentLiveness == .empty, "Stopped Run 1 must leave currentLiveness empty")

        await controller.processFrame(makeSyntheticFrame(id: 3))
        expect(extractorCalls == 2, "Superseded Run 1 cleanup must not clear Run 2's activeProcessingGeneration")

        gate2.resumeExtraction(with: .success(makeExtractedLabFrame(embedding: [0.1, 0.9])))
        await run2Task.value
        expect(controller.currentResult?.embedding == [0.1, 0.9], "Run 2 must apply its own extraction result")
        expect(controller.detectedFaces.count == 1, "Run 2 must update detectedFaces")
        expect(controller.lastLivenessFrame != nil, "Run 2 must update lastLivenessFrame")

        await controller.processFrame(makeSyntheticFrame(id: 4))
        expect(extractorCalls == 3, "Run 2 must allow subsequent frames after completing")
    }

    /// Review Focus #4: `teardown()` during `scheduleCompletionDismiss()` MUST cancel dismissal
    /// and suppress both `onDismissOnboarding` and `onFirstRunComplete`.
    @MainActor
    private static func testOnboardingTeardownDuringCompletionDismissSuppressesCallbacks() async {
        await withSavedOnboardingSettings {
            var dismissCount = 0
            var firstRunCompleteCount = 0
            let controller = makeOfflineOnboardingController(
                onDismissOnboarding: { dismissCount += 1 },
                completionDismissDelay: .milliseconds(80)
            )
            controller.onFirstRunComplete = { firstRunCompleteCount += 1 }

            controller.scheduleCompletionDismiss()
            try? await Task.sleep(for: .milliseconds(20))
            controller.teardown()
            try? await Task.sleep(for: .milliseconds(120))

            expect(dismissCount == 0, "teardown() during dismiss delay must suppress onDismissOnboarding")
            expect(firstRunCompleteCount == 0, "teardown() during dismiss delay must suppress onFirstRunComplete")
            expect(controller.completionDismissTask == nil, "teardown() must clear completionDismissTask")
            expect(controller.isTornDown == true, "teardown() must mark controller torn down")

            // Normal completion path clears completionDismissTask before teardown() so callbacks run uncancelled.
            var normalDismissCount = 0
            var normalCompleteCount = 0
            var sawCancelledInCallback = false
            let normalController = makeOfflineOnboardingController(
                onDismissOnboarding: {
                    normalDismissCount += 1
                    if Task.isCancelled { sawCancelledInCallback = true }
                },
                completionDismissDelay: .milliseconds(20)
            )
            normalController.onFirstRunComplete = {
                normalCompleteCount += 1
                if Task.isCancelled { sawCancelledInCallback = true }
            }

            normalController.scheduleCompletionDismiss()
            try? await Task.sleep(for: .milliseconds(80))

            expect(normalDismissCount == 1, "Normal completion dismiss must invoke onDismissOnboarding once")
            expect(normalCompleteCount == 1, "Normal completion dismiss must invoke onFirstRunComplete once")
            expect(!sawCancelledInCallback, "Normal dismiss must clear completionDismissTask before teardown()")
            expect(normalController.completionDismissTask == nil, "Completed dismiss must leave task nil")
        }
    }

    @MainActor
    private static func testOnboardingTeardownDuringFinishEnrollmentDoesNotAdvanceToName() async {
        await withSavedOnboardingSettings {
            let timings = OnboardingController.EnrollmentFinishTimings(
                guideOverlayFadeOut: .milliseconds(20),
                previewFadeOut: .milliseconds(20),
                checkmarkDelay: .milliseconds(60),
                cameraCompleteToNameDelay: .milliseconds(120)
            )
            let controller = makeOfflineOnboardingController(enrollmentFinishTimings: timings)
            controller.step = .enroll
            let initialGeneration = controller.enrollGeneration

            let finishTask = Task { @MainActor in
                await controller.finishEnrollment()
            }
            try? await Task.sleep(for: .milliseconds(10))
            expect(controller.enrollmentComplete == true, "finishEnrollment() must enter before teardown")

            controller.teardown()
            await finishTask.value
            try? await Task.sleep(for: .milliseconds(130))

            expect(controller.step == .enroll, "teardown() during finishEnrollment() must not advance to .name")
            expect(controller.showCheckmark == false, "teardown() during finishEnrollment() must not show checkmark")
            expect(controller.isTornDown == true, "teardown() must mark controller torn down")
            expect(controller.enrollGeneration > initialGeneration, "teardown() must bump enrollGeneration")
        }
    }
}
