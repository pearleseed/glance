//
//  CameraFrame.swift
//  glance
//
//  Pure CoreImage/CoreGraphics frame container and native-resolution crop renderer.
//  Kept separate from `CameraManager` so recognition and standalone self-tests can
//  crop native frames without importing `AVFoundation` or AppKit settings.
//

import CoreGraphics
import CoreImage
import os

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
nonisolated struct CameraFrame: @unchecked Sendable {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize

    /// Renders a native-resolution crop of `imageRect` (in `image`'s top-left/y-down pixel space)
    /// from `source`, expanded by `paddingFraction` on each side and downscaled so the longer edge
    /// does not exceed `maxEdge`.
    func renderCrop(
        imageRect: CGRect,
        paddingFraction: CGFloat = 0.15,
        maxEdge: CGFloat = 448
    ) -> CGImage? {
        let workingWidth = CGFloat(image.width)
        let workingHeight = CGFloat(image.height)
        guard workingWidth > 0, workingHeight > 0,
            sourceSize.width > 0, sourceSize.height > 0,
            maxEdge > 0
        else { return nil }
        let scaleX = sourceSize.width / workingWidth
        let scaleY = sourceSize.height / workingHeight

        let expanded = imageRect.insetBy(
            dx: -imageRect.width * paddingFraction,
            dy: -imageRect.height * paddingFraction
        )

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up (reverse of FaceDetector.convertToImageSpace).
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isEmpty else { return nil }

        var cropped = source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return SharedCoreImageContext.srgb.createCGImage(cropped, from: cropped.extent)
    }

    /// Zero-copy slices the `paddingFraction` glare crop (`0.15`) from an already-rendered Phase-2 `nativeCrop`,
    /// mapping `faceBoundingBox`'s padded working-frame rect (top-left/y-down) into `nativeCrop`'s pixel bounds.
    /// Returns `nil` if the mapped rect is invalid or `CGImage.cropping(to:)` fails, allowing fallback to `renderCrop`.
    static func sliceGlareCrop(
        from nativeCrop: CGImage,
        nativeCropWorkingRect: CGRect,
        faceBoundingBox: CGRect,
        workingSize: CGSize,
        paddingFraction: CGFloat = 0.15
    ) -> CGImage? {
        guard workingSize.width > 0, workingSize.height > 0,
            nativeCropWorkingRect.width > 0, nativeCropWorkingRect.height > 0,
            nativeCrop.width > 0, nativeCrop.height > 0,
            faceBoundingBox.width > 0, faceBoundingBox.height > 0
        else { return nil }

        let expanded = faceBoundingBox.insetBy(
            dx: -faceBoundingBox.width * paddingFraction,
            dy: -faceBoundingBox.height * paddingFraction
        )
        let workingBounds = CGRect(origin: .zero, size: workingSize)
        let glareWorkingRect = expanded.intersection(workingBounds)
        guard !glareWorkingRect.isNull, !glareWorkingRect.isEmpty,
            glareWorkingRect.width > 0, glareWorkingRect.height > 0
        else { return nil }

        let cropBounds = CGRect(x: 0, y: 0, width: nativeCrop.width, height: nativeCrop.height)
        let scaleX = cropBounds.width / nativeCropWorkingRect.width
        let scaleY = cropBounds.height / nativeCropWorkingRect.height
        let cropRect = CGRect(
            x: (glareWorkingRect.minX - nativeCropWorkingRect.minX) * scaleX,
            y: (glareWorkingRect.minY - nativeCropWorkingRect.minY) * scaleY,
            width: glareWorkingRect.width * scaleX,
            height: glareWorkingRect.height * scaleY
        ).intersection(cropBounds)
        guard !cropRect.isNull, !cropRect.isEmpty, cropRect.width >= 1, cropRect.height >= 1 else {
            return nil
        }

        return nativeCrop.cropping(to: cropRect)
    }
}

