//
//  GlareFaceRegion.swift
//  glance
//
//  Builds a normalized 2D convex-hull face polygon (jaw contour extended upward
//  across the forehead) aligned with `CameraFrame.renderCrop` so `GlareCueExtractor`
//  can ignore bright background lamps in the crop corners.
//

import CoreGraphics

nonisolated enum GlareFaceRegion {
    private static let cropPaddingFraction: CGFloat = 0.15
    private static let foreheadInwardTaperFraction: CGFloat = 0.10

    /// Converts a top-left/y-down `faceContour` into a convex polygon normalized (`0...1`)
    /// inside `CameraFrame.renderCrop`'s expanded crop rect (`cropPaddingFraction = 0.15`),
    /// extending the left and right temple endpoints upward to `faceBounds.minY` (tapered
    /// inward toward `faceBounds.midX`) so the forehead stays covered while upper background
    /// corners stay excluded.
    static func polygon(contour: [CGPoint], faceBounds: CGRect, imageSize: CGSize) -> [CGPoint]? {
        guard contour.count >= 3,
            faceBounds.width > 0, faceBounds.height > 0,
            imageSize.width > 0, imageSize.height > 0,
            faceBounds.origin.x.isFinite, faceBounds.origin.y.isFinite,
            faceBounds.size.width.isFinite, faceBounds.size.height.isFinite,
            imageSize.width.isFinite, imageSize.height.isFinite,
            contour.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return nil }

        let cropBounds =
            faceBounds
            .insetBy(dx: -faceBounds.width * cropPaddingFraction, dy: -faceBounds.height * cropPaddingFraction)
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard !cropBounds.isNull, !cropBounds.isEmpty, cropBounds.width > 0, cropBounds.height > 0 else {
            return nil
        }

        // Handle both ordered Vision contours (temple -> chin -> temple) and arbitrary orderings
        // by locating the horizontal extremes, breaking ties toward the upper (smaller-y) point.
        guard let leftTemple = contour.min(by: { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }),
            let rightTemple = contour.max(by: { $0.x < $1.x || ($0.x == $1.x && $0.y > $1.y) })
        else { return nil }

        let inset = faceBounds.width * foreheadInwardTaperFraction
        let midX = faceBounds.midX
        let leftForeheadX =
            leftTemple.x <= midX
            ? min(leftTemple.x + inset, midX)
            : max(leftTemple.x - inset, midX)
        let rightForeheadX =
            rightTemple.x >= midX
            ? max(rightTemple.x - inset, midX)
            : min(rightTemple.x + inset, midX)

        let leftForehead = CGPoint(x: leftForeheadX, y: min(leftTemple.y, faceBounds.minY))
        let rightForehead = CGPoint(x: rightForeheadX, y: min(rightTemple.y, faceBounds.minY))

        let hull = convexHull(contour + [leftForehead, rightForehead])
        guard hull.count >= 3, polygonArea(hull) > 1e-3 else { return nil }

        return hull.map { point in
            CGPoint(
                x: min(max((point.x - cropBounds.minX) / cropBounds.width, 0), 1),
                y: min(max((point.y - cropBounds.minY) / cropBounds.height, 0), 1)
            )
        }
    }

    /// Andrew's monotone chain 2D convex hull; returns vertices in counter-clockwise order.
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        var unique: [CGPoint] = []
        unique.reserveCapacity(sorted.count)
        for point in sorted {
            if let last = unique.last, abs(last.x - point.x) < 1e-9, abs(last.y - point.y) < 1e-9 {
                continue
            }
            unique.append(point)
        }
        guard unique.count >= 3 else { return unique }

        var lower: [CGPoint] = []
        for point in unique {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [CGPoint] = []
        for point in unique.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func cross(_ origin: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
    }

    private static func polygonArea(_ vertices: [CGPoint]) -> CGFloat {
        guard vertices.count >= 3 else { return 0 }
        var area: CGFloat = 0
        for i in 0..<vertices.count {
            let j = (i + 1) % vertices.count
            area += vertices[i].x * vertices[j].y - vertices[j].x * vertices[i].y
        }
        return abs(area) * 0.5
    }
}
