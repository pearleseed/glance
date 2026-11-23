//
//  LowLightEnhancer.swift
//  glance
//
//  Bounded CoreImage exposure & gamma lift applied ONLY to the 640px working frame
//  for Vision/ArcFace recognition — never to liveness or glare-extraction inputs.
//

import CoreGraphics
import CoreImage

nonisolated enum LowLightEnhancer: Sendable {
    private static let context = CIContext()
    private static let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private static let maxExposureEV: Double = 1.8
    private static let minGammaPower: Double = 0.65

    /// Applies bounded low-light gain when `meanLuminance < SceneLuminance.enhanceThreshold`,
    /// scaling smoothly with darkness without mutating `image`.
    static func enhance(_ image: CGImage, meanLuminance: Double) -> CGImage {
        guard image.width > 0,
            image.height > 0,
            meanLuminance.isFinite,
            meanLuminance < SceneLuminance.enhanceThreshold,
            let srgbColorSpace
        else {
            return image
        }

        let threshold = SceneLuminance.enhanceThreshold
        let clampedLuminance = max(0.0, meanLuminance)
        let darkness = min(max((threshold - clampedLuminance) / threshold, 0.0), 1.0)

        let exposureEV = darkness * maxExposureEV
        let gammaPower = 1.0 - darkness * (1.0 - minGammaPower)

        let inputImage = CIImage(cgImage: image)
        let extent = inputImage.extent
        var output = inputImage

        if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(output, forKey: kCIInputImageKey)
            exposureFilter.setValue(exposureEV, forKey: kCIInputEVKey)
            if let exposed = exposureFilter.outputImage {
                output = exposed
            }
        }

        if let gammaFilter = CIFilter(name: "CIGammaAdjust") {
            gammaFilter.setValue(output, forKey: kCIInputImageKey)
            gammaFilter.setValue(gammaPower, forKey: "inputPower")
            if let lifted = gammaFilter.outputImage {
                output = lifted
            }
        }

        let bounded = output.cropped(to: extent)
        return context.createCGImage(bounded, from: extent, format: .RGBA8, colorSpace: srgbColorSpace) ?? image
    }
}
