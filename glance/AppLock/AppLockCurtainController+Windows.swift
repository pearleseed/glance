//
//  AppLockCurtainController+Windows.swift
//  glance
//
//  Window-list enumeration, Mission Control backdrop detection, and repeating-timer
//  support for AppLockCurtainController.
//

import AppKit
import CoreGraphics
import Foundation

extension AppLockCurtainController {
    static func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func extractTargetWindows(
        for pid: pid_t,
        from rawList: [[String: Any]],
        primaryHeight: CGFloat,
        screenFrames: [CGRect]
    ) -> [TargetWindow] {
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

        var results: [TargetWindow] = []
        for entry in rawList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                ownerPID == pid,
                let windowNumber = entry[kCGWindowNumber as String] as? Int,
                windowNumber > 0
            else { continue }

            let layer = entry[kCGWindowLayer as String] as? Int ?? normalLayer
            guard layer >= normalLayer && layer < dockLayer else { continue }

            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { continue }

            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let cgBounds = CGRect(dictionaryRepresentation: boundsDict),
                cgBounds.width >= 40,
                cgBounds.height >= 40
            else { continue }

            let appKitFrame = NSRect(
                x: cgBounds.origin.x,
                y: primaryHeight - cgBounds.origin.y - cgBounds.height,
                width: cgBounds.width,
                height: cgBounds.height
            )

            guard screenFrames.contains(where: { $0.intersects(appKitFrame) }) else { continue }

            let isFullscreen = screenFrames.contains { screenFrame in
                abs(appKitFrame.width - screenFrame.width) <= 2
                    && abs(appKitFrame.height - screenFrame.height) <= 2
            }

            results.append(
                TargetWindow(
                    id: CGWindowID(windowNumber),
                    layer: layer,
                    frame: appKitFrame,
                    isFullscreen: isFullscreen
                )
            )
        }
        return results
    }

    static func selectPrimaryWindowID(from windows: [TargetWindow]) -> CGWindowID? {
        if let firstLarge = windows.first(where: { $0.frame.width >= 220 && $0.frame.height >= 180 }) {
            return firstLarge.id
        }
        return windows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        })?.id
    }

    /// Detects Dock's Mission Control / App Exposé backdrop window without requiring Screen Recording permission.
    static func isMissionControlActive(
        in rawList: [[String: Any]],
        dockPID: pid_t?,
        screenSizes: [CGSize]
    ) -> Bool {
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))

        for entry in rawList {
            let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32
            let ownerName = entry[kCGWindowOwnerName as String] as? String
            let isDock = (dockPID != nil && ownerPID == dockPID) || ownerName == "Dock"
            guard isDock else { continue }

            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { continue }

            if let windowName = entry[kCGWindowName as String] as? String,
                windowName.localizedCaseInsensitiveContains("Mission Control")
            {
                return true
            }

            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            guard layer >= normalLayer && layer < mainMenuLayer && layer != dockLayer else { continue }

            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let cgBounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            let coversScreen = screenSizes.contains { size in
                cgBounds.width >= size.width * 0.85 && cgBounds.height >= size.height * 0.85
            }
            if coversScreen {
                return true
            }
        }
        return false
    }
}

/// Owns a repeating `Timer` outside MainActor isolation so `deinit` can invalidate safely under Swift 6.
nonisolated final class AppLockRepeatingTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Timer?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    func set(_ newTimer: Timer) {
        lock.lock()
        let old = timer
        timer = newTimer
        lock.unlock()
        old?.invalidate()
    }

    func invalidate() {
        lock.lock()
        let old = timer
        timer = nil
        lock.unlock()
        old?.invalidate()
    }

    deinit {
        invalidate()
    }
}
