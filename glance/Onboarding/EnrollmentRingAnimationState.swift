//
//  EnrollmentRingAnimationState.swift
//  glance
//
//  Per-tick animation state machine for `EnrollmentRingView`.
//

import Foundation

struct RingTargetsInput {
    let capturedPoses: Set<EnrollmentPose>
    let headTurn: OnboardingController.HeadTurn?
    let isComplete: Bool
    let pulseActive: Bool
    let tickAngles: [Double]
    let tickSectorPoses: [EnrollmentPose?]
    let snapIfFirstAppear: Bool
}

@MainActor
final class RingAnimationState {
    private struct ChannelTarget {
        let value: Double
        let tau: Double
        let delayUntil: TimeInterval
    }

    private struct TickStepContext {
        let nowSec: TimeInterval
        let dt: Double
    }

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

    func updateTargets(_ input: RingTargetsInput) -> Bool {
        let isSnap = input.snapIfFirstAppear && !hasInitialized
        hasInitialized = true
        let nowSec = Date.now.timeIntervalSinceReferenceDate

        for index in 0..<Self.tickCount {
            updateTickTarget(at: index, input: input, isSnap: isSnap, nowSec: nowSec)
        }

        targetRingOpacity = input.isComplete ? 1.0 : 0.0
        targetRingScale = input.isComplete ? 1.0 : 0.92
        previousComplete = input.isComplete
        previousPulseActive = input.pulseActive

        if isSnap {
            let needsRedraw =
                abs(currentRingOpacity - targetRingOpacity) >= Self.convergenceEpsilon
                || abs(currentRingScale - targetRingScale) >= Self.convergenceEpsilon
                || previousLit.contains(true)
                || input.headTurn != nil
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

    private func updateTickTarget(
        at index: Int,
        input: RingTargetsInput,
        isSnap: Bool,
        nowSec: TimeInterval
    ) {
        let pose = input.tickSectorPoses[index]
        let isLitNow = input.isComplete || (pose.map { input.capturedPoses.contains($0) } ?? false)
        let intensity = headTurnIntensity(
            at: input.tickAngles[index],
            headTurn: input.headTurn,
            isComplete: input.isComplete,
            isLitNow: isLitNow
        )

        let newLength =
            (isLitNow || input.pulseActive)
            ? Double(OnboardingMetrics.tickLengthLit)
            : Double(OnboardingMetrics.tickLengthUnlit)
                + Double(OnboardingMetrics.turnIndicatorLengthBoost) * intensity
        let newWidth = Double(input.isComplete ? OnboardingMetrics.tickWidthComplete : OnboardingMetrics.tickWidth)
        let newOpacity = input.isComplete ? 0.0 : 1.0
        let newColorMix = (isLitNow || input.isComplete) ? 1.0 : min(max(intensity, 0), 1)

        if isSnap {
            currentLength[index] = newLength
            currentWidth[index] = newWidth
            currentOpacity[index] = newOpacity
            currentColorMix[index] = newColorMix
            lengthDelayUntil[index] = 0
            opacityDelayUntil[index] = 0
            colorDelayUntil[index] = 0
            widthDelayUntil[index] = 0
        } else {
            applyTickTiming(at: index, input: input, isLitNow: isLitNow, nowSec: nowSec)
        }

        targetLength[index] = newLength
        targetWidth[index] = newWidth
        targetOpacity[index] = newOpacity
        targetColorMix[index] = newColorMix
        previousLit[index] = isLitNow
    }

    private func headTurnIntensity(
        at tickAngle: Double,
        headTurn: OnboardingController.HeadTurn?,
        isComplete: Bool,
        isLitNow: Bool
    ) -> Double {
        guard let turn = headTurn, !isComplete, !isLitNow else { return 0 }
        var delta = abs(tickAngle - turn.angle)
        if delta > 180 { delta = 360 - delta }
        let falloff = max(0, 1 - (delta / Self.degreesPerTick) / Self.halfTurnSpan)
        return turn.progress * falloff
    }

    private func applyTickTiming(
        at index: Int,
        input: RingTargetsInput,
        isLitNow: Bool,
        nowSec: TimeInterval
    ) {
        let newlyLit = !previousLit[index] && isLitNow
        let newlyComplete = !previousComplete && input.isComplete

        if newlyComplete {
            let stagger = Double(index) * 0.004
            widthDelayUntil[index] = nowSec + stagger
            widthTau[index] = 0.13
            opacityDelayUntil[index] = nowSec + stagger
            opacityTau[index] = 0.13
            lengthDelayUntil[index] = nowSec + stagger
            lengthTau[index] = 0.13
            colorDelayUntil[index] = nowSec + stagger
            colorTau[index] = 0.13
        } else if !input.isComplete && previousComplete {
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
        } else if input.pulseActive != previousPulseActive, !isLitNow, !input.isComplete {
            lengthDelayUntil[index] = 0
            lengthTau[index] = 0.065
        } else if !isLitNow, !input.isComplete {
            if !input.pulseActive {
                lengthDelayUntil[index] = 0
                lengthTau[index] = 0.045
            }
            colorDelayUntil[index] = 0
            colorTau[index] = 0.045
        }
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
        let context = TickStepContext(nowSec: nowSec, dt: dt)

        var allConverged = true
        for index in 0..<Self.tickCount where !stepTick(at: index, context: context) {
            allConverged = false
        }

        if !stepChannel(
            &currentRingOpacity,
            target: ChannelTarget(value: targetRingOpacity, tau: 0.13, delayUntil: 0),
            context: context
        ) {
            allConverged = false
        }
        if !stepChannel(
            &currentRingScale,
            target: ChannelTarget(value: targetRingScale, tau: 0.13, delayUntil: 0),
            context: context
        ) {
            allConverged = false
        }

        if allConverged {
            isSettled = true
            lastTimestamp = nil
        }
        return allConverged
    }

    private func stepTick(at index: Int, context: TickStepContext) -> Bool {
        let lengthDone = stepChannel(
            &currentLength[index],
            target: ChannelTarget(
                value: targetLength[index], tau: lengthTau[index], delayUntil: lengthDelayUntil[index]),
            context: context
        )
        let opacityDone = stepChannel(
            &currentOpacity[index],
            target: ChannelTarget(
                value: targetOpacity[index],
                tau: opacityTau[index],
                delayUntil: opacityDelayUntil[index]
            ),
            context: context
        )
        let colorDone = stepChannel(
            &currentColorMix[index],
            target: ChannelTarget(
                value: targetColorMix[index],
                tau: colorTau[index],
                delayUntil: colorDelayUntil[index]
            ),
            context: context
        )
        let widthDone = stepChannel(
            &currentWidth[index],
            target: ChannelTarget(value: targetWidth[index], tau: widthTau[index], delayUntil: widthDelayUntil[index]),
            context: context
        )
        return lengthDone && opacityDone && colorDone && widthDone
    }

    @inline(__always)
    private func stepChannel(
        _ current: inout Double,
        target: ChannelTarget,
        context: TickStepContext
    ) -> Bool {
        if context.nowSec < target.delayUntil {
            return false
        }
        let diff = target.value - current
        if abs(diff) < Self.convergenceEpsilon {
            current = target.value
            return true
        }
        if context.dt > 0 {
            let alpha = 1 - exp(-context.dt / max(target.tau, 0.001))
            current += diff * alpha
            if abs(target.value - current) < Self.convergenceEpsilon {
                current = target.value
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
