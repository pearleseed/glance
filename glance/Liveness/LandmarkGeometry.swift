//
//  LandmarkGeometry.swift
//  glance
//
//  Shared landmark math used by `FaceAligner` and the liveness analyzer —
//  moved out of `FaceAligner` so the two call sites can't drift apart.
//

import CoreGraphics
import Vision

/// Every landmark region this app reads from `VNFaceLandmarks2D`. Includes several regions
/// `FaceAligner` never needed — liveness samples more of them for its residual-coherence check.
enum LandmarkRegion: String, CaseIterable, Hashable, Sendable {
    case leftEye, rightEye
    case leftEyebrow, rightEyebrow
    case nose, noseCrest
    case outerLips, innerLips
    case faceContour, medianLine
}

/// One landmark point, tagged with where it came from. `indexInRegion` lets two frames'
/// points be paired up for cross-frame comparison.
nonisolated struct LandmarkPoint: Sendable {
    let point: CGPoint
    let region: LandmarkRegion
    let indexInRegion: Int
}

/// Pure geometry — `nonisolated` so it's callable from the same background
/// tasks `FaceAligner`/`FaceDetector` already run on.
nonisolated enum LandmarkGeometry {
    /// Maps a point from top-left/y-down crop pixel space (`0...cropSize`) back into
    /// top-left/y-down working-frame pixel space inside `cropWorkingRect`.
    static func mapPointFromCrop(
        _ point: CGPoint,
        cropSize: CGSize,
        toWorkingRect cropWorkingRect: CGRect
    ) -> CGPoint {
        guard cropSize.width > 0, cropSize.height > 0 else { return point }
        return CGPoint(
            x: cropWorkingRect.minX + (point.x / cropSize.width) * cropWorkingRect.width,
            y: cropWorkingRect.minY + (point.y / cropSize.height) * cropWorkingRect.height
        )
    }

    /// Vision returns points in bottom-left-origin, y-up; flipped here to top-left/y-down
    /// to match `DetectedFace.boundingBox`. When `workingRect` is provided, maps crop-space
    /// points linearly into working-frame coordinates.
    static func imagePoints(
        of region: VNFaceLandmarkRegion2D,
        imageSize: CGSize,
        mappedTo workingRect: CGRect? = nil
    ) -> [CGPoint] {
        let points = region.pointsInImage(imageSize: imageSize).map {
            CGPoint(x: $0.x, y: imageSize.height - $0.y)
        }
        guard let workingRect else { return points }
        return points.map { mapPointFromCrop($0, cropSize: imageSize, toWorkingRect: workingRect) }
    }

    static func centroid(
        of region: VNFaceLandmarkRegion2D,
        imageSize: CGSize,
        mappedTo workingRect: CGRect? = nil
    ) -> CGPoint? {
        let points = imagePoints(of: region, imageSize: imageSize, mappedTo: workingRect)
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Prefers the pupil landmark (a precise point) over the eye outline's
    /// centroid (an approximation from eyelid boundary points) when Vision
    /// provides one.
    static func eyeCenter(
        pupil: VNFaceLandmarkRegion2D?,
        eye: VNFaceLandmarkRegion2D?,
        imageSize: CGSize,
        mappedTo workingRect: CGRect? = nil
    ) -> CGPoint? {
        if let pupil, let center = centroid(of: pupil, imageSize: imageSize, mappedTo: workingRect) { return center }
        if let eye { return centroid(of: eye, imageSize: imageSize, mappedTo: workingRect) }
        return nil
    }

    /// Distance between the two eye centers — the normalization scale used throughout
    /// liveness scoring so scores stay comparable regardless of camera distance.
    static func interocularDistance(
        from landmarks: VNFaceLandmarks2D,
        imageSize: CGSize,
        mappedTo workingRect: CGRect? = nil
    ) -> CGFloat? {
        guard
            let left = eyeCenter(
                pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize, mappedTo: workingRect),
            let right = eyeCenter(
                pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize, mappedTo: workingRect)
        else { return nil }
        return hypot(left.x - right.x, left.y - right.y)
    }

    /// Rotation-invariant aspect ratio of a contour: spans along the longest axis
    /// (max pairwise distance) and its perpendicular normal, so 2D head roll does not
    /// shrink or inflate eye aspect ratio.
    static func contourAspectRatio(points: [CGPoint]) -> CGFloat? {
        guard points.count >= 3 else { return nil }
        var pA = points[0]
        var pB = points[1]
        var maxDistSq: CGFloat = 0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = points[j].x - points[i].x
                let dy = points[j].y - points[i].y
                let distSq = dx * dx + dy * dy
                if distSq > maxDistSq {
                    maxDistSq = distSq
                    pA = points[i]
                    pB = points[j]
                }
            }
        }
        let maxDist = maxDistSq.squareRoot()
        guard maxDist > 0 else { return nil }

        let ux = (pB.x - pA.x) / maxDist
        let uy = (pB.y - pA.y) / maxDist
        let nx = -uy
        let ny = ux

        var minProj = CGFloat.greatestFiniteMagnitude
        var maxProj = -CGFloat.greatestFiniteMagnitude
        for p in points {
            let proj = (p.x - pA.x) * nx + (p.y - pA.y) * ny
            if proj < minProj { minProj = proj }
            if proj > maxProj { maxProj = proj }
        }
        return (maxProj - minProj) / maxDist
    }

    static func eyeAspectRatio(
        of eyeRegion: VNFaceLandmarkRegion2D,
        imageSize: CGSize,
        mappedTo workingRect: CGRect? = nil
    ) -> CGFloat? {
        contourAspectRatio(points: imagePoints(of: eyeRegion, imageSize: imageSize, mappedTo: workingRect))
    }

    /// Projects the nose-to-eye-midpoint vector onto the inter-eye unit axis and normalizes
    /// by interocular distance, making the offset invariant to 2D in-plane roll.
    static func eyeAlignedNoseOffsetRatio(eyeA: CGPoint, eyeB: CGPoint, noseCenter: CGPoint) -> CGFloat? {
        let imageLeft = eyeA.x <= eyeB.x ? eyeA : eyeB
        let imageRight = eyeA.x <= eyeB.x ? eyeB : eyeA
        let dx = imageRight.x - imageLeft.x
        let dy = imageRight.y - imageLeft.y
        let iod = hypot(dx, dy)
        guard iod > 0 else { return nil }
        let ux = dx / iod
        let uy = dy / iod
        let midX = (imageLeft.x + imageRight.x) / 2
        let midY = (imageLeft.y + imageRight.y) / 2
        return ((noseCenter.x - midX) * ux + (noseCenter.y - midY) * uy) / iod
    }

    static func region(_ region: LandmarkRegion, of landmarks: VNFaceLandmarks2D) -> VNFaceLandmarkRegion2D? {
        switch region {
        case .leftEye: return landmarks.leftEye
        case .rightEye: return landmarks.rightEye
        case .leftEyebrow: return landmarks.leftEyebrow
        case .rightEyebrow: return landmarks.rightEyebrow
        case .nose: return landmarks.nose
        case .noseCrest: return landmarks.noseCrest
        case .outerLips: return landmarks.outerLips
        case .innerLips: return landmarks.innerLips
        case .faceContour: return landmarks.faceContour
        case .medianLine: return landmarks.medianLine
        }
    }

    /// Every point Vision detected, tagged by region and position so a later frame's
    /// points can be matched back up; a region missing this frame just contributes nothing.
    static func allPoints(
        from landmarks: VNFaceLandmarks2D,
        imageSize: CGSize,
        mappedTo workingRect: CGRect? = nil
    ) -> [LandmarkPoint] {
        var result: [LandmarkPoint] = []
        for regionCase in LandmarkRegion.allCases {
            guard let vnRegion = region(regionCase, of: landmarks) else { continue }
            let points = imagePoints(of: vnRegion, imageSize: imageSize, mappedTo: workingRect)
            for (index, point) in points.enumerated() {
                result.append(LandmarkPoint(point: point, region: regionCase, indexInRegion: index))
            }
        }
        return result
    }
}

