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
    private var isSkyLightDelegated = false

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
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if LockMonitor.isScreenActuallyLocked(), let skyLight = NotchSkyLight.shared {
            skyLight.delegate(panel)
            isSkyLightDelegated = true
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
        if isSkyLightDelegated, let skyLight = NotchSkyLight.shared {
            skyLight.undelegate(panel)
            isSkyLightDelegated = false
        }
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
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
    private static let warmColors: [CGColor] = [
        CGColor(srgbRed: 1.0, green: 0.94, blue: 0.83, alpha: 0.88),
        CGColor(srgbRed: 1.0, green: 0.92, blue: 0.79, alpha: 0.72),
        CGColor(srgbRed: 1.0, green: 0.90, blue: 0.75, alpha: 0.28),
        CGColor(srgbRed: 1.0, green: 0.89, blue: 0.72, alpha: 0.0)
    ]
    private static let warmLocations: [NSNumber] = [0.0, 0.45, 0.80, 1.0]

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let gradientLayer = CAGradientLayer()
        gradientLayer.type = .axial
        gradientLayer.colors = Self.warmColors
        gradientLayer.locations = Self.warmLocations
        // Non-flipped AppKit/CoreAnimation coordinates: (0.5, 1.0) is top, (0.5, 0.0) is bottom.
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        return gradientLayer
    }
}
