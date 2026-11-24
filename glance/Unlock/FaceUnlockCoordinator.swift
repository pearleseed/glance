//
//  FaceUnlockCoordinator.swift
//  glance
//
//  Connects face recognition to the actual unlock path. Off by default; user opts in after validating accuracy in Face Lab.
//
//  Known limitation: LivenessAnalyzer defeats a photo but not a replayed video (real non-rigid motion looks live) — a successful spoof types the real macOS password.
//

import AppKit
import CoreGraphics
import Foundation
import Observation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline: FaceRecognitionPipeline

    /// Persisted via GlanceSettings. Setting to false cancels any in-flight scan and disarms the overlay immediately.
    var isEnabled: Bool {
        didSet {
            GlanceSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled {
                disarmOverlay()
            } else {
                updateSpaceMonitor()
            }
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real unlock gate.
    var matchThreshold: Float {
        didSet { GlanceSettings.shared.matchThreshold = matchThreshold }
    }
    /// Shares its setting with NotchOverlayController's scanning timeout, so the background loop stops in step with the UI collapsing.
    var scanWindowDuration: TimeInterval {
        TimeInterval(GlanceSettings.shared.faceDetectionSeconds)
    }
    /// A wake often catches the owner while they are still looking away from
    /// the camera. Require a sustained non-match rather than a few early
    /// frames before giving the failure animation.
    let wrongFaceGraceDuration: Duration = .seconds(2)

    var statusMessage = "Idle"
    var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session — an auto-retry that could itself auto-retry would loop the camera for the whole lock session.
    var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    var scanGeneration = 0
    /// When the last scan cycle was armed — collapses a single wake into a single arm (see `.wake` branch of `evaluateTrigger`).
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms of each other; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    /// Held separately from `scanTask` since it's scheduled from inside the scan task it follows — reusing `scanTask` would self-cancel it.
    var autoRetryTask: Task<Void, Never>?
    /// Gap between headless auto-retries, just to keep the camera from restarting in a tight loop.
    let headlessRetryDelay: Duration = .seconds(1)
    /// Max wait for `CGSessionCopyCurrentDictionary()` to catch up with a lock/wake notification.
    private let lockStateSettleTimeout: Duration = .milliseconds(300)
    /// Polling cadence while waiting for lock state to settle.
    private let lockStatePollInterval: Duration = .milliseconds(25)
    /// Brief buffer past the login window's entrance before showing the notch overlay.
    private let armDelay: Duration = .milliseconds(250)

    private var wakeSettleTask: Task<Void, Never>?
    private var armTask: Task<Void, Never>?
    var cameraPrewarmTask: Task<Void, Never>?
    let sceneIlluminator = SceneIlluminator()
    private let observerBox = NotificationObserverBox()

    /// System-wide shortcut for toggling Face Unlock on/off.
    private let toggleHotKey = GlobalHotKey()
    /// Pauses global hotkey handling while `ShortcutRecorderPill` is capturing a new binding.
    var isRecordingToggleShortcut = false {
        didSet {
            guard isRecordingToggleShortcut != oldValue else { return }
            syncToggleHotKeyRegistration()
        }
    }
    /// True when Carbon refused the configured toggle shortcut (e.g. conflict with another app).
    private(set) var isToggleShortcutUnavailable = false

    /// When off, no notch/pill presence at all — every overlay call in this file is conditioned on this rather than just skipping the video.
    var showsUI: Bool { GlanceSettings.shared.showUnlockAnimation }

    /// Blocks lock-screen unlock and space-key monitoring until onboarding and the security notice are completed and the overlay isn't hosting onboarding.
    var isOnboardingGateSatisfied: Bool {
        let settings = GlanceSettings.shared
        return settings.hasCompletedOnboarding
            && settings.hasAcknowledgedSecurityNotice
            && NotchOverlayController.shared.phase != .onboarding
    }

    /// Refuses unlock whenever ArcFace failed to load and the weaker Vision fallback embedder is active.
    private var hasUnlockCapableEmbedder: Bool {
        pipeline.isUnlockCapable
    }

    /// Allows arming and space-key monitoring while ArcFace is still loading at startup;
    /// `runScanCycle` awaits readiness and verifies `hasUnlockCapableEmbedder` before scanning.
    private var canArmWithPipeline: Bool {
        pipeline.loadState == .loading || hasUnlockCapableEmbedder
    }

    /// Reads the space key on the lock screen for the "On space" trigger; only runs while locked + opted in.
    private let spaceKeyMonitor = SpaceKeyMonitor()

    init(pocController: POCController, pipeline: FaceRecognitionPipeline) {
        self.pocController = pocController
        self.pipeline = pipeline
        self.isEnabled = GlanceSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = GlanceSettings.shared.matchThreshold
        spaceKeyMonitor.onSpaceKeyDown = { [weak self] in self?.handleSpaceKeyPress() }
        toggleHotKey.onHotKey = { [weak self] in self?.toggleFromShortcut() }
        observeLockAndWakeEvents()
        observeDisplayContextSettings()
        observeScreenParameters()
        observeToggleShortcut()
        observePipelineLoadState()
        syncToggleHotKeyRegistration()
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeLockAndWakeEvents()
                self.scheduleLockStateEvaluation()
            }
        }
    }

    private func observeDisplayContextSettings() {
        withObservationTracking {
            let settings = GlanceSettings.shared
            _ = settings.isFaceUnlockEnabledBuiltInOnly
            _ = settings.isFaceUnlockEnabledBuiltInAndExternal
            _ = settings.isFaceUnlockEnabledExternalOnly
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDisplayContextSettings()
                self.handleDisplayContextOrPreferenceChange()
            }
        }
    }

    private func observeScreenParameters() {
        observerBox.observe(forName: NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDisplayContextOrPreferenceChange()
            }
        }
    }

    private func handleDisplayContextOrPreferenceChange() {
        if !GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current()) {
            disarmOverlay()
        } else {
            updateSpaceMonitor()
        }
    }

    private func observeToggleShortcut() {
        withObservationTracking {
            _ = GlanceSettings.shared.faceUnlockToggleShortcut
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeToggleShortcut()
                self.syncToggleHotKeyRegistration()
            }
        }
    }

    private func observePipelineLoadState() {
        withObservationTracking {
            _ = pipeline.loadState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePipelineLoadState()
                self.handlePipelineLoadStateChange()
            }
        }
    }

    private func handlePipelineLoadStateChange() {
        if case .fallback = pipeline.loadState {
            disarmOverlay()
        }
        updateSpaceMonitor()
    }

    private func syncToggleHotKeyRegistration() {
        guard !isRecordingToggleShortcut else {
            toggleHotKey.unregister()
            isToggleShortcutUnavailable = false
            return
        }
        guard let shortcut = GlanceSettings.shared.faceUnlockToggleShortcut else {
            toggleHotKey.unregister()
            isToggleShortcutUnavailable = false
            return
        }
        isToggleShortcutUnavailable = !toggleHotKey.register(shortcut)
    }

    func toggleFromShortcut() {
        guard !isRecordingToggleShortcut else { return }
        isEnabled.toggle()
        NSSound(named: isEnabled ? "Tink" : "Pop")?.play()
    }

    /// Polls `LockMonitor.isScreenActuallyLocked()` briefly after wake/lock events since CGSession
    /// can lag behind distributed/workspace notifications, exiting early as soon as lock state settles.
    /// `.screenUnlocked` and `.willSleep` evaluate immediately so unlock disarms without delay.
    private func scheduleLockStateEvaluation() {
        wakeSettleTask?.cancel()
        wakeSettleTask = nil

        let lastEvent = lockMonitor.lastEvent
        let shouldPollForLock =
            !lockMonitor.isSleeping
            && lastEvent != .screenUnlocked
            && lastEvent != .willSleep
            && (lastEvent == .wake || lastEvent == .screenLocked || lockMonitor.isScreenLocked)

        guard shouldPollForLock, !LockMonitor.isScreenActuallyLocked() else {
            evaluateTrigger()
            return
        }

        wakeSettleTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + self.lockStateSettleTimeout
            while !LockMonitor.isScreenActuallyLocked(),
                ContinuousClock.now < deadline,
                !Task.isCancelled
            {
                try? await Task.sleep(for: self.lockStatePollInterval)
            }
            guard !Task.isCancelled else { return }
            self.wakeSettleTask = nil
            self.evaluateTrigger()
        }
    }

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else {
            sceneIlluminator.end()
            return
        }
        guard GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current()) else {
            disarmOverlay()
            return
        }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard let signal = checkArmPrerequisites() else { return }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = GlanceSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else { return }

        scheduleArm(autoScan: shouldAutoScan)
    }

    private func checkArmPrerequisites() -> UnlockTrigger? {
        guard isEnabled, !hasArmedForCurrentLock, isOnboardingGateSatisfied else { return nil }
        guard canArmWithPipeline else {
            statusMessage = "Face unlock unavailable — the discriminative face model could not be loaded."
            return nil
        }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent),
            // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
            NotchGeometry.preferredScreen() != nil
        else { return nil }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage =
                "Face unlock is on, but the session is locked — authenticate once from Password settings first."
            return nil
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return nil
        }
        return signal
    }

    private func scheduleArm(autoScan: Bool) {
        hasArmedForCurrentLock = true
        lastArmedAt = .now

        armTask?.cancel()
        armTask = nil
        if cameraPrewarmTask != nil {
            stopPrewarmedCamera()
        }

        guard showsUI else {
            // Headless has no overlay entrance to wait for — arm and start scanning immediately.
            arm(autoScan: autoScan)
            return
        }

        if autoScan {
            // Start warming the camera while waiting out the login-window entrance buffer.
            cameraPrewarmTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.camera.start()
            }
        }
        armTask = Task { [weak self] in
            guard let self else { return }
            // arm() only shows a small closed notch silhouette, so this only needs a brief buffer past the login window's entrance.
            try? await Task.sleep(for: self.armDelay)
            guard !Task.isCancelled else { return }
            self.armTask = nil
            self.arm(autoScan: autoScan)
        }
    }

    /// Whether the last arm was recent enough to be part of the same wake burst rather than a new one.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that shouldn't arm anything — including a nil `lastEvent`, or the first observation would fire regardless of user selection.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func disarmOverlay() {
        wakeSettleTask?.cancel()
        wakeSettleTask = nil
        armTask?.cancel()
        armTask = nil
        cameraPrewarmTask?.cancel()
        cameraPrewarmTask = nil
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still suspended at `await camera.start()` inert, rather than resuming and re-showing the overlay.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        camera.stop()
        sceneIlluminator.end()
        NotchOverlayController.shared.disarm()
        // Covers isEnabled being switched off directly, keeping "disarmed" and "not listening for space" in lockstep.
        spaceKeyMonitor.stop()
    }

    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    private func updateSpaceMonitor() {
        let shouldListen =
            isEnabled
            && GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current())
            && isOnboardingGateSatisfied
            && canArmWithPipeline
            && GlanceSettings.shared.unlockTriggers.contains(.onSpace)
            && LockMonitor.isScreenActuallyLocked()
            && SpaceKeyMonitor.hasInputMonitoringAccess()
        if shouldListen {
            spaceKeyMonitor.start()
        } else {
            spaceKeyMonitor.stop()
        }
    }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    private func handleSpaceKeyPress() {
        guard isEnabled,
            GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current()),
            isOnboardingGateSatisfied,
            canArmWithPipeline,
            GlanceSettings.shared.unlockTriggers.contains(.onSpace),
            LockMonitor.isScreenActuallyLocked(),
            NotchGeometry.preferredScreen() != nil,
            SecureCredentialManager.isSessionUnlocked,
            SecureCredentialManager.hasStoredPassword()
        else { return }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            armTask?.cancel()
            armTask = nil
            arm(autoScan: true)
        }
    }

    /// Shared gate checked at arm, scan-cycle entry, and auto-retry wakeup.
    var canArmOrScan: Bool {
        LockMonitor.isScreenActuallyLocked()
            && isEnabled
            && isOnboardingGateSatisfied
            && canArmWithPipeline
            && GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current())
    }

    func stopPrewarmedCamera() {
        cameraPrewarmTask?.cancel()
        cameraPrewarmTask = nil
        camera.stop()
    }

    /// Either way the overlay still arms — a deselected trigger only skips the automatic scan, leaving hover-to-start available.
    private func arm(autoScan: Bool) {
        guard canArmOrScan else {
            stopPrewarmedCamera()
            return
        }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            startScanCycle()
            return
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
    }

    /// Called on arm, and again whenever the overlay hover-activates.
    func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }
}
