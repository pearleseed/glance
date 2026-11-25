//
//  CameraCaptureSession.swift
//  glance
//
//  Off-main-actor AVCaptureSession wrapper and sample-buffer frame coalescer
//  used by `CameraManager`.
//

@preconcurrency import AVFoundation
import CoreImage
import os

nonisolated struct CameraReconcileResult: Sendable {
    let errorMessage: String?
    let clearedInput: Bool
}

/// Serializes all `AVCaptureSession` configuration, device switching, start, and stop onto `sessionQueue`.
/// `AVCaptureSession` and `AVCaptureVideoDataOutput` are created lazily on first use so idle app launch
/// allocates zero AVFoundation capture objects.
nonisolated final class CameraSessionBox: @unchecked Sendable {
    private struct LazySessionSlot: @unchecked Sendable {
        var session: AVCaptureSession?
    }

    private let sessionLock = OSAllocatedUnfairLock(initialState: LazySessionSlot())
    private var videoOutput: AVCaptureVideoDataOutput?
    private let framePublisher: CameraFramePublisher
    private let queue: DispatchQueue
    private var isConfigured = false
    private var wantsRunning = false
    private var needsDeviceRebind = false
    private var currentInput: AVCaptureDeviceInput?

    var session: AVCaptureSession { ensureSession() }

    init(framePublisher: CameraFramePublisher, queue: DispatchQueue) {
        self.framePublisher = framePublisher
        self.queue = queue
    }

    func markDeviceRebindNeeded() {
        needsDeviceRebind = true
    }

    func start(preferredID: String?) -> String? {
        wantsRunning = true
        let session = ensureSession()
        configureSessionIfNeeded(on: session)
        let result = reconcileDevice(on: session, preferredID: preferredID)
        syncSessionRunningState(on: session)
        return result.errorMessage
    }

    func reconcileIfRunning(preferredID: String?) -> CameraReconcileResult? {
        guard wantsRunning else { return nil }
        let session = ensureSession()
        configureSessionIfNeeded(on: session)
        let result = reconcileDevice(on: session, preferredID: preferredID)
        syncSessionRunningState(on: session)
        return result
    }

    func stop() {
        wantsRunning = false
        framePublisher.discardPending()
        let session = sessionLock.withLock { $0.session }
        guard let session else { return }
        if session.isRunning {
            session.stopRunning()
        }
        if framePublisher.publishesFrames {
            SharedCoreImageContext.clearCaches()
        }
    }

    private func ensureSession() -> AVCaptureSession {
        sessionLock.withLock { slot in
            if let existing = slot.session {
                return existing
            }
            let created = AVCaptureSession()
            slot.session = created
            return created
        }
    }

    private func syncSessionRunningState(on session: AVCaptureSession) {
        if currentInput != nil {
            if !session.isRunning {
                session.startRunning()
            }
        } else if session.isRunning {
            session.stopRunning()
        }
    }

    private func configureSessionIfNeeded(on session: AVCaptureSession) {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // `.high` doesn't guarantee the sensor's max resolution; macOS (unlike iOS) doesn't fight an explicitly-set
        // `activeFormat`, so leaving this at `.high` and locking the format separately below is sufficient.
        session.sessionPreset = .high

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(framePublisher, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        self.videoOutput = output

        session.commitConfiguration()
    }

    private func reconcileDevice(on session: AVCaptureSession, preferredID: String?) -> CameraReconcileResult {
        guard let device = CameraDeviceCatalog.resolvedDevice(preferredID: preferredID) else {
            let cleared = clearCurrentInput(on: session)
            return CameraReconcileResult(errorMessage: "No camera device found.", clearedInput: cleared)
        }
        if !needsDeviceRebind,
            let existing = currentInput,
            existing.device === device,
            existing.device.isConnected,
            !existing.device.isSuspended
        {
            return CameraReconcileResult(errorMessage: nil, clearedInput: false)
        }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        framePublisher.discardPending()
        let errorMessage: String?
        let clearedInput: Bool
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            needsDeviceRebind = false
            errorMessage = selectHighestResolutionFormat(for: device)
            clearedInput = false
        } else {
            clearedInput = currentInput != nil
            currentInput = nil
            needsDeviceRebind = false
            errorMessage = "No camera device found."
        }
        session.commitConfiguration()
        return CameraReconcileResult(errorMessage: errorMessage, clearedInput: clearedInput)
    }

    private func clearCurrentInput(on session: AVCaptureSession) -> Bool {
        needsDeviceRebind = false
        framePublisher.discardPending()
        guard let existing = currentInput else { return false }
        session.beginConfiguration()
        session.removeInput(existing)
        currentInput = nil
        session.commitConfiguration()
        return true
    }

    /// Highest resolution supporting `>= 24 fps` (keeping USB webcams off 5–10 fps modes),
    /// falling back to all formats only when none reach 24 fps.
    private func selectHighestResolutionFormat(for device: AVCaptureDevice) -> String? {
        let smoothFormats = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 24 }
        }
        let candidates = smoothFormats.isEmpty ? device.formats : smoothFormats
        let best = candidates.max { lhs, rhs in
            let leftDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rightDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(leftDims.width) * Int(leftDims.height) < Int(rightDims.width) * Int(rightDims.height)
        }
        guard let best else { return nil }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = best
            return nil
        } catch {
            return "Couldn't select the camera's highest-resolution format: \(error.localizedDescription)"
        }
    }
}

