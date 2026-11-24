//
//  NotchShape.swift
//  glance
//
//  The notch silhouette. Inverted (concave) top corners flare the panel into the
//  menu bar; the flare has no standard-shape equivalent so it's a hand-built quad
//  curve, while the bottom corners use Apple's real `.continuous` curve (see
//  `ContinuousCorner`) for pixel parity with system UI. Body is inset by `topRadius`
//  per side for the flare (see `NotchGeometry.flareAllowance`).
//
//  `style` is fixed per screen, so deliberately excluded from `animatableData` —
//  only the radii interpolate.
//

import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var style: NotchPanelStyle = .notch

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        switch style {
        case .notch: return notchPath(in: rect)
        case .pill: return pillPath(in: rect)
        }
    }

    private nonisolated static func clampedRadii(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat, bodyRect: CGRect) {
        // Clamp so a small closed size can't produce self-intersecting
        // curves when the radii exceed half the available width/height.
        let top = max(0, min(topRadius, rect.width / 2))
        let bottom = max(0, min(bottomRadius, min(rect.width / 2 - top, rect.height)))
        let bodyRect = CGRect(
            x: rect.minX + top,
            y: rect.minY,
            width: rect.width - 2 * top,
            height: rect.height
        )
        return (top, bottom, bodyRect)
    }

    /// Reports whether `notchPath(in:)` uses the zero-allocation cached unit-corner
    /// Bézier fast path rather than clamped `UnevenRoundedRectangle` extraction.
    nonisolated static func usesCachedUnitCornerFastPath(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> Bool {
        let (_, bottom, bodyRect) = Self.clampedRadii(
            in: rect,
            topRadius: topRadius,
            bottomRadius: bottomRadius
        )
        return ContinuousCorner.canUseFastPath(bodyRect: bodyRect, radius: bottom)
    }

    private func notchPath(in rect: CGRect) -> Path {
        let (top, bottom, bodyRect) = Self.clampedRadii(
            in: rect,
            topRadius: topRadius,
            bottomRadius: bottomRadius
        )

        var path = Path()

        // Top-left: flare outward to meet the screen edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        if !ContinuousCorner.addBottomCorners(to: &path, bodyRect: bodyRect, radius: bottom) {
            // Fallback if a future OS version changes how UnevenRoundedRectangle
            // emits its path: the original quad-curve approximation.
            path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - top, y: rect.maxY)
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Top-right flare.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }

    /// Apple's real `.continuous` corner style — reads as a genuine Dynamic Island
    /// rather than a plain rounded card.
    private func pillPath(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let top = max(0, min(topRadius, limit))
        let bottom = max(0, min(bottomRadius, limit))
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        ).path(in: rect)
    }
}

