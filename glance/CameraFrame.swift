//
//  CameraFrame.swift
//  glance
//
//  Pure CoreImage/CoreGraphics frame container and native-resolution crop renderer.
//  Kept separate from `CameraManager` so recognition and standalone self-tests can
//  crop native frames without importing `AVFoundation` or AppKit settings.
//

import CoreGraphics
import CoreImage

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
nonisolated struct CameraFrame: @unchecked Sendable {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize

    /// `CIContext` is expensive to create and safe to reuse concurrently.
    private static let cropRenderContext = CIContext()

    /// Renders a native-resolution crop of `imageRect` (in `image`'s top-left/y-down pixel space)
    /// from `source`, expanded by `paddingFraction` on each side and downscaled so the longer edge
    /// does not exceed `maxEdge`.
    func renderCrop(
        imageRect: CGRect,
        paddingFraction: CGFloat = 0.15,
        maxEdge: CGFloat = 448
    ) -> CGImage? {
        let workingWidth = CGFloat(image.width)
        let workingHeight = CGFloat(image.height)
        guard workingWidth > 0, workingHeight > 0,
              sourceSize.width > 0, sourceSize.height > 0,
              maxEdge > 0 else { return nil }
        let scaleX = sourceSize.width / workingWidth
        let scaleY = sourceSize.height / workingHeight

        let expanded = imageRect.insetBy(
            dx: -imageRect.width * paddingFraction,
            dy: -imageRect.height * paddingFraction
        )

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up (reverse of FaceDetector.convertToImageSpace).
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isEmpty else { return nil }

        var cropped = source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return Self.cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }
}
