//
//  AppLockCoordinator.swift
//  glance
//
//  Wires workspace lifecycle events, monotonic uptime, AppLockEngine, per-window curtains,
//  shared-pipeline face scanning, and Touch ID / system password fallback together.
//

import AppKit
import Foundation
import LocalAuthentication
import Observation
import UniformTypeIdentifiers
import os

@Observable
@MainActor
final class AppLockCoordinator {
    private var engine = AppLockEngine()
    private let faceScanner: AppLockFaceScanner
    private let curtainController = AppLockCurtainController()
    private let observerBox = ObserverBox()
    private let reconcileTimerBox = AppLockRepeatingTimer()

    private var activeSystemPromptChallengeID: UUID?
    private var activeSystemPromptContext: LAContext?

    private static let reconcileInterval: TimeInterval = 2.0
    private static let log = Logger(subsystem: "com.jonathan.glance", category: "AppLockCoordinator")

    init(pipeline: FaceRecognitionPipeline) {
        self.faceScanner = AppLockFaceScanner(pipeline: pipeline)
        registerWorkspaceAndSystemObservers()
        observeSettings()
        syncEngineConfiguration()
    }

    private var isEffectivelyEnabled: Bool {
        let settings = GlanceSettings.shared
        return settings.hasCompletedOnboarding
            && settings.hasAcknowledgedSecurityNotice
            && settings.isAppLockEnabled
    }

    private func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Settings & Observation

