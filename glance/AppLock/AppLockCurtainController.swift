//
//  AppLockCurtainController.swift
//  glance
//
//  Attaches one borderless non-activating NSPanel per visible window of the challenged app,
//  ordered directly above that window in z-order via CGWindowListCopyWindowInfo, and detects
//  Dock's Mission Control backdrop so the challenged app hides instead of leaking thumbnails.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// MUST remain a concrete non-generic subclass to avoid the Swift 6.2/6.4 Release inliner crash.
private final class FirstMouseHostingView: NSHostingView<AppLockCurtainView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class CurtainPanel: NSPanel {
    private let hostingView: FirstMouseHostingView
    private(set) var isPrimary: Bool
    private(set) var isFullscreen: Bool

    init(
        contentRect: NSRect,
        viewModel: AppLockCurtainViewModel,
        isPrimary: Bool,
        isFullscreen: Bool
    ) {
        self.isPrimary = isPrimary
        self.isFullscreen = isFullscreen
        let rootView = AppLockCurtainView(model: viewModel, isPrimary: isPrimary, isFullscreen: isFullscreen)
        self.hostingView = FirstMouseHostingView(rootView: rootView)
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false

        hostingView.frame = NSRect(origin: .zero, size: contentRect.size)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(viewModel: AppLockCurtainViewModel, isPrimary: Bool, isFullscreen: Bool) {
        guard self.isPrimary != isPrimary || self.isFullscreen != isFullscreen else { return }
        self.isPrimary = isPrimary
        self.isFullscreen = isFullscreen
        hostingView.rootView = AppLockCurtainView(model: viewModel, isPrimary: isPrimary, isFullscreen: isFullscreen)
    }
}

@MainActor
struct CurtainPresentation {
    let challengeID: UUID
    let targetPID: pid_t
    let appName: String
    let appIcon: NSImage
    let onRetry: () -> Void
    let onUseSystemAuth: () -> Void
    let onMissionControlDetected: () -> Void
}

@MainActor
final class AppLockCurtainController {
    private struct TargetWindow {
        let id: CGWindowID
        let layer: Int
        let frame: NSRect
        let isFullscreen: Bool
    }

    private var activeChallengeID: UUID?
    private var activeTargetPID: pid_t?
    private var activeViewModel: AppLockCurtainViewModel?
    private var onMissionControlDetected: (() -> Void)?

    private var panelsByWindowID: [CGWindowID: CurtainPanel] = [:]
    private var fallbackPanel: CurtainPanel?
    private let timerBox = AppLockRepeatingTimer()
    private let observerBox = NotificationObserverBox()

    private var cachedDockPID: pid_t?
    private var cachedScreenFrames: [CGRect] = []
    private var cachedPrimaryHeight: CGFloat = 0
    private var currentSyncInterval: TimeInterval?
    private var lastWindowActivityAt: TimeInterval = 0
    private var lastTrackedWindows: [CGWindowID: CGRect] = [:]

    private static let activeSyncInterval: TimeInterval = 0.06
    private static let activeSyncTolerance: TimeInterval = 0.01
    private static let stationarySyncInterval: TimeInterval = 0.12
    private static let stationarySyncTolerance: TimeInterval = 0.02
    private static let activeWindowBurstDuration: TimeInterval = 0.4
    private nonisolated static let dockBundleIdentifier = "com.apple.dock"

    init() {
        registerEnvironmentObservers()
    }

