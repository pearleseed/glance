//
//  OnboardingController+Enrollment.swift
//  glance
//
//  Camera selection and guided circular face-enrollment frame processing
//  for `OnboardingController`.
//

import AVFoundation
import AppKit
import Foundation
import Observation
import SwiftUI

extension OnboardingController {
    // MARK: - Enrollment computed views

    /// Returns `.center` during initial neutral calibration and `nil` during the free circular
    /// sweep so `EnrollmentSweepWindowController` does not play conflicting single-direction cues.
    var currentPose: EnrollmentPose? {
        isCenterCaptured ? nil : .center
    }

    /// Copy shown under the camera: unavailable warning, calibration guidance, continuous
    /// circular prompt, distance/turn warnings, or the completion line.
    var enrollmentInstruction: String {
        if let enrollmentUnavailableMessage { return enrollmentUnavailableMessage }
        if enrollmentComplete { return "Face captured" }
        if let excessiveTurn { return excessiveTurn.instruction }
        if isTooFar { return "Bring your face closer" }
        if !isCenterCaptured { return EnrollmentPose.center.instruction }
        return "Move your head slowly to complete the circle"
    }

    /// Live head direction relative to calibrated neutral, or `nil` before calibration / outside valid tracking.
    var headTurn: HeadTurn? {
        guard step == .enroll, !enrollmentComplete, faceDetected, !isTooFar,
            excessiveTurn == nil, isCenterCaptured
        else { return nil }
        return poseEvaluator.headTurn()
    }

    var overallEnrollmentProgress: Double {
        let total = Double(EnrollmentPose.allCases.count * samplesPerPose)
        return min(Double(collectedSamples.count) / total, 1.0)
    }

    // MARK: - Camera selection

    func refreshCameraDevices() {
        cameraDevices = CameraDeviceCatalog.usableDevices()
    }

    /// Text shown inside the pill: the explicitly chosen device's name, or the resolved
    /// system default's name suffixed "(Default)" when nothing's been picked yet.
    var cameraSelectionLabel: String {
        if let id = GlanceSettings.shared.defaultCameraID,
            let device = cameraDevices.first(where: { $0.id == id })
        {
            return device.name
        }
        guard let name = CameraDeviceCatalog.resolvedDefaultDevice()?.localizedName else {
            return "System default"
        }
        return "\(name) (Default)"
    }

    func selectCamera(id: String?) {
        GlanceSettings.shared.defaultCameraID = id
        applyDisplayPinForCameraSelection()
    }

    func applyDisplayPinForCameraSelection() {
        guard NSScreen.screens.count > 1 else { return }
        let selectedDevice = CameraDeviceCatalog.resolvedDevice(preferredID: GlanceSettings.shared.defaultCameraID)
        let isBuiltIn = selectedDevice?.deviceType == .builtInWideAngleCamera
        if isBuiltIn {
            guard let builtInScreen = NSScreen.screens.first(where: { $0.isBuiltIn }) else { return }
            GlanceSettings.shared.preferredDisplayID = builtInScreen.stableDisplayID
            GlanceSettings.shared.preferredDisplayName = builtInScreen.localizedName
        } else {
            GlanceSettings.shared.preferredDisplayID = nil
            GlanceSettings.shared.preferredDisplayName = nil
        }
    }

    // MARK: - Guided enrollment lifecycle

    /// Note `pendingName` deliberately survives — no reason to make the user retype it.
    func resetEnrollmentState() {
        bumpEnrollGeneration()
        collectedSamples = []
        nameError = nil
        poseEvaluator = EnrollmentPoseEvaluator()
        isCenterCaptured = false
        remainingDirectionalPoses = Set(EnrollmentPose.directionalPoses)
        capturedCounts = [:]
        capturedPoses = []
        faceDetected = false
        currentYaw = nil
        currentPitch = nil
        clearMatchProgress()
        isTooFar = false
        excessiveTurn = nil
        enrollmentComplete = false
        enrollmentUnavailableMessage = nil
        guideVisible = false
        cameraPreviewVisible = true
        showCheckmark = false
        passwordError = nil
    }

