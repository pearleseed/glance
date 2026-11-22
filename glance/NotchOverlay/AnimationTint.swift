//
//  AnimationTint.swift
//  glance
//
//  Runtime linear-light CIColorMatrix tinting for scan/unlock stills & videos.
//

import AppKit
import AVFoundation
import CoreImage

/// Which media the overlay is showing. `.idle` is a still image (the first
/// frame of the success video) so the transition into a playing video is
/// seamless.
nonisolated enum ScanMedia: Equatable, Sendable {
    case idle
    case success
    case failure

    var videoResourceName: String? {
        switch self {
        case .idle: return nil
        case .success: return "unlockanimation"
        case .failure: return "unsuccessfulunlockanimation"
        }
    }
}

nonisolated struct AnimationTintRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// macOS systemGreen (#34C759)
    static let systemGreen = AnimationTintRGB(
        red: Double(0x34) / 255.0,
        green: Double(0xC7) / 255.0,
        blue: Double(0x59) / 255.0
    )
}

nonisolated enum UnlockAnimationColor: String, CaseIterable, Identifiable, Sendable {
    case blueToGreen
    case blue
    case green

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blueToGreen: return "Blue → Green"
        case .blue: return "Blue"
        case .green: return "Green"
        }
    }

    func resolvedTintRGB(for media: ScanMedia) -> AnimationTintRGB? {
        switch self {
        case .blue: return nil
        case .green: return .systemGreen
        case .blueToGreen: return media == .success ? .systemGreen : nil
        }
    }
}

nonisolated enum AnimationTint {
    private static let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearSRGBColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    // CIContext is thread-safe for concurrent rendering; share one linear-sRGB
    // context to avoid per-frame/per-thumbnail allocation overhead.
    static let linearContext = CIContext(
        options: [.workingColorSpace: linearSRGBColorSpace]
    )

    static func apply(_ rgb: AnimationTintRGB?, to image: CIImage) -> CIImage {
        guard let rgb, let filter = CIFilter(name: "CIColorMatrix") else { return image }
        let red = linearized(rgb.red)
        let green = linearized(rgb.green)
        let blue = linearized(rgb.blue)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: red, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 0, z: green, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: blue, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    static func apply(_ rgb: AnimationTintRGB?, to image: NSImage) -> NSImage {
        guard let rgb,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let output = apply(rgb, to: CIImage(cgImage: cgImage))
        guard let rendered = linearContext.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: srgbColorSpace
        ) else {
            return image
        }
        return NSImage(cgImage: rendered, size: image.size)
    }

    static func videoComposition(for asset: AVAsset, rgb: AnimationTintRGB?) -> AVVideoComposition? {
        guard let rgb else { return nil }
        let composition = AVMutableVideoComposition(asset: asset) { request in
            request.finish(with: apply(rgb, to: request.sourceImage), context: linearContext)
        }
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    private static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