/// Lock-protected state shared between sample-buffer capture (`sessionQueue`) and main-actor drain,
/// supporting preview-only suppression (`publishesFrames == false`) and consumer backpressure (`isConsumerBusy`).
nonisolated struct PendingCameraFrameState {
    var pendingFrame: CameraFrame?
    var isDeliveryScheduled = false
    var publishesFrames: Bool
    var isCapturing: Bool
    var isConsumerBusy = false
    var captureGeneration: UInt64 = 0

    init(publishesFrames: Bool = true, isCapturing: Bool = false) {
        self.publishesFrames = publishesFrames
        self.isCapturing = isCapturing
    }

    var shouldRenderSample: Bool {
        publishesFrames && isCapturing && !isConsumerBusy
    }

    mutating func beginCapture() {
        isCapturing = true
        isConsumerBusy = false
        pendingFrame = nil
        isDeliveryScheduled = false
        captureGeneration &+= 1
    }

    mutating func endCapture() {
        isCapturing = false
        isConsumerBusy = false
        pendingFrame = nil
        isDeliveryScheduled = false
        captureGeneration &+= 1
    }

    mutating func discardPending() {
        pendingFrame = nil
        isDeliveryScheduled = false
    }

    mutating func enqueueIfActive(_ frame: CameraFrame, generation: UInt64) -> Bool {
        guard publishesFrames, isCapturing, captureGeneration == generation else {
            return false
        }
        pendingFrame = frame
        if isDeliveryScheduled {
            return false
        }
        isDeliveryScheduled = true
        return true
    }

    mutating func drainPending() -> CameraFrame? {
        let next = pendingFrame
        pendingFrame = nil
        isDeliveryScheduled = false
        return next
    }
}

