//
//  SettingsWindowView.swift
//  glance
//
//  Root layout: one `.sidebar` material behind the whole window, the
//  selected page scrolling beneath a transparent header (traffic lights and
//  the session lock button) and a floating tab bar pinned to the bottom.
//

import AppKit
import SwiftUI
import os

/// A closure `onPreferenceChange` can actually consume — that API requires
/// `Value: Equatable`, which a bare closure can never be. Equality is by
/// identity (a fresh `id` per instance), so this is deliberately never
/// equal to a previous instance.
struct HeaderAction: Equatable {
    private let id = UUID()
    let perform: () -> Void

    static func == (lhs: HeaderAction, rhs: HeaderAction) -> Bool { lhs.id == rhs.id }
}

/// Lets one page (today, only Camera's "Refresh camera list") publish a
/// trailing action into the shared header without the header needing
/// to know that page's state. Switching away resolves back to `defaultValue`.
struct HeaderTrailingActionKey: PreferenceKey {
    static var defaultValue: HeaderAction? { nil }
    static func reduce(value: inout HeaderAction?, nextValue: () -> HeaderAction?) {
        value = nextValue() ?? value
    }
}

struct SettingsWindowView: View {
    let environment: AppEnvironment
    @State private var selection: SettingsTab = .general
    @State private var headerTrailingAction: HeaderAction?
    @State private var isWindowVisible = true
    @Environment(\.dismissWindow) private var dismissWindow

    /// Defense-in-depth, not the primary gate: Settings is `.suppressed` at
    /// launch and `AppDelegate.revealSettingsWindow()` refuses to open it
    /// while onboarding is incomplete. A real user should never hit this
    /// branch, only a blank frame before `dismissWindow` closes it.
    var body: some View {
        if GlanceSettings.shared.hasCompletedOnboarding,
            environment.allowsSettingsWindowPresentation
        {
            settingsContent
        } else {
            Color.clear
                .background(
                    SuppressedWindowHider {
                        !GlanceSettings.shared.hasCompletedOnboarding
                            || !environment.allowsSettingsWindowPresentation
                    }
                )
                .onAppear { dismissWindow(id: "settings") }
        }
    }

    private var settingsContent: some View {
        ZStack {
            Color.clear
            if isWindowVisible {
                ZStack {
                    VisualEffectView()
                    SettingsMetrics.windowTintColor
                    contentPage
                }
                // Cascades to every native control so nothing falls back to the
                // system accent. Only takes effect because the window can become
                // key; see WindowConfiguringView.configure.
                .tint(GlanceTheme.accent)
                // A native swipe-event monitor observes the hosting window so it
                // recognizes two-finger trackpad swipes across the full Settings UI,
                // including the header, page content, and tab bar.
                .background(
                    SettingsTabSwipeRecognizer { direction in
                        selectAdjacentTab(for: direction)
                    }
                )
            }
        }
        // No `.clipShape`, manual stroke, or `.shadow` on the outer window —
        // deliberately: the window keeps its native background (see
        // WindowConfiguringView), so AppKit masks it to the real macOS
        // corner and draws its own edge highlight and shadow for free.
        //
        // Fills whatever size the window is (set once by
        // WindowConfiguringView) — a fixed size here combined with
        // content-size resizability made SwiftUI keep re-adding a titlebar
        // band to the window height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Outer `ZStack` (not `Group`) gives `WindowConfigurator` a single stable
        // structural identity across `isWindowVisible` toggles: `Group` forwards
        // modifiers into each conditional branch, destroying and recreating
        // `WindowConfiguringView` on every close/reopen.
        .background(
            WindowConfigurator { visible in
                if isWindowVisible != visible {
                    isWindowVisible = visible
                }
                if visible {
                    applyRequestedSettingsTabIfNeeded()
                } else {
                    selection = .general
                    headerTrailingAction = nil
                }
            }
        )
        .onAppear { applyRequestedSettingsTabIfNeeded() }
        .onChange(of: environment.requestedSettingsTab) { _, _ in
            applyRequestedSettingsTabIfNeeded()
        }
        // Backup reset if `settingsContent` unmounts (e.g. onboarding/presentation guard);
        // normal window close resets `selection` via `WindowConfigurator` since `Window` keeps `@State` alive.
        .onDisappear { selection = .general }
    }

    private func applyRequestedSettingsTabIfNeeded() {
        guard isWindowVisible, let tab = environment.requestedSettingsTab else { return }
        let allowedTabs = SettingsTab.visibleTabs(includingDebug: environment.isDebugSectionRevealed)
        if allowedTabs.contains(tab) {
            selection = tab
        }
        environment.requestedSettingsTab = nil
    }

