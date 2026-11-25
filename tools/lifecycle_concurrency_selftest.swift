//
//  lifecycle_concurrency_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for generation-aware backpressure frame extraction
//  on `FaceAuthEvaluator` and `FrameBackpressureTarget`.
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
private final class ExtractionGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<ExtractedAuthFrame, Never>?
    private var entered = false
    private var releasedResult: ExtractedAuthFrame?
    private(set) var observedCancelled = false

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func suspendExtraction() async -> ExtractedAuthFrame {
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

    func resumeExtraction(
        with result: ExtractedAuthFrame = ExtractedAuthFrame(
            luminance: nil,
            recognition: nil,
            livenessFrame: nil
        )
    ) {
        if let continuation = releaseContinuation {
            releaseContinuation = nil
            continuation.resume(returning: result)
        } else {
            releasedResult = result
        }
    }
}

private func makeEvaluator() -> FaceAuthEvaluator {
    let pipeline = FaceRecognitionPipeline(
        embedder: VisionFeaturePrintEmbedder(),
        usingFallbackEmbedder: true,
        fallbackReason: "lifecycle_concurrency_selftest"
    )
    return FaceAuthEvaluator(
        pipeline: pipeline,
        livenessEnabled: false,
        livenessModeProvider: { .light }
    )
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
        print("PASS: generation-aware backpressure extraction and cancellation cleanup verified.")
    }

    /// Review Focus #4: Run 1 (gen = 1) completing after Run 2 (gen = 2) is already busy
    /// must NOT clear Run 2's `isConsumerBusy` flag.
    @MainActor
    private static func testSupersededExtractionDoesNotClearNewerRunsBusyState() async {
        let camera = FakeBackpressureCamera()
        let evaluator = makeEvaluator()
        let generation = GenerationState(current: 1)
        let gate1 = ExtractionGate()
        let gate2 = ExtractionGate()

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

        gate1.resumeExtraction()
        await task1.value
        expect(camera.isConsumerBusy == true, "Superseded Run 1 must NOT clear Run 2's busy flag")
        expect(camera.busyHistory == [true, true], "Superseded Run 1 must not emit busy=false")

        gate2.resumeExtraction()
        await task2.value
        expect(camera.isConsumerBusy == false, "Current Run 2 finishing must clear busy flag")
        expect(camera.busyHistory == [true, true, false], "Current Run 2 must emit busy=false")
    }

    @MainActor
    private static func testCancelledCurrentGenerationStillClearsBusyState() async {
        let camera = FakeBackpressureCamera()
        let evaluator = makeEvaluator()
        let generation = GenerationState(current: 1)
        let gate = ExtractionGate()

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
        gate.resumeExtraction()
        await task.value

        expect(gate.observedCancelled == true, "Task must observe cancellation before cleanup")
        expect(camera.isConsumerBusy == false, "Cancelled current-generation extraction must still clear busy state")
        expect(camera.busyHistory == [true, false], "Cancelled current-generation run must record [true, false]")
    }

    @MainActor
    private static func testConvenienceOverloadManagesBackpressureAndGeneration() async {
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
        let frame = CameraFrame(
            id: 1,
            image: cgImage,
            source: CIImage(cgImage: cgImage),
            sourceSize: CGSize(width: 8, height: 8)
        )

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
}