    func present(_ request: CurtainPresentation) {
        dismiss()

        let viewModel = AppLockCurtainViewModel(
            appName: request.appName,
            appIcon: request.appIcon,
            statusMessage: "Looking for your face…",
            isScanning: true,
            canRetry: false,
            onRetry: request.onRetry,
            onUseSystemAuth: request.onUseSystemAuth
        )

        activeChallengeID = request.challengeID
        activeTargetPID = request.targetPID
        activeViewModel = viewModel
        onMissionControlDetected = request.onMissionControlDetected
        lastWindowActivityAt = ProcessInfo.processInfo.systemUptime
        lastTrackedWindows = [:]

        refreshWindows()
        if activeChallengeID == request.challengeID {
            updateSyncCadence(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    func updateStatus(
        challengeID: UUID,
        message: String,
        isScanning: Bool,
        canRetry: Bool
    ) {
        guard activeChallengeID == challengeID, let viewModel = activeViewModel else { return }
        viewModel.statusMessage = message
        viewModel.isScanning = isScanning
        viewModel.canRetry = canRetry
    }

    func dismiss(ifMatching challengeID: UUID? = nil) {
        if let challengeID, activeChallengeID != challengeID {
            return
        }

        stopSyncTimer()
        activeChallengeID = nil
        activeTargetPID = nil
        activeViewModel = nil
        onMissionControlDetected = nil
        lastWindowActivityAt = 0
        lastTrackedWindows.removeAll()

        for panel in panelsByWindowID.values {
            panel.orderOut(nil)
            panel.close()
        }
        panelsByWindowID.removeAll()

        if let fallbackPanel {
            fallbackPanel.orderOut(nil)
            fallbackPanel.close()
            self.fallbackPanel = nil
        }
    }

    private func registerEnvironmentObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerBox.observe(center: workspaceCenter, forName: NSWorkspace.didLaunchApplicationNotification) {
            [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.dockBundleIdentifier else { return }
            let pid = app?.processIdentifier
            Task { @MainActor [weak self] in
                self?.cachedDockPID = pid
            }
        }
        observerBox.observe(center: workspaceCenter, forName: NSWorkspace.didTerminateApplicationNotification) {
            [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isDockBundle = app?.bundleIdentifier == Self.dockBundleIdentifier
            let pid = app?.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isDockBundle || (pid != nil && self.cachedDockPID == pid) {
                    self.cachedDockPID = nil
                }
            }
        }
        observerBox.observe(center: .default, forName: NSApplication.didChangeScreenParametersNotification) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshScreenCache()
            }
        }
    }

    private func dockPID() -> pid_t? {
        if let cachedDockPID {
            return cachedDockPID
        }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .first?
            .processIdentifier
        cachedDockPID = pid
        return pid
    }

    private func ensureScreenCache() -> (screenFrames: [CGRect], primaryHeight: CGFloat) {
        if cachedScreenFrames.isEmpty || cachedPrimaryHeight <= 0 {
            refreshScreenCache()
        }
        return (cachedScreenFrames, cachedPrimaryHeight)
    }

    private func refreshScreenCache() {
        cachedScreenFrames = NSScreen.screens.map(\.frame)
        cachedPrimaryHeight = CGDisplayBounds(CGMainDisplayID()).height
    }

    private func stopSyncTimer() {
        timerBox.invalidate()
        currentSyncInterval = nil
    }

    private func updateSyncCadence(now: TimeInterval) {
        guard activeChallengeID != nil else {
            stopSyncTimer()
            return
        }

        let isActiveBurst = (now - lastWindowActivityAt) < Self.activeWindowBurstDuration
        let desiredInterval = isActiveBurst ? Self.activeSyncInterval : Self.stationarySyncInterval
        let desiredTolerance = isActiveBurst ? Self.activeSyncTolerance : Self.stationarySyncTolerance
        guard currentSyncInterval != desiredInterval else { return }

        currentSyncInterval = desiredInterval
        let timer = Timer(timeInterval: desiredInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshWindows()
            }
        }
        timer.tolerance = desiredTolerance
        RunLoop.main.add(timer, forMode: .common)
        timerBox.set(timer)
    }

    private func refreshWindows() {
        guard activeChallengeID != nil,
            let targetPID = activeTargetPID,
            let viewModel = activeViewModel
        else { return }

        guard
            let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return
        }

        let (screenFrames, primaryHeight) = ensureScreenCache()

        if Self.isMissionControlActive(
            in: rawList,
            dockPID: dockPID(),
            screenSizes: screenFrames.map(\.size)
        ) {
            let callback = onMissionControlDetected
            callback?()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let targetWindows = Self.extractTargetWindows(
            for: targetPID,
            from: rawList,
            primaryHeight: primaryHeight,
            screenFrames: screenFrames
        )

        var trackedSnapshot: [CGWindowID: CGRect] = [:]
        trackedSnapshot.reserveCapacity(targetWindows.count)
        for target in targetWindows {
            trackedSnapshot[target.id] = target.frame
        }
        if trackedSnapshot != lastTrackedWindows {
            lastTrackedWindows = trackedSnapshot
            lastWindowActivityAt = now
        }

        if targetWindows.isEmpty {
            clearPerWindowPanels()
            showFallbackPanelIfNeeded(viewModel: viewModel)
        } else {
            dismissFallbackPanel()

            let primaryWindowID = Self.selectPrimaryWindowID(from: targetWindows)
            pruneStalePanels(keeping: Set(targetWindows.map(\.id)))
            let zOrderIndexByWindowNumber = Self.zOrderIndexMap(from: rawList)

            for target in targetWindows {
                syncPanel(
                    for: target,
                    viewModel: viewModel,
                    isPrimary: target.id == primaryWindowID,
                    zOrderIndexByWindowNumber: zOrderIndexByWindowNumber
                )
            }
        }

        updateSyncCadence(now: now)
    }