// MARK: - Homography & Linear System

nonisolated extension LandmarkGeometry {
    /// 3×3 homography — the model a flat photograph (or phone screen) is limited to,
    /// including perspective tilt; strictly more general than `solveSimilarityTransform`.
    struct Homography {
        let h11, h12, h13, h21, h22, h23, h31, h32, h33: CGFloat

        func apply(_ point: CGPoint) -> CGPoint {
            let w = h31 * point.x + h32 * point.y + h33
            guard abs(w) > 1e-12 else { return point }
            return CGPoint(
                x: (h11 * point.x + h12 * point.y + h13) / w,
                y: (h21 * point.x + h22 * point.y + h23) / w
            )
        }

        fileprivate func multiplied(by other: Homography) -> Homography {
            Homography(
                h11: h11 * other.h11 + h12 * other.h21 + h13 * other.h31,
                h12: h11 * other.h12 + h12 * other.h22 + h13 * other.h32,
                h13: h11 * other.h13 + h12 * other.h23 + h13 * other.h33,
                h21: h21 * other.h11 + h22 * other.h21 + h23 * other.h31,
                h22: h21 * other.h12 + h22 * other.h22 + h23 * other.h32,
                h23: h21 * other.h13 + h22 * other.h23 + h23 * other.h33,
                h31: h31 * other.h11 + h32 * other.h21 + h33 * other.h31,
                h32: h31 * other.h12 + h32 * other.h22 + h33 * other.h32,
                h33: h31 * other.h13 + h32 * other.h23 + h33 * other.h33
            )
        }
    }

    private struct DLTRow {
        let xw, yw, ww, pxw, pyw, rhs: Double
    }

    /// Hartley-normalized DLT homography with `h33 = 1`, solved as an 8×8
    /// normal-equation system using stack-allocated flat buffers (0 heap allocations).
    /// Needs at least 4 correspondences; 6+ is the practical floor used by callers.
    static func solveHomography(
        from sourcePoints: [CGPoint], to destinationPoints: [CGPoint], weights: [CGFloat]? = nil
    ) -> Homography? {
        guard let weights else {
            return solveHomography(from: sourcePoints, to: destinationPoints, weightsBuffer: nil)
        }
        guard weights.count == sourcePoints.count else { return nil }
        return weights.withUnsafeBufferPointer {
            solveHomography(from: sourcePoints, to: destinationPoints, weightsBuffer: $0)
        }
    }

    private static func solveHomography(
        from sourcePoints: [CGPoint],
        to destinationPoints: [CGPoint],
        weightsBuffer: UnsafeBufferPointer<CGFloat>?
    ) -> Homography? {
        guard sourcePoints.count == destinationPoints.count, sourcePoints.count >= 4 else { return nil }
        guard weightsBuffer?.count ?? sourcePoints.count == sourcePoints.count else { return nil }
        guard let srcT = normalizingTransform(sourcePoints),
            let dstT = normalizingTransform(destinationPoints)
        else { return nil }

        let n = sourcePoints.count
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: 64) { ata in
            ata.initialize(repeating: 0)
            return withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { atb in
                atb.initialize(repeating: 0)

                for i in 0..<n {
                    let src = applyNormalization(sourcePoints[i], srcT)
                    let dst = applyNormalization(destinationPoints[i], dstT)
                    let w = Double((weightsBuffer?[i] ?? 1).squareRoot())
                    guard w > 0 else { continue }
                    let u = Double(dst.x)
                    let v = Double(dst.y)
                    let xw = Double(src.x) * w
                    let yw = Double(src.y) * w
                    // Two DLT rows, h33 fixed at 1:
                    // [x y 1 0 0 0 -u x -u y] · h = u
                    // [0 0 0 x y 1 -v x -v y] · h = v
                    accumulateDLTRowUpper(
                        blockStart: 0,
                        row: DLTRow(xw: xw, yw: yw, ww: w, pxw: -u * xw, pyw: -u * yw, rhs: u * w),
                        ata: ata, atb: atb
                    )
                    accumulateDLTRowUpper(
                        blockStart: 3,
                        row: DLTRow(xw: xw, yw: yw, ww: w, pxw: -v * xw, pyw: -v * yw, rhs: v * w),
                        ata: ata, atb: atb
                    )
                }

                for i in 0..<8 {
                    for j in (i + 1)..<8 { ata[j * 8 + i] = ata[i * 8 + j] }
                }

                guard solveLinearSystemInPlace(ata, atb, count: 8) else { return nil }
                let hNorm = Homography(
                    h11: CGFloat(atb[0]), h12: CGFloat(atb[1]), h13: CGFloat(atb[2]),
                    h21: CGFloat(atb[3]), h22: CGFloat(atb[4]), h23: CGFloat(atb[5]),
                    h31: CGFloat(atb[6]), h32: CGFloat(atb[7]), h33: 1
                )
                return denormalizeHomography(hNorm, source: srcT, destination: dstT)
            }
        }
    }

    /// Two-pass IRLS around `solveHomography`, Tukey biweight, so one wildly jittered
    /// landmark can't pull the plane around. Cutoff uses the full-set median so a smiling
    /// mouth stays in the fit rather than letting an underconstrained homography absorb parallax.
    static func solveRobustHomography(from sourcePoints: [CGPoint], to destinationPoints: [CGPoint]) -> Homography? {
        guard var current = solveHomography(from: sourcePoints, to: destinationPoints, weightsBuffer: nil) else {
            return nil
        }
        let n = sourcePoints.count
        return withUnsafeTemporaryAllocation(of: CGFloat.self, capacity: n * 3) { buffer in
            let residuals = UnsafeMutableBufferPointer(start: buffer.baseAddress, count: n)
            var scratch = UnsafeMutableBufferPointer(start: buffer.baseAddress! + n, count: n)
            let weights = UnsafeMutableBufferPointer(start: buffer.baseAddress! + n * 2, count: n)

            for _ in 0..<2 {
                for i in 0..<n {
                    let predicted = current.apply(sourcePoints[i])
                    let r = hypot(destinationPoints[i].x - predicted.x, destinationPoints[i].y - predicted.y)
                    residuals[i] = r
                    scratch[i] = r
                }
                scratch.sort()
                let mid = n / 2
                let median = n.isMultiple(of: 2) ? (scratch[mid - 1] + scratch[mid]) / 2 : scratch[mid]
                let cutoff = 4.685 * 1.4826 * max(median, 1e-4)
                var inliers = 0
                for i in 0..<n {
                    let u = residuals[i] / cutoff
                    if u >= 1 {
                        weights[i] = 0
                    } else {
                        let t = 1 - u * u
                        let w = t * t
                        weights[i] = w
                        if w > 0 { inliers += 1 }
                    }
                }
                if inliers < 6 { weights.initialize(repeating: 1) }
                if let refined = solveHomography(
                    from: sourcePoints, to: destinationPoints, weightsBuffer: UnsafeBufferPointer(weights)
                ) {
                    current = refined
                }
            }
            return current
        }
    }

    private struct SimilarityNorm {
        let scale, centerX, centerY: CGFloat
    }

    /// Translate to centroid, scale so mean distance from origin is √2.
    private static func normalizingTransform(_ points: [CGPoint]) -> SimilarityNorm? {
        let n = CGFloat(points.count)
        guard n > 0 else { return nil }
        let cx = points.reduce(CGFloat(0)) { $0 + $1.x } / n
        let cy = points.reduce(CGFloat(0)) { $0 + $1.y } / n
        let meanDist = points.reduce(CGFloat(0)) { $0 + hypot($1.x - cx, $1.y - cy) } / n
        guard meanDist > 1e-8 else { return nil }
        return SimilarityNorm(scale: CGFloat(2).squareRoot() / meanDist, centerX: cx, centerY: cy)
    }

    private static func applyNormalization(_ point: CGPoint, _ t: SimilarityNorm) -> CGPoint {
        CGPoint(x: t.scale * (point.x - t.centerX), y: t.scale * (point.y - t.centerY))
    }

    /// `H = Tdst⁻¹ · Hn · Tsrc`.
    private static func denormalizeHomography(
        _ h: Homography, source: SimilarityNorm, destination: SimilarityNorm
    ) -> Homography {
        let tSrc = Homography(
            h11: source.scale, h12: 0, h13: -source.scale * source.centerX,
            h21: 0, h22: source.scale, h23: -source.scale * source.centerY,
            h31: 0, h32: 0, h33: 1
        )
        let tDstInv = Homography(
            h11: 1 / destination.scale, h12: 0, h13: destination.centerX,
            h21: 0, h22: 1 / destination.scale, h23: destination.centerY,
            h31: 0, h32: 0, h33: 1
        )
        return tDstInv.multiplied(by: h.multiplied(by: tSrc))
    }

    @inline(__always)
    private static func accumulateDLTRowUpper(
        blockStart: Int,
        row: DLTRow,
        ata: UnsafeMutableBufferPointer<Double>,
        atb: UnsafeMutableBufferPointer<Double>
    ) {
        let c0 = blockStart
        let c1 = blockStart + 1
        let c2 = blockStart + 2
        atb[c0] += row.xw * row.rhs
        atb[c1] += row.yw * row.rhs
        atb[c2] += row.ww * row.rhs
        atb[6] += row.pxw * row.rhs
        atb[7] += row.pyw * row.rhs

        let r0 = c0 * 8
        let r1 = c1 * 8
        let r2 = c2 * 8
        ata[r0 + c0] += row.xw * row.xw
        ata[r0 + c1] += row.xw * row.yw
        ata[r0 + c2] += row.xw * row.ww
        ata[r0 + 6] += row.xw * row.pxw
        ata[r0 + 7] += row.xw * row.pyw
        ata[r1 + c1] += row.yw * row.yw
        ata[r1 + c2] += row.yw * row.ww
        ata[r1 + 6] += row.yw * row.pxw
        ata[r1 + 7] += row.yw * row.pyw
        ata[r2 + c2] += row.ww * row.ww
        ata[r2 + 6] += row.ww * row.pxw
        ata[r2 + 7] += row.ww * row.pyw
        ata[48 + 6] += row.pxw * row.pxw
        ata[48 + 7] += row.pxw * row.pyw
        ata[56 + 7] += row.pyw * row.pyw
    }

    /// In-place Gaussian elimination with partial pivoting on an `n x n` row-major flat buffer `a`
    /// and RHS buffer `b` (solution written back into `b`). Returns `false` if singular.
    private static func solveLinearSystemInPlace(
        _ a: UnsafeMutableBufferPointer<Double>,
        _ b: UnsafeMutableBufferPointer<Double>,
        count n: Int
    ) -> Bool {
        for k in 0..<n {
            var pivot = k
            var maxVal = abs(a[k * n + k])
            if k + 1 < n {
                for i in (k + 1)..<n {
                    let v = abs(a[i * n + k])
                    if v > maxVal {
                        maxVal = v
                        pivot = i
                    }
                }
            }
            if maxVal < 1e-12 { return false }
            if pivot != k {
                let rowK = k * n
                let rowP = pivot * n
                for j in k..<n { (a[rowK + j], a[rowP + j]) = (a[rowP + j], a[rowK + j]) }
                b.swapAt(k, pivot)
            }
            let rowK = k * n
            let diag = a[rowK + k]
            if k + 1 < n {
                for i in (k + 1)..<n {
                    let rowI = i * n
                    let factor = a[rowI + k] / diag
                    for j in k..<n { a[rowI + j] -= factor * a[rowK + j] }
                    b[i] -= factor * b[k]
                }
            }
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            let rowI = i * n
            var sum = b[i]
            if i + 1 < n {
                for j in (i + 1)..<n { sum -= a[rowI + j] * b[j] }
            }
            let diag = a[rowI + i]
            guard abs(diag) > 1e-12 else { return false }
            b[i] = sum / diag
        }
        return true
    }

    /// Gaussian elimination with partial pivoting. `nil` if singular.
    static func solveLinearSystem(_ matrix: [[CGFloat]], _ rhs: [CGFloat]) -> [CGFloat]? {
        let n = rhs.count
        guard matrix.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }
        if n == 0 { return [] }
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: n * n) { a in
            return withUnsafeTemporaryAllocation(of: Double.self, capacity: n) { b in
                for i in 0..<n {
                    b[i] = Double(rhs[i])
                    for j in 0..<n { a[i * n + j] = Double(matrix[i][j]) }
                }
                guard solveLinearSystemInPlace(a, b, count: n) else { return nil }
                return (0..<n).map { CGFloat(b[$0]) }
            }
        }
    }

    static func medianValue(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Similarity transform

    /// Closed-form least-squares similarity transform (rotation + uniform scale + translation),
    /// via 2D Procrustes in complex-number form — no SVD needed. This is exactly the model a flat
    /// presentation is limited to; motion it can't explain is the non-rigid residual `LivenessScoring` measures.
    static func solveSimilarityTransform(from sourcePoints: [CGPoint], to destinationPoints: [CGPoint])
        -> CGAffineTransform?
    {
        guard sourcePoints.count == destinationPoints.count, sourcePoints.count >= 2 else { return nil }

        let n = CGFloat(sourcePoints.count)
        let srcSum = sourcePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let srcMean = CGPoint(x: srcSum.x / n, y: srcSum.y / n)
        let dstSum = destinationPoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let dstMean = CGPoint(x: dstSum.x / n, y: dstSum.y / n)

        var numeratorReal: CGFloat = 0
        var numeratorImag: CGFloat = 0
        var denominator: CGFloat = 0
        for i in 0..<sourcePoints.count {
            let p = CGPoint(x: sourcePoints[i].x - srcMean.x, y: sourcePoints[i].y - srcMean.y)
            let q = CGPoint(x: destinationPoints[i].x - dstMean.x, y: destinationPoints[i].y - dstMean.y)
            // q * conj(p) = (qx + i*qy)(px - i*py) = (qx*px + qy*py) + i(qy*px - qx*py)
            numeratorReal += q.x * p.x + q.y * p.y
            numeratorImag += q.y * p.x - q.x * p.y
            denominator += p.x * p.x + p.y * p.y
        }
        guard denominator > 0 else { return nil }

        // scale*cos(theta), scale*sin(theta)
        let sc = numeratorReal / denominator
        let ss = numeratorImag / denominator

        // dst = R * scale * (src - srcMean) + dstMean, expanded into
        // CGAffineTransform's convention: x' = a*x + c*y + tx, y' = b*x + d*y + ty
        let tx = dstMean.x - (sc * srcMean.x - ss * srcMean.y)
        let ty = dstMean.y - (ss * srcMean.x + sc * srcMean.y)
        return CGAffineTransform(a: sc, b: ss, c: -ss, d: sc, tx: tx, ty: ty)
    }
}