    private func observeSettings() {
        withObservationTracking {
            let settings = GlanceSettings.shared
            _ = settings.isAppLockEnabled
            _ = settings.lockedApps
            _ = settings.defaultAppRelockPolicy
            _ = settings.hasCompletedOnboarding
            _ = settings.hasAcknowledgedSecurityNotice
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettings()
                self.syncEngineConfiguration()
            }
        }
    }

    private func syncEngineConfiguration() {
        let settings = GlanceSettings.shared
        let enabled = isEffectivelyEnabled
        let defaultPolicy = settings.defaultAppRelockPolicy

        var policies: [String: RelockPolicy] = [:]
        for entry in settings.lockedApps where LockedApp.canLock(bundleIdentifier: entry.bundleIdentifier) {
            policies[entry.bundleIdentifier] = entry.relockPolicyOverride ?? defaultPolicy
        }

        let effects = engine.configure(isEnabled: enabled, policies: policies)
        execute(effects)

        if enabled && !policies.isEmpty {
            startReconcileTimerIfNeeded()
            reconcileWorkspace()
        } else {
            reconcileTimerBox.invalidate()
        }
    }

    private func registerWorkspaceAndSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerBox.add(workspaceCenter, token: workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                self?.handleAppActivated(pid: pid)
            }
        })

        observerBox.add(workspaceCenter, token: workspaceCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let pid else { return }
                let effects = self.engine.appHidden(pid: pid, monotonicNow: self.monotonicNow())
                self.execute(effects)
            }
        })

        observerBox.add(workspaceCenter, token: workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let pid else { return }
                let effects = self.engine.appTerminated(pid: pid)
                self.execute(effects)
            }
        })

        observerBox.add(workspaceCenter, token: workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lockAllSessions()
            }
        })

        observerBox.add(workspaceCenter, token: workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileWorkspace()
            }
        })

        let distributedCenter = DistributedNotificationCenter.default()
        observerBox.add(distributedCenter, token: distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lockAllSessions()
            }
        })

        observerBox.add(distributedCenter, token: distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lockAllSessions()
            }
        })

        observerBox.add(distributedCenter, token: distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileWorkspace()
            }
        })

        observerBox.add(distributedCenter, token: distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileWorkspace()
            }
        })
    }

    // MARK: - Workspace Handling

    private func handleAppActivated(pid: pid_t?) {
        guard isEffectivelyEnabled else { return }
        guard !LockMonitor.isScreenActuallyLocked() else {
            lockAllSessions()
            return
        }

        let targetApp: NSRunningApplication?
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            targetApp = app
        } else {
            targetApp = NSWorkspace.shared.frontmostApplication
        }
        guard let targetApp, let engineApp = makeEngineApp(from: targetApp) else { return }

        let effects = engine.appActivated(engineApp, monotonicNow: monotonicNow())
        execute(effects)
    }

    private func reconcileWorkspace() {
        guard isEffectivelyEnabled else { return }
        guard !LockMonitor.isScreenActuallyLocked() else {
            lockAllSessions()
            return
        }

        let workspace = NSWorkspace.shared
        let frontmost = workspace.frontmostApplication.flatMap(makeEngineApp(from:))
        let running = workspace.runningApplications.compactMap(makeEngineApp(from:))

        let effects = engine.reconcile(
            frontmost: frontmost,
            running: running,
            monotonicNow: monotonicNow()
        )
        execute(effects)
    }

    func lockAllSessions() {
        let effects = engine.lockAll()
        execute(effects)
    }

    private func makeEngineApp(from runningApp: NSRunningApplication) -> AppLockEngine.App? {
        let pid = runningApp.processIdentifier
        guard pid > 0 else { return nil }
        return AppLockEngine.App(
            pid: pid,
            bundleID: runningApp.bundleIdentifier ?? "",
            isRegular: runningApp.activationPolicy == .regular
        )
    }

    private func startReconcileTimerIfNeeded() {
        guard !reconcileTimerBox.isRunning else { return }
        let timer = Timer(timeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileWorkspace()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimerBox.set(timer)
    }

    // MARK: - Effect Execution

    private func execute(_ effects: [AppLockEngine.Effect]) {
        // Cancel any lingering Touch ID modal if engine state cleared or replaced the active prompt.
        if let promptID = activeSystemPromptChallengeID,
           engine.activeChallenge?.id != promptID || engine.activeChallenge?.phase != .systemPrompt {
            activeSystemPromptContext?.invalidate()
            activeSystemPromptContext = nil
            activeSystemPromptChallengeID = nil
        }

        for effect in effects {
            switch effect {
            case .raiseCurtain(let challenge):
                presentCurtainAndStartScan(for: challenge)
            case .lowerCurtain(let challenge):
                faceScanner.stop(ifMatching: challenge.id)
                curtainController.dismiss(ifMatching: challenge.id)
            case .hide(let app):
                NSRunningApplication(processIdentifier: app.pid)?.hide()
            case .reopen(let app):
                if let runningApp = NSRunningApplication(processIdentifier: app.pid) {
                    runningApp.unhide()
                    runningApp.activate()
                }
            case .presentSystemPrompt(let challenge):
                presentSystemPrompt(for: challenge)
            }
        }
    }

    private func presentCurtainAndStartScan(for challenge: AppLockEngine.Challenge) {
        let metadata = resolveAppMetadata(for: challenge.app)

        curtainController.present(
            challengeID: challenge.id,
            targetPID: challenge.app.pid,
            appName: metadata.name,
            appIcon: metadata.icon,
            onRetry: { [weak self] in
                self?.retryFaceScan(for: challenge)
            },
            onUseSystemAuth: { [weak self] in
                self?.requestSystemPrompt(challengeID: challenge.id)
            },
            onMissionControlDetected: { [weak self] in
                guard let self else { return }
                Self.log.info("Mission Control detected during active App Lock curtain — hiding challenged app.")
                let effects = self.engine.cancel(challengeID: challenge.id)
                self.execute(effects)
            }
        )

        startFaceScan(for: challenge)
    }

    private func retryFaceScan(for challenge: AppLockEngine.Challenge) {
        guard engine.activeChallenge?.id == challenge.id,
              engine.activeChallenge?.phase == .scanning
        else { return }
        startFaceScan(for: challenge)
    }

    private func startFaceScan(for challenge: AppLockEngine.Challenge) {
        faceScanner.startScan(
            challengeID: challenge.id,
            onStatus: { [weak self] message in
                self?.curtainController.updateStatus(
                    challengeID: challenge.id,
                    message: message,
                    isScanning: true,
                    canRetry: false
                )
            },
            onOutcome: { [weak self] challengeID, outcome in
                guard let self else { return }
                switch outcome {
                case .matched:
                    let effects = self.engine.passed(challengeID: challengeID, monotonicNow: self.monotonicNow())
                    self.execute(effects)
                case .failed(let reason, let canRetry):
                    self.curtainController.updateStatus(
                        challengeID: challengeID,
                        message: reason,
                        isScanning: false,
                        canRetry: canRetry
                    )
                case .cancelled:
                    break
                }
            }
        )
    }

    private func requestSystemPrompt(challengeID: UUID) {
        let effects = engine.systemPromptRequested(challengeID: challengeID)
        execute(effects)
    }

    private func presentSystemPrompt(for challenge: AppLockEngine.Challenge) {
        activeSystemPromptContext?.invalidate()
        let context = LAContext()
        activeSystemPromptChallengeID = challenge.id
        activeSystemPromptContext = context

        let appName = resolveAppMetadata(for: challenge.app).name
        Task { [weak self] in
            let outcome = await SystemAuthentication.authenticate(
                reason: "Unlock \(appName)",
                context: context
            )
            guard let self else { return }
            if self.activeSystemPromptChallengeID == challenge.id {
                self.activeSystemPromptChallengeID = nil
                self.activeSystemPromptContext = nil
            }
            let effects = self.engine.systemPromptFinished(
                challengeID: challenge.id,
                success: outcome.isAuthenticated,
                monotonicNow: self.monotonicNow()
            )
            self.execute(effects)
        }
    }

    private func resolveAppMetadata(for app: AppLockEngine.App) -> (name: String, icon: NSImage) {
        let running = NSRunningApplication(processIdentifier: app.pid)
        let lowerBundleID = app.bundleID.lowercased()
        if let entry = GlanceSettings.shared.lockedApps.first(where: { $0.bundleIdentifier.lowercased() == lowerBundleID }) {
            let name = running?.localizedName ?? entry.name
            let icon = running?.icon ?? entry.resolvedIcon()
            return (name, icon)
        }
        let name = running?.localizedName ?? app.bundleID
        let icon = running?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
        return (name, icon)
    }

    /// Owns `NotificationCenter` tokens outside actor isolation so `deinit` can unregister safely under Swift 6.
    nonisolated private final class ObserverBox: @unchecked Sendable {
        private var entries: [(center: NotificationCenter, token: NSObjectProtocol)] = []

        func add(_ center: NotificationCenter, token: NSObjectProtocol) {
            entries.append((center, token))
        }

        deinit {
            for entry in entries {
                entry.center.removeObserver(entry.token)
            }
        }
    }
}
