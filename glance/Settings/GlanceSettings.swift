//
//  GlanceSettings.swift
//  glance
//
//  Backed directly by `UserDefaults.standard` — each property's `didSet`
//  writes through immediately, so there's no explicit "save" step.
//

import Foundation
import Observation

@Observable
@MainActor
final class GlanceSettings {
    static let shared = GlanceSettings()

    private enum Key {
        static let isFaceUnlockEnabled = "GlanceSettings.isFaceUnlockEnabled"
        static let isFaceUnlockEnabledBuiltInOnly = "GlanceSettings.isFaceUnlockEnabledBuiltInOnly"
        static let isFaceUnlockEnabledBuiltInAndExternal = "GlanceSettings.isFaceUnlockEnabledBuiltInAndExternal"
        static let isFaceUnlockEnabledExternalOnly = "GlanceSettings.isFaceUnlockEnabledExternalOnly"
        static let faceUnlockToggleShortcut = "GlanceSettings.faceUnlockToggleShortcut"
        static let matchThreshold = "GlanceSettings.matchThreshold"
        static let livenessChecksEnabled = "GlanceSettings.livenessChecksEnabled"
        static let livenessMode = "GlanceSettings.livenessMode"
        static let strictCloseRangeOnly = "GlanceSettings.strictCloseRangeOnly"
        static let unlockAnimationStyle = "GlanceSettings.unlockAnimationStyle"
        static let showUnlockAnimation = "GlanceSettings.showUnlockAnimation"
        static let unlockAnimationColor = "GlanceSettings.unlockAnimationColor"
        static let notchWidthAdjustment = "GlanceSettings.notchWidthAdjustment"
        static let notchHeightAdjustment = "GlanceSettings.notchHeightAdjustment"
        /// Legacy bool key — read once during migration, then ignored.
        static let playUnlockAnimation = "GlanceSettings.playUnlockAnimation"
        static let unlockTriggers = "GlanceSettings.unlockTriggers"
        static let retryOnHover = "GlanceSettings.retryOnHover"
        static let faceDetectionSeconds = "GlanceSettings.faceDetectionSeconds"
        static let autoRetryOnce = "GlanceSettings.autoRetryOnce"
        static let hapticFeedbackEnabled = "GlanceSettings.hapticFeedbackEnabled"
        static let nightBoostEnabled = "GlanceSettings.nightBoostEnabled"
        static let showsInMenuBar = "GlanceSettings.showsInMenuBar"
        static let preferredDisplayID = "GlanceSettings.preferredDisplayID"
        static let preferredDisplayName = "GlanceSettings.preferredDisplayName"
        static let autoLockIntervalDays = "GlanceSettings.autoLockIntervalDays"
        static let defaultCameraID = "GlanceSettings.defaultCameraID"
        static let builtInDisplayCameraID = "GlanceSettings.builtInDisplayCameraID"
        static let externalDisplayCameraID = "GlanceSettings.externalDisplayCameraID"
        static let hasCompletedOnboarding = "GlanceSettings.hasCompletedOnboarding"
        static let onboardingResumeStep = "GlanceSettings.onboardingResumeStep"
        static let hasAcknowledgedSecurityNotice = "GlanceSettings.hasAcknowledgedSecurityNotice"
        static let isAppLockEnabled = "GlanceSettings.isAppLockEnabled"
        static let lockedApps = "GlanceSettings.lockedApps"
        static let defaultAppRelockPolicy = "GlanceSettings.defaultAppRelockPolicy"
        static let sudoFaceAuthEnabled = "GlanceSettings.sudoFaceAuthEnabled"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// AppKit owns the actual status item. This callback keeps the persisted
    /// preference independent from that UI lifecycle.
    @ObservationIgnored private var menuBarVisibilityDidChange: ((Bool) -> Void)?

    var isFaceUnlockEnabled: Bool {
        didSet { defaults.set(isFaceUnlockEnabled, forKey: Key.isFaceUnlockEnabled) }
    }
    /// Per-display-topology enablement toggles ("Active when" in General settings).
    var isFaceUnlockEnabledBuiltInOnly: Bool {
        didSet { defaults.set(isFaceUnlockEnabledBuiltInOnly, forKey: Key.isFaceUnlockEnabledBuiltInOnly) }
    }
    var isFaceUnlockEnabledBuiltInAndExternal: Bool {
        didSet {
            defaults.set(isFaceUnlockEnabledBuiltInAndExternal, forKey: Key.isFaceUnlockEnabledBuiltInAndExternal)
        }
    }
    var isFaceUnlockEnabledExternalOnly: Bool {
        didSet { defaults.set(isFaceUnlockEnabledExternalOnly, forKey: Key.isFaceUnlockEnabledExternalOnly) }
    }

