//
//  RelockPolicy.swift
//  glance
//

import Foundation

/// Defines when a previously unlocked application must require authentication again.
/// Time-based variants are evaluated against monotonic uptime (`TimeInterval`) so wall-clock edits cannot bypass locks.
nonisolated enum RelockPolicy: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Relocks immediately whenever another regular application becomes frontmost or the app hides.
    case everyTime
    /// Stays unlocked for `minutes` after authentication, regardless of app switches.
    case afterMinutes(Int)
    /// Stays unlocked while focused, and relocks once unfocused or hidden for `minutes`.
    case afterFocusLossMinutes(Int)

    var id: String {
        switch self {
        case .everyTime:
            return "everyTime"
        case .afterMinutes(let minutes):
            return "afterMinutes:\(minutes)"
        case .afterFocusLossMinutes(let minutes):
            return "afterFocusLossMinutes:\(minutes)"
        }
    }

    var title: String {
        switch self {
        case .everyTime:
            return "Every time"
        case .afterMinutes(let minutes):
            let clamped = max(0, minutes)
            return clamped == 1 ? "After 1 minute" : "After \(clamped) minutes"
        case .afterFocusLossMinutes(let minutes):
            let clamped = max(0, minutes)
            return clamped == 1 ? "1 minute after leaving" : "\(clamped) minutes after leaving"
        }
    }

    var shortTitle: String {
        switch self {
        case .everyTime:
            return "Every time"
        case .afterMinutes(let minutes):
            return "\(max(0, minutes))m"
        case .afterFocusLossMinutes(let minutes):
            return "\(max(0, minutes))m away"
        }
    }

    /// Timeout duration in seconds for timed variants, or `nil` for `.everyTime`.
    var durationSeconds: TimeInterval? {
        switch self {
        case .everyTime:
            return nil
        case .afterMinutes(let minutes), .afterFocusLossMinutes(let minutes):
            return TimeInterval(max(0, minutes)) * 60.0
        }
    }
}
