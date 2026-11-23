//
//  DisplayBrightnessControl.swift
//  glance
//
//  Private DisplayServices brightness bridge for Night Boost, failing safely
//  when symbols are missing or a display has no controllable backlight.
//

import CoreGraphics
import Darwin

@MainActor
protocol DisplayBrightnessControlling: AnyObject {
    func getBrightness(for displayID: CGDirectDisplayID) -> Float?
    func setBrightness(_ brightness: Float, for displayID: CGDirectDisplayID) -> Bool
}

@MainActor
final class DisplayBrightnessControl: DisplayBrightnessControlling {
    private typealias DisplayServicesGetBrightnessFn =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DisplayServicesSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightnessFn: DisplayServicesGetBrightnessFn?
    private let setBrightnessFn: DisplayServicesSetBrightnessFn?

    init() {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                RTLD_LAZY
            )
        else {
            getBrightnessFn = nil
            setBrightnessFn = nil
            return
        }

        let getSym = dlsym(handle, "DisplayServicesGetBrightness")
        let setSym = dlsym(handle, "DisplayServicesSetBrightness")
        getBrightnessFn = getSym.map { unsafeBitCast($0, to: DisplayServicesGetBrightnessFn.self) }
        setBrightnessFn = setSym.map { unsafeBitCast($0, to: DisplayServicesSetBrightnessFn.self) }
    }

    func getBrightness(for displayID: CGDirectDisplayID) -> Float? {
        guard displayID != 0, let getBrightnessFn else { return nil }
        var brightness: Float = 0
        let status = getBrightnessFn(displayID, &brightness)
        guard status == 0, brightness.isFinite else { return nil }
        return min(max(brightness, 0), 1)
    }

    func setBrightness(_ brightness: Float, for displayID: CGDirectDisplayID) -> Bool {
        guard displayID != 0, brightness.isFinite, let setBrightnessFn else { return false }
        let clamped = min(max(brightness, 0), 1)
        return setBrightnessFn(displayID, clamped) == 0
    }
}
