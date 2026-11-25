//
//  LockMonitor.swift
//  glance
//
//  Detects macOS lock/unlock state for the CGEvent injection POC.
//

import AppKit
import CoreGraphics
import Foundation
import Observation

/// Which signal most recently fired — `withObservationTracking`'s `onChange` doesn't say which property changed, so observers
/// read this alongside the monotonic `eventCount` to tell events apart.
enum LockEventKind {
    case screenLocked
    case screenUnlocked
    case willSleep
    /// Display turned back on, from system sleep, display sleep, or the screensaver stopping.
    case wake
}

@Observable
final class LockMonitor {
    /// NOT trustworthy alone: any same-user process can post these distributed notifications, and this process can be
    /// suspended before one is delivered (e.g. lid-close sleep racing a lock). UI/trigger signal only, never a security gate.
    private(set) var isScreenLocked: Bool = false

    /// Catches the case above: lock may have already happened while suspended, so wake is the first chance to notice — callers
    /// should re-derive lock state via `isScreenActuallyLocked()` on change rather than trust `isScreenLocked`.
    private(set) var wakeEventCount: Int = 0

    /// True from `willSleepNotification` until the next wake. `screenIsLocked` fires ~150ms before the system actually finishes
    /// suspending (measured via pmset/os_log correlation), so callers should skip acting on a lock while this is true and wait
    /// for the wake trigger instead.
    private(set) var isSleeping: Bool = false

    /// True while displays are asleep (`screensDidSleepNotification` until `screensDidWakeNotification` / `didWakeNotification`).
    private(set) var isDisplayAsleep: Bool = false

    /// Timestamps of the most recent display/system wakes so keystroke injection can avoid racing
    /// `loginwindow`'s `Clearing password field for NSWorkspaceScreensDidWakeNotification`.
    private(set) var lastDisplayWakeAt: ContinuousClock.Instant?
    private(set) var lastSystemWakeAt: ContinuousClock.Instant?

    /// Observers track `eventCount` (changes on every event, even repeats of the same kind) then read `lastEvent`.
    private(set) var lastEvent: LockEventKind?
    private(set) var eventCount: Int = 0

    private let observerBox = NotificationObserverBox()
    private let returnWatchBox = CancellableTaskBox()
    private var lastIdleSeconds: Double = 0

    init() {
        startMonitoring()
    }

    private func startMonitoring() {
        registerDistributedObservers()
        registerWorkspaceObservers()
    }

    private func registerDistributedObservers() {
        let distributed = DistributedNotificationCenter.default()
        observerBox.observe(
            center: distributed,
            forName: Notification.Name("com.apple.screenIsLocked"),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScreenLocked = true
                if !self.isSleeping && !self.isDisplayAsleep {
                    self.startReturnWatch()
                }
                self.record(.screenLocked)
            }
        }
        observerBox.observe(
            center: distributed,
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScreenLocked = false
                self.isSleeping = false
                self.isDisplayAsleep = false
                self.stopReturnWatch()
                self.record(.screenUnlocked)
            }
        }
        observerBox.observe(
            center: distributed,
            forName: Notification.Name("com.apple.screensaver.didstart"),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startReturnWatch()
            }
        }
        // Observing the key press that dismissed the screensaver isn't possible — Secure Event Input suppresses keyboard taps
        // on the lock screen regardless of Accessibility trust — so this notification stands in for it.
        observerBox.observe(
            center: distributed,
            forName: Notification.Name("com.apple.screensaver.didstop"),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = false
                self.isDisplayAsleep = false
                self.stopReturnWatch()
                if Self.isScreenActuallyLocked() {
                    self.startReturnWatch()
                }
                self.record(.wake)
            }
        }
    }

    private func registerWorkspaceObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observerBox.observe(
            center: workspace,
            forName: NSWorkspace.willSleepNotification,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = true
                self.stopReturnWatch()
                self.record(.willSleep)
            }
        }
        observerBox.observe(
            center: workspace,
            forName: NSWorkspace.screensDidSleepNotification,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDisplayAsleep = true
                self.stopReturnWatch()
            }
        }
        // Display- and system-level wake are treated as equivalent triggers — they land within ~100ms of each other in either order.
        observerBox.observe(
            center: workspace,
            forName: NSWorkspace.screensDidWakeNotification,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDisplayAsleep = false
                self.lastDisplayWakeAt = .now
                self.recordWake()
                if Self.isScreenActuallyLocked() {
                    self.startReturnWatch()
                }
            }
        }
        observerBox.observe(
            center: workspace,
            forName: NSWorkspace.didWakeNotification,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDisplayAsleep = false
                self.lastSystemWakeAt = .now
                self.recordWake()
                if Self.isScreenActuallyLocked() {
                    self.startReturnWatch()
                }
            }
        }
    }

    private func startReturnWatch() {
        stopReturnWatch()
        lastIdleSeconds = 0
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.checkUserReturned()
            }
        }
        returnWatchBox.replace(with: task)
    }

    private func stopReturnWatch() {
        returnWatchBox.cancel()
    }

    private func checkUserReturned() {
        guard Self.isScreenActuallyLocked() else {
            stopReturnWatch()
            return
        }
        guard !isSleeping, !isDisplayAsleep else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        if lastIdleSeconds >= 3, idle < 1 {
            recordWake()
        }
        lastIdleSeconds = idle
    }

    private func recordWake() {
        isSleeping = false
        wakeEventCount += 1
        record(.wake)
    }

    private func record(_ kind: LockEventKind) {
        lastEvent = kind
        eventCount += 1
    }

    /// Authoritative lock state from the CoreGraphics session server, not a spoofable notification. Fails closed if unavailable.
    nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
