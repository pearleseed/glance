//
//  IlluminationPanel.swift
//  glance
//
//  Non-activating, click-through warm top-screen illumination panel supporting
//  macOS lock-screen visibility via SkyLight delegation.
//

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class IlluminationPanel: IlluminationPresenting {
    private var panel: WarmIlluminationPanel?

    func show(on screen: NSScreen, coverageFraction: CGFloat, fadeInDuration: TimeInterval) {
        let fraction = min(max(coverageFraction, 0), 1)
        let height = screen.frame.height * fraction
        guard screen.frame.width > 0, height > 0 else { return }

        let targetFrame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        )

        let panel = panelIfNeeded(for: targetFrame)
        panel.setFrame(targetFrame, display: true)
        panel.contentView?.needsDisplay = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if LockMonitor.isScreenActuallyLocked() {
            NotchSkyLight.shared?.delegate(panel)
        }

        if fadeInDuration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        // Cancel any in-flight fade-in immediately before pulling the panel off screen.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 0
        }
        panel.alphaValue = 0
        NotchSkyLight.shared?.undelegate(panel)
        panel.orderOut(nil)
    }

    private func panelIfNeeded(for frame: NSRect) -> WarmIlluminationPanel {
        if let panel { return panel }
        let created = WarmIlluminationPanel(contentRect: frame)
        panel = created
        return created
    }
}

extension SceneIlluminator {
    convenience init() {
        self.init(
            brightnessControl: DisplayBrightnessControl(),
            panel: IlluminationPanel(),
            screenProvider: { NotchGeometry.preferredScreen() }
        )
    }
}

private final class WarmIlluminationPanel: NSPanel {
    init(contentRect: NSRect) {
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
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = WarmIlluminationView(frame: NSRect(origin: .zero, size: contentRect.size))
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WarmIlluminationView: NSView {
    private static let warmGradient = NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 1.0, green: 0.94, blue: 0.83, alpha: 0.88), 0.0),
        (NSColor(srgbRed: 1.0, green: 0.92, blue: 0.79, alpha: 0.72), 0.45),
        (NSColor(srgbRed: 1.0, green: 0.90, blue: 0.75, alpha: 0.28), 0.80),
        (NSColor(srgbRed: 1.0, green: 0.89, blue: 0.72, alpha: 0.0), 1.0)
    )

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        Self.warmGradient?.draw(in: bounds, angle: 270)
    }
}
