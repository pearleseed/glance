//
//  GlareCueExtractor.swift
//  glance
//
//  Turns a native-resolution face crop into a `GlareSample`. One decode-and-scan
//  pass, no frequency-domain work — cheap enough to run on every liveness frame.
//

import CoreGraphics

nonisolated enum GlareCueExtractor {
    /// Near-white, near-gray pixel — signature of a direct specular highlight vs. a bright colored surface.
    private static let specularLumaFloor: Float = 235
    private static let specularChromaTolerance: Float = 10

    /// Coarse on purpose — just distinguishes "one blob" from "many scattered points".
    private static let clusterGridSize = 8
    /// Rejects tiny or degenerate masks so a malformed contour falls back to the full crop.
    private static let minimumMaskCoverageFraction: Float = 0.40

    /// Rasterizes a normalized (`0...1`, top-left/y-down) polygon into an 8-bit mask.
    /// Returns `nil` if the polygon is degenerate or covers fewer than 40% of the crop.
    static func regionMask(_ polygon: [CGPoint], width: Int, height: Int) -> [UInt8]? {
        guard polygon.count >= 3,
              width > 0, height > 0,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return nil }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount > 0 else { return nil }

        var mask = [UInt8](repeating: 0, count: pixelCount)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let rendered = mask.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            // `CGContext.draw(faceCrop, ...)` maps top rows to byte row 0, whereas CoreGraphics
            // path coordinates have bottom-left origin; flip Y so `p.y = 0` paints row 0.
            let points = polygon.map {
                CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height))
            }
            context.setAllowsAntialiasing(false)
            context.setFillColor(gray: 1.0, alpha: 1.0)
            context.addLines(between: points)
            context.closePath()
            context.fillPath()
            return true
        }
        guard rendered else { return nil }

        var coveredCount = 0
        for byte in mask where byte != 0 {
            coveredCount += 1
        }
        guard Float(coveredCount) / Float(pixelCount) >= minimumMaskCoverageFraction else {
            return nil
        }
        return mask
    }

    /// Returns `nil` only if the crop couldn't be rasterized; a too-small crop still
    /// yields a sample, discounted elsewhere via `cropPixelWidth`.
    static func extract(faceCrop: CGImage, faceRegion: [CGPoint]? = nil) -> GlareSample? {
        let width = faceCrop.width
        let height = faceCrop.height
        guard width > 0, height > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = data.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        context.draw(faceCrop, in: CGRect(x: 0, y: 0, width: width, height: height))

        let mask = faceRegion.flatMap { regionMask($0, width: width, height: height) }
        var gridCounts = [Int](repeating: 0, count: clusterGridSize * clusterGridSize)
        var specularTotal = 0
        var maskedPixelCount = 0

        data.withUnsafeBufferPointer { bytes in
            for y in 0..<height {
                let rowBase = y * width * 4
                let maskRowBase = y * width
                let gy = min(clusterGridSize - 1, y * clusterGridSize / height)
                for x in 0..<width {
                    if let mask, mask[maskRowBase + x] == 0 { continue }
                    maskedPixelCount += 1

                    let offset = rowBase + x * 4
                    let r = Float(bytes[offset])
                    let g = Float(bytes[offset + 1])
                    let b = Float(bytes[offset + 2])

                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    guard luma >= specularLumaFloor else { continue }
                    let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
                    let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
                    guard abs(cb - 128) <= specularChromaTolerance,
                          abs(cr - 128) <= specularChromaTolerance
                    else { continue }

                    specularTotal += 1
                    let gx = min(clusterGridSize - 1, x * clusterGridSize / width)
                    gridCounts[gy * clusterGridSize + gx] += 1
                }
            }
        }

        let pixelCount = mask != nil ? maskedPixelCount : (width * height)
        guard pixelCount > 0 else { return nil }
        let specularFraction = Float(specularTotal) / Float(pixelCount)
        let largestCluster = gridCounts.max() ?? 0
        let clusterRatio = specularTotal > 0 ? Float(largestCluster) / Float(specularTotal) : 0

        return GlareSample(
            cropPixelWidth: CGFloat(width),
            specularFraction: specularFraction,
            specularClusterRatio: clusterRatio
        )
    }
}