    func isFaceUnlockEnabled(for context: DisplayContext) -> Bool {
        switch context {
        case .builtInOnly: return isFaceUnlockEnabledBuiltInOnly
        case .builtInAndExternal: return isFaceUnlockEnabledBuiltInAndExternal
        case .externalOnly: return isFaceUnlockEnabledExternalOnly
        }
    }

    /// Global shortcut that toggles Face Unlock on/off. Stored as JSON `Data`
    /// (empty `Data()` sentinel when explicitly cleared) so `nil` persists
    /// across relaunches instead of reverting to `.defaultToggleFaceUnlock`.
    var faceUnlockToggleShortcut: HotKeyShortcut? {
        didSet {
            if let faceUnlockToggleShortcut,
                let data = try? JSONEncoder().encode(faceUnlockToggleShortcut)
            {
                defaults.set(data, forKey: Key.faceUnlockToggleShortcut)
            } else {
                defaults.set(Data(), forKey: Key.faceUnlockToggleShortcut)
            }
        }
    }
    var matchThreshold: Float {
        didSet { defaults.set(matchThreshold, forKey: Key.matchThreshold) }
    }
    /// Master switch for liveness checking. Off means face recognition
    /// alone decides an unlock — a photo of the enrolled user would pass.
    var livenessChecksEnabled: Bool {
        didSet { defaults.set(livenessChecksEnabled, forKey: Key.livenessChecksEnabled) }
    }
    /// Light (deny-only) vs Heavy (deny plus a required proof of life) —
    /// see `LivenessMode`.
    var livenessMode: LivenessMode {
        didSet { defaults.set(livenessMode.rawValue, forKey: Key.livenessMode) }
    }
    /// Mirrored into `FaceRecognitionPipeline.strictCloseRangeOnly` on
    /// every change, since that's read from a background `nonisolated` context.
    var strictCloseRangeOnly: Bool {
        didSet {
            defaults.set(strictCloseRangeOnly, forKey: Key.strictCloseRangeOnly)
            FaceRecognitionPipeline.strictCloseRangeOnly = strictCloseRangeOnly
        }
    }
    /// The remembered choice (`.minimal`/`.original` only); `showUnlockAnimation`
    /// tracks on/off separately so toggling back on restores the prior pick.
    /// Read `effectiveUnlockAnimationStyle`, not this, to decide what to show.
    var unlockAnimationStyle: UnlockAnimationStyle {
        didSet { defaults.set(unlockAnimationStyle.rawValue, forKey: Key.unlockAnimationStyle) }
    }
    var showUnlockAnimation: Bool {
        didSet { defaults.set(showUnlockAnimation, forKey: Key.showUnlockAnimation) }
    }
    var unlockAnimationColor: UnlockAnimationColor {
        didSet { defaults.set(unlockAnimationColor.rawValue, forKey: Key.unlockAnimationColor) }
    }

    /// What the overlay should actually render — the pick, or `.none` when
    /// animations are switched off entirely.
    var effectiveUnlockAnimationStyle: UnlockAnimationStyle {
        showUnlockAnimation ? unlockAnimationStyle : .none
    }