private nonisolated final class MainActorOwnerBox: Sendable {
    @MainActor weak var owner: CameraManager?
}

/// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor; this delegate converts there,
/// coalesces to the latest unconsumed frame, and hops to `@MainActor` at most once per drain cycle.
nonisolated final class CameraFramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @MainActor var owner: CameraManager? {
        get { ownerBox.owner }
        set { ownerBox.owner = newValue }
    }
    let publishesFrames: Bool
    private let ownerBox = MainActorOwnerBox()
    /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
    /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
    private let maxLongEdge: CGFloat = 640
    private var nextFrameID: UInt64 = 0

    private let pendingState: OSAllocatedUnfairLock<PendingCameraFrameState>

    init(publishesFrames: Bool = true) {
        self.publishesFrames = publishesFrames
        self.pendingState = OSAllocatedUnfairLock(
            initialState: PendingCameraFrameState(publishesFrames: publishesFrames, isCapturing: false)
        )
        super.init()
    }

    func beginCapture() {
        pendingState.withLock { $0.beginCapture() }
    }

    func endCapture() {
        pendingState.withLock { $0.endCapture() }
    }

    func discardPending() {
        pendingState.withLock { $0.discardPending() }
    }

    func setConsumerBusy(_ busy: Bool) {
        pendingState.withLock { $0.isConsumerBusy = busy }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let captureGen: UInt64? = pendingState.withLock { state in
            guard state.shouldRenderSample else { return nil }
            return state.captureGeneration
        }
        guard let captureGen else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = sourceImage.extent
        var ciImage = sourceImage
        let longEdge = max(ciImage.extent.width, ciImage.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = SharedCoreImageContext.srgb.createCGImage(ciImage, from: ciImage.extent) else { return }

        nextFrameID &+= 1
        let frame = CameraFrame(
            id: nextFrameID,
            image: cgImage,
            source: sourceImage,
            sourceSize: sourceExtent.size
        )

        let shouldSchedule = pendingState.withLock { state -> Bool in
            state.enqueueIfActive(frame, generation: captureGen)
        }

        if shouldSchedule {
            let pendingState = self.pendingState
            let ownerBox = self.ownerBox
            Task { @MainActor in
                if let frame = pendingState.withLock({ $0.drainPending() }) {
                    ownerBox.owner?.publish(frame: frame)
                }
            }
        }
    }
}
