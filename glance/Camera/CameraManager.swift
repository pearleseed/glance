//
//  CameraManager.swift
//  glance
//
//  Owns the AVCaptureSession and publishes the newest camera frame as a CGImage. Runs entirely on-device.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

@Observable
@MainActor
final class CameraManager {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    var session: AVCaptureSession { sessionBox.session }
    private let sessionQueue = DispatchQueue(label: "com.pearleseed.glance.camera.session")

    /// Handed to the delegate outside the actor; coalesces frames back onto `@MainActor`.
    private let framePublisher: CameraFramePublisher
    private let frameWaiter = CameraFrameWaiter(isActive: false)
    private let sessionBox: CameraSessionBox
    private let observerBox = NotificationObserverBox()
    /// Monotonic token bumped on `start()` and `stop()` so suspended `start()` / `reconcileDeviceIfNeeded()`
    /// callbacks cannot clobber state after a subsequent `stop()` or restart.
    private var sessionGeneration: UInt64 = 0

    init(publishesFrames: Bool = true) {
        let publisher = CameraFramePublisher(publishesFrames: publishesFrames)
        self.framePublisher = publisher
        self.sessionBox = CameraSessionBox(framePublisher: publisher, queue: sessionQueue)
        publisher.owner = self

        let queue = sessionQueue
        let box = sessionBox
        let reconcileIfRunning: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.reconcileDeviceIfNeeded()
            }
        }
        observerBox.observe(forName: AVCaptureDevice.wasConnectedNotification) { _ in
            reconcileIfRunning()
        }
        observerBox.observe(forName: AVCaptureDevice.wasDisconnectedNotification) { [weak box] _ in
            // Always flag rebind on sessionQueue even while stopped so unplug/replug
            // between scans never keeps a stale AVCaptureDeviceInput with the same uniqueID.
            let capturedBox = box
            queue.async {
                capturedBox?.markDeviceRebindNeeded()
            }
            reconcileIfRunning()
        }
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
            errorMessage = Self.permissionDeniedMessage(for: status)
            return
        }

        guard !Task.isCancelled else { return }
        errorMessage = nil
        isRunning = true
        frameWaiter.start()
        framePublisher.beginCapture()

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
        framePublisher.endCapture()
        frameWaiter.stop()
        sessionQueue.async { [sessionBox] in
            sessionBox.stop()
        }
    }

    func setConsumerBusy(_ busy: Bool) {
        framePublisher.setConsumerBusy(busy)
    }

    func nextFrame(
        after lastFrameID: UInt64?,
        until deadline: ContinuousClock.Instant
    ) async -> CameraFrame? {
        guard isRunning else { return nil }
        let epoch = frameWaiter.currentEpoch
        return await frameWaiter.nextFrame(after: lastFrameID, until: deadline, expectedEpoch: epoch)
    }

    func publish(frame: CameraFrame) {
        guard isRunning else { return }
        currentFrame = frame
        frameWaiter.deliver(frame)
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
                    self.frameWaiter.clearLatestFrame()
                }
            }
        }
    }

    private static func permissionDeniedMessage(for status: AVAuthorizationStatus) -> String {
        let description = describe(status)
        if status == .restricted {
            return "Camera access not granted (status: \(description)). "
                + "macOS reports this as *restricted* — not a simple user denial. This usually means Screen Time "
                + "content restrictions or an MDM/profile policy is blocking camera access for this app; toggling "
                + "it in System Settings > Privacy & Security > Camera won't help until that restriction is lifted."
        }
        return "Camera access not granted (status: \(description)). "
            + "Enable it in System Settings > Privacy & Security > Camera. If glance isn't listed there, quit the "
            + "app, run `tccutil reset Camera com.pearleseed.glance` in Terminal, then relaunch so macOS asks again."
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