    /// Which signals arm Face Unlock. Persisted as raw-value strings; the
    /// setter refuses to store an empty set (see `UnlockTrigger`).
    var unlockTriggers: Set<UnlockTrigger> {
        didSet {
            // Belt-and-braces behind the picker's own min-one rule. This
            // reassignment re-enters didSet once, then terminates since the
            // corrected value is never itself empty.
            if unlockTriggers.isEmpty {
                unlockTriggers = oldValue.isEmpty ? Set(UnlockTrigger.allCases) : oldValue
            }
            defaults.set(unlockTriggers.map(\.rawValue), forKey: Key.unlockTriggers)
        }
    }
    var retryOnHover: Bool {
        didSet { defaults.set(retryOnHover, forKey: Key.retryOnHover) }
    }
    /// How long each scan cycle looks for a face before giving up. Must stay
    /// equal to `FaceUnlockCoordinator.scanWindowDuration` and
    /// `NotchOverlayController.scanTimeoutDuration`.
    var faceDetectionSeconds: Int {
        didSet {
            // Only reassign when clamping actually changes the value —
            // unconditional reassignment would recurse infinitely, since the
            // slider only ever produces already-in-range values.
            let clamped = min(
                max(faceDetectionSeconds, Self.faceDetectionRange.lowerBound),
                Self.faceDetectionRange.upperBound)
            guard clamped == faceDetectionSeconds else {
                faceDetectionSeconds = clamped
                return
            }
            defaults.set(faceDetectionSeconds, forKey: Key.faceDetectionSeconds)
        }
    }
    var autoRetryOnce: Bool {
        didSet { defaults.set(autoRetryOnce, forKey: Key.autoRetryOnce) }
    }
    /// Trackpad haptic on hovering the notch/pill, on a successful unlock, and
    /// on enrollment alignment/capture — see `NotchOverlayView` and `OnboardingController`.
    var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Key.hapticFeedbackEnabled) }
    }
    /// Opt-in dark-room helper: softly illuminates the top of the screen and boosts
    /// low-light recognition frames during Face Unlock without touching liveness inputs.
    var nightBoostEnabled: Bool {
        didSet { defaults.set(nightBoostEnabled, forKey: Key.nightBoostEnabled) }
    }
    /// Hiding the status item does not quit Glance; a relaunch still routes
    /// through `AppDelegate.applicationShouldHandleReopen` to show Settings.
    var showsInMenuBar: Bool {
        didSet {
            defaults.set(showsInMenuBar, forKey: Key.showsInMenuBar)
            menuBarVisibilityDidChange?(showsInMenuBar)
        }
    }

    /// Bound once by `AppDelegate` after AppKit has finished launching. The
    /// initial call applies the stored preference as well as subsequent edits.
    func bindMenuBarVisibility(_ handler: @escaping (Bool) -> Void) {
        menuBarVisibilityDidChange = handler
        handler(showsInMenuBar)
    }

    static let faceDetectionRange = 3...10
    static let notchAdjustmentRange = -20...20

    /// Point adjustments applied to the measured physical notch silhouette on
    /// notched displays (`-20...20`). Ignored on non-notched (pill) displays.
    var notchWidthAdjustment: Int {
        didSet {
            let clamped = Self.clampNotchAdjustment(notchWidthAdjustment)
            guard clamped == notchWidthAdjustment else {
                notchWidthAdjustment = clamped
                return
            }
            defaults.set(notchWidthAdjustment, forKey: Key.notchWidthAdjustment)
        }
    }

    var notchHeightAdjustment: Int {
        didSet {
            let clamped = Self.clampNotchAdjustment(notchHeightAdjustment)
            guard clamped == notchHeightAdjustment else {
                notchHeightAdjustment = clamped
                return
            }
            defaults.set(notchHeightAdjustment, forKey: Key.notchHeightAdjustment)
        }
    }

    private static func clampNotchAdjustment(_ value: Int) -> Int {
        min(max(value, notchAdjustmentRange.lowerBound), notchAdjustmentRange.upperBound)
    }

    /// Which display Face Unlock shows on. `nil` means `NotchGeometry.preferredScreen()`'s
    /// default, re-evaluated live; a pinned display has deliberately no
    /// fallback if disconnected (see `FaceUnlockCoordinator.evaluateTrigger()`).
    var preferredDisplayID: String? {
        didSet { defaults.set(preferredDisplayID, forKey: Key.preferredDisplayID) }
    }
    /// The chosen display's name at pick time — cosmetic only, so the row can
    /// show something recognizable when that display is disconnected.
    var preferredDisplayName: String? {
        didSet { defaults.set(preferredDisplayName, forKey: Key.preferredDisplayName) }
    }
    /// Enforced by `SessionAutoLocker`, not here — this is only the stored
    /// preference.
    var autoLockInterval: AutoLockInterval {
        didSet { defaults.set(autoLockInterval.rawValue, forKey: Key.autoLockIntervalDays) }
    }
    /// Device `uniqueID`s, not device objects — devices can disconnect/
    /// reconnect between launches, but their unique ID is stable.
    var defaultCameraID: String? {
        didSet { defaults.set(defaultCameraID, forKey: Key.defaultCameraID) }
    }
    var builtInDisplayCameraID: String? {
        didSet { defaults.set(builtInDisplayCameraID, forKey: Key.builtInDisplayCameraID) }
    }
    var externalDisplayCameraID: String? {
        didSet { defaults.set(externalDisplayCameraID, forKey: Key.externalDisplayCameraID) }
    }

    /// Gates first-run onboarding — `AppDelegate` shows it instead of the
    /// Settings window until this is `true`. Set once, by `OnboardingController`
    /// on the true first-run flow reaching `.complete`.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }
    /// Where to resume first-run onboarding if the app quit mid-flow; `nil`
    /// starts fresh at `.intro`. Steps depending on in-memory capture state
    /// collapse to `.preSetup` before storing, since that state doesn't
    /// survive a relaunch — see `OnboardingStep.resumeTarget`.
    var onboardingResumeStep: OnboardingStep? {
        didSet { defaults.set(onboardingResumeStep?.rawValue, forKey: Key.onboardingResumeStep) }
    }
    /// Gates the one-time post-update notice for users who completed onboarding before the
    /// security-disclaimer step existed. Set alongside `hasCompletedOnboarding` for anyone
    /// finishing normal onboarding (which now includes that step), and separately by
    /// `OnboardingController.startPostUpdateNotice()` once the standalone catch-up notice is
    /// acknowledged. Defaults `false`, so an upgrading 1.0 install (where this key has never
    /// been written) correctly triggers the catch-up flow once.
    var hasAcknowledgedSecurityNotice: Bool {
        didSet { defaults.set(hasAcknowledgedSecurityNotice, forKey: Key.hasAcknowledgedSecurityNotice) }
    }
    /// Opt-in App Lock master switch; defaults to `false`.
    var isAppLockEnabled: Bool {
        didSet { defaults.set(isAppLockEnabled, forKey: Key.isAppLockEnabled) }
    }
    /// Applications guarded by App Lock, persisted as JSON.
    var lockedApps: [LockedApp] {
        didSet {
            if let data = try? JSONEncoder().encode(lockedApps) {
                defaults.set(data, forKey: Key.lockedApps)
            }
        }
    }
    /// Default relock behavior for locked apps without a per-app override.
    var defaultAppRelockPolicy: RelockPolicy {
        didSet {
            if let data = try? JSONEncoder().encode(defaultAppRelockPolicy) {
                defaults.set(data, forKey: Key.defaultAppRelockPolicy)
            }
        }
    }
    /// Opt-in Face-for-sudo PAM authentication; defaults to `false`.
    var sudoFaceAuthEnabled: Bool {
        didSet { defaults.set(sudoFaceAuthEnabled, forKey: Key.sudoFaceAuthEnabled) }
    }

    private init() {
        // Enabled by default — onboarding already enrolled a face and set a password specifically to use Face Unlock.
        isFaceUnlockEnabled = defaults.bool(forKey: Key.isFaceUnlockEnabled, default: true)
        isFaceUnlockEnabledBuiltInOnly = defaults.bool(forKey: Key.isFaceUnlockEnabledBuiltInOnly, default: true)
        isFaceUnlockEnabledBuiltInAndExternal = defaults.bool(
            forKey: Key.isFaceUnlockEnabledBuiltInAndExternal, default: true)
        isFaceUnlockEnabledExternalOnly = defaults.bool(forKey: Key.isFaceUnlockEnabledExternalOnly, default: true)
        faceUnlockToggleShortcut = Self.decodeToggleShortcut(from: defaults)

        // Matches `MatchConfidenceLevel.standard` — see RecognitionSettingsPage.swift.
        matchThreshold = defaults.object(forKey: Key.matchThreshold) as? Float ?? 0.66
        livenessChecksEnabled = defaults.bool(forKey: Key.livenessChecksEnabled, default: true)
        livenessMode = defaults.string(forKey: Key.livenessMode).flatMap(LivenessMode.init(rawValue:)) ?? .light
        strictCloseRangeOnly = defaults.bool(forKey: Key.strictCloseRangeOnly, default: false)

        let (style, showAnimation) = Self.resolveAnimationSettings(from: defaults)
        unlockAnimationStyle = style
        showUnlockAnimation = showAnimation
        unlockAnimationColor =
            defaults.string(forKey: Key.unlockAnimationColor)
            .flatMap(UnlockAnimationColor.init(rawValue:)) ?? .blue
        notchWidthAdjustment =
            (defaults.object(forKey: Key.notchWidthAdjustment) as? Int)
            .map(Self.clampNotchAdjustment) ?? 0
        notchHeightAdjustment =
            (defaults.object(forKey: Key.notchHeightAdjustment) as? Int)
            .map(Self.clampNotchAdjustment) ?? 0

        unlockTriggers = Self.decodeUnlockTriggers(from: defaults)
        retryOnHover = defaults.bool(forKey: Key.retryOnHover, default: true)
        faceDetectionSeconds =
            (defaults.object(forKey: Key.faceDetectionSeconds) as? Int)
            .map { min(max($0, Self.faceDetectionRange.lowerBound), Self.faceDetectionRange.upperBound) } ?? 5
        autoRetryOnce = defaults.bool(forKey: Key.autoRetryOnce, default: false)
        hapticFeedbackEnabled = defaults.bool(forKey: Key.hapticFeedbackEnabled, default: true)
        nightBoostEnabled = defaults.bool(forKey: Key.nightBoostEnabled, default: false)
        showsInMenuBar = defaults.bool(forKey: Key.showsInMenuBar, default: true)
        preferredDisplayID = defaults.string(forKey: Key.preferredDisplayID)
        preferredDisplayName = defaults.string(forKey: Key.preferredDisplayName)

        autoLockInterval =
            (defaults.object(forKey: Key.autoLockIntervalDays) as? Int)
            .flatMap(AutoLockInterval.init(rawValue:)) ?? .thirtyDays
        defaultCameraID = defaults.string(forKey: Key.defaultCameraID)
        builtInDisplayCameraID = defaults.string(forKey: Key.builtInDisplayCameraID)
        externalDisplayCameraID = defaults.string(forKey: Key.externalDisplayCameraID)

        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding, default: false)
        onboardingResumeStep = defaults.string(forKey: Key.onboardingResumeStep)
            .flatMap(OnboardingStep.init(rawValue:))
        hasAcknowledgedSecurityNotice = defaults.bool(forKey: Key.hasAcknowledgedSecurityNotice, default: false)
        isAppLockEnabled = defaults.bool(forKey: Key.isAppLockEnabled, default: false)
        lockedApps = Self.decodeLockedApps(from: defaults)
        defaultAppRelockPolicy = Self.decodeRelockPolicy(from: defaults)
        sudoFaceAuthEnabled = defaults.bool(forKey: Key.sudoFaceAuthEnabled, default: false)

        // Push into the nonisolated mirror immediately, or FaceRecognitionPipeline
        // would keep its own default until the toggle is first switched.
        FaceRecognitionPipeline.strictCloseRangeOnly = strictCloseRangeOnly
    }
}

