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

nonisolated struct PendingCameraFrameState {
    var pendingFrame: CameraFrame?
    var isDeliveryScheduled = false
}

/// Serializes all `AVCaptureSession` configuration, device switching, start, and stop onto `sessionQueue`.
nonisolated final class CameraSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let framePublisher: CameraFramePublisher
    private let queue: DispatchQueue
    private var isConfigured = false
    private var wantsRunning = false
    private var needsDeviceRebind = false
    private var currentInput: AVCaptureDeviceInput?

    init(framePublisher: CameraFramePublisher, queue: DispatchQueue) {
        self.framePublisher = framePublisher
        self.queue = queue
    }

    func markDeviceRebindNeeded() {
        needsDeviceRebind = true
    }

    func start(preferredID: String?) -> String? {
        wantsRunning = true
        configureSessionIfNeeded()
        let result = reconcileDevice(preferredID: preferredID)
        syncSessionRunningState()
        return result.errorMessage
    }

    func reconcileIfRunning(preferredID: String?) -> CameraReconcileResult? {
        guard wantsRunning else { return nil }
        let result = reconcileDevice(preferredID: preferredID)
        syncSessionRunningState()
        return result
    }

    func stop() {
        wantsRunning = false
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func syncSessionRunningState() {
        if currentInput != nil {
            if !session.isRunning {
                session.startRunning()
            }
        } else if session.isRunning {
            session.stopRunning()
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // `.high` doesn't guarantee the sensor's max resolution; macOS (unlike iOS) doesn't fight an explicitly-set
        // `activeFormat`, so leaving this at `.high` and locking the format separately below is sufficient.
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: queue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    private func reconcileDevice(preferredID: String?) -> CameraReconcileResult {
        guard let device = CameraDeviceCatalog.resolvedDevice(preferredID: preferredID) else {
            let cleared = clearCurrentInput()
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

    private func clearCurrentInput() -> Bool {
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

/// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor; this delegate converts there,
/// coalesces to the latest unconsumed frame, and hops to `@MainActor` at most once per drain cycle.
nonisolated final class CameraFramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: CameraManager?
    private let ciContext = CIContext()
    /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
    /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
    private let maxLongEdge: CGFloat = 640
    private var nextFrameID: UInt64 = 0

    private let pendingState = OSAllocatedUnfairLock(initialState: PendingCameraFrameState())

    func discardPending() {
        pendingState.withLock { state in
            state.pendingFrame = nil
            state.isDeliveryScheduled = false
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = sourceImage.extent
        var ciImage = sourceImage
        let longEdge = max(ciImage.extent.width, ciImage.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        nextFrameID &+= 1
        let frame = CameraFrame(
            id: nextFrameID,
            image: cgImage,
            source: sourceImage,
            sourceSize: sourceExtent.size
        )

        let shouldSchedule = pendingState.withLock { state -> Bool in
            state.pendingFrame = frame
            if state.isDeliveryScheduled {
                return false
            }
            state.isDeliveryScheduled = true
            return true
        }

        if shouldSchedule {
            Task { @MainActor [weak self] in
                self?.drainPendingFrame()
            }
        }
    }

    @MainActor
    private func drainPendingFrame() {
        let frame = pendingState.withLock { state -> CameraFrame? in
            let next = state.pendingFrame
            state.pendingFrame = nil
            state.isDeliveryScheduled = false
            return next
        }
        if let frame {
            owner?.publish(frame: frame)
        }
    }
}
