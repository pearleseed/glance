//
//  EnrollmentDirectionSweep.swift
//  glance
//
//  Procedural GPU-rendered light ribbons that sweep toward an enrollment direction;
//  intentionally not an arrow — the motion itself is the cue.
//

import SwiftUI

nonisolated enum EnrollmentSweepDirection: CaseIterable, Hashable, Sendable {
    case left, right, up, down, topLeft, topRight, bottomLeft, bottomRight

    /// Unit travel vector in screen space (x right, y down); sweep originates on the
    /// opposite side, e.g. `.left` travels right → left.
    var travel: CGVector {
        let d = CGFloat(1 / sqrt(2.0))
        switch self {
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        case .up: return CGVector(dx: 0, dy: -1)
        case .down: return CGVector(dx: 0, dy: 1)
        case .topLeft: return CGVector(dx: -d, dy: -d)
        case .topRight: return CGVector(dx: d, dy: -d)
        case .bottomLeft: return CGVector(dx: -d, dy: d)
        case .bottomRight: return CGVector(dx: d, dy: d)
        }
    }

    init?(pose: EnrollmentPose) {
        switch pose {
        case .center: return nil
        case .left: self = .left
        case .right: self = .right
        case .top: self = .up
        case .bottom: self = .down
        case .topLeft: self = .topLeft
        case .topRight: self = .topRight
        case .bottomLeft: self = .bottomLeft
        case .bottomRight: self = .bottomRight
        }
    }

    var previewLabel: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

struct EnrollmentDirectionSweep: View {
    let direction: EnrollmentSweepDirection

    @State private var startDate: Date?
    @State private var isPaused = false

    var body: some View {
        TimelineView(.animation(paused: isPaused)) { timeline in
            Canvas { context, size in
                guard size.width > 0, size.height > 0, let startDate, !isPaused else { return }
                let elapsed = max(0, timeline.date.timeIntervalSince(startDate))
                guard elapsed < Self.maxSweepDuration else { return }
                drawSweep(in: &context, size: size, elapsed: elapsed)
            }
            .opacity(OnboardingMetrics.sweepOverallOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            startDate = .now
            isPaused = false
        }
        .onDisappear {
            isPaused = true
        }
        .onChange(of: direction) { _, _ in
            startDate = .now
            isPaused = false
        }
        .task(id: direction) {
            try? await Task.sleep(for: .seconds(Self.maxSweepDuration + 0.05))
            guard !Task.isCancelled else { return }
            isPaused = true
        }
    }

    private struct SweepLayout {
        let travel: CGVector
        let perp: CGVector
        let shortEdge: CGFloat
        let startSpan: CGFloat
        let endSpan: CGFloat
        let center: CGPoint
        let perpExtent: CGFloat
        let spreadScale: CGFloat
        let baseTransform: CGAffineTransform
        let baseOpacity: Double
    }

    private func drawSweep(in context: inout GraphicsContext, size: CGSize, elapsed: Double) {
        let baseTransform = context.transform
        let baseOpacity = context.opacity
        let baseBlendMode = context.blendMode
        context.blendMode = .plusLighter

        let travel = direction.travel
        let perp = CGVector(dx: -travel.dy, dy: travel.dx)
        let shortEdge = min(size.width, size.height)
        let diagonal = hypot(size.width, size.height)
        let layout = SweepLayout(
            travel: travel,
            perp: perp,
            shortEdge: shortEdge,
            // Far end stops short of a full off-screen exit so the ease-out is still on-camera.
            startSpan: diagonal * 0.58,
            endSpan: diagonal * 0.50,
            center: CGPoint(x: size.width * 0.5, y: size.height * 0.5),
            // Spread along the true perpendicular screen axis so ribbons fan across the display.
            perpExtent: abs(perp.dx) * size.width + abs(perp.dy) * size.height,
            spreadScale: min(max(shortEdge / 700, 0.35), 1.35),
            baseTransform: baseTransform,
            baseOpacity: baseOpacity
        )

        for spec in Self.specs {
            drawStreak(spec, elapsed: elapsed, layout: layout, in: &context)
        }

        context.transform = baseTransform
        context.opacity = baseOpacity
        context.blendMode = baseBlendMode
    }

    private func drawStreak(
        _ spec: StreakSpec,
        elapsed: Double,
        layout: SweepLayout,
        in context: inout GraphicsContext
    ) {
        let rawU = (elapsed - spec.delay) / spec.duration
        guard rawU > 0, rawU < 1 else { return }

        let progress = Self.sweepTimingCurve(min(max(rawU, 0), 1))
        guard progress < spec.fadeOutAt else { return }
        let streakOpacity = Self.streakOpacity(
            at: progress,
            peak: spec.peakOpacity,
            fadeOutAt: spec.fadeOutAt
        )
        guard streakOpacity > 0.001 else { return }

        let lateral = spec.lateral * layout.perpExtent * 0.46
        let start = CGPoint(
            x: layout.center.x - layout.travel.dx * layout.startSpan + layout.perp.dx * lateral,
            y: layout.center.y - layout.travel.dy * layout.startSpan + layout.perp.dy * lateral
        )
        let end = CGPoint(
            x: layout.center.x + layout.travel.dx * layout.endSpan + layout.perp.dx * lateral,
            y: layout.center.y + layout.travel.dy * layout.endSpan + layout.perp.dy * lateral
        )
        let bow = spec.bow * layout.shortEdge * 0.20
        let control = CGPoint(
            x: (start.x + end.x) * 0.5 + layout.perp.dx * bow,
            y: (start.y + end.y) * 0.5 + layout.perp.dy * bow
        )

        let u = 1 - progress
        let point = CGPoint(
            x: u * u * start.x + 2 * u * progress * control.x + progress * progress * end.x,
            y: u * u * start.y + 2 * u * progress * control.y + progress * progress * end.y
        )
        let dx = 2 * u * (control.x - start.x) + 2 * progress * (end.x - control.x)
        let dy = 2 * u * (control.y - start.y) + 2 * progress * (end.y - control.y)
        let heading = atan2(dy, dx) + spec.rotationDrift * progress

        let length = max(layout.shortEdge * spec.lengthFactor * 0.55, 180)
        let baseAlpha = layout.baseOpacity * streakOpacity

        context.transform = layout.baseTransform
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: Angle(radians: heading))
        let streakTransform = context.transform

        // Outer soft aurora halo with Gaussian-like radial falloff to alpha 0.
        let haloRx = length * 0.62 + 82 * spec.haloScale * layout.spreadScale
        let haloRy = spec.thickness * 0.48 * layout.spreadScale + 78 * spec.haloScale * layout.spreadScale
        context.opacity = baseAlpha * (spec.isVivid ? 0.075 : 0.044)
        context.scaleBy(x: haloRx, y: haloRy)
        context.fill(Self.unitEllipsePath, with: Self.haloShading)

        // Mid luminous ribbon body shifted slightly forward for directional momentum.
        let bodyRx = length * 0.52 + 28 * spec.haloScale * layout.spreadScale
        let bodyRy = spec.thickness * 0.28 * layout.spreadScale + 22 * spec.haloScale * layout.spreadScale
        context.transform = streakTransform
        context.translateBy(x: length * 0.06, y: 0)
        context.scaleBy(x: bodyRx, y: bodyRy)
        context.opacity = baseAlpha * (spec.isVivid ? 0.17 : 0.105)
        context.fill(
            Self.unitEllipsePath,
            with: spec.isVivid ? Self.vividBodyShading : Self.normalBodyShading
        )

        // Crisp inner filament highlight for vivid / foreground streaks.
        if spec.hasHighlight {
            let highlightRx = length * 0.38 + 10 * layout.spreadScale
            let highlightRy = max(spec.thickness * 0.085 * layout.spreadScale, 5) + 6 * layout.spreadScale
            context.transform = streakTransform
            context.translateBy(x: length * 0.10, y: 0)
            context.scaleBy(x: highlightRx, y: highlightRy)
            context.opacity = baseAlpha * (spec.isVivid ? 0.22 : 0.13)
            context.fill(Self.unitEllipsePath, with: Self.highlightShading)
        }
    }
}

// MARK: - Streak specs & shading

private struct StreakSpec {
    let thickness: CGFloat
    let lengthFactor: CGFloat
    let haloScale: CGFloat
    let peakOpacity: Double
    let duration: Double
    let delay: Double
    /// Perpendicular offset (fraction of the shorter canvas edge); signed so streaks fan out.
    let lateral: CGFloat
    /// Bézier curvature (fraction of the shorter canvas edge); opposite signs arc opposite ways.
    let bow: CGFloat
    let rotationDrift: Double
    /// Progress at which opacity reaches zero; below 1 dies mid-screen, 1.0 runs off the far edge.
    let fadeOutAt: Double
    let hasHighlight: Bool
    let isVivid: Bool
}

extension EnrollmentDirectionSweep {
    private static let unitEllipsePath = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))

    private static let haloShading = GraphicsContext.Shading.radialGradient(
        Gradient(stops: [
            .init(color: GlanceTheme.accentBright, location: 0.0),
            .init(color: GlanceTheme.accentBright.opacity(0.84), location: 0.22),
            .init(color: GlanceTheme.accent.opacity(0.49), location: 0.45),
            .init(color: GlanceTheme.accent.opacity(0.20), location: 0.68),
            .init(color: GlanceTheme.accentDeep.opacity(0.08), location: 0.85),
            .init(color: GlanceTheme.accentDeep.opacity(0.0), location: 1.0)
        ]),
        center: .zero,
        startRadius: 0,
        endRadius: 1
    )

    private static let normalBodyShading = GraphicsContext.Shading.radialGradient(
        Gradient(stops: [
            .init(color: GlanceTheme.accentBright, location: 0.0),
            .init(color: GlanceTheme.accentBright.opacity(0.84), location: 0.22),
            .init(color: GlanceTheme.accent.opacity(0.49), location: 0.45),
            .init(color: GlanceTheme.accent.opacity(0.20), location: 0.68),
            .init(color: GlanceTheme.accent.opacity(0.07), location: 0.85),
            .init(color: GlanceTheme.accent.opacity(0.0), location: 1.0)
        ]),
        center: .zero,
        startRadius: 0,
        endRadius: 1
    )

    private static let vividBodyShading = GraphicsContext.Shading.radialGradient(
        Gradient(stops: [
            .init(color: GlanceTheme.accentPale, location: 0.0),
            .init(color: GlanceTheme.accentPale.opacity(0.85), location: 0.22),
            .init(color: GlanceTheme.accentBright.opacity(0.52), location: 0.45),
            .init(color: GlanceTheme.accentBright.opacity(0.22), location: 0.68),
            .init(color: GlanceTheme.accent.opacity(0.08), location: 0.85),
            .init(color: GlanceTheme.accent.opacity(0.0), location: 1.0)
        ]),
        center: .zero,
        startRadius: 0,
        endRadius: 1
    )

    private static let highlightShading = GraphicsContext.Shading.radialGradient(
        Gradient(stops: [
            .init(color: Color.white, location: 0.0),
            .init(color: GlanceTheme.accentPale.opacity(0.82), location: 0.24),
            .init(color: GlanceTheme.accentPale.opacity(0.44), location: 0.48),
            .init(color: GlanceTheme.accentBright.opacity(0.14), location: 0.74),
            .init(color: GlanceTheme.accentBright.opacity(0.0), location: 1.0)
        ]),
        center: .zero,
        startRadius: 0,
        endRadius: 1
    )

    /// 28 ribbons fanned across a fixed perpendicular span — matches dense aurora field
    /// while rendering in a single GPU Canvas pass without offscreen blur surfaces.
    private static let specs: [StreakSpec] = makeSpecs()
    private static let maxSweepDuration: Double = specs.map { $0.delay + $0.duration }.max() ?? 1.4

    private static func makeSpecs() -> [StreakSpec] {
        let count = 28
        let laterals = (0..<count).map { index -> CGFloat in
            let t = CGFloat(index) / CGFloat(count - 1)
            return -0.86 + t * 1.72
        }
        return laterals.enumerated().map { index, lateral in
            let lane = index % 7
            let edgeFade = 1 - abs(Double(lateral)) * 0.22
            let isVivid = index % 6 == 1 || index % 6 == 4
            let wideHalo = index % 4 != 0
            let haloScale: CGFloat =
                [1.35, 1.16, 0.96, 1.22, 0.82, 1.32, 1.02][lane]
                * (wideHalo ? 2.6 : 1.1)
            let peakBase: Double = [0.58, 0.72, 0.80, 0.52, 0.66, 0.42, 0.48][lane]
            let bow: CGFloat = [0.18, -0.14, 0.10, -0.22, 0.26, 0.08, -0.12][lane]
            return StreakSpec(
                thickness: [310, 190, 105, 155, 72, 230, 88][lane],
                lengthFactor: [1.16, 0.94, 0.72, 0.86, 0.54, 1.04, 0.62][lane],
                haloScale: haloScale,
                peakOpacity: peakBase * edgeFade * (isVivid ? 1.4 : 1),
                duration: [1.22, 1.08, 0.98, 1.16, 0.94, 1.28, 1.04][lane],
                delay: [0.00, 0.03, 0.06, 0.015, 0.08, 0.04, 0.065][lane]
                    + Double(index % 4) * 0.008,
                lateral: lateral,
                bow: bow,
                rotationDrift: bow.sign == .minus ? -0.05 : 0.05,
                fadeOutAt: 1,
                hasHighlight: isVivid || lane == 2 || lane == 4,
                isVivid: isVivid
            )
        }
    }

    /// Evaluates cubic Bézier timing curve (0.68, 0.0, 0.32, 1.0) at normalized time `u` in `0...1`.
    private static func sweepTimingCurve(_ u: Double) -> Double {
        var s = u
        // x(s) = 2.04*s - 3.12*s^2 + 2.08*s^3, derivative >= 0.48 everywhere on [0, 1].
        for _ in 0..<5 {
            let x = (2.04 + (-3.12 + 2.08 * s) * s) * s
            let dx = 2.04 + (-6.24 + 6.24 * s) * s
            s = min(max(s - (x - u) / dx, 0), 1)
        }
        // y(s) with p1y = 0, p2y = 1 simplifies to s^2 * (3 - 2*s).
        return s * s * (3 - 2 * s)
    }

    private static func streakOpacity(at t: Double, peak: Double, fadeOutAt: Double) -> Double {
        let fadeInEnd = 0.07
        // Dissolve during the ease-out so the slowdown is still visible.
        let fadeOutStart = 0.7
        if t <= 0 || t >= fadeOutAt { return 0 }
        if t < fadeInEnd {
            let u = t / fadeInEnd
            return peak * (u * u * (3 - 2 * u))
        }
        if t > fadeOutStart {
            let span = max(fadeOutAt - fadeOutStart, 0.001)
            let u = (t - fadeOutStart) / span
            let s = u * u * (3 - 2 * u)
            return peak * (1 - s)
        }
        return peak
    }
}

// MARK: - Previews

#Preview("All directions") {
    let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]
    LazyVGrid(columns: columns, spacing: 8) {
        ForEach(EnrollmentSweepDirection.allCases, id: \.self) { direction in
            ZStack(alignment: .topLeading) {
                Color.black
                EnrollmentDirectionSweep(direction: direction)
                Text(direction.previewLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(8)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
    .padding(12)
    .frame(width: 920, height: 360)
    .background(Color.black)
}

#Preview("Cycling") {
    struct CyclingSweepPreview: View {
        @State private var index = 0
        private let directions = EnrollmentSweepDirection.allCases

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                EnrollmentDirectionSweep(direction: directions[index])
                    .id(directions[index])
                    .transition(.opacity)
                    .animation(.easeInOut(duration: OnboardingMetrics.sweepDirectionCrossfade), value: index)
                Text(directions[index].previewLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(16)
            }
            .frame(width: 900, height: 560)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4.2))
                    index = (index + 1) % directions.count
                }
            }
        }
    }

    return CyclingSweepPreview()
}
