//
//  night_boost_selftest.swift
//  glance (tools)
//
//  Offline, camera-free self-test for Night Boost:
//    1. SceneLuminance Rec. 709 measurement & thresholds
//    2. LowLightEnhancer bounded lift, bright passthrough, & source immutability
//    3. SceneIlluminator brightness raise/preserve/no-dim/restore, idempotency,
//       top-38% 0.8s panel presentation, and NSApplication.willTerminateNotification cleanup
//    4. DisplayBrightnessControl safe failure/clamping behavior
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/night_boost_selftest \
//        glance/Core/NotificationObserverBox.swift \
//        glance/NightBoost/SceneLuminance.swift \
//        glance/Camera/SharedCoreImageContext.swift \
//        glance/NightBoost/LowLightEnhancer.swift \
//        glance/NightBoost/DisplayBrightnessControl.swift \
//        glance/NightBoost/SceneIlluminator.swift \
//        tools/night_boost_selftest.swift \
//      && /tmp/night_boost_selftest
//

import AppKit
import CoreGraphics
import Foundation

private func makeSolidSRGBImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        let base = i * 4
        pixels[base] = r
        pixels[base + 1] = g
        pixels[base + 2] = b
    }
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    return pixels.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}

private func makeSplitSRGBImage(width: Int, height: Int, left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8)) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let base = (y * width + x) * 4
            let rgb = x < width / 2 ? left : right
            pixels[base] = rgb.0
            pixels[base + 1] = rgb.1
            pixels[base + 2] = rgb.2
        }
    }
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    return pixels.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}

private func readSRGBPixels(_ image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    pixels.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
}

@MainActor
private final class MockBrightnessControl: DisplayBrightnessControlling {
    var stored: [CGDirectDisplayID: Float] = [:]
    var setCalls: [(displayID: CGDirectDisplayID, brightness: Float)] = []
    var allowSet = true

    func getBrightness(for displayID: CGDirectDisplayID) -> Float? {
        stored[displayID]
    }

    func setBrightness(_ brightness: Float, for displayID: CGDirectDisplayID) -> Bool {
        let clamped = min(max(brightness, 0), 1)
        setCalls.append((displayID, clamped))
        guard allowSet else { return false }
        stored[displayID] = clamped
        return true
    }
}

@MainActor
private final class MockIlluminationPanel: IlluminationPresenting {
    struct ShowEvent {
        let screen: NSScreen
        let coverageFraction: CGFloat
        let fadeInDuration: TimeInterval
    }

    var showEvents: [ShowEvent] = []
    var hideCallCount = 0

    func show(on screen: NSScreen, coverageFraction: CGFloat, fadeInDuration: TimeInterval) {
        showEvents.append(ShowEvent(
            screen: screen,
            coverageFraction: coverageFraction,
            fadeInDuration: fadeInDuration
        ))
    }

    func hide() {
        hideCallCount += 1
    }
}

@main
struct NightBoostSelfTest {
    @MainActor
    static func main() {
        runSceneLuminanceTests()
        runLowLightEnhancerTests()
        runSceneIlluminatorTests()
        runDisplayBrightnessSafetyTests()
        print("PASS: Night Boost luminance, low-light enhancer, and illuminator lifecycle verified.")
    }

