//
//  EnrollmentRingView.swift
//  glance
//
//  80 ticks tile the circle in 45deg sectors that light up once captured; center has no
//  sector of its own and pulses every tick instead (see `centerPulseTick`). A short band
//  also tracks where the head is currently turned.
//

import SwiftUI

struct EnrollmentRingView: View {
    let controller: OnboardingController

    @State private var pulseActive = false
    @State private var pulseTask: Task<Void, Never>?
    @State private var isPaused = true
    @State private var animState = RingAnimationState()

    var body: some View {
        TimelineView(.animation(paused: isPaused)) { timeline in
            Canvas { context, size in
                let converged = animState.step(to: timeline.date)
                drawRing(in: &context, size: size)
                if converged && !isPaused && !animState.pauseScheduled {
                    animState.pauseScheduled = true
                    Task { @MainActor in
                        animState.pauseScheduled = false
                        if animState.isSettled {
                            isPaused = true
                        }
                    }
                }
            }
            .frame(width: Self.canvasDiameter, height: Self.canvasDiameter)
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .onAppear {
            syncTargets(snapIfFirstAppear: true)
        }
        .onDisappear {
            pulseTask?.cancel()
            pulseTask = nil
        }
        .onChange(of: controller.capturedPoses) { _, _ in
            syncTargets(snapIfFirstAppear: false)
        }
        .onChange(of: controller.headTurn) { _, _ in
            syncTargets(snapIfFirstAppear: false)
        }
        .onChange(of: controller.enrollmentComplete) { _, _ in
            syncTargets(snapIfFirstAppear: false)
        }
        .onChange(of: controller.centerPulseTick) { _, _ in
            triggerPulse()
        }
        .onChange(of: pulseActive) { _, _ in
            syncTargets(snapIfFirstAppear: false)
        }
    }

    private func syncTargets(snapIfFirstAppear: Bool) {
        let shouldAnimate = animState.updateTargets(
            RingTargetsInput(
                capturedPoses: controller.capturedPoses,
                headTurn: controller.headTurn,
                isComplete: controller.enrollmentComplete,
                pulseActive: pulseActive,
                tickAngles: Self.tickAngles,
                tickSectorPoses: Self.tickSectorPoses,
                snapIfFirstAppear: snapIfFirstAppear
            )
        )
        if shouldAnimate {
            isPaused = false
        }
    }

    private func drawRing(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let baseTransform = context.transform
        let baseOpacity = context.opacity

        for index in 0..<OnboardingMetrics.tickCount {
            let opacity = animState.currentOpacity[index]
            guard opacity > 0.001 else { continue }

            let length = CGFloat(animState.currentLength[index])
            let width = CGFloat(animState.currentWidth[index])
            let colorMix = animState.currentColorMix[index]

            context.transform = baseTransform
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: Angle(radians: Self.tickRadians[index]))
            context.opacity = baseOpacity * opacity

            let path: Path
            if abs(width - OnboardingMetrics.tickWidth) < 0.001
                && abs(length - OnboardingMetrics.tickLengthUnlit) < 0.001
            {
                path = Self.unlitTickPath
            } else if abs(width - OnboardingMetrics.tickWidth) < 0.001
                && abs(length - OnboardingMetrics.tickLengthLit) < 0.001
            {
                path = Self.litTickPath
            } else {
                // Inner tip anchored at `ringRadius`; growing `length` extends outward, not inward.
                let rect = CGRect(
                    x: -width * 0.5,
                    y: -(Self.ringRadius + length),
                    width: width,
                    height: length
                )
                path = Path(roundedRect: rect, cornerRadius: min(width, length) * 0.5)
            }

            let shading: GraphicsContext.Shading
            if colorMix <= 0.001 {
                shading = Self.whiteShading
            } else if colorMix >= 0.999 {
                shading = Self.accentShading
            } else {
                shading = GraphicsContext.Shading.color(GlanceTheme.whiteToAccent(colorMix))
            }

            context.fill(path, with: shading)
        }

        let ringOpacity = animState.currentRingOpacity
        if ringOpacity > 0.001 {
            let ringScale = CGFloat(animState.currentRingScale)
            context.transform = baseTransform
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: ringScale, y: ringScale)
            context.opacity = baseOpacity * ringOpacity
            context.stroke(
                Self.completionRingPath,
                with: Self.accentShading,
                lineWidth: OnboardingMetrics.completionRingWidth
            )
        }

        context.transform = baseTransform
        context.opacity = baseOpacity
    }

    private func triggerPulse() {
        pulseTask?.cancel()
        pulseTask = Task { @MainActor in
            pulseActive = true
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            pulseActive = false
        }
    }
}

// MARK: - Static geometry & sector lookup tables

extension EnrollmentRingView {
    private static let ringDiameter: CGFloat = OnboardingMetrics.tickRingOuterDiameter
    private static let ringRadius: CGFloat = ringDiameter / 2
    private static let canvasDiameter: CGFloat = OnboardingMetrics.enrollCameraClusterDiameter + 4

    private static let tickAngles: [Double] = (0..<OnboardingMetrics.tickCount).map { index in
        Double(index) * (360.0 / Double(OnboardingMetrics.tickCount))
    }

    private static let tickRadians: [Double] = tickAngles.map { $0 * .pi / 180.0 }

    /// Which of the 8 directional poses a tick's angle falls under —
    /// buckets each tick into the nearest 45deg sector once at type load.
    private static let tickSectorPoses: [EnrollmentPose?] = tickAngles.map { angle in
        let raw = Int((angle / 45.0).rounded()) % 8
        let sectorAngle = Double(raw) * 45
        return EnrollmentPose.allCases.first { $0.compassAngle == sectorAngle }
    }

    private static let unlitTickPath = Path(
        roundedRect: CGRect(
            x: -OnboardingMetrics.tickWidth * 0.5,
            y: -(ringRadius + OnboardingMetrics.tickLengthUnlit),
            width: OnboardingMetrics.tickWidth,
            height: OnboardingMetrics.tickLengthUnlit
        ),
        cornerRadius: OnboardingMetrics.tickWidth * 0.5
    )

    private static let litTickPath = Path(
        roundedRect: CGRect(
            x: -OnboardingMetrics.tickWidth * 0.5,
            y: -(ringRadius + OnboardingMetrics.tickLengthLit),
            width: OnboardingMetrics.tickWidth,
            height: OnboardingMetrics.tickLengthLit
        ),
        cornerRadius: OnboardingMetrics.tickWidth * 0.5
    )

    // Sized to sit just inside the lit ticks' outer tips, so the ring reads a hair
    // smaller once the ticks vanish and it's left on its own.
    private static let completionRingDiameter: CGFloat =
        ringDiameter
        + 2 * (OnboardingMetrics.tickLengthLit - OnboardingMetrics.completionRingRadiusInset)
        - OnboardingMetrics.completionRingWidth

    private static let completionRingPath = Path(
        ellipseIn: CGRect(
            x: -completionRingDiameter * 0.5,
            y: -completionRingDiameter * 0.5,
            width: completionRingDiameter,
            height: completionRingDiameter
        )
    )

    private static let whiteShading = GraphicsContext.Shading.color(.white)
    private static let accentShading = GraphicsContext.Shading.color(GlanceTheme.accent)
}
