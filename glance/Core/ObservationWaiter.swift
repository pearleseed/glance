//
//  ObservationWaiter.swift
//  glance
//
//  Event-driven `@MainActor` observation waiter backed by `withObservationTracking`
//  and a single deadline timer, replacing polling loops on `@Observable` state.
//

import Foundation
import Observation
import os

/// Lightweight `@Observable` signal whose version counter can be bumped to wake any
/// `ObservationWaiter` listening on non-observable control state (e.g. `stop()`).
@Observable
@MainActor
final class ObservationSignal {
    private(set) var version: UInt64 = 0

    func signal() {
        version &+= 1
    }
}

@MainActor
enum ObservationWaiter {
    /// Suspends on `@MainActor` until `keepWaiting()` returns `false`, `deadline` expires,
    /// or the current task is cancelled. Any `@Observable` property read by `keepWaiting()`
    /// automatically wakes the waiter when mutated, with zero periodic polling.
    static func waitWhile(
        until deadline: ContinuousClock.Instant,
        _ keepWaiting: @escaping @MainActor () -> Bool
    ) async {
        while !Task.isCancelled, ContinuousClock.now < deadline {
            let changed = await waitForSingleChange(until: deadline, keepWaiting: keepWaiting)
            if !changed {
                return
            }
        }
    }

    private static func waitForSingleChange(
        until deadline: ContinuousClock.Instant,
        keepWaiting: @MainActor () -> Bool
    ) async -> Bool {
        let state = WaitState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldWait = withObservationTracking {
                    keepWaiting()
                } onChange: {
                    // `onChange` fires synchronously inside `willSet` (before the new value is
                    // stored) and may run off `@MainActor`. Hopping to `@MainActor` ensures
                    // `keepWaiting()` reads the committed state after the turn completes.
                    Task { @MainActor in
                        state.resumeIfPending(didChange: true)
                    }
                }

                guard shouldWait, !Task.isCancelled, ContinuousClock.now < deadline else {
                    state.resolveImmediately(continuation: continuation, didChange: false)
                    return
                }

                guard state.attach(continuation: continuation) else {
                    return
                }

                let timeoutTask = Task.detached {
                    try? await Task.sleep(until: deadline, tolerance: .milliseconds(2), clock: .continuous)
                    guard !Task.isCancelled else { return }
                    state.resumeIfPending(didChange: false)
                }
                state.attachTimeoutTask(timeoutTask)
            }
        } onCancel: {
            state.resumeIfPending(didChange: false)
        }
    }
}

nonisolated private final class WaitState: Sendable {
    private struct Storage: @unchecked Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        var resolvedValue: Bool?
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: Storage())

    func resolveImmediately(continuation: CheckedContinuation<Bool, Never>, didChange: Bool) {
        let timeoutToCancel = lock.withLock { s -> Task<Void, Never>? in
            s.resolvedValue = didChange
            let timeout = s.timeoutTask
            s.timeoutTask = nil
            return timeout
        }
        timeoutToCancel?.cancel()
        continuation.resume(returning: didChange)
    }

    func attach(continuation: CheckedContinuation<Bool, Never>) -> Bool {
        let earlyResult = lock.withLock { s -> Bool? in
            if let resolved = s.resolvedValue {
                return resolved
            }
            s.continuation = continuation
            return nil
        }
        if let earlyResult {
            continuation.resume(returning: earlyResult)
            return false
        }
        return true
    }

    func attachTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { s -> Bool in
            if s.resolvedValue != nil {
                return true
            }
            s.timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func resumeIfPending(didChange: Bool) {
        let action = lock.withLock { s -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
            guard s.resolvedValue == nil else {
                return (nil, nil)
            }
            s.resolvedValue = didChange
            let cont = s.continuation
            s.continuation = nil
            let timeout = s.timeoutTask
            s.timeoutTask = nil
            return (cont, timeout)
        }
        action.1?.cancel()
        action.0?.resume(returning: didChange)
    }
}
