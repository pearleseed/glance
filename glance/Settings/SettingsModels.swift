//
//  SettingsModels.swift
//  glance
//
//  Value-type option enums persisted by `GlanceSettings`.
//

import Foundation

/// How long the Touch-ID-unlocked session may sit idle before it re-locks.
enum AutoLockInterval: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case never = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .sevenDays: return "7 days"
        case .fourteenDays: return "14 days"
        case .thirtyDays: return "30 days"
        }
    }

    /// `nil` means the session stays open until the app exits or the user
    /// explicitly locks it; the session key itself is never persisted in memory.
    var duration: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue) * 24 * 60 * 60
    }

    /// Position in `allCases`, used to drive the discrete 4-stop slider.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> AutoLockInterval {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .thirtyDays
    }
}

/// Unlock success/failure animation style shown in the notch overlay.
enum UnlockAnimationStyle: String, CaseIterable, Identifiable {
    case none
    case minimal
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .original: return "Original"
        }
    }

    /// The styles the picker offers; `.none` is still a valid stored value but is now produced
    /// by the "Show animation" toggle, not a tile.
    static let selectableCases: [UnlockAnimationStyle] = [.minimal, .original]
}

/// What can prompt Face Unlock. Multi-select; at least one is always kept
/// selected, since a Mac with none armed would never show the notch.
enum UnlockTrigger: String, CaseIterable, Identifiable {
    /// The display turned back on (see `LockEventKind.wake`).
    case onWake
    /// The screen just became locked, no wake involved.
    case onLock
    /// Pressing space on the lock screen starts a scan. The lock screen's
    /// Secure Event Input blocks normal event taps, so this is detected via
    /// IOKit HID instead (see `SpaceKeyMonitor`), requiring Input Monitoring.
    case onSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onWake: return "On wake"
        case .onLock: return "On lock"
        case .onSpace: return "On space"
        }
    }

    var iconName: String {
        switch self {
        case .onWake: return "moon.fill"
        case .onLock: return "lock.laptopcomputer"
        case .onSpace: return "space"
        }
    }
}
