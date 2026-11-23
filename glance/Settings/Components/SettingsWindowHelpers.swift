//
//  SettingsWindowHelpers.swift
//  glance
//
//  AppKit bridges for the Settings window: appearance-adaptive backdrop blur
//  and one-shot NSWindow chrome/size configuration.
//

import AppKit
import CoreImage
import SwiftUI

/// Wraps an `NSVisualEffectView` for the window's background blur.
///
/// `.sidebar`, not `.hudWindow` — Apple's own purpose-built material for
/// this element (Finder/Mail/Xcode sidebars), reading as a properly light,
/// neutral glass panel on its own. Both materials still desaturate heavily
/// against real wallpaper, though, which is what `saturationFilter` restores.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    /// `CALayer.filters` is the property that actually reaches this view's
    /// rendered content (confirmed empirically — `.backgroundFilters` moved
    /// saturation by far less). 1.75/1.2 (light/dark) are the boosts that
    /// empirically matched a reference app's tinted sidebar against real
    /// desktop wallpaper — re-measure if the backdrop or material changes.
    private static let lightSaturationFilter: CIFilter = {
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(1.75, forKey: "inputSaturation")
        return filter
    }()

    private static let darkSaturationFilter: CIFilter = {
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(1.2, forKey: "inputSaturation")
        return filter
    }()

    func makeNSView(context: Context) -> AppearanceAdaptiveVisualEffectView {
        let view = AppearanceAdaptiveVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.followsWindowActiveState`, not `.active` — `.active` pins the
        // material on permanently, so the window stays translucent even
        // when it's neither key nor main.
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.lightFilter = Self.lightSaturationFilter
        view.darkFilter = Self.darkSaturationFilter
        view.applyFilterForCurrentAppearance()
        return view
    }

    func updateNSView(_ nsView: AppearanceAdaptiveVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Swaps between `VisualEffectView`'s light/dark saturation filters live,
/// reacting to the user toggling System Settings' appearance while open.
final class AppearanceAdaptiveVisualEffectView: NSVisualEffectView {
    var lightFilter: CIFilter?
    var darkFilter: CIFilter?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFilterForCurrentAppearance()
    }

    func applyFilterForCurrentAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let filter = isDark ? darkFilter : lightFilter
        layer?.filters = filter.map { [$0] }
    }
}

/// Configures the hosting `NSWindow`'s chrome once it's available: fully
/// borderless (see `WindowConfiguringView` for why), fixed-size, and
/// background-draggable since there's no title bar to grab.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowConfiguringView {
        WindowConfiguringView()
    }

    func updateNSView(_ nsView: WindowConfiguringView, context: Context) {}
}

/// Makes the hosting window an ordinary macOS window that simply doesn't
/// draw a title bar.
///
/// Note: no `setFrame`/`setContentSize` on every layout pass — that fights
/// SwiftUI's resize-to-fit-content pass in a mutual invalidation loop and
/// can crash. Size is set exactly once, here.
final class WindowConfiguringView: NSView {
    private var hasConfigured = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasConfigured else { return }
        hasConfigured = true

        // Deferred by one runloop turn — mutating the window synchronously
        // here (mid SwiftUI render pass) corrupts an AppKit-internal lock
        // and hard-crashes in `_NSSetBoolValueAndNotify`.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.configure(window)
        }
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
        window.setFrame(frame, display: true)

        // Belt-and-suspenders non-resizability alongside the absent
        // `.resizable` style flag — pinning min == max forecloses other
        // paths to a size change (e.g. window-manager tiling/snap).
        window.minSize = target
        window.maxSize = target

        // `ignoringOtherApps` covers the automatic post-onboarding path
        // (window created after an `.accessory` stretch, no click in the
        // activation chain) — otherwise the window opens in the inactive
        // look until the user Cmd-Tabs.
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
