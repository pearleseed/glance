//
//  glare_mask_selftest.swift
//  glance (tools)
//
//  Offline self-test for GlareFaceRegion face-contour polygon masking and
//  GlareCueExtractor.regionMask / extract(faceCrop:faceRegion:).
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/glare_mask_selftest \
//        glance/CameraFrame.swift \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/GlareFaceRegion.swift \
//        glance/Liveness/GlareCueExtractor.swift \
//        tools/glare_mask_selftest.swift \
//      && /tmp/glare_mask_selftest
//

import Foundation
import CoreGraphics
import CoreImage

private func makeTestImage(width: Int, height: Int, isBrightPixel: (Int, Int) -> Bool) -> CGImage {
    var pixels = [UInt8](repeating: 80, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let idx = (y * width + x) * 4
            pixels[idx + 3] = 255
            if isBrightPixel(x, y) {
                pixels[idx] = 255; pixels[idx + 1] = 255; pixels[idx + 2] = 255
            }
        }
    }
    return pixels.withUnsafeMutableBytes { buffer -> CGImage in
        let ctx = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}

private func makeImage(width: Int, height: Int, brightCorner: Bool, brightForehead: Bool) -> CGImage {
    makeTestImage(width: width, height: height) { x, y in
        // Bright background lamp in top-left corner outside jaw contour
        let inCorner = brightCorner && x < width / 4 && y < height / 4
        // Bright specular glare on forehead inside polygon
        let inForehead = brightForehead && x > width * 3 / 8 && x < width * 5 / 8 && y > height / 10 && y < height / 3
        return inCorner || inForehead
    }
}

private func makeFrameImage(width: Int, height: Int, whiteRect: CGRect?) -> CGImage {
    makeTestImage(width: width, height: height) { x, y in
        guard let whiteRect else { return false }
        return whiteRect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
    }
}

@main
struct GlareMaskSelfTest {
    static func main() {
        runCornerAndForeheadMaskTests()
        runDegeneratePolygonFallbackTests()
        runCenteredFrameRenderCropAlignmentTests()
        runArbitraryContourOrderTests()
        print("PASS: GlareFaceRegion excludes background glare while preserving forehead speculars.")
    }

    private static func runCornerAndForeheadMaskTests() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let contour = [
            CGPoint(x: 20, y: 35), CGPoint(x: 25, y: 70), CGPoint(x: 50, y: 95),
            CGPoint(x: 75, y: 70), CGPoint(x: 80, y: 35)
        ]
        let poly = GlareFaceRegion.polygon(contour: contour, faceBounds: bounds, imageSize: CGSize(width: 100, height: 100))!

        let cornerImg = makeImage(width: 100, height: 100, brightCorner: true, brightForehead: false)
        let unmasked = GlareCueExtractor.extract(faceCrop: cornerImg)!
        let masked = GlareCueExtractor.extract(faceCrop: cornerImg, faceRegion: poly)!
        precondition(unmasked.specularFraction > 0.05, "FAIL: baseline corner glare should exist unmasked")
        precondition(masked.specularFraction < 0.01, "FAIL: background corner glare leaked through face mask: \(masked.specularFraction)")

