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
            capturedPoses: controller.capturedPoses,
            headTurn: controller.headTurn,
            isComplete: controller.enrollmentComplete,
            pulseActive: pulseActive,
            tickAngles: Self.tickAngles,
            tickSectorPoses: Self.tickSectorPoses,
            snapIfFirstAppear: snapIfFirstAppear
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

// MARK: - Per-tick animation state

@MainActor
private final class RingAnimationState {
    private static let tickCount = OnboardingMetrics.tickCount
    private static let degreesPerTick = 360.0 / Double(tickCount)
    private static let halfTurnSpan = Double(OnboardingMetrics.turnIndicatorTickSpan) / 2
    private static let convergenceEpsilon = 0.001

    var currentLength = [Double](repeating: Double(OnboardingMetrics.tickLengthUnlit), count: tickCount)
    var currentOpacity = [Double](repeating: 1.0, count: tickCount)
    var currentColorMix = [Double](repeating: 0.0, count: tickCount)
    var currentWidth = [Double](repeating: Double(OnboardingMetrics.tickWidth), count: tickCount)
    var currentRingOpacity = 0.0
    var currentRingScale = 0.92

    private var targetLength = [Double](repeating: Double(OnboardingMetrics.tickLengthUnlit), count: tickCount)
    private var targetOpacity = [Double](repeating: 1.0, count: tickCount)
    private var targetColorMix = [Double](repeating: 0.0, count: tickCount)
    private var targetWidth = [Double](repeating: Double(OnboardingMetrics.tickWidth), count: tickCount)
    private var targetRingOpacity = 0.0
    private var targetRingScale = 0.92

    private var lengthTau = [Double](repeating: 0.08, count: tickCount)
    private var opacityTau = [Double](repeating: 0.13, count: tickCount)
    private var colorTau = [Double](repeating: 0.08, count: tickCount)
    private var widthTau = [Double](repeating: 0.13, count: tickCount)

    private var lengthDelayUntil = [TimeInterval](repeating: 0, count: tickCount)
    private var opacityDelayUntil = [TimeInterval](repeating: 0, count: tickCount)
    private var colorDelayUntil = [TimeInterval](repeating: 0, count: tickCount)
    private var widthDelayUntil = [TimeInterval](repeating: 0, count: tickCount)

    private var previousLit = [Bool](repeating: false, count: tickCount)
    private var previousComplete = false
    private var previousPulseActive = false
    private var hasInitialized = false
    private var lastTimestamp: Date?

    var isSettled = true
    var pauseScheduled = false

    func updateTargets(
        capturedPoses: Set<EnrollmentPose>,
        headTurn: OnboardingController.HeadTurn?,
        isComplete: Bool,
        pulseActive: Bool,
        tickAngles: [Double],
        tickSectorPoses: [EnrollmentPose?],
        snapIfFirstAppear: Bool
    ) -> Bool {
        let isSnap = snapIfFirstAppear && !hasInitialized
        hasInitialized = true
        let nowSec = Date.now.timeIntervalSinceReferenceDate

        for index in 0..<Self.tickCount {
            let pose = tickSectorPoses[index]
            let isLitNow = isComplete || (pose.map { capturedPoses.contains($0) } ?? false)
            let newlyLit = !previousLit[index] && isLitNow
            let newlyComplete = !previousComplete && isComplete

            let intensity: Double
            if let turn = headTurn, !isComplete, !isLitNow {
                var delta = abs(tickAngles[index] - turn.angle)
                if delta > 180 { delta = 360 - delta }
                let falloff = max(0, 1 - (delta / Self.degreesPerTick) / Self.halfTurnSpan)
                intensity = turn.progress * falloff
            } else {
                intensity = 0
            }

            let newLength = (isLitNow || pulseActive)
                ? Double(OnboardingMetrics.tickLengthLit)
                : Double(OnboardingMetrics.tickLengthUnlit)
                    + Double(OnboardingMetrics.turnIndicatorLengthBoost) * intensity
            let newWidth = Double(isComplete ? OnboardingMetrics.tickWidthComplete : OnboardingMetrics.tickWidth)
            let newOpacity = isComplete ? 0.0 : 1.0
            let newColorMix = (isLitNow || isComplete) ? 1.0 : min(max(intensity, 0), 1)

            if isSnap {
                currentLength[index] = newLength
                currentWidth[index] = newWidth
                currentOpacity[index] = newOpacity
                currentColorMix[index] = newColorMix
                lengthDelayUntil[index] = 0
                opacityDelayUntil[index] = 0
                colorDelayUntil[index] = 0
                widthDelayUntil[index] = 0
            } else if newlyComplete {
                let stagger = Double(index) * 0.004
                widthDelayUntil[index] = nowSec + stagger
                widthTau[index] = 0.13
                opacityDelayUntil[index] = nowSec + stagger
                opacityTau[index] = 0.13
                lengthDelayUntil[index] = nowSec + stagger
                lengthTau[index] = 0.13
                colorDelayUntil[index] = nowSec + stagger
                colorTau[index] = 0.13
            } else if !isComplete && previousComplete {
                widthDelayUntil[index] = 0
                widthTau[index] = 0.08
                opacityDelayUntil[index] = 0
                opacityTau[index] = 0.08
                lengthDelayUntil[index] = 0
                lengthTau[index] = 0.08
                colorDelayUntil[index] = 0
                colorTau[index] = 0.08
            } else if newlyLit {
                let stagger = Double(index % OnboardingMetrics.ticksPerSector) * OnboardingMetrics.tickStagger
                lengthDelayUntil[index] = nowSec + stagger
                lengthTau[index] = 0.09
                colorDelayUntil[index] = nowSec + stagger
                colorTau[index] = 0.09
            } else if pulseActive != previousPulseActive, !isLitNow, !isComplete {
                lengthDelayUntil[index] = 0
                lengthTau[index] = 0.065
            } else if !isLitNow, !isComplete {
                if !pulseActive {
                    lengthDelayUntil[index] = 0
                    lengthTau[index] = 0.045
                }
                colorDelayUntil[index] = 0
                colorTau[index] = 0.045
            }

            targetLength[index] = newLength
            targetWidth[index] = newWidth
            targetOpacity[index] = newOpacity
            targetColorMix[index] = newColorMix
            previousLit[index] = isLitNow
        }

        targetRingOpacity = isComplete ? 1.0 : 0.0
        targetRingScale = isComplete ? 1.0 : 0.92
        previousComplete = isComplete
        previousPulseActive = pulseActive

        if isSnap {
            let needsRedraw =
                abs(currentRingOpacity - targetRingOpacity) >= Self.convergenceEpsilon
                || abs(currentRingScale - targetRingScale) >= Self.convergenceEpsilon
                || previousLit.contains(true)
                || headTurn != nil
            currentRingOpacity = targetRingOpacity
            currentRingScale = targetRingScale
            isSettled = true
            lastTimestamp = nil
            return needsRedraw
        }

        if matchesTargets(nowSec: nowSec) {
            isSettled = true
            lastTimestamp = nil
            return false
        }

        if isSettled {
            lastTimestamp = nil
        }
        isSettled = false
        return true
    }

