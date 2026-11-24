//
//  SettingsWindowHelpers.swift
//  glance
//
//  AppKit bridges for the Settings window: appearance-adaptive backdrop blur
//  and one-shot NSWindow chrome/size configuration.
//

import AppKit
import SwiftUI

/// Wraps an `NSVisualEffectView` for the window's background blur.
///
/// `.sidebar`, not `.hudWindow` — Apple's own purpose-built material for
/// this element (Finder/Mail/Xcode sidebars), keeping compositing on
/// WindowServer's hardware fast-path during scrolling without CoreImage
/// layer filters.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.followsWindowActiveState`, not `.active` — `.active` pins the
        // material on permanently, so the window stays translucent even
        // when it's neither key nor main.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Configures the hosting `NSWindow`'s chrome once it's available: fully
/// borderless (see `WindowConfiguringView` for why), fixed-size, and
/// background-draggable since there's no title bar to grab.
struct WindowConfigurator: NSViewRepresentable {
    var onVisibilityChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> WindowConfiguringView {
        let view = WindowConfiguringView()
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ nsView: WindowConfiguringView, context: Context) {
        nsView.onVisibilityChange = onVisibilityChange
    }
}

/// Makes the hosting window an ordinary macOS window that simply doesn't
/// draw a title bar.
///
/// Note: no `setFrame`/`setContentSize` on every layout pass — that fights
/// SwiftUI's resize-to-fit-content pass in a mutual invalidation loop and
/// can crash. Size and chrome are applied once per `NSWindow` instance, and
/// this view never orders a closed window back on screen (window presentation
/// belongs solely to `AppDelegate.revealSettingsWindow()`).
final class WindowConfiguringView: NSView {
    /// Tracks `NSWindow` instances already configured so even if SwiftUI ever
    /// recreates this view, one-shot chrome/frame setup never re-runs on the
    /// same window.
    private static let configuredWindows = NSHashTable<NSWindow>.weakObjects()

    var onVisibilityChange: ((Bool) -> Void)?
    private var visibilityObservation: NSKeyValueObservation?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            visibilityObservation?.invalidate()
            visibilityObservation = nil
            observedWindow = nil
            return
        }

        if observedWindow !== window {
            installVisibilityObserver(for: window)
        }

        // Deferred by one runloop turn — mutating the window synchronously
        // here (mid SwiftUI render pass) corrupts an AppKit-internal lock
        // and hard-crashes in `_NSSetBoolValueAndNotify`.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, window.isVisible else { return }
            self.configureIfNeeded(window)
            self.onVisibilityChange?(true)
        }
    }

    private func installVisibilityObserver(for window: NSWindow) {
        visibilityObservation?.invalidate()
        observedWindow = window

        // KVO on `NSWindow.isVisible` fires strictly on real on-screen / off-screen
        // transitions — no noisy callbacks on focus/occlusion churn and no missed
        // reopens when the window orders front before the app becomes key.
        visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] window, _ in
            let handleChange: @MainActor () -> Void = { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                if window.isVisible {
                    if !Self.configuredWindows.contains(window) {
                        DispatchQueue.main.async { [weak self, weak window] in
                            guard let self, let window, self.window === window, window.isVisible else { return }
                            self.configureIfNeeded(window)
                        }
                    }
                    self.onVisibilityChange?(true)
                } else if !window.isMiniaturized {
                    self.onVisibilityChange?(false)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(handleChange)
            } else {
                Task { @MainActor in handleChange() }
            }
        }
    }

    private func configureIfNeeded(_ window: NSWindow) {
        guard !Self.configuredWindows.contains(window) else { return }
        Self.configuredWindows.add(window)
        Self.configure(window)
    }

    private static func configure(_ window: NSWindow) {
        // `.fullSizeContentView` + transparent titlebar + hidden title keeps
        // real titlebar machinery (traffic lights, native corner mask,
        // active/inactive appearance) without drawing a chrome band.
        //
        // `.titled` is also load-bearing: AppKit only lets a window become
        // key if it has a title bar, and a never-key window draws every
        // control desaturated with tint ignored.
        //
        // `.miniaturizable` makes the yellow button work; `.resizable` is
        // deliberately absent, which natively disables the green button too.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // An empty, item-less `NSToolbar` with `.unified` style is what
        // buys the macOS 26 corner radius (measured: 17.5pt with no
        // toolbar vs. Finder's own radius with `.unified`). Nothing of it
        // is visible; it only reserves the band the traffic lights sit in.
        let toolbar = NSToolbar(identifier: "GlanceSettingsToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.isMovableByWindowBackground = true
        window.hasShadow = true
        if #unavailable(macOS 15) {
            window.isRestorable = false
        }

        // Deliberately NOT `isOpaque = false` / `backgroundColor = .clear` —
        // that pairing stops AppKit from masking to the window's own native
        // rounded frame. Left at defaults, the system mask applies and the
        // corner is the real thing. Translucency still works since the
        // `NSVisualEffectView` behind the content blends on its own.
        let target = SettingsMetrics.windowSize
        var frame = window.frame
        frame.origin.y += frame.height - target.height  // keep the top edge fixed
        frame.size = NSSize(width: target.width, height: target.height)
        window.setFrame(frame, display: window.isVisible)

        // Belt-and-suspenders non-resizability alongside the absent
        // `.resizable` style flag — pinning min == max forecloses other
        // paths to a size change (e.g. window-manager tiling/snap).
        window.minSize = target
        window.maxSize = target

        // Restores opacity in case `SuppressedWindowHider` dimmed the window
        // before its first intentional reveal. Deliberately does NOT call
        // `makeKeyAndOrderFront` — presentation is owned by `AppDelegate`.
        window.alphaValue = 1
    }
}
