//
//  FaceUnlockCoordinator+Scanning.swift
//  glance
//
//  Camera prewarm, scan-window frame evaluation, Night Boost activation,
//  and outcome / auto-retry handling for `FaceUnlockCoordinator`.
//

import Foundation
import OSLog

extension FaceUnlockCoordinator {
    enum ScanOutcome {
        case matchedAndUnlocked
        case injectionFailed(String)
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match.
        case spoofSuspected
        case noResolution
    }

    private var postDisplayWakeClearGuard: Duration { .milliseconds(150) }
    private var postInjectionVerifyTimeout: Duration { .milliseconds(1_000) }
    private var postInjectionVerifyPollInterval: Duration { .milliseconds(25) }

    /// `generation` is what makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its global side effects (`camera.stop()` etc.) could otherwise land on the newer cycle instead
    /// of itself.
    func runScanCycle(generation: Int) async {
        guard canArmOrScan else {
            stopPrewarmedCamera()
            sceneIlluminator.end()
            return
        }

        if pipeline.loadState == .loading {
            await pipeline.waitUntilReady()
            // Bail without side effects if superseded or cancelled while awaiting model readiness.
            guard generation == scanGeneration, !Task.isCancelled else { return }
        }

        guard pipeline.isUnlockCapable else {
            statusMessage = "Face unlock unavailable — the discriminative face model could not be loaded."
            stopPrewarmedCamera()
            sceneIlluminator.end()
            NotchOverlayController.shared.disarm()
            return
        }

        guard canArmOrScan else {
            stopPrewarmedCamera()
            sceneIlluminator.end()
            return
        }

        let showsUI = self.showsUI
        // Wait for the prewarmed camera before expanding the scanning UI so the notch doesn't sit idle
        // while the sensor cold-starts; still surface a visible failure if camera startup fails.
        guard await prepareCamera(for: generation) else {
            guard generation == scanGeneration, !Task.isCancelled else { return }
            if showsUI {
                NotchOverlayController.shared.beginScanning()
                NotchOverlayController.shared.finish(success: false)
            }
            return
        }

        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(
            generation: generation,
            deadline: ContinuousClock.now + .seconds(scanWindowDuration),
            requireOverlayScanning: showsUI
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        guard generation == scanGeneration else { return }

        camera.stop()
        sceneIlluminator.end()
        handleScanOutcome(outcome, showsUI: showsUI)
    }

    private func prepareCamera(for generation: Int) async -> Bool {
        var ranPrewarm = false
        if let prewarm = cameraPrewarmTask {
            ranPrewarm = true
            await prewarm.value
            guard generation == scanGeneration else { return false }
            cameraPrewarmTask = nil
        }
        if !camera.isRunning && !(ranPrewarm && camera.errorMessage != nil) {
            await camera.start()
            guard generation == scanGeneration else { return false }
        }

        // A freshly woken camera can briefly report suspended/unavailable — retry once after a short beat.
        if camera.errorMessage != nil, !Task.isCancelled, LockMonitor.isScreenActuallyLocked() {
            let initialError = camera.errorMessage ?? "unknown"
            UnlockLog.logger.warning(
                "Camera start failed on first attempt (\(initialError, privacy: .public)) — retrying once"
            )
            camera.stop()
            try? await Task.sleep(for: .milliseconds(150))
            guard generation == scanGeneration, !Task.isCancelled, canArmOrScan else { return false }
            await camera.start()
            guard generation == scanGeneration else { return false }
        }

        if let error = camera.errorMessage {
            statusMessage = error
            UnlockLog.logger.error("Camera failed to start for lock-screen scan: \(error, privacy: .public)")
            camera.stop()
            sceneIlluminator.end()
            return false
        }
        return true
    }

    private func handleScanOutcome(_ outcome: ScanOutcome, showsUI: Bool) {
        switch outcome {
        case .matchedAndUnlocked:
            if showsUI && NotchOverlayController.shared.phase != .success {
                NotchOverlayController.shared.finish(success: true)
            }
        case .injectionFailed(let reason):
            finishFailedScan(
                baseMessage: reason,
                showsUI: showsUI,
                notifyOverlayFailure: true,
                allowAutoRetry: false
            )
        case .consistentlyWrongFace:
            finishFailedScan(
                baseMessage: "Face not recognized",
                showsUI: showsUI,
                notifyOverlayFailure: true
            )
        case .spoofSuspected:
            finishFailedScan(
                baseMessage: "Couldn't confirm a live face",
                showsUI: showsUI,
                notifyOverlayFailure: true
            )
        case .noResolution:
            finishFailedScan(
                baseMessage: "No face detected",
                showsUI: showsUI,
                notifyOverlayFailure: false
            )
        }
    }

    private func finishFailedScan(
        baseMessage: String,
        showsUI: Bool,
        notifyOverlayFailure: Bool,
        allowAutoRetry: Bool = true
    ) {
        guard showsUI else {
            statusMessage = "\(baseMessage)."
            if allowAutoRetry {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
            return
        }
        if notifyOverlayFailure {
            NotchOverlayController.shared.finish(success: false)
            if allowAutoRetry {
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            }
        } else {
            // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
            if allowAutoRetry {
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            }
        }
        statusMessage = "\(baseMessage) — hover the notch to try again."
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard GlanceSettings.shared.autoRetryOnce,
            !hasAutoRetriedForCurrentLock,
            isOnboardingGateSatisfied,
            GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current())
        else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password or retried manually while this waited.
            guard self.canArmOrScan else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    /// Recognition runs first per frame so confirm-liveness only accumulates for a matched identity and resets whenever
    /// the face disappears, fails to match, or switches identities (while unmatched faces still feed deny-only liveness cues).
    private func observeScanWindow(
        generation: Int,
        deadline: ContinuousClock.Instant,
        requireOverlayScanning: Bool
    ) async -> ScanOutcome {
        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        let nightBoostEnabled = GlanceSettings.shared.nightBoostEnabled
        let evaluator = FaceAuthEvaluator(
            pipeline: pipeline,
            livenessEnabled: livenessEnabled,
            livenessModeProvider: { GlanceSettings.shared.livenessMode },
            wrongFaceGraceDuration: wrongFaceGraceDuration
        )
        var lastProcessedFrameID: UInt64?

        guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

        // Clear any leftover backpressure flag if a superseded cycle exited mid-extraction without stopping the camera.
        camera.setConsumerBusy(false)

        while ContinuousClock.now < deadline,
            isScanWindowActive(generation: generation, requireOverlayScanning: requireOverlayScanning)
        {
            guard let frame = await camera.nextFrame(after: lastProcessedFrameID, until: deadline) else {
                break
            }
            lastProcessedFrameID = frame.id

            guard isScanWindowActive(generation: generation, requireOverlayScanning: requireOverlayScanning),
                LockMonitor.isScreenActuallyLocked()
            else {
                return .noResolution
            }

            let extracted = await extractFrameWithBackpressure(
                frame: frame,
                generation: generation,
                evaluator: evaluator,
                livenessEnabled: livenessEnabled,
                nightBoostEnabled: nightBoostEnabled
            )

            guard isScanWindowActive(generation: generation, requireOverlayScanning: requireOverlayScanning),
                LockMonitor.isScreenActuallyLocked()
            else {
                return .noResolution
            }

            activateNightBoostIfNeeded(
                luminance: extracted.luminance,
                nightBoostEnabled: nightBoostEnabled,
                requireOverlayScanning: requireOverlayScanning
            )

            // `activeIdentities`, not `identities`: someone switched off on the Your Face page stays enrolled but must not unlock.
            let step = evaluator.evaluate(
                extracted,
                activeIdentities: FaceEnrollmentStore.shared.activeIdentities,
                threshold: matchThreshold
            )
            switch step {
            case .pending:
                continue
            case .spoofDenied(let reason):
                lastOutcome = reason
                return .spoofSuspected
            case .wrongFaceTimedOut:
                return .consistentlyWrongFace
            case .matched(let readyMatch, let confirmingCue):
                return await completeMatchedUnlock(
                    generation: generation,
                    readyMatch: readyMatch,
                    confirmingCue: confirmingCue,
                    livenessEnabled: livenessEnabled
                )
            }
        }
        return .noResolution
    }

    private func isScanWindowActive(generation: Int, requireOverlayScanning: Bool) -> Bool {
        !Task.isCancelled
            && generation == scanGeneration
            && (!requireOverlayScanning || NotchOverlayController.shared.phase == .scanning)
    }

    private func extractFrameWithBackpressure(
        frame: CameraFrame,
        generation: Int,
        evaluator: FaceAuthEvaluator,
        livenessEnabled: Bool,
        nightBoostEnabled: Bool
    ) async -> ExtractedAuthFrame {
        camera.setConsumerBusy(true)
        defer {
            if generation == scanGeneration {
                camera.setConsumerBusy(false)
            }
        }
        let strictCloseRangeOnly = GlanceSettings.shared.strictCloseRangeOnly
        return await FaceAuthEvaluator.extractFrame(
            from: frame,
            pipeline: pipeline,
            previousBoundingBox: evaluator.lastFaceBoundingBox,
            strictCloseRangeOnly: strictCloseRangeOnly,
            livenessEnabled: livenessEnabled,
            nightBoostEnabled: nightBoostEnabled,
            geometryContext: evaluator.geometryContextIfNeeded()
        )
    }

    private func completeMatchedUnlock(
        generation: Int,
        readyMatch: ScoredIdentity,
        confirmingCue: LivenessCue?,
        livenessEnabled: Bool
    ) async -> ScanOutcome {
        // Release camera & Night Boost right away while injecting and verifying unlock.
        camera.stop()
        sceneIlluminator.end()

        statusMessage = "Recognized — unlocking…"
        let livenessNote =
            livenessEnabled
            ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
            : "liveness off"
        lastOutcome =
            "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
        UnlockLog.logger.info("Face matched (\(livenessNote, privacy: .public)) — injecting stored password")

        await waitPastRecentDisplayWakeClearIfNeeded()
        guard !Task.isCancelled, generation == scanGeneration else { return .noResolution }

        isAwaitingPostInjectionUnlock = true
        defer {
            if generation == scanGeneration {
                isAwaitingPostInjectionUnlock = false
            }
        }

        let showsUI = self.showsUI
        for attempt in 1...2 {
            let isRetry = attempt == 2
            if isRetry, showsUI {
                // Re-enter scanning briefly while the conservative retry runs so the overlay won't collapse early.
                NotchOverlayController.shared.beginScanning()
            }
            let result = await pocController.injectStoredPassword(
                requireAuthoritativeLock: true,
                singleGraphemeMode: isRetry
            )
            if case .failure(let failure) = result {
                if failure == .screenNotLocked {
                    return .matchedAndUnlocked
                }
                return .injectionFailed(failure.localizedDescription)
            }

            // Keystrokes were accepted with valid Accessibility + decrypted credentials — start the
            // completion animation right away so it runs in parallel with loginwindow's ~200ms auth
            // instead of waiting until after the desktop already appears. If the screen unexpectedly
            // remains locked, the retry/failure branch below overrides the overlay cleanly.
            if showsUI && NotchOverlayController.shared.phase != .success {
                NotchOverlayController.shared.finish(success: true)
            }

            if await waitForScreenToUnlock(generation: generation) {
                return .matchedAndUnlocked
            }
            guard !Task.isCancelled, generation == scanGeneration else { return .noResolution }

            if attempt == 1 {
                UnlockLog.logger.warning(
                    "Screen remained locked after fast password injection — retrying in single-grapheme mode"
                )
            }
        }

        UnlockLog.logger.error(
            "Screen remained locked after retry — stored password may be incorrect or lock screen rejected input"
        )
        return .injectionFailed("Couldn't unlock — verify your stored password in Password settings.")
    }

    /// Avoids racing `loginwindow`'s `Clearing password field for NSWorkspaceScreensDidWakeNotification`.
    private func waitPastRecentDisplayWakeClearIfNeeded() async {
        guard let wakeAt = lockMonitor.lastDisplayWakeAt else { return }
        let elapsed = ContinuousClock.now - wakeAt
        guard elapsed < postDisplayWakeClearGuard else { return }
        try? await Task.sleep(for: postDisplayWakeClearGuard - elapsed)
    }

    private func waitForScreenToUnlock(generation: Int) async -> Bool {
        let deadline = ContinuousClock.now + postInjectionVerifyTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled, generation == scanGeneration {
            if !LockMonitor.isScreenActuallyLocked() {
                return true
            }
            try? await Task.sleep(for: postInjectionVerifyPollInterval)
        }
        return !LockMonitor.isScreenActuallyLocked()
    }

    private func activateNightBoostIfNeeded(
        luminance: Double?,
        nightBoostEnabled: Bool,
        requireOverlayScanning: Bool
    ) {
        guard nightBoostEnabled,
            let luminance,
            luminance < SceneLuminance.darkThreshold,
            !Task.isCancelled,
            LockMonitor.isScreenActuallyLocked(),
            !lockMonitor.isSleeping,
            !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning
        else { return }
        sceneIlluminator.activateIfNeeded()
    }
}