    func step(to date: Date) -> Bool {
        if isSettled { return true }

        let nowSec = date.timeIntervalSinceReferenceDate
        let dt: Double
        if let lastTimestamp {
            dt = min(max(date.timeIntervalSince(lastTimestamp), 0), 0.05)
        } else {
            dt = 0
        }
        lastTimestamp = date

        var allConverged = true
        for index in 0..<Self.tickCount {
            if !stepChannel(
                &currentLength[index],
                target: targetLength[index],
                tau: lengthTau[index],
                delayUntil: lengthDelayUntil[index],
                nowSec: nowSec,
                dt: dt
            ) {
                allConverged = false
            }
            if !stepChannel(
                &currentOpacity[index],
                target: targetOpacity[index],
                tau: opacityTau[index],
                delayUntil: opacityDelayUntil[index],
                nowSec: nowSec,
                dt: dt
            ) {
                allConverged = false
            }
            if !stepChannel(
                &currentColorMix[index],
                target: targetColorMix[index],
                tau: colorTau[index],
                delayUntil: colorDelayUntil[index],
                nowSec: nowSec,
                dt: dt
            ) {
                allConverged = false
            }
            if !stepChannel(
                &currentWidth[index],
                target: targetWidth[index],
                tau: widthTau[index],
                delayUntil: widthDelayUntil[index],
                nowSec: nowSec,
                dt: dt
            ) {
                allConverged = false
            }
        }

        if !stepChannel(
            &currentRingOpacity,
            target: targetRingOpacity,
            tau: 0.13,
            delayUntil: 0,
            nowSec: nowSec,
            dt: dt
        ) {
            allConverged = false
        }
        if !stepChannel(
            &currentRingScale,
            target: targetRingScale,
            tau: 0.13,
            delayUntil: 0,
            nowSec: nowSec,
            dt: dt
        ) {
            allConverged = false
        }

        if allConverged {
            isSettled = true
            lastTimestamp = nil
        }
        return allConverged
    }

    @inline(__always)
    private func stepChannel(
        _ current: inout Double,
        target: Double,
        tau: Double,
        delayUntil: TimeInterval,
        nowSec: TimeInterval,
        dt: Double
    ) -> Bool {
        if nowSec < delayUntil {
            return false
        }
        let diff = target - current
        if abs(diff) < Self.convergenceEpsilon {
            current = target
            return true
        }
        if dt > 0 {
            let alpha = 1 - exp(-dt / max(tau, 0.001))
            current += diff * alpha
            if abs(target - current) < Self.convergenceEpsilon {
                current = target
                return true
            }
        }
        return false
    }

    private func matchesTargets(nowSec: TimeInterval) -> Bool {
        if abs(currentRingOpacity - targetRingOpacity) >= Self.convergenceEpsilon
            || abs(currentRingScale - targetRingScale) >= Self.convergenceEpsilon
        {
            return false
        }
        for index in 0..<Self.tickCount {
            if nowSec < lengthDelayUntil[index]
                || nowSec < opacityDelayUntil[index]
                || nowSec < colorDelayUntil[index]
                || nowSec < widthDelayUntil[index]
            {
                return false
            }
            if abs(currentLength[index] - targetLength[index]) >= Self.convergenceEpsilon
                || abs(currentOpacity[index] - targetOpacity[index]) >= Self.convergenceEpsilon
                || abs(currentColorMix[index] - targetColorMix[index]) >= Self.convergenceEpsilon
                || abs(currentWidth[index] - targetWidth[index]) >= Self.convergenceEpsilon
            {
                return false
            }
        }
        return true
    }
}