    private static func runSceneLuminanceTests() {
        precondition(abs(SceneLuminance.darkThreshold - 0.22) < 1e-6, "FAIL: unexpected darkThreshold")
        precondition(abs(SceneLuminance.enhanceThreshold - 0.28) < 1e-6, "FAIL: unexpected enhanceThreshold")

        let black = makeSolidSRGBImage(width: 64, height: 64, r: 0, g: 0, b: 0)
        let blackLum = SceneLuminance.meanLuminance(of: black)
        precondition(blackLum < 0.01, "FAIL: black luminance expected < 0.01, got \(blackLum)")

        let midGray = makeSolidSRGBImage(width: 64, height: 64, r: 128, g: 128, b: 128)
        let midLum = SceneLuminance.meanLuminance(of: midGray)
        precondition(abs(midLum - 0.5) < 0.02, "FAIL: mid-gray luminance expected ~0.5, got \(midLum)")

        let white = makeSolidSRGBImage(width: 64, height: 64, r: 255, g: 255, b: 255)
        let whiteLum = SceneLuminance.meanLuminance(of: white)
        precondition(whiteLum > 0.99, "FAIL: white luminance expected > 0.99, got \(whiteLum)")

        // Rec. 709 weights: R=0.2126, G=0.7152, B=0.0722
        let pureRed = makeSolidSRGBImage(width: 64, height: 64, r: 255, g: 0, b: 0)
        let pureGreen = makeSolidSRGBImage(width: 64, height: 64, r: 0, g: 255, b: 0)
        let pureBlue = makeSolidSRGBImage(width: 64, height: 64, r: 0, g: 0, b: 255)
        let redLum = SceneLuminance.meanLuminance(of: pureRed)
        let greenLum = SceneLuminance.meanLuminance(of: pureGreen)
        let blueLum = SceneLuminance.meanLuminance(of: pureBlue)
        precondition(abs(redLum - 0.2126) < 0.02, "FAIL: Rec.709 red expected ~0.2126, got \(redLum)")
        precondition(abs(greenLum - 0.7152) < 0.02, "FAIL: Rec.709 green expected ~0.7152, got \(greenLum)")
        precondition(abs(blueLum - 0.0722) < 0.02, "FAIL: Rec.709 blue expected ~0.0722, got \(blueLum)")

        let split = makeSplitSRGBImage(width: 64, height: 64, left: (0, 0, 0), right: (255, 255, 255))
        let splitLum = SceneLuminance.meanLuminance(of: split)
        precondition(abs(splitLum - 0.5) < 0.03, "FAIL: half-black half-white luminance expected ~0.5, got \(splitLum)")
    }

    private static func runLowLightEnhancerTests() {
        // Dark synthetic image (RGB 20,20,20 => luminance ~0.078 < 0.28)
        let dark = makeSolidSRGBImage(width: 64, height: 48, r: 20, g: 20, b: 20)
        let darkPixelsBefore = readSRGBPixels(dark)
        let darkLum = SceneLuminance.meanLuminance(of: dark)
        precondition(darkLum < SceneLuminance.enhanceThreshold, "FAIL: synthetic dark image not below enhanceThreshold")

        let enhanced = LowLightEnhancer.enhance(dark, meanLuminance: darkLum)
        precondition(enhanced.width == dark.width && enhanced.height == dark.height, "FAIL: enhancer changed image dimensions")
        let enhancedLum = SceneLuminance.meanLuminance(of: enhanced)
        precondition(enhancedLum > darkLum + 0.10, "FAIL: enhancer did not significantly lift dark image: \(darkLum) -> \(enhancedLum)")

        // Original CGImage must remain completely untouched
        let darkPixelsAfter = readSRGBPixels(dark)
        precondition(darkPixelsBefore == darkPixelsAfter, "FAIL: LowLightEnhancer mutated source image pixels")

        // Bright image (>= enhanceThreshold) must pass through unchanged
        let bright = makeSolidSRGBImage(width: 64, height: 48, r: 140, g: 140, b: 140)
        let brightLum = SceneLuminance.meanLuminance(of: bright)
        precondition(brightLum >= SceneLuminance.enhanceThreshold, "FAIL: synthetic bright image below enhanceThreshold")
        let brightOut = LowLightEnhancer.enhance(bright, meanLuminance: brightLum)
        precondition(brightOut === bright, "FAIL: bright image at or above enhanceThreshold should be returned unchanged")
    }

