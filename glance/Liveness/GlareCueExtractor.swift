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

    private static let deviceGrayColorSpace = CGColorSpaceCreateDeviceGray()
    private static let deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

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
        let rendered = mask.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: deviceGrayColorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }

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
        let (totalPixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = totalPixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, byteCount > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: byteCount)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: deviceRGBColorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(faceCrop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let mask = faceRegion.flatMap { regionMask($0, width: width, height: height) }
        return computeGlareSample(
            from: data,
            mask: mask,
            width: width,
            height: height
        )
    }

    private static func computeGlareSample(
        from data: [UInt8],
        mask: [UInt8]?,
        width: Int,
        height: Int
    ) -> GlareSample? {
        var gridCounts = [Int](repeating: 0, count: clusterGridSize * clusterGridSize)
        var specularTotal = 0
        var maskedPixelCount = 0

        data.withUnsafeBufferPointer { bytes in
            let scanPixels: (UnsafeBufferPointer<UInt8>?) -> Void = { maskBytes in
                let maxGridIndex = clusterGridSize - 1
                for y in 0..<height {
                    let rowBase = y * width * 4
                    let maskRowBase = y * width
                    let gridY = min(maxGridIndex, y * clusterGridSize / height)
                    let gridRowOffset = gridY * clusterGridSize
                    for x in 0..<width {
                        if let maskBytes, maskBytes[maskRowBase + x] == 0 { continue }
                        maskedPixelCount += 1

                        let offset = rowBase + x * 4
                        let red = Float(bytes[offset])
                        let green = Float(bytes[offset + 1])
                        let blue = Float(bytes[offset + 2])

                        let luma = 0.299 * red + 0.587 * green + 0.114 * blue
                        guard luma >= specularLumaFloor else { continue }
                        let cbCentered = -0.168736 * red - 0.331264 * green + 0.5 * blue
                        let crCentered = 0.5 * red - 0.418688 * green - 0.081312 * blue
                        guard abs(cbCentered) <= specularChromaTolerance,
                            abs(crCentered) <= specularChromaTolerance
                        else { continue }

                        specularTotal += 1
                        let gridX = min(maxGridIndex, x * clusterGridSize / width)
                        gridCounts[gridRowOffset + gridX] += 1
                    }
                }
            }
            if let mask {
                mask.withUnsafeBufferPointer { scanPixels($0) }
            } else {
                scanPixels(nil)
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
