//
//  NotchGeometry+Screen.swift
//  glance
//
//  AppKit screen measurement and settings-backed sizing helpers for NotchGeometry.
//

import AppKit
import CoreGraphics

extension NotchGeometry {
    @MainActor
    static func windowSize(for style: NotchPanelStyle) -> CGSize {
        switch style {
        case .notch:
            let contentWidth = max(notchOpenSize.width, OnboardingMetrics.maxPanelWidth)
            let contentHeight = max(notchOpenSize.height, OnboardingMetrics.maxPanelHeight(for: .notch))
            return CGSize(
                width: contentWidth + notchShadowPadding * 2 + hoverBump,
                height: contentHeight + notchShadowPadding + hoverBump
            )
        case .pill:
            let contentWidth = max(pillOpenSize.width, OnboardingMetrics.maxPanelWidth)
            let contentHeight = max(pillOpenSize.height, OnboardingMetrics.maxPanelHeight(for: .pill))
            return CGSize(
                width: contentWidth + pillShadowPadding * 2 + hoverBump,
                // `pillTopGap` since the detached pill's panel is pushed down by that much.
                height: contentHeight + pillShadowPadding + hoverBump + pillTopGap
            )
        }
    }

    @MainActor
    static func forMainScreen() -> NotchGeometry {
        guard let screen = NSScreen.main else {
            return NotchGeometry(closedSize: pillClosedSize, isPhysicalNotch: false)
        }
        return forScreen(screen)
    }

    @MainActor
    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        guard screen.safeAreaInsets.top > 0 else {
            return NotchGeometry(closedSize: pillClosedSize, isPhysicalNotch: false)
        }

        // Width derived from the menu-bar areas flanking the notch — nil/empty on
        // displays without one, hence the safeAreaInsets check above.
        let leftPadding = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = screen.auxiliaryTopRightArea?.width ?? 0
        // These are all AppKit point values. Do not impose a model-derived minimum:
        // the camera housing on a 13-inch MacBook Air is legitimately narrower than
        // the 200-point housing on several MacBook Pro models.
        let measuredWidth = screen.frame.width - leftPadding - rightPadding
        let measuredHeight = screen.safeAreaInsets.top
        let settings = GlanceSettings.shared
        let closedSize = adjustedPhysicalNotchSize(
            measuredWidth: measuredWidth,
            measuredHeight: measuredHeight,
            widthAdjustment: settings.notchWidthAdjustment,
            heightAdjustment: settings.notchHeightAdjustment
        )

        return NotchGeometry(closedSize: closedSize, isPhysicalNotch: true)
    }

    /// Picks the screen the overlay should show on. Uses a pinned display (`preferredDisplayID`)
    /// whenever connected, falling back to an active screen when the current display topology
    /// has Face Unlock enabled (e.g. clamshell External Only or transient wake reconfiguration).
    @MainActor
    static func preferredScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let mainScreen = NSScreen.main
        let candidates = screens.map { screen in
            DisplayCandidate(
                id: screen.stableDisplayID,
                hasPhysicalNotch: screen.safeAreaInsets.top > 0,
                isMain: screen === mainScreen
            )
        }
        let allowFallback = GlanceSettings.shared.isFaceUnlockEnabled(for: DisplayContext.current())
        guard
            let index = preferredDisplayIndex(
                in: candidates,
                preferredDisplayID: GlanceSettings.shared.preferredDisplayID,
                allowFallbackWhenPinnedMissing: allowFallback
            )
        else { return nil }
        return screens[index]
    }
}

extension NSScreen {
    /// Stable enough to persist a user's display choice across launches — the only
    /// per-display identity AppKit exposes.
    var stableDisplayID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return String(number)
    }

    /// True for the Mac's own display (vs. an external monitor) — used to pin the Face
    /// Unlock panel there while the built-in camera is selected.
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(number) != 0
    }
}
