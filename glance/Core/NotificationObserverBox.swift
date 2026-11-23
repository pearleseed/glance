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
    private struct State: @unchecked Sendable {
        var entries: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func add(_ token: NSObjectProtocol, center: NotificationCenter = .default) {
        state.withLock { $0.entries.append((center, token)) }
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

    deinit {
        let entries = state.withLock { state in
            let current = state.entries
            state.entries.removeAll()
            return current
        }
        for entry in entries {
            entry.center.removeObserver(entry.token)
        }
    }
}
