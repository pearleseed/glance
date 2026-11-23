//
//  FaceUnlockCoordinator+Scanning.swift
//  glance
//
//  Camera prewarm, scan-window frame evaluation, Night Boost activation,
//  and outcome / auto-retry handling for `FaceUnlockCoordinator`.
//

import Foundation

extension FaceUnlockCoordinator {
    enum ScanOutcome {
        case matched
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match.
        case spoofSuspected
        case noResolution
    }

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

        guard await prepareCamera(for: generation) else { return }

        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(
            deadline: Date().addingTimeInterval(scanWindowDuration),
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

        if let error = camera.errorMessage {
            statusMessage = error
            camera.stop()
            sceneIlluminator.end()
            return false
        }
        return true
    }

    private func handleScanOutcome(_ outcome: ScanOutcome, showsUI: Bool) {
        switch outcome {
        case .matched:
            // The unlock already happened inside observeScanWindow — this only decides whether anything is shown about it.
            if showsUI {
                NotchOverlayController.shared.finish(success: true)
            }
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

    private func finishFailedScan(baseMessage: String, showsUI: Bool, notifyOverlayFailure: Bool) {
        guard showsUI else {
            statusMessage = "\(baseMessage)."
            scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            return
        }
        if notifyOverlayFailure {
            NotchOverlayController.shared.finish(success: false)
            scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
        } else {
            // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
            scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
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
            guard LockMonitor.isScreenActuallyLocked(),
                self.isEnabled,
                self.isOnboardingGateSatisfied,
                GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current())
            else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    /// Recognition runs first per frame so confirm-liveness only accumulates for a matched identity and resets whenever
    /// the face disappears, fails to match, or switches identities (while unmatched faces still feed deny-only liveness cues).
    private func observeScanWindow(deadline: Date, requireOverlayScanning: Bool) async -> ScanOutcome {
        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        let nightBoostEnabled = GlanceSettings.shared.nightBoostEnabled
        let evaluator = FaceAuthEvaluator(
            pipeline: pipeline,
            livenessEnabled: livenessEnabled,
            livenessModeProvider: { GlanceSettings.shared.livenessMode },
            wrongFaceGraceDuration: wrongFaceGraceDuration
        )
        var lastProcessedFrameID: UInt64?

        while Date() < deadline, !Task.isCancelled,
            !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning
        {
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(for: framePollInterval)
                continue
            }
            lastProcessedFrameID = frame.id

            let extracted = await FaceAuthEvaluator.extractFrame(
                from: frame,
                pipeline: pipeline,
                previousBoundingBox: evaluator.lastFaceBoundingBox,
                nightBoostEnabled: nightBoostEnabled
            )

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
                statusMessage = "Recognized — unlocking…"
                let livenessNote =
                    livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                lastOutcome =
                    "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
                await pocController.injectStoredPassword(requireAuthoritativeLock: true)
                return .matched
            }
        }
        return .noResolution
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
