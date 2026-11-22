//
//  SceneLuminance.swift
//  glance
//
//  Fast Rec. 709 frame luminance sampler for opt-in Night Boost.
//

import CoreGraphics

nonisolated enum SceneLuminance: Sendable {
    /// Mean normalized luminance below which warm top-screen illumination activates.
    static let darkThreshold: Double = 0.22
    /// Mean normalized luminance below which the 640px recognition frame receives bounded low-light gain.
    static let enhanceThreshold: Double = 0.28

    private static let sampleDimension = 32
    private static let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// Measures mean Rec. 709 luminance (`0.2126*R + 0.7152*G + 0.0722*B`, normalized `0.0...1.0`)
    /// by downsampling `image` into a compact 32x32 RGBA8 sRGB buffer.
    static func meanLuminance(of image: CGImage) -> Double {
        guard image.width > 0, image.height > 0, let srgbColorSpace else { return 1.0 }

        let dimension = sampleDimension
        let pixelCount = dimension * dimension
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)

        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension * 4,
                space: srgbColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            return true
        }
        guard drawn else { return 1.0 }

        var weightedSum = 0.0
        pixels.withUnsafeBufferPointer { bytes in
            for i in 0..<pixelCount {
                let offset = i * 4
                let r = Double(bytes[offset])
                let g = Double(bytes[offset + 1])
                let b = Double(bytes[offset + 2])
                weightedSum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }

        let mean = weightedSum / (Double(pixelCount) * 255.0)
        return min(max(mean, 0.0), 1.0)
    }
}