/// Event-driven frame waiter backed by `CheckedContinuation` and a single unfair lock so frame arrival,
/// `stop()`, deadline expiry, and external `Task.cancel()` each resume every waiter exactly once and
/// never leak pre-`stop()` frames across restarts.
nonisolated final class CameraFrameWaiter: Sendable {
    private enum Resolution: @unchecked Sendable {
        case frame(CameraFrame)
        case cancelled
    }

    private struct WaiterEntry: @unchecked Sendable {
        let id: UInt64
        let epoch: UInt64
        let afterFrameID: UInt64?
        var continuation: CheckedContinuation<CameraFrame?, Never>?
        var resolution: Resolution?
        var timeoutTask: Task<Void, Never>?
    }

    private struct State: @unchecked Sendable {
        var isActive: Bool
        var epoch: UInt64 = 0
        var latestFrame: CameraFrame?
        var nextWaitID: UInt64 = 1
        var waiters: [UInt64: WaiterEntry] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    var currentEpoch: UInt64 {
        state.withLock { $0.epoch }
    }

    init(isActive: Bool = true) {
        self.state = OSAllocatedUnfairLock(initialState: State(isActive: isActive))
    }

    deinit {
        let pending = state.withLock { s -> [(CheckedContinuation<CameraFrame?, Never>, Task<Void, Never>?)] in
            var result: [(CheckedContinuation<CameraFrame?, Never>, Task<Void, Never>?)] = []
            for entry in s.waiters.values {
                entry.timeoutTask?.cancel()
                if let continuation = entry.continuation {
                    result.append((continuation, entry.timeoutTask))
                }
            }
            s.waiters.removeAll()
            return result
        }
        for (continuation, timeoutTask) in pending {
            timeoutTask?.cancel()
            continuation.resume(returning: nil)
        }
    }

    func start() {
        let pending = state.withLock { s -> [CheckedContinuation<CameraFrame?, Never>] in
            s.isActive = true
            s.latestFrame = nil
            s.epoch &+= 1
            return Self.drainAttachedWaiters(&s, resolution: .cancelled)
        }
        for continuation in pending {
            continuation.resume(returning: nil)
        }
    }

    func stop() {
        let pending = state.withLock { s -> [CheckedContinuation<CameraFrame?, Never>] in
            s.isActive = false
            s.latestFrame = nil
            s.epoch &+= 1
            return Self.drainAttachedWaiters(&s, resolution: .cancelled)
        }
        for continuation in pending {
            continuation.resume(returning: nil)
        }
    }

    func clearLatestFrame() {
        state.withLock { s in
            s.latestFrame = nil
        }
    }

    func deliver(_ frame: CameraFrame) {
        let toResume = state.withLock { s -> [CheckedContinuation<CameraFrame?, Never>] in
            guard s.isActive else { return [] }
            s.latestFrame = frame

            var resumed: [CheckedContinuation<CameraFrame?, Never>] = []
            let matchingIDs = s.waiters.compactMap { id, entry -> UInt64? in
                guard entry.epoch == s.epoch,
                    case nil = entry.resolution,
                    entry.afterFrameID.map({ frame.id != $0 }) ?? true
                else {
                    return nil
                }
                return id
            }
            for id in matchingIDs {
                guard var entry = s.waiters[id] else { continue }
                entry.timeoutTask?.cancel()
                if let continuation = entry.continuation {
                    s.waiters.removeValue(forKey: id)
                    resumed.append(continuation)
                } else {
                    entry.resolution = .frame(frame)
                    s.waiters[id] = entry
                }
            }
            return resumed
        }
        for continuation in toResume {
            continuation.resume(returning: frame)
        }
    }

    func nextFrame(
        after lastFrameID: UInt64?,
        until deadline: ContinuousClock.Instant,
        expectedEpoch: UInt64? = nil
    ) async -> CameraFrame? {
        let clock = ContinuousClock()
        enum Preflight {
            case immediate(CameraFrame?)
            case wait(id: UInt64, epoch: UInt64)
        }

        let preflight: Preflight = state.withLock { s in
            guard s.isActive, !Task.isCancelled else {
                return .immediate(nil)
            }
            if let expectedEpoch, s.epoch != expectedEpoch {
                return .immediate(nil)
            }
            if let latest = s.latestFrame,
                lastFrameID.map({ latest.id != $0 }) ?? true
            {
                return .immediate(latest)
            }
            guard clock.now < deadline else {
                return .immediate(nil)
            }
            let waitID = s.nextWaitID
            s.nextWaitID &+= 1
            s.waiters[waitID] = WaiterEntry(
                id: waitID,
                epoch: s.epoch,
                afterFrameID: lastFrameID
            )
            return .wait(id: waitID, epoch: s.epoch)
        }

        guard case .wait(let waitID, let epoch) = preflight else {
            if case .immediate(let frame) = preflight {
                return frame
            }
            return nil
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enum AttachOutcome {
                    case resumeImmediately(CameraFrame?)
                    case suspended
                }

                let outcome: AttachOutcome = state.withLock { s in
                    guard var entry = s.waiters[waitID] else {
                        return .resumeImmediately(nil)
                    }
                    if let resolution = entry.resolution {
                        entry.timeoutTask?.cancel()
                        s.waiters.removeValue(forKey: waitID)
                        switch resolution {
                        case .frame(let frame):
                            return .resumeImmediately(frame)
                        case .cancelled:
                            return .resumeImmediately(nil)
                        }
                    }
                    if Task.isCancelled || !s.isActive || entry.epoch != s.epoch {
                        entry.timeoutTask?.cancel()
                        s.waiters.removeValue(forKey: waitID)
                        return .resumeImmediately(nil)
                    }
                    entry.continuation = continuation
                    s.waiters[waitID] = entry
                    return .suspended
                }

                switch outcome {
                case .resumeImmediately(let frame):
                    continuation.resume(returning: frame)
                case .suspended:
                    let timeoutTask = Task.detached { [weak self] in
                        try? await Task.sleep(until: deadline, tolerance: .milliseconds(2), clock: .continuous)
                        guard !Task.isCancelled else { return }
                        self?.expireWaiter(id: waitID, epoch: epoch)
                    }
                    state.withLock { s in
                        if s.waiters[waitID] != nil {
                            s.waiters[waitID]?.timeoutTask = timeoutTask
                        } else {
                            timeoutTask.cancel()
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(id: waitID)
        }
    }

    private func cancelWaiter(id waitID: UInt64) {
        resolveWaiterWithNil(id: waitID, expectedEpoch: nil)
    }

    private func expireWaiter(id waitID: UInt64, epoch: UInt64) {
        resolveWaiterWithNil(id: waitID, expectedEpoch: epoch)
    }

    private func resolveWaiterWithNil(id waitID: UInt64, expectedEpoch: UInt64?) {
        let continuation: CheckedContinuation<CameraFrame?, Never>? = state.withLock { s in
            guard var entry = s.waiters[waitID], case nil = entry.resolution else {
                return nil
            }
            if let expectedEpoch, entry.epoch != expectedEpoch {
                return nil
            }
            entry.timeoutTask?.cancel()
            if let cont = entry.continuation {
                s.waiters.removeValue(forKey: waitID)
                return cont
            } else {
                entry.resolution = .cancelled
                s.waiters[waitID] = entry
                return nil
            }
        }
        continuation?.resume(returning: nil)
    }

    private static func drainAttachedWaiters(
        _ s: inout State,
        resolution: Resolution
    ) -> [CheckedContinuation<CameraFrame?, Never>] {
        var resumed: [CheckedContinuation<CameraFrame?, Never>] = []
        for id in Array(s.waiters.keys) {
            guard var entry = s.waiters[id] else { continue }
            entry.timeoutTask?.cancel()
            if let continuation = entry.continuation {
                s.waiters.removeValue(forKey: id)
                resumed.append(continuation)
            } else if case nil = entry.resolution {
                entry.resolution = resolution
                s.waiters[id] = entry
            }
        }
        return resumed
    }
}
