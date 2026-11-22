//
//  SceneIlluminator.swift
//  glance
//
//  Coordinates Night Boost display brightness boost/restore and the top-38% warm panel.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol IlluminationPresenting: AnyObject {
    func show(on screen: NSScreen, coverageFraction: CGFloat, fadeInDuration: TimeInterval)
    func hide()
}

@MainActor
final class SceneIlluminator {
    static let coverageFraction: CGFloat = 0.38
    static let maxBrightness: Float = 0.9
    static let fadeInDuration: TimeInterval = 0.8

    private let brightnessControl: DisplayBrightnessControlling
    private let panel: IlluminationPresenting
    private let screenProvider: @MainActor () -> NSScreen?
    private let displayIDProvider: @MainActor (NSScreen) -> CGDirectDisplayID?
    private let observerBox: ObserverBox

    private var isActive = false
    private var savedBrightness: (displayID: CGDirectDisplayID, value: Float)?

    init(
        brightnessControl: DisplayBrightnessControlling? = nil,
        panel: IlluminationPresenting,
        screenProvider: @escaping @MainActor () -> NSScreen? = { NSScreen.main },
        displayIDProvider: @escaping @MainActor (NSScreen) -> CGDirectDisplayID? = { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.brightnessControl = brightnessControl ?? DisplayBrightnessControl()
        self.panel = panel
        self.screenProvider = screenProvider
        self.displayIDProvider = displayIDProvider
        self.observerBox = ObserverBox(center: notificationCenter)

        observerBox.add(notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.end()
            }
        })
    }

    /// Idempotent activation targeting `screen` (or `screenProvider()` when `nil`).
    func activateIfNeeded(on screen: NSScreen? = nil) {
        guard !isActive else { return }
        guard let targetScreen = screen ?? screenProvider() else { return }
        activate(displayID: displayIDProvider(targetScreen), screen: targetScreen)
    }

    /// Headless entry point allowing direct `CGDirectDisplayID` verification without a backing `NSScreen`.
    func activateIfNeeded(displayID: CGDirectDisplayID?) {
        guard !isActive else { return }
        activate(displayID: displayID, screen: screenProvider())
    }

    private func activate(displayID: CGDirectDisplayID?, screen: NSScreen?) {
        isActive = true

        if let displayID,
           let currentBrightness = brightnessControl.getBrightness(for: displayID),
           currentBrightness < Self.maxBrightness {
            if brightnessControl.setBrightness(Self.maxBrightness, for: displayID) {
                savedBrightness = (displayID, currentBrightness)
            }
        }

        if let screen {
            panel.show(
                on: screen,
                coverageFraction: Self.coverageFraction,
                fadeInDuration: Self.fadeInDuration
            )
        }
    }

    /// Idempotent teardown: restores original display brightness (if raised) and hides the illumination panel.
    func end() {
        guard isActive else { return }
        isActive = false

        if let saved = savedBrightness {
            savedBrightness = nil
            _ = brightnessControl.setBrightness(saved.value, for: saved.displayID)
        }

        panel.hide()
    }

    /// Owns `NotificationCenter` tokens outside actor isolation so `deinit` can unregister them safely under Swift 6.
    nonisolated private final class ObserverBox: @unchecked Sendable {
        private let center: NotificationCenter
        private var tokens: [NSObjectProtocol] = []

        init(center: NotificationCenter) {
            self.center = center
        }

        func add(_ token: NSObjectProtocol) {
            tokens.append(token)
        }

        deinit {
            for token in tokens {
                center.removeObserver(token)
            }
        }
    }
}