    private func pruneStalePanels(keeping activeIDs: Set<CGWindowID>) {
        for (windowID, panel) in panelsByWindowID where !activeIDs.contains(windowID) {
            panel.orderOut(nil)
            panel.close()
            panelsByWindowID.removeValue(forKey: windowID)
        }
    }

    private static func zOrderIndexMap(from rawList: [[String: Any]]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        map.reserveCapacity(rawList.count)
        for (index, entry) in rawList.enumerated() {
            if let num = entry[kCGWindowNumber as String] as? Int {
                map[num] = index
            }
        }
        return map
    }

    private func syncPanel(
        for target: TargetWindow,
        viewModel: AppLockCurtainViewModel,
        isPrimary: Bool,
        zOrderIndexByWindowNumber: [Int: Int]
    ) {
        let panel: CurtainPanel
        if let existing = panelsByWindowID[target.id] {
            panel = existing
            panel.update(viewModel: viewModel, isPrimary: isPrimary, isFullscreen: target.isFullscreen)
            if panel.frame != target.frame {
                panel.setFrame(target.frame, display: true)
            }
        } else {
            panel = CurtainPanel(
                contentRect: target.frame,
                viewModel: viewModel,
                isPrimary: isPrimary,
                isFullscreen: target.isFullscreen
            )
            panelsByWindowID[target.id] = panel
        }

        let desiredLevel = NSWindow.Level(rawValue: target.layer)
        if panel.level != desiredLevel {
            panel.level = desiredLevel
        }

        let targetNum = Int(target.id)
        let isDirectlyAbove =
            panel.isVisible
            && zOrderIndexByWindowNumber[panel.windowNumber]
                .flatMap { panelIdx in zOrderIndexByWindowNumber[targetNum].map { panelIdx == $0 - 1 } }
                ?? false
        if !isDirectlyAbove {
            panel.order(.above, relativeTo: targetNum)
        }
    }

    private func clearPerWindowPanels() {
        for panel in panelsByWindowID.values {
            panel.orderOut(nil)
            panel.close()
        }
        panelsByWindowID.removeAll()
    }

    private func showFallbackPanelIfNeeded(viewModel: AppLockCurtainViewModel) {
        guard let screen = Self.preferredScreen() else {
            dismissFallbackPanel()
            return
        }
        let size = NSSize(width: 400, height: 280)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        let frame = NSRect(origin: origin, size: size)

        if let fallbackPanel {
            fallbackPanel.update(viewModel: viewModel, isPrimary: true, isFullscreen: false)
            if fallbackPanel.frame != frame {
                fallbackPanel.setFrame(frame, display: true)
            }
            if !fallbackPanel.isVisible {
                fallbackPanel.orderFrontRegardless()
            }
            return
        }

        let panel = CurtainPanel(
            contentRect: frame,
            viewModel: viewModel,
            isPrimary: true,
            isFullscreen: false
        )
        panel.level = .floating
        panel.orderFrontRegardless()
        fallbackPanel = panel
    }

    private func dismissFallbackPanel() {
        guard let fallbackPanel else { return }
        fallbackPanel.orderOut(nil)
        fallbackPanel.close()
        self.fallbackPanel = nil
    }

    private static func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func extractTargetWindows(
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

    private static func selectPrimaryWindowID(from windows: [TargetWindow]) -> CGWindowID? {
        if let firstLarge = windows.first(where: { $0.frame.width >= 220 && $0.frame.height >= 180 }) {
            return firstLarge.id
        }
        return windows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        })?.id
    }

    /// Detects Dock's Mission Control / App Exposé backdrop window without requiring Screen Recording permission.
    private static func isMissionControlActive(
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
