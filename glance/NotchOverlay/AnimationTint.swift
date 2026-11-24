//
//  AnimationTint.swift
//  glance
//
//  Runtime linear-light CIColorMatrix tinting for scan/unlock stills & videos.
//

import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import os

/// Which media the overlay is showing. `.idle` is a still image (the first
/// frame of the success video) so the transition into a playing video is
/// seamless.
nonisolated enum ScanMedia: Equatable, Hashable, Sendable {
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
    private struct StillCacheKey: Hashable, Sendable {
        let color: UnlockAnimationColor
        let compact: Bool
    }

    private struct ColorMatrixVectors: Sendable {
        let r: CIVector
        let g: CIVector
        let b: CIVector
        let a: CIVector
    }

    private static let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearSRGBColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    // CIContext is thread-safe for concurrent rendering; share one linear-sRGB
    // context to avoid per-frame/per-thumbnail allocation overhead.
    static let linearContext = CIContext(
        options: [.workingColorSpace: linearSRGBColorSpace]
    )
    private static let alphaVector = CIVector(x: 0, y: 0, z: 0, w: 1)

    private static let baseStillCache = OSAllocatedUnfairLock<[Bool: NSImage]>(initialState: [:])
    private static let tintedStillCache = OSAllocatedUnfairLock<[StillCacheKey: NSImage]>(initialState: [:])

    private static func colorMatrixVectors(for rgb: AnimationTintRGB) -> ColorMatrixVectors {
        ColorMatrixVectors(
            r: CIVector(x: 0, y: 0, z: linearized(rgb.red), w: 0),
            g: CIVector(x: 0, y: 0, z: linearized(rgb.green), w: 0),
            b: CIVector(x: 0, y: 0, z: linearized(rgb.blue), w: 0),
            a: alphaVector
        )
    }

    private static func apply(_ vectors: ColorMatrixVectors, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = vectors.r
        filter.gVector = vectors.g
        filter.bVector = vectors.b
        filter.aVector = vectors.a
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    static func apply(_ rgb: AnimationTintRGB?, to image: CIImage) -> CIImage {
        guard let rgb else { return image }
        return apply(colorMatrixVectors(for: rgb), to: image)
    }

    static func apply(_ rgb: AnimationTintRGB?, to image: NSImage) -> NSImage {
        guard let rgb,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return image }
        let output = apply(rgb, to: CIImage(cgImage: cgImage))
        guard
            let rendered = linearContext.createCGImage(
                output,
                from: output.extent,
                format: .RGBA8,
                colorSpace: srgbColorSpace
            )
        else {
            return image
        }
        return NSImage(cgImage: rendered, size: image.size)
    }

    /// Loads `unlockstatic` / `unlockstatic-small` from `Bundle.main` and caches
    /// the tinted idle still keyed by `(color, compact)` to avoid repeated disk reads.
    static func cachedStill(for color: UnlockAnimationColor, compact: Bool) -> NSImage? {
        let key = StillCacheKey(color: color, compact: compact)
        if let cached = tintedStillCache.withLock({ $0[key] }) {
            return cached
        }
        guard let base = baseStill(compact: compact) else { return nil }
        let tinted = apply(color.resolvedTintRGB(for: .idle), to: base)
        return tintedStillCache.withLock { cache in
            if let existing = cache[key] { return existing }
            cache[key] = tinted
            return tinted
        }
    }

    private static func baseStill(compact: Bool) -> NSImage? {
        if let cached = baseStillCache.withLock({ $0[compact] }) {
            return cached
        }
        let resource = compact ? "unlockstatic-small" : "unlockstatic"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
            let loaded = NSImage(contentsOf: url)
        else {
            return nil
        }
        return baseStillCache.withLock { cache in
            if let existing = cache[compact] { return existing }
            cache[compact] = loaded
            return loaded
        }
    }

    /// Builds a tinted `AVVideoComposition` asynchronously without blocking `@MainActor`,
    /// precomputing the 4 linear-sRGB `CIVector`s once outside the per-frame filter closure.
    static func makeVideoComposition(for asset: AVAsset, rgb: AnimationTintRGB?) async -> AVVideoComposition? {
        guard let rgb else { return nil }
        let vectors = colorMatrixVectors(for: rgb)

        if #available(macOS 26.0, *) {
            guard
                let base = try? await AVVideoComposition(
                    applyingFiltersTo: asset,
                    applier: { params in
                        AVCIImageFilteringResult(
                            resultImage: apply(vectors, to: params.sourceImage),
                            ciContext: linearContext
                        )
                    }
                )
            else {
                return nil
            }
            let config = AVVideoComposition.Configuration(
                animationTool: base.animationTool,
                colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
                colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
                colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
                customVideoCompositorClass: base.customVideoCompositorClass,
                frameDuration: base.frameDuration,
                instructions: base.instructions,
                perFrameHDRDisplayMetadataPolicy: base.perFrameHDRDisplayMetadataPolicy,
                renderScale: base.renderScale,
                renderSize: base.renderSize,
                sourceSampleDataTrackIDs: base.sourceSampleDataTrackIDs,
                sourceTrackIDForFrameTiming: base.sourceTrackIDForFrameTiming
            )
            return AVVideoComposition(configuration: config)
        } else {
            return await withCheckedContinuation { continuation in
                AVVideoComposition.videoComposition(
                    with: asset,
                    applyingCIFiltersWithHandler: { request in
                        request.finish(
                            with: apply(vectors, to: request.sourceImage),
                            context: linearContext
                        )
                    },
                    completionHandler: { composition, _ in
                        continuation.resume(returning: composition)
                    }
                )
            }
        }
    }

    private static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