    /// The header and tab bar float over the scroll content so scrolled rows
    /// pass underneath them rather than being pushed aside.
    private var contentPage: some View {
        Group {
            if #available(macOS 26, *) {
                scrollContent(topPadding: 4)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        header
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                scrollContent(topPadding: SettingsMetrics.headerHeight + 4)
                    .overlay(alignment: .top) {
                        // Blur first, header content on top — so it fades whatever
                        // scrolls beneath both without ever softening the buttons
                        // themselves.
                        ZStack(alignment: .top) {
                            ProgressiveHeaderBlur(height: SettingsMetrics.headerBlurHeight)
                            header
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            SettingsTabBar(
                selection: $selection,
                isDebugSectionRevealed: environment.isDebugSectionRevealed
            )
            .padding(.bottom, SettingsMetrics.tabBarBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(HeaderTrailingActionKey.self) { headerTrailingAction = $0 }
    }

    private func scrollContent(topPadding: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            pageBody
                .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, SettingsMetrics.pageBottomInset)
                // Without an explicit top alignment the scroll view
                // centers short pages vertically, leaving a large gap
                // between the header and the first row.
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Leading side stays empty — the window's real traffic lights are drawn
    /// there by AppKit (see WindowConfiguringView). No background of its
    /// own; on macOS 14–15 `ProgressiveHeaderBlur` sits behind it in
    /// `contentPage`, while macOS 26+ uses native `.safeAreaInset(edge: .top)`
    /// + `.scrollEdgeEffectStyle(.soft, for: .top)`.
    private var header: some View {
        HStack(spacing: 8) {
            Spacer()

            if let headerTrailingAction {
                Button(action: headerTrailingAction.perform) {
                    Image(systemName: refreshSymbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .frame(width: SettingsMetrics.headerButtonHeight, height: SettingsMetrics.headerButtonHeight)
                        .background(Circle().fill(SettingsMetrics.rowColor))
                        .overlay(
                            Circle()
                                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh camera list")
            }

            SessionLockButton(pocController: environment.pocController)
        }
        .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
        .frame(height: SettingsMetrics.headerHeight)
    }

    private var refreshSymbolName: String {
        if #available(macOS 15, *) {
            "arrow.trianglehead.clockwise.rotate.90"
        } else {
            "arrow.clockwise"
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            switch selection {
            case .general:
                GeneralSettingsPage(
                    coordinator: environment.faceUnlockCoordinator,
                    pocController: environment.pocController
                )
            case .yourFace:
                YourFaceSettingsPage(environment: environment)
            case .apps:
                AppLockSettingsPage(pocController: environment.pocController)
            case .sudo:
                SudoSettingsPage(environment: environment)
            case .password:
                PasswordSettingsPage(pocController: environment.pocController)
            case .camera:
                CameraSettingsPage(pocController: environment.pocController)
            case .recognition:
                RecognitionSettingsPage(
                    coordinator: environment.faceUnlockCoordinator,
                    pocController: environment.pocController
                )
            case .about:
                AboutSettingsPage(updater: environment.updater, environment: environment)
            case .debugFaceLab:
                LazyFaceLabPage(pipeline: environment.recognitionPipeline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectAdjacentTab(for direction: SettingsTabSwipeDirection) {
        let tabs = SettingsTab.visibleTabs(includingDebug: environment.isDebugSectionRevealed)
        guard let currentIndex = tabs.firstIndex(of: selection) else { return }

        let adjacentIndex: Int
        switch direction {
        case .left:
            adjacentIndex = currentIndex + 1
        case .right:
            adjacentIndex = currentIndex - 1
        }

        guard tabs.indices.contains(adjacentIndex) else { return }
        withAnimation(SettingsMetrics.tabSelectionAnimation) {
            selection = tabs[adjacentIndex]
        }
    }
}

/// Face Lab is deliberately hidden behind a debug gesture, so we defer creating
/// its controller and camera manager until the tab is selected while reusing
/// the shared `AppEnvironment.recognitionPipeline`.
private struct LazyFaceLabPage: View {
    let pipeline: FaceRecognitionPipeline
    @State private var controller: FaceLabController?

    var body: some View {
        Group {
            if let controller {
                FaceLabView(controller: controller)
            } else {
                ProgressView("Loading Face Lab…")
                    .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
                    .task {
                        // Yield once so the loading state can draw before creating the controller.
                        await Task.yield()
                        guard !Task.isCancelled, controller == nil else { return }
                        controller = FaceLabController(pipeline: pipeline)
                    }
            }
        }
        .onDisappear {
            controller?.stop()
            controller = nil
        }
    }
}

private enum SettingsTabSwipeDirection {
    case left
    case right
}

/// Observes horizontal trackpad scroll gestures for this Settings window. Unlike
/// a transparent SwiftUI `DragGesture`, this does not compete with buttons or
/// vertical scrolling.
private struct SettingsTabSwipeRecognizer: NSViewRepresentable {
    let onSwipe: (SettingsTabSwipeDirection) -> Void

    func makeNSView(context: Context) -> SwipeHostingView {
        SwipeHostingView(onSwipe: onSwipe)
    }

    func updateNSView(_ view: SwipeHostingView, context: Context) {
        view.onSwipe = onSwipe
        view.installEventMonitorIfNeeded()
    }
}

private nonisolated final class LocalEventMonitorBox: Sendable {
    private nonisolated struct Monitor: @unchecked Sendable {
        let token: Any
    }

    private let state = OSAllocatedUnfairLock<Monitor?>(initialState: nil)

    var isInstalled: Bool {
        state.withLock { $0 != nil }
    }

    func install(_ token: Any?) {
        let monitor = token.map { Monitor(token: $0) }
        let previous = state.withLock { current in
            let old = current
            current = monitor
            return old
        }
        if let previous {
            NSEvent.removeMonitor(previous.token)
        }
    }

    func remove() {
        install(nil)
    }

    deinit {
        remove()
    }
}

private final class SwipeHostingView: NSView {
    var onSwipe: (SettingsTabSwipeDirection) -> Void
    private let eventMonitorBox = LocalEventMonitorBox()
    private var observerBox: NotificationObserverBox?
    private weak var observedWindow: NSWindow?
    private var accumulatedHorizontalScroll: CGFloat = 0
    private var accumulatedVerticalScroll: CGFloat = 0
    private var didNavigateThisGesture = false

    /// Prevents a small diagonal scroll from switching pages, while remaining
    /// comfortably below the distance of an intentional two-finger swipe.
    private let swipeDistanceThreshold: CGFloat = 36

    init(onSwipe: @escaping (SettingsTabSwipeDirection) -> Void) {
        self.onSwipe = onSwipe
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            removeEventMonitor()
            observerBox = nil
            observedWindow = nil
            return
        }

        if observedWindow !== window {
            installWindowCloseObserver(for: window)
        }
        installEventMonitorIfNeeded()
    }

    func installEventMonitorIfNeeded() {
        guard window != nil, !eventMonitorBox.isInstalled else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, event.hasPreciseScrollingDeltas else {
                return event
            }
            self.handleTrackpadScroll(event)
            return event
        }
        eventMonitorBox.install(monitor)
    }

    private func installWindowCloseObserver(for window: NSWindow) {
        let box = NotificationObserverBox()
        observedWindow = window
        box.observe(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeEventMonitor()
            }
        }
        observerBox = box
    }

    private func removeEventMonitor() {
        eventMonitorBox.remove()
        resetSwipeTracking()
    }

    private func handleTrackpadScroll(_ event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            resetSwipeTracking()
        }

        guard !didNavigateThisGesture else {
            // Do not reset at `.ended`: the same physical swipe can still emit
            // momentum events, which must not advance a second page.
            return
        }

        accumulatedHorizontalScroll += event.scrollingDeltaX
        accumulatedVerticalScroll += event.scrollingDeltaY

        let horizontalDistance = abs(accumulatedHorizontalScroll)
        let verticalDistance = abs(accumulatedVerticalScroll)
        guard horizontalDistance >= swipeDistanceThreshold,
            horizontalDistance > verticalDistance * 1.5
        else { return }

        didNavigateThisGesture = true
        onSwipe(accumulatedHorizontalScroll < 0 ? .left : .right)
    }

    private func resetSwipeTracking() {
        accumulatedHorizontalScroll = 0
        accumulatedVerticalScroll = 0
        didNavigateThisGesture = false
    }
}

/// Keeps an unrequested SwiftUI `Window` scene invisible, ordered out, and
/// non-restorable before `dismissWindow(id: "settings")` closes it (for
/// example on macOS 14 launch where `.defaultLaunchBehavior(.suppressed)` is
/// unavailable, or if SwiftUI presents the scene on a later runloop turn).
private struct SuppressedWindowHider: NSViewRepresentable {
    let shouldSuppress: @MainActor @Sendable () -> Bool

    func makeNSView(context: Context) -> SuppressedWindowHiderView {
        SuppressedWindowHiderView(shouldSuppress: shouldSuppress)
    }

    func updateNSView(_ nsView: SuppressedWindowHiderView, context: Context) {
        nsView.shouldSuppress = shouldSuppress
        nsView.hideHostingWindow()
    }
}

private final class SuppressedWindowHiderView: NSView {
    var shouldSuppress: @MainActor @Sendable () -> Bool

    init(shouldSuppress: @escaping @MainActor @Sendable () -> Bool) {
        self.shouldSuppress = shouldSuppress
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hide(newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideHostingWindow()
    }

    func hideHostingWindow() {
        hide(window)
    }

    private func hide(_ targetWindow: NSWindow?) {
        guard let targetWindow, shouldSuppress() else { return }
        targetWindow.alphaValue = 0
        targetWindow.isRestorable = false
        targetWindow.orderOut(nil)
        let shouldSuppress = self.shouldSuppress
        DispatchQueue.main.async { [weak targetWindow] in
            MainActor.assumeIsolated {
                guard let targetWindow, shouldSuppress() else { return }
                targetWindow.orderOut(nil)
                if !NSApp.windows.contains(where: { $0 !== targetWindow && $0.canBecomeMain && $0.isVisible }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