    func beginEnrollment() async {
        guard step == .enroll, shouldObserveFrames else { return }
        let generation = bumpEnrollGeneration()
        enrollmentUnavailableMessage = nil
        guideVisible = true
        cameraPreviewVisible = true
        showCheckmark = false
        clearMatchProgress()
        excessiveTurn = nil
        sweepWindow.present(for: self)

        if let pipeline, pipeline.loadState != .loading, !pipeline.isUnlockCapable {
            sweepWindow.dismiss()
            enrollmentUnavailableMessage = Self.enrollmentUnavailableReason
            return
        }

        async let cameraStart: Void = camera.start()
        await pipeline?.waitUntilReady()
        _ = await cameraStart

        guard step == .enroll, shouldObserveFrames, generation == enrollGeneration else { return }
        guard let pipeline, pipeline.isUnlockCapable else {
            stopCameraIfCreated()
            sweepWindow.dismiss()
            enrollmentUnavailableMessage = Self.enrollmentUnavailableReason
            return
        }

        poseStartedAt = .now
        captureReadyAt = .now + initialCaptureDelay
        observeFramesIfNeeded()
    }

    private func observeFramesIfNeeded() {
        guard markFrameObservationStartedIfNeeded() else { return }
        observeFrames()
    }

    func observeFrames() {
        guard shouldObserveFrames else {
            resetFrameObservationFlag()
            return
        }
        withObservationTracking {
            _ = camera.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.shouldObserveFrames else { return }
                self.observeFrames()
                await self.processEnrollFrame()
            }
        }
    }

    // MARK: - Frame processing

    private func processEnrollFrame() async {
        guard step == .enroll, !enrollmentComplete, !isProcessingFrame,
            let pipeline = self.pipeline,
            pipeline.isUnlockCapable,
            let cameraFrame = camera.currentFrame
        else { return }
        let generation = enrollGeneration
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let minimumWidth = enrollmentMinimumFaceWidth
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let faces = try FaceDetector.detectFaces(in: cameraFrame.image, includeQuality: false)
                guard let face = FaceRecognitionPipeline.largestFace(in: faces) else {
                    return EnrollFrameOutcome.noFace
                }
                if Float(face.normalizedBoundingBox.width) < minimumWidth {
                    return EnrollFrameOutcome.tooFar
                }
                return EnrollFrameOutcome.ready(try pipeline.recognize(face, in: cameraFrame, includeQuality: true))
            } catch {
                return EnrollFrameOutcome.noFace
            }
        }.value

        guard step == .enroll, !enrollmentComplete, generation == enrollGeneration, pipeline.isUnlockCapable else {
            return
        }
        await applyEnrollFrameOutcome(outcome)
    }

    private func applyEnrollFrameOutcome(_ outcome: EnrollFrameOutcome) async {
        switch outcome {
        case .noFace:
            clearLivePoseState(faceDetected: false, isTooFar: false)
        case .tooFar:
            clearLivePoseState(faceDetected: true, isTooFar: true)
        case .ready(let result):
            guard let yaw = result.face.yaw, let pitch = result.face.pitch else {
                clearLivePoseState(faceDetected: true, isTooFar: false)
                return
            }
            faceDetected = true
            currentYaw = yaw
            currentPitch = pitch
            isTooFar = false
            poseEvaluator = poseEvaluator.observing(rawYaw: yaw, rawPitch: pitch)
            let phasePose: EnrollmentPose? = isCenterCaptured ? nil : .center
            excessiveTurn = poseEvaluator.excessiveTurn(for: phasePose, remaining: remainingDirectionalPoses)
            guard excessiveTurn == nil else {
                clearMatchProgress()
                return
            }
            await processMatchedEnrollFrame(result, rawYaw: yaw, rawPitch: pitch)
        }
    }

    private func clearLivePoseState(faceDetected: Bool, isTooFar: Bool) {
        self.faceDetected = faceDetected
        currentYaw = nil
        currentPitch = nil
        poseEvaluator = poseEvaluator.clearedFrame()
        clearMatchProgress()
        self.isTooFar = isTooFar
        excessiveTurn = nil
    }

    private func processMatchedEnrollFrame(
        _ result: FaceRecognitionResult,
        rawYaw: Float,
        rawPitch: Float
    ) async {
        // Detection above still ran; only capture is held back until settled.
        guard ContinuousClock.now >= captureReadyAt else {
            clearMatchProgress()
            return
        }

        let qualityOK = result.quality.map { $0 >= qualityFloor } ?? true
        let alignmentOK = result.alignmentTier == .fivePoint
        guard qualityOK, alignmentOK, !isTooFar else {
            clearMatchProgress()
            return
        }

        let stalled = ContinuousClock.now - poseStartedAt > stallTimeout
        if !isCenterCaptured {
            processCenterCalibrationFrame(result, rawYaw: rawYaw, rawPitch: rawPitch, stalled: stalled)
        } else {
            await processDirectionalSweepFrame(result, stalled: stalled)
        }
    }

    private func processCenterCalibrationFrame(
        _ result: FaceRecognitionResult,
        rawYaw: Float,
        rawPitch: Float,
        stalled: Bool
    ) {
        guard poseEvaluator.matchesCenter(stalled: stalled) else {
            clearMatchProgress()
            return
        }

        let holdStartedAt = poseHoldStartedAt ?? .now
        poseHoldStartedAt = holdStartedAt
        guard ContinuousClock.now - holdStartedAt >= poseHoldDuration else { return }

        poseEvaluator = poseEvaluator.recordingCenterSample(yaw: rawYaw, pitch: rawPitch)
        matchStreak += 1
        guard matchStreak >= requiredMatchStreak else { return }
        matchStreak = 0

        recordCapturedSample(result, pose: .center)
        if capturedCounts[.center, default: 0] >= samplesPerPose {
            poseEvaluator = poseEvaluator.finalizingCenterCalibration()
            isCenterCaptured = true
            centerPulseTick += 1
            performAlignmentHaptic()
            poseStartedAt = .now
            clearMatchProgress()
        }
    }

    private func processDirectionalSweepFrame(
        _ result: FaceRecognitionResult,
        stalled: Bool
    ) async {
        guard
            let matchedPose = poseEvaluator.matchingDirection(
                remaining: remainingDirectionalPoses,
                stalled: stalled
            )
        else {
            clearMatchProgress()
            return
        }

        if activeCandidatePose != matchedPose {
            activeCandidatePose = matchedPose
            poseHoldStartedAt = .now
            matchStreak = 1
            return
        }

        let holdStartedAt = poseHoldStartedAt ?? .now
        poseHoldStartedAt = holdStartedAt
        guard ContinuousClock.now - holdStartedAt >= circularHoldDuration else { return }

        matchStreak += 1
        guard matchStreak >= circularRequiredMatchStreak else { return }
        matchStreak = 0

        recordCapturedSample(result, pose: matchedPose)
        if capturedCounts[matchedPose, default: 0] >= samplesPerPose {
            capturedPoses.insert(matchedPose)
            remainingDirectionalPoses.remove(matchedPose)
            performAlignmentHaptic()
            poseStartedAt = .now
            clearMatchProgress()
            if remainingDirectionalPoses.isEmpty {
                await finishEnrollment()
            }
        }
    }

    private func recordCapturedSample(_ result: FaceRecognitionResult, pose: EnrollmentPose) {
        collectedSamples.append(
            CollectedSample(
                embedding: result.embedding,
                pose: pose,
                quality: result.quality,
                capturedAt: Date()
            ))
        capturedCounts[pose, default: 0] += 1
    }

    func clearMatchProgress() {
        matchStreak = 0
        poseHoldStartedAt = nil
        activeCandidatePose = nil
    }

    private func performAlignmentHaptic() {
        guard GlanceSettings.shared.hapticFeedbackEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Runs the camera-complete sequence (instructions fade, preview fades, checkmark
    /// draws) then auto-advances to naming. Samples stay in memory here.
    private func finishEnrollment() async {
        enrollmentComplete = true
        sweepWindow.dismiss()
        try? await Task.sleep(for: .seconds(OnboardingMetrics.guideOverlayFadeOut))

        cameraPreviewVisible = false
        try? await Task.sleep(for: .seconds(OnboardingMetrics.previewFadeOut))

        try? await Task.sleep(for: .seconds(OnboardingMetrics.checkmarkDelay))
        showCheckmark = true

        let elapsed =
            OnboardingMetrics.guideOverlayFadeOut
            + OnboardingMetrics.previewFadeOut
            + OnboardingMetrics.checkmarkDelay
        let remaining = max(OnboardingMetrics.cameraCompleteToNameDelay - elapsed, 0)
        try? await Task.sleep(for: .seconds(remaining))

        stopCameraIfCreated()
        navDirection = .forward
        withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
    }
}