extension GlanceSettings {
    fileprivate static func decodeToggleShortcut(from defaults: UserDefaults) -> HotKeyShortcut? {
        guard let shortcutData = defaults.data(forKey: Key.faceUnlockToggleShortcut) else {
            return .defaultToggleFaceUnlock
        }
        guard !shortcutData.isEmpty else { return nil }
        return (try? JSONDecoder().decode(HotKeyShortcut.self, from: shortcutData))
            ?? .defaultToggleFaceUnlock
    }

    fileprivate static func resolveAnimationSettings(from defaults: UserDefaults) -> (UnlockAnimationStyle, Bool) {
        let storedStyle: UnlockAnimationStyle
        if let raw = defaults.string(forKey: Key.unlockAnimationStyle),
            let style = UnlockAnimationStyle(rawValue: raw)
        {
            storedStyle = style
        } else if let legacy = defaults.object(forKey: Key.playUnlockAnimation) as? Bool {
            // Migrate the oldest on/off toggle: off → none, on → original.
            storedStyle = legacy ? .original : .none
        } else {
            storedStyle = .original
        }
        // A stored `.none` becomes "off, remembering .original" so switching back on has something to restore.
        let style = storedStyle == .none ? .original : storedStyle
        let show = defaults.bool(forKey: Key.showUnlockAnimation, default: storedStyle != .none)
        return (style, show)
    }

