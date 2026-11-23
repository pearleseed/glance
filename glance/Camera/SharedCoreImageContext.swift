//
//  SharedCoreImageContext.swift
//  glance
//
//  Shared sRGB CIContext reused across camera frame downscaling, native crop
//  rendering, and low-light enhancement so Metal/CoreImage caches are allocated once.
//

import CoreImage

nonisolated enum SharedCoreImageContext {
    static let srgb = CIContext()

    static func clearCaches() {
        srgb.clearCaches()
    }
}