/// There's no public API for "just the geometry of one continuous corner," so this
/// extracts unit-radius coefficients once from an unclamped `UnevenRoundedRectangle`
/// into `unitCorner` and scales/translates them directly per frame with zero allocations.
/// When a small rect clamps the corners (`reach > min(width/2, height)`), it falls back
/// to live `UnevenRoundedRectangle` extraction so clamped geometry stays exact.
private nonisolated enum ContinuousCorner {
    struct Segment: Sendable {
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    private struct ExtractedCorners: Sendable {
        let leftEdgeReach: CGPoint
        let left0: Segment
        let left1: Segment
        let left2: Segment
        let bottomEdgeRightReach: CGPoint
        let right0: Segment
        let right1: Segment
        let right2: Segment
    }

    private struct UnitCorner: Sendable {
        /// Normalized reach from the corner vertex along the straight edge for `radius = 1`.
        let reach: CGFloat
        let left0: Segment
        let left1: Segment
        let left2: Segment
        let right0: Segment
        let right1: Segment
        let right2: Segment
    }

    /// Extracted once for the lifetime of the process on an unclamped `1000×1000` square.
    private static let unitCorner: UnitCorner? = {
        let refRadius: CGFloat = 100
        let refSize: CGFloat = 1000
        let refRect = CGRect(x: 0, y: 0, width: refSize, height: refSize)
        guard let raw = extractCorners(bodyRect: refRect, radius: refRadius) else {
            return nil
        }

        func normLeft(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / refRadius, y: (point.y - refSize) / refRadius)
        }
        func normRight(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - refSize) / refRadius, y: (point.y - refSize) / refRadius)
        }
        func normSegment(_ segment: Segment, map: (CGPoint) -> CGPoint) -> Segment {
            Segment(control1: map(segment.control1), control2: map(segment.control2), to: map(segment.to))
        }

        return UnitCorner(
            reach: (refSize - raw.leftEdgeReach.y) / refRadius,
            left0: normSegment(raw.left0, map: normLeft),
            left1: normSegment(raw.left1, map: normLeft),
            left2: normSegment(raw.left2, map: normLeft),
            right0: normSegment(raw.right0, map: normRight),
            right1: normSegment(raw.right1, map: normRight),
            right2: normSegment(raw.right2, map: normRight)
        )
    }()

    static func canUseFastPath(bodyRect: CGRect, radius: CGFloat) -> Bool {
        guard radius > 0 else { return true }
        guard let unit = unitCorner else { return false }
        let reach = unit.reach * radius
        return reach <= bodyRect.width / 2 && reach <= bodyRect.height
    }

    static func addBottomCorners(to path: inout Path, bodyRect: CGRect, radius: CGFloat) -> Bool {
        if radius <= 0 {
            path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY))
            path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY))
            return true
        }

        if let unit = unitCorner {
            let reach = unit.reach * radius
            if reach <= bodyRect.width / 2 && reach <= bodyRect.height {
                emit(scaledCorners(unit: unit, bodyRect: bodyRect, radius: radius, reach: reach), to: &path)
                return true
            }
        }

        guard let corners = extractCorners(bodyRect: bodyRect, radius: radius) else {
            return false
        }
        emit(corners, to: &path)
        return true
    }

    private static func scaledCorners(
        unit: UnitCorner,
        bodyRect: CGRect,
        radius: CGFloat,
        reach: CGFloat
    ) -> ExtractedCorners {
        @inline(__always)
        func scaleLeft(_ offset: CGPoint) -> CGPoint {
            CGPoint(x: bodyRect.minX + offset.x * radius, y: bodyRect.maxY + offset.y * radius)
        }
        @inline(__always)
        func scaleRight(_ offset: CGPoint) -> CGPoint {
            CGPoint(x: bodyRect.maxX + offset.x * radius, y: bodyRect.maxY + offset.y * radius)
        }
        @inline(__always)
        func scaleSegment(_ segment: Segment, map: (CGPoint) -> CGPoint) -> Segment {
            Segment(control1: map(segment.control1), control2: map(segment.control2), to: map(segment.to))
        }

        // Not simply `bodyRect.maxY - radius` — continuous corners reach further up
        // the straight edge (`unit.reach * radius`) than a circular corner would.
        return ExtractedCorners(
            leftEdgeReach: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - reach),
            left0: scaleSegment(unit.left0, map: scaleLeft),
            left1: scaleSegment(unit.left1, map: scaleLeft),
            left2: scaleSegment(unit.left2, map: scaleLeft),
            bottomEdgeRightReach: CGPoint(x: bodyRect.maxX - reach, y: bodyRect.maxY),
            right0: scaleSegment(unit.right0, map: scaleRight),
            right1: scaleSegment(unit.right1, map: scaleRight),
            right2: scaleSegment(unit.right2, map: scaleRight)
        )
    }

    private static func emit(_ corners: ExtractedCorners, to path: inout Path) {
        path.addLine(to: corners.leftEdgeReach)
        path.addCurve(to: corners.left0.to, control1: corners.left0.control1, control2: corners.left0.control2)
        path.addCurve(to: corners.left1.to, control1: corners.left1.control1, control2: corners.left1.control2)
        path.addCurve(to: corners.left2.to, control1: corners.left2.control1, control2: corners.left2.control2)
        path.addLine(to: corners.bottomEdgeRightReach)
        path.addCurve(to: corners.right0.to, control1: corners.right0.control1, control2: corners.right0.control2)
        path.addCurve(to: corners.right1.to, control1: corners.right1.control1, control2: corners.right1.control2)
        path.addCurve(to: corners.right2.to, control1: corners.right2.control1, control2: corners.right2.control2)
    }

    /// `bodyRect` is the notch's inset-by-flare body, so extracted points already land
    /// on our own edges. Returns `nil` if a future OS version changes how the corner is emitted.
    private static func extractCorners(bodyRect: CGRect, radius: CGFloat) -> ExtractedCorners? {
        let reference = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        ).path(in: bodyRect)

        var elements: [Path.Element] = []
        reference.forEach { elements.append($0) }

        // Emitted order (verified empirically): move → line down the right edge (to p1,
        // where curvature begins) → 3 curves (bottom-right) → line across the bottom →
        // 3 curves (bottom-left) → line up the left edge → degenerate top-corner curves → close.
        guard elements.count >= 9,
            case .line(let p1) = elements[1],
            case .curve(let p2, let c2a, let c2b) = elements[2],
            case .curve(let p3, let c3a, let c3b) = elements[3],
            case .curve(let p4, let c4a, let c4b) = elements[4],
            case .line(let l5) = elements[5],
            case .curve(let p6, let c6a, let c6b) = elements[6],
            case .curve(let p7, let c7a, let c7b) = elements[7],
            case .curve(let p8, let c8a, let c8b) = elements[8]
        else { return nil }

        // The reference traces right→left; our path needs left→right, so everything
        // is reversed: segment order flips within each corner, control points swap,
        // and the two corners swap ends.
        return ExtractedCorners(
            leftEdgeReach: p8,
            left0: Segment(control1: c8b, control2: c8a, to: p7),
            left1: Segment(control1: c7b, control2: c7a, to: p6),
            left2: Segment(control1: c6b, control2: c6a, to: l5),
            bottomEdgeRightReach: p4,
            right0: Segment(control1: c4b, control2: c4a, to: p3),
            right1: Segment(control1: c3b, control2: c3a, to: p2),
            right2: Segment(control1: c2b, control2: c2a, to: p1)
        )
    }
}

#Preview("Notch") {
    NotchShape(topRadius: 16, bottomRadius: 65)
        .frame(width: 380, height: 260)
        .padding(20)
}

#Preview("Notch — closed") {
    NotchShape(topRadius: 8, bottomRadius: 12)
        .frame(width: 200, height: 32)
        .padding(20)
}

#Preview("Pill — collapsed") {
    NotchShape(topRadius: 16, bottomRadius: 16, style: .pill)
        .frame(width: NotchGeometry.pillClosedSize.width, height: NotchGeometry.pillClosedSize.height)
        .padding(20)
}

#Preview("Pill — expanded") {
    NotchShape(
        topRadius: NotchGeometry.pillOpenCornerRadius,
        bottomRadius: NotchGeometry.pillOpenCornerRadius,
        style: .pill
    )
    .frame(width: 380, height: 220)
    .padding(20)
}
