//
//  CameraManager.swift
//  glance
//
//  Owns the AVCaptureSession and publishes the newest camera frame as a CGImage. Runs entirely on-device.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation
import os

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    var session: AVCaptureSession { sessionBox.session }
    private let sessionQueue = DispatchQueue(label: "com.jonathan.glance.camera.session")

    /// Handed to the delegate outside the actor; coalesces frames back onto `@MainActor`.
    private let framePublisher = FramePublisher()
    private let sessionBox: SessionBox
    private let observerBox = ObserverBox()
    /// Monotonic token bumped on `start()` and `stop()` so suspended `start()` / `reconcileDeviceIfNeeded()`
    /// callbacks cannot clobber state after a subsequent `stop()` or restart.
    private var sessionGeneration: UInt64 = 0

    override init() {
        self.sessionBox = SessionBox(framePublisher: framePublisher, queue: sessionQueue)
        super.init()
        framePublisher.owner = self

        let center = NotificationCenter.default
        let queue = sessionQueue
        let box = sessionBox
        let reconcileIfRunning: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.reconcileDeviceIfNeeded()
            }
        }
        let onConnected: @Sendable (Notification) -> Void = { _ in
            reconcileIfRunning()
        }
        let onDisconnected: @Sendable (Notification) -> Void = { [weak box] _ in
            // Always flag rebind on sessionQueue even while stopped so unplug/replug
            // between scans never keeps a stale AVCaptureDeviceInput with the same uniqueID.
            queue.async {
                box?.markDeviceRebindNeeded()
            }
            reconcileIfRunning()
        }
        observerBox.add(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil,
            using: onConnected
        ))
        observerBox.add(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil,
            using: onDisconnected
        ))
    }

    deinit {
        let box = sessionBox
        sessionQueue.async {
            box.stop()
        }
    }

    func start() async {
        guard !Task.isCancelled else { return }
        sessionGeneration &+= 1
        let token = sessionGeneration

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard token == sessionGeneration, !Task.isCancelled else { return }
            permission = granted ? .granted : .denied
        default:
            permission = .denied
        }

        guard permission == .granted else {
            errorMessage = "Camera access not granted (status: \(describe(status))). " +
                (status == .restricted
                    ? "macOS reports this as *restricted* — not a simple user denial. This usually means Screen Time content restrictions or an MDM/profile policy is blocking camera access for this app; toggling it in System Settings > Privacy & Security > Camera won't help until that restriction is lifted."
                    : "Enable it in System Settings > Privacy & Security > Camera. If glance isn't listed there, quit the app, run `tccutil reset Camera com.jonathan.glance` in Terminal, then relaunch so macOS asks again.")
            return
        }

        guard !Task.isCancelled else { return }
        errorMessage = nil
        isRunning = true

        let preferredID = CameraDeviceCatalog.preferredCameraID()
        let startError = await withCheckedContinuation { continuation in
            sessionQueue.async { [sessionBox] in
                let error = sessionBox.start(preferredID: preferredID)
                continuation.resume(returning: error)
            }
        }

        guard token == sessionGeneration else { return }
        errorMessage = startError
    }

    func stop() {
        sessionGeneration &+= 1
        isRunning = false
        currentFrame = nil
        framePublisher.discardPending()
        sessionQueue.async { [sessionBox] in
            sessionBox.stop()
        }
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Re-resolves the active camera on `sessionQueue` when devices connect/disconnect while running.
    private func reconcileDeviceIfNeeded() {
        guard isRunning else { return }
        let token = sessionGeneration
        let preferredID = CameraDeviceCatalog.preferredCameraID()
        sessionQueue.async { [weak self, sessionBox] in
            let result = sessionBox.reconcileIfRunning(preferredID: preferredID)
            Task { @MainActor [weak self] in
                guard let self, token == self.sessionGeneration, let result else { return }
                self.errorMessage = result.errorMessage
                if result.clearedInput {
                    self.currentFrame = nil
                }
            }
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        guard isRunning else { return }
        currentFrame = frame
    }

    /// Renders a native-resolution crop of `imageRect` from `frame.source`, for spoof-cue extraction which
    /// needs pixel detail (screen texture, moiré, gloss) the downscaled working frame throws away.
    nonisolated static func renderCrop(
        from frame: CameraFrame,
        imageRect: CGRect,
        paddingFraction: CGFloat = 0.15,
        maxEdge: CGFloat = 448
    ) -> CGImage? {
        frame.renderCrop(imageRect: imageRect, paddingFraction: paddingFraction, maxEdge: maxEdge)
    }

    /// Owns `NotificationCenter` tokens outside actor isolation so `deinit` can unregister them safely under Swift 6.
    nonisolated private final class ObserverBox: @unchecked Sendable {
        private var tokens: [NSObjectProtocol] = []

        func add(_ token: NSObjectProtocol) {
            tokens.append(token)
        }

        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    /// Serializes all `AVCaptureSession` configuration, device switching, start, and stop onto `sessionQueue`.
    nonisolated private final class SessionBox: @unchecked Sendable {
        let session = AVCaptureSession()
        private let videoOutput = AVCaptureVideoDataOutput()
        private let framePublisher: FramePublisher
        private let queue: DispatchQueue
        private var isConfigured = false
        private var wantsRunning = false
        private var needsDeviceRebind = false
        private var currentInput: AVCaptureDeviceInput?

        struct ReconcileResult: Sendable {
            let errorMessage: String?
            let clearedInput: Bool
        }

        init(framePublisher: FramePublisher, queue: DispatchQueue) {
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

        func reconcileIfRunning(preferredID: String?) -> ReconcileResult? {
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

        private func reconcileDevice(preferredID: String?) -> ReconcileResult {
            guard let device = CameraDeviceCatalog.resolvedDevice(preferredID: preferredID) else {
                let cleared = clearCurrentInput()
                return ReconcileResult(errorMessage: "No camera device found.", clearedInput: cleared)
            }
            if !needsDeviceRebind,
               let existing = currentInput,
               existing.device === device,
               existing.device.isConnected,
               !existing.device.isSuspended {
                return ReconcileResult(errorMessage: nil, clearedInput: false)
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
                clearedInput = (currentInput != nil)
                currentInput = nil
                needsDeviceRebind = false
                errorMessage = "No camera device found."
            }
            session.commitConfiguration()
            return ReconcileResult(errorMessage: errorMessage, clearedInput: clearedInput)
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
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
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
    nonisolated private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: CameraManager?
        private let ciContext = CIContext()
        /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
        /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0

        private struct PendingState {
            var pendingFrame: CameraFrame?
            var isDeliveryScheduled = false
        }
        private let pendingState = OSAllocatedUnfairLock(initialState: PendingState())

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
}