    @MainActor
    private static func runSceneIlluminatorTests() {
        precondition(abs(SceneIlluminator.coverageFraction - 0.38) < 1e-6, "FAIL: coverageFraction must be 0.38")
        precondition(abs(SceneIlluminator.maxBrightness - 0.9) < 1e-6, "FAIL: maxBrightness must be 0.9")
        precondition(abs(SceneIlluminator.fadeInDuration - 0.8) < 1e-6, "FAIL: fadeInDuration must be 0.8")

        let displayID: CGDirectDisplayID = 777
        let center = NotificationCenter()

        // 1. Raises brightness to 0.9, stays idempotent across repeated activateIfNeeded calls, restores on end()
        do {
            let brightness = MockBrightnessControl()
            brightness.stored[displayID] = 0.25
            let panel = MockIlluminationPanel()
            let illuminator = SceneIlluminator(
                brightnessControl: brightness,
                panel: panel,
                screenProvider: { nil },
                displayIDProvider: { _ in displayID },
                notificationCenter: center
            )

            illuminator.activateIfNeeded(displayID: displayID)
            precondition(abs((brightness.stored[displayID] ?? -1) - 0.9) < 1e-6, "FAIL: expected brightness boosted to 0.9")
            precondition(brightness.setCalls.count == 1, "FAIL: expected single brightness write on activation")

            // Repeat activation while active must NOT overwrite saved 0.25 with 0.9
            illuminator.activateIfNeeded(displayID: displayID)
            precondition(brightness.setCalls.count == 1, "FAIL: repeat activateIfNeeded should be idempotent")

            illuminator.end()
            precondition(abs((brightness.stored[displayID] ?? -1) - 0.25) < 1e-6, "FAIL: end() did not restore original brightness 0.25")
            precondition(panel.hideCallCount == 1, "FAIL: end() must call panel.hide()")

            // Idempotent second end()
            illuminator.end()
            precondition(brightness.setCalls.count == 2, "FAIL: second end() must be idempotent and not rewrite brightness")
            precondition(panel.hideCallCount == 1, "FAIL: second end() must be idempotent for panel.hide()")
        }

        // 2. Does NOT dim when original brightness > 0.9
        do {
            let brightness = MockBrightnessControl()
            brightness.stored[displayID] = 0.96
            let panel = MockIlluminationPanel()
            let illuminator = SceneIlluminator(
                brightnessControl: brightness,
                panel: panel,
                screenProvider: { nil },
                displayIDProvider: { _ in displayID },
                notificationCenter: center
            )

            illuminator.activateIfNeeded(displayID: displayID)
            precondition(brightness.setCalls.isEmpty, "FAIL: must not dim display when original brightness > 0.9")
            precondition(abs((brightness.stored[displayID] ?? -1) - 0.96) < 1e-6, "FAIL: brightness > 0.9 was modified")

            illuminator.end()
            precondition(brightness.setCalls.isEmpty, "FAIL: end() must not write brightness when it was not modified")
            precondition(panel.hideCallCount == 1, "FAIL: end() must still hide panel")
        }

        // 2b. Handles nil getBrightness (external display) and failed setBrightness safely
        do {
            let nilBrightness = MockBrightnessControl() // stored[displayID] is nil
            let panel1 = MockIlluminationPanel()
            let illuminator1 = SceneIlluminator(
                brightnessControl: nilBrightness,
                panel: panel1,
                screenProvider: { nil },
                displayIDProvider: { _ in displayID },
                notificationCenter: center
            )
            illuminator1.activateIfNeeded(displayID: displayID)
            precondition(nilBrightness.setCalls.isEmpty, "FAIL: nil getBrightness must not attempt setBrightness")
            illuminator1.end()
            precondition(nilBrightness.setCalls.isEmpty, "FAIL: end() must not restore brightness when unreadable")
            precondition(panel1.hideCallCount == 1, "FAIL: end() must still hide panel on external display")

            let rejectedBrightness = MockBrightnessControl()
            rejectedBrightness.stored[displayID] = 0.25
            rejectedBrightness.allowSet = false
            let panel2 = MockIlluminationPanel()
            let illuminator2 = SceneIlluminator(
                brightnessControl: rejectedBrightness,
                panel: panel2,
                screenProvider: { nil },
                displayIDProvider: { _ in displayID },
                notificationCenter: center
            )
            illuminator2.activateIfNeeded(displayID: displayID)
            precondition(rejectedBrightness.setCalls.count == 1, "FAIL: expected single boost attempt")
            illuminator2.end()
            precondition(rejectedBrightness.setCalls.count == 1, "FAIL: failed boost must not trigger restore write in end()")
            precondition(panel2.hideCallCount == 1, "FAIL: end() must still hide panel when setBrightness failed")
        }

        // 3. Restores brightness and hides panel on NSApplication.willTerminateNotification
        do {
            let brightness = MockBrightnessControl()
            brightness.stored[displayID] = 0.30
            let panel = MockIlluminationPanel()
            let illuminator = SceneIlluminator(
                brightnessControl: brightness,
                panel: panel,
                screenProvider: { nil },
                displayIDProvider: { _ in displayID },
                notificationCenter: center
            )

            illuminator.activateIfNeeded(displayID: displayID)
            precondition(abs((brightness.stored[displayID] ?? -1) - 0.9) < 1e-6, "FAIL: expected boost before termination test")

            center.post(name: NSApplication.willTerminateNotification, object: nil)
            precondition(abs((brightness.stored[displayID] ?? -1) - 0.30) < 1e-6, "FAIL: willTerminateNotification did not restore brightness")
            precondition(panel.hideCallCount == 1, "FAIL: willTerminateNotification did not hide panel")
            _ = illuminator
        }

        // 4. Screen presentation path (top 38%, 0.8s fade-in, idempotent show, hide on end)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let brightness = MockBrightnessControl()
            brightness.stored[displayID] = 0.20
            let panel = MockIlluminationPanel()
            let illuminator = SceneIlluminator(
                brightnessControl: brightness,
                panel: panel,
                screenProvider: { screen },
                displayIDProvider: { _ in displayID },
                notificationCenter: center
            )

            illuminator.activateIfNeeded()
            precondition(panel.showEvents.count == 1, "FAIL: expected panel.show once on activation")
            precondition(abs(panel.showEvents[0].coverageFraction - 0.38) < 1e-6, "FAIL: panel coverageFraction must be 0.38")
            precondition(abs(panel.showEvents[0].fadeInDuration - 0.8) < 1e-6, "FAIL: panel fadeInDuration must be 0.8")
            precondition(abs((brightness.stored[displayID] ?? -1) - 0.9) < 1e-6, "FAIL: screen activation did not boost brightness")

            illuminator.activateIfNeeded()
            precondition(panel.showEvents.count == 1, "FAIL: repeat screen activation should not re-show panel")

            illuminator.end()
            precondition(panel.hideCallCount == 1, "FAIL: end() did not hide panel after screen activation")
            precondition(abs((brightness.stored[displayID] ?? -1) - 0.20) < 1e-6, "FAIL: end() did not restore brightness after screen activation")
        } else {
            print("SKIP: screen presentation subtest skipped (no NSScreen available in headless environment)")
        }
    }

    @MainActor
    private static func runDisplayBrightnessSafetyTests() {
        let control = DisplayBrightnessControl()
        let invalidID: CGDirectDisplayID = 0
        precondition(control.getBrightness(for: invalidID) == nil, "FAIL: invalid display ID should return nil brightness")
        precondition(control.setBrightness(.nan, for: invalidID) == false, "FAIL: NaN brightness must fail safely")
        precondition(control.setBrightness(0.5, for: invalidID) == false, "FAIL: invalid display ID setBrightness must return false")
    }
}
