//
//  OnboardingController.swift
//  glance
//
//  Core state, entry points, and panel metrics for the notch-hosted guided onboarding flow.
//  Flow transitions/permissions/credentials live in `OnboardingController+Flow.swift`;
//  camera selection and guided enrollment live in `OnboardingController+Enrollment.swift`.
//

import AVFoundation
import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class OnboardingController {
    typealias HeadTurn = EnrollmentHeadTurn
    typealias ExcessiveTurn = EnrollmentExcessiveTurn

    /// Who this run is enrolling. Recapture is keyed by `id` rather than name so the
    /// naming step can rename an identity without orphaning it under its old name.
    enum EnrollmentTarget: Equatable {
        case newIdentity
        case replacing(UUID)

        var identityID: UUID? {
            if case .replacing(let id) = self { return id }
            return nil
        }
    }

    enum NavDirection {
        case forward
        case backward
    }

    struct CollectedSample {
        let embedding: [Float]
        let pose: EnrollmentPose
        /// Carried through so an enrolled identity can report how good its samples were.
        let quality: Float?
        /// Stamped at capture, not at save — samples sit in memory across the naming
        /// (and, on first run, password) step, so a save-time stamp would be wrong.
        let capturedAt: Date
    }

    enum EnrollFrameOutcome: Sendable {
        case noFace
        case tooFar
        case ready(FaceRecognitionResult)
    }

    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()
    let store = FaceEnrollmentStore.shared
    let sweepWindow = EnrollmentSweepWindowController()

    /// Persists the resume point for a true first-run flow on every step change, so
    /// `AppDelegate` can drop a relaunched, mid-onboarding user back where they left off.
    /// Settings-triggered flows never touch this.
    var step: OnboardingStep = .intro {
        didSet {
            guard isFirstRunFlow else { return }
            if step == .complete {
                GlanceSettings.shared.hasCompletedOnboarding = true
                // Normal onboarding now passes through `.securityNotice` on its own —
                // completing it here means the standalone post-update notice never needs to.
                GlanceSettings.shared.hasAcknowledgedSecurityNotice = true
                GlanceSettings.shared.onboardingResumeStep = nil
            } else {
                GlanceSettings.shared.onboardingResumeStep = step.resumeTarget
            }
        }
    }

    /// Fires exactly once, after the "You're all set" screen dismisses — either the true
    /// first-run flow (so `AppDelegate` can open Settings only once onboarding UI is gone)
    /// or the standalone post-update notice (so it can resume startup). `nil` otherwise.
    var onFirstRunComplete: (() -> Void)?

    /// True when started by `startEnrollmentOnly()` — shows only the guided pose-capture
    /// step and saves samples directly instead of continuing to the password step.
    let isEnrollmentOnly: Bool
    /// True when started by `startPasswordOnly()` — jumps straight to `.password` and
    /// treats Back as "cancel" rather than a setup flow that isn't running.
    let isPasswordOnly: Bool
    /// True when started by `startPostUpdateNotice()` — a standalone replay of just the
    /// security-notice step for users who completed onboarding before it existed.
    let isPostUpdateNotice: Bool
    let enrollmentTarget: EnrollmentTarget

    /// True only for the genuine first-run flow (also true when replayed via Face Lab's
    /// "Start Onboarding" debug button). Gates whether `step`'s `didSet` persists a resume point.
    var isFirstRunFlow: Bool { !isEnrollmentOnly && !isPasswordOnly && !isPostUpdateNotice }

    /// Whether the intro's one-time light sweep already played this session.
    private var hasPlayedIntroSweep = false

    /// Which way the step just changed — read by OnboardingNotchView to
    /// pick the scroll direction for the blur transition.
    var navDirection: NavDirection = .forward

    // MARK: - Permissions state

    var accessibilityGranted = false
    var cameraPermission: CameraPermissionState = .notDetermined
    var bothPermissionsGranted: Bool { accessibilityGranted && cameraPermission == .granted }
    var permissionsPollTask: Task<Void, Never>?
    var hasPromptedAccessibility = false

    // MARK: - Camera selection state

    /// Devices offered by the picker — refreshed when the step appears, since a camera
    /// can be plugged in after the app launched.
    var cameraDevices: [CameraDevice] = []

    // MARK: - Enrollment state

    /// 9 poses x 2 samples = 18 total, enough for a stable template without overlong holds.
    let samplesPerPose = 2
    /// Consecutive matching frames required before a `.center` calibration capture fires.
    let requiredMatchStreak = 3
    /// Wait this long after `.center` matches before samples count, so the user has settled.
    let poseHoldDuration: Duration = .milliseconds(500)
    /// Debounces single noisy frames during the continuous circular sweep while letting the user rotate smoothly.
    let circularRequiredMatchStreak = 2
    let circularHoldDuration: Duration = .milliseconds(80)
    /// Permissive floor for Vision's capture-quality score.
    let qualityFloor: Float = 0.2
    /// Hold off accepting captures this long once the camera comes up, so the first
    /// samples aren't taken mid-blink. Detection still runs during this window.
    let initialCaptureDelay: Duration = .seconds(1.5)
    /// Seated wide-angle webcams place a natural user around ~14% of frame width.
    let enrollmentMinimumFaceWidth: Float = 0.14
    /// If center or circular capture stalls longer than this, matching tolerances widen.
    let stallTimeout: Duration = .seconds(12)

    var poseEvaluator = EnrollmentPoseEvaluator()
    var isCenterCaptured = false
    var remainingDirectionalPoses: Set<EnrollmentPose> = Set(EnrollmentPose.directionalPoses)
    var capturedCounts: [EnrollmentPose: Int] = [:]
    var activeCandidatePose: EnrollmentPose?

    var faceDetected = false
    var currentYaw: Float?
    var currentPitch: Float?
    var isTooFar = false
    var excessiveTurn: ExcessiveTurn?
    var enrollmentComplete = false
    var capturedPoses: Set<EnrollmentPose> = []
    var centerPulseTick = 0
    var guideVisible = false
    var cameraPreviewVisible = true
    var showCheckmark = false

    var collectedSamples: [CollectedSample] = []
    var matchStreak = 0
    var isProcessingFrame = false
    var poseStartedAt: ContinuousClock.Instant = .now
    var captureReadyAt: ContinuousClock.Instant = .now
    var poseHoldStartedAt: ContinuousClock.Instant?

    // MARK: - Naming & Password state

    /// Bound directly by `NameStepView`; pre-filled by whichever entry point started the flow.
    var pendingName: String = ""
    var nameError: String?
    var nameStepPrimaryTitle: String { isEnrollmentOnly ? "Save" : "Continue" }

    var passwordError: String?
    var isSavingPassword = false

    /// Only a pre-fill for the first-run flow's naming step.
    static let defaultName: String = {
        let name = NSFullUserName()
        return name.isEmpty ? "Owner" : name
    }()

    // MARK: - Panel sizing (read by NotchOverlayView)

    private var currentPanelStyle: NotchPanelStyle {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen)?.style ?? .notch
    }

    var panelSize: CGSize { OnboardingMetrics.panelSize(for: step, style: currentPanelStyle) }
    var panelBottomRadius: CGFloat { OnboardingMetrics.panelBottomRadius(for: step) }

    init(
        isEnrollmentOnly: Bool = false,
        isPasswordOnly: Bool = false,
        isPostUpdateNotice: Bool = false,
        enrollmentTarget: EnrollmentTarget = .newIdentity
    ) {
        self.isEnrollmentOnly = isEnrollmentOnly
        self.isPasswordOnly = isPasswordOnly
        self.isPostUpdateNotice = isPostUpdateNotice
        self.enrollmentTarget = enrollmentTarget
        observeFrames()
        if isEnrollmentOnly {
            step = .enroll
            // Deferred a tick for the same reason `advance()` defers it.
            Task { @MainActor [weak self] in self?.beginEnrollment() }
        } else if isPasswordOnly {
            step = .password
        } else if isPostUpdateNotice {
            step = .securityNotice
        }
    }

    /// Plays the intro screen's one-time top-to-bottom light sweep full-screen via the
    /// same `sweepWindow` guided enrollment uses. No-op after the first call this session.
    func playIntroSweepIfNeeded() {
        guard !hasPlayedIntroSweep else { return }
        hasPlayedIntroSweep = true
        sweepWindow.presentOnce(direction: .down)
    }

    /// Tears down everything onboarding spun up: camera, sweep overlay,
    /// and permissions polling. Idempotent.
    func teardown() {
        stopPermissionsPolling()
        camera.stop()
        sweepWindow.dismiss()
    }

    // MARK: - Entry points

    static func startFlow(resumingAt step: OnboardingStep? = nil, onFirstRunComplete: (() -> Void)? = nil) {
        let controller = OnboardingController()
        controller.pendingName = defaultName
        controller.onFirstRunComplete = onFirstRunComplete
        if let step, step != .intro {
            controller.step = step
            if step == .permissions {
                controller.startPermissionsPolling()
            }
        }
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    static func startEnrollmentOnly() {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to re-enroll your face") else { return }
            let store = FaceEnrollmentStore.shared
            store.reloadIfUnlocked()
            let existing = store.identities.first
            present(
                target: existing.map { .replacing($0.id) } ?? .newIdentity,
                prefillName: existing?.name ?? defaultName
            )
        }
    }

    static func startAddIdentity() {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to enroll another face") else { return }
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            present(target: .newIdentity, prefillName: "")
        }
    }

    static func startRecapture(of identity: FaceIdentity) {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to re-enroll this face") else { return }
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            present(target: .replacing(identity.id), prefillName: identity.name)
        }
    }

    static func startPasswordOnly() {
        Task { @MainActor in
            let controller = OnboardingController(isPasswordOnly: true)
            NotchOverlayController.shared.presentOnboarding(controller)
        }
    }

    static func startPostUpdateNotice(onComplete: (() -> Void)? = nil) {
        let controller = OnboardingController(isPostUpdateNotice: true)
        controller.onFirstRunComplete = onComplete
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    private static func unlockForEnrollment(reason: String) async -> Bool {
        guard !SecureCredentialManager.isSessionUnlocked else { return true }
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: reason)
            }.value
            return true
        } catch {
            return false
        }
    }

    private static func present(target: EnrollmentTarget, prefillName: String) {
        let controller = OnboardingController(isEnrollmentOnly: true, enrollmentTarget: target)
        controller.pendingName = prefillName
        NotchOverlayController.shared.presentOnboarding(controller)
    }
}