    fileprivate static func decodeUnlockTriggers(from defaults: UserDefaults) -> Set<UnlockTrigger> {
        let stored = (defaults.array(forKey: Key.unlockTriggers) as? [String])?.compactMap { raw -> UnlockTrigger? in
            // "onActivity" was merged into "onWake"; keep old installs working.
            if raw == "onActivity" { return .onWake }
            return UnlockTrigger(rawValue: raw)
        }
        return stored.map(Set.init).flatMap { $0.isEmpty ? nil : $0 } ?? [.onWake, .onLock]
    }

    fileprivate static func decodeLockedApps(from defaults: UserDefaults) -> [LockedApp] {
        guard let data = defaults.data(forKey: Key.lockedApps),
            let decoded = try? JSONDecoder().decode([LockedApp].self, from: data)
        else { return [] }
        var seenLowerIDs = Set<String>()
        return decoded.filter { entry in
            guard LockedApp.canLock(bundleIdentifier: entry.bundleIdentifier) else { return false }
            return seenLowerIDs.insert(entry.bundleIdentifier.lowercased()).inserted
        }
    }

    fileprivate static func decodeRelockPolicy(from defaults: UserDefaults) -> RelockPolicy {
        guard let data = defaults.data(forKey: Key.defaultAppRelockPolicy),
            let decoded = try? JSONDecoder().decode(RelockPolicy.self, from: data)
        else { return .everyTime }
        return decoded
    }
}

extension UserDefaults {
    fileprivate func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) as? Bool ?? defaultValue
    }
}
