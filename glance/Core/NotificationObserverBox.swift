//
//  NotificationObserverBox.swift
//  glance
//
//  Thread-safe NotificationCenter token bag that unregisters all observers on `deinit`
//  outside `@MainActor` isolation under Swift 6 strict concurrency.
//

import Foundation
import os

nonisolated final class NotificationObserverBox: Sendable {
    private nonisolated struct Entry: @unchecked Sendable {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private let state = OSAllocatedUnfairLock(initialState: [Entry]())

    func add(_ token: NSObjectProtocol, center: NotificationCenter = .default) {
        let entry = Entry(center: center, token: token)
        state.withLock { $0.append(entry) }
    }

    func observe(
        center: NotificationCenter = .default,
        forName name: Notification.Name,
        object: Any? = nil,
        queue: OperationQueue? = nil,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: queue, using: block)
        add(token, center: center)
    }

    func removeAll() {
        let entries = state.withLock { entries in
            let current = entries
            entries.removeAll()
            return current
        }
        for entry in entries {
            entry.center.removeObserver(entry.token)
        }
    }

    deinit {
        removeAll()
    }
}

/// Thread-safe box holding a cancellable `Task<Void, Never>` that cancels the
/// previous task on replacement and cancels any active task on `deinit` outside `@MainActor`.
nonisolated final class CancellableTaskBox: Sendable {
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    func replace(with newTask: Task<Void, Never>?) {
        let previous = task.withLock { current in
            let old = current
            current = newTask
            return old
        }
        previous?.cancel()
    }

    func cancel() {
        replace(with: nil)
    }

    deinit {
        cancel()
    }
}