        let foreheadImg = makeImage(width: 100, height: 100, brightCorner: false, brightForehead: true)
        let maskedForehead = GlareCueExtractor.extract(faceCrop: foreheadImg, faceRegion: poly)!
        precondition(maskedForehead.specularFraction > 0.03, "FAIL: forehead highlight was wrongly masked out: \(maskedForehead.specularFraction)")
    }

    private static func runDegeneratePolygonFallbackTests() {
        // Tiny polygon covering < 40% of the crop must return nil from regionMask and fall back to full crop.
        let tinyPoly = [
            CGPoint(x: 0.4, y: 0.4),
            CGPoint(x: 0.6, y: 0.4),
            CGPoint(x: 0.5, y: 0.6)
        ]
        precondition(
            GlareCueExtractor.regionMask(tinyPoly, width: 100, height: 100) == nil,
            "FAIL: tiny polygon (< 40% area) should be rejected by regionMask"
        )

        let cornerImg = makeImage(width: 100, height: 100, brightCorner: true, brightForehead: false)
        let unmasked = GlareCueExtractor.extract(faceCrop: cornerImg)!
        let fallback = GlareCueExtractor.extract(faceCrop: cornerImg, faceRegion: tinyPoly)!
        precondition(
            abs(fallback.specularFraction - unmasked.specularFraction) < 1e-5,
            "FAIL: degenerate polygon did not fall back to full-crop glare extraction"
        )

        // Fewer than 3 contour points or invalid bounds must return nil.
        precondition(
            GlareFaceRegion.polygon(
                contour: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90)],
                faceBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                imageSize: CGSize(width: 100, height: 100)
            ) == nil,
            "FAIL: < 3 contour points must return nil"
        )
    }

    private static func runCenteredFrameRenderCropAlignmentTests() {
        let imageSize = CGSize(width: 640, height: 360)
        let faceBounds = CGRect(x: 220, y: 80, width: 200, height: 200)
        // Realistic Vision face contour inside `faceBounds`: temples ~4% from edges, chin ~98% of maxY.
        let contour = [
            CGPoint(x: 228, y: 150),
            CGPoint(x: 234, y: 195),
            CGPoint(x: 256, y: 240),
            CGPoint(x: 320, y: 276),
            CGPoint(x: 384, y: 240),
            CGPoint(x: 406, y: 195),
            CGPoint(x: 412, y: 150)
        ]
        let poly = GlareFaceRegion.polygon(contour: contour, faceBounds: faceBounds, imageSize: imageSize)!

        // 1.3x crop bounds: x: 190..<450 (width 260), y: 50..<310 (height 260).
        // Mask coverage should clear the 40% floor (~42% here).
        let mask = GlareCueExtractor.regionMask(poly, width: 260, height: 260)
        precondition(mask != nil, "FAIL: realistic centered 640x360 face contour fell below 40% mask floor")

        // Background glare strictly inside the 15% top-left crop padding margin (x: 190..<228, y: 50..<145).
        let cornerLampRect = CGRect(x: 190, y: 50, width: 38, height: 95)
        let fullCornerFrame = makeFrameImage(width: 640, height: 360, whiteRect: cornerLampRect)
        let cameraCornerFrame = CameraFrame(
            id: 1,
            image: fullCornerFrame,
            source: CIImage(cgImage: fullCornerFrame),
            sourceSize: imageSize
        )
        let cornerCrop = cameraCornerFrame.renderCrop(imageRect: faceBounds)!
        let cornerUnmasked = GlareCueExtractor.extract(faceCrop: cornerCrop)!
        let cornerMasked = GlareCueExtractor.extract(faceCrop: cornerCrop, faceRegion: poly)!
        precondition(cornerUnmasked.specularFraction > 0.05, "FAIL: expected padded margin lamp glare unmasked: \(cornerUnmasked.specularFraction)")
        precondition(cornerMasked.specularFraction < 0.001, "FAIL: padded margin corner glare leaked into 640x360 face mask: \(cornerMasked.specularFraction)")

        // Forehead specular inside the face region (x: 295..<345, y: 100..<140).
        let foreheadRect = CGRect(x: 295, y: 100, width: 50, height: 40)
        let fullForeheadFrame = makeFrameImage(width: 640, height: 360, whiteRect: foreheadRect)
        let cameraForeheadFrame = CameraFrame(
            id: 2,
            image: fullForeheadFrame,
            source: CIImage(cgImage: fullForeheadFrame),
            sourceSize: imageSize
        )
        let foreheadCrop = cameraForeheadFrame.renderCrop(imageRect: faceBounds)!
        let foreheadMasked = GlareCueExtractor.extract(faceCrop: foreheadCrop, faceRegion: poly)!
        precondition(foreheadMasked.specularFraction > 0.03, "FAIL: 640x360 forehead highlight was wrongly masked out: \(foreheadMasked.specularFraction)")
    }

    private static func runArbitraryContourOrderTests() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ordered = [
            CGPoint(x: 20, y: 35), CGPoint(x: 25, y: 70), CGPoint(x: 50, y: 95),
            CGPoint(x: 75, y: 70), CGPoint(x: 80, y: 35)
        ]
        let shuffled = [ordered[2], ordered[4], ordered[1], ordered[0], ordered[3]]
        let orderedPoly = GlareFaceRegion.polygon(contour: ordered, faceBounds: bounds, imageSize: CGSize(width: 100, height: 100))!
        let shuffledPoly = GlareFaceRegion.polygon(contour: shuffled, faceBounds: bounds, imageSize: CGSize(width: 100, height: 100))!
        precondition(orderedPoly == shuffledPoly, "FAIL: contour point order changed normalized convex hull polygon")
    }
}
