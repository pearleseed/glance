//
//  EnrollmentPoseEvaluatorTests.swift
//  GlanceTests
//
//  Swift Testing suite for `EnrollmentPoseEvaluator` neutral pitch calibration
//  and omni-directional circular matching.
//

import Foundation
import Testing

@Suite("EnrollmentPoseEvaluator")
struct EnrollmentPoseEvaluatorTests {
    @Test("Calibrates tilted laptop lid pitch and matches omni-directional poses")
    func briefCoreCalibrationAndMatching() {
        // 1. Laptop lid camera tilted below eye level (-0.36 rad raw pitch):
        //    Center calibration must absorb -0.36 rad so looking straight isn't flagged "Too far up".
        var evaluator = EnrollmentPoseEvaluator()
        for _ in 0..<4 {
            evaluator = evaluator.observing(rawYaw: 0.02, rawPitch: -0.36)
            evaluator = evaluator.recordingCenterSample(yaw: 0.02, pitch: -0.36)
        }
        evaluator = evaluator.finalizingCenterCalibration()
        #expect(evaluator.isCalibrated)
        #expect(abs(evaluator.neutralPitch - (-0.36)) < 0.05)

        // 2. Omni-directional matching: turning right (+0.28 relative right = -0.28 yaw) matches .right.
        evaluator = evaluator.clearedFrame().observing(rawYaw: -0.28, rawPitch: -0.36)
        let remaining: Set<EnrollmentPose> = [.top, .right, .bottom, .left]
        let matched = evaluator.matchingDirection(remaining: remaining, stalled: false)
        #expect(matched == .right)

        // 3. Turning head down relative to calibrated -0.36 baseline (rawPitch = -0.14 => delta +0.22) matches .bottom.
        evaluator = evaluator.clearedFrame().observing(rawYaw: 0.01, rawPitch: -0.14)
        let matchedDown = evaluator.matchingDirection(remaining: remaining, stalled: false)
        #expect(matchedDown == .bottom)
    }

    @Test("Accepts realistic laptop-lid center angles before calibration and rejects extremes")
    func uncalibratedLaptopCenterBounds() {
        // Steep tilted laptop lid (-0.36 rad) must pass center match and never warn "Too far up".
        let tilted = EnrollmentPoseEvaluator().observing(rawYaw: 0.02, rawPitch: -0.36)
        #expect(tilted.matchesCenter(stalled: false))
        #expect(tilted.excessiveTurn(for: .center, remaining: []) == nil)

        let upperDeskCam = EnrollmentPoseEvaluator().observing(rawYaw: 0.0, rawPitch: 0.35)
        #expect(upperDeskCam.matchesCenter(stalled: false))
        #expect(upperDeskCam.excessiveTurn(for: .center, remaining: []) == nil)

        // Genuinely extreme pitch or yaw during uncalibrated center must be rejected.
        let extremeUp = EnrollmentPoseEvaluator().observing(rawYaw: 0.0, rawPitch: -0.65)
        #expect(!extremeUp.matchesCenter(stalled: false))
        #expect(extremeUp.excessiveTurn(for: .center, remaining: []) == .up)

        let extremeDown = EnrollmentPoseEvaluator().observing(rawYaw: 0.0, rawPitch: 0.55)
        #expect(!extremeDown.matchesCenter(stalled: false))
        #expect(extremeDown.excessiveTurn(for: .center, remaining: []) == .down)

        let offCenterYaw = EnrollmentPoseEvaluator().observing(rawYaw: 0.25, rawPitch: -0.36)
        #expect(!offCenterYaw.matchesCenter(stalled: false))
    }

    @Test("Calibration uses median to reject outliers, clamps bounds, and handles empty samples")
    func calibrationMedianAndClamp() {
        // Median rejects single-frame outlier and clamps to (-0.10...0.10, -0.45...0.35).
        var evaluator = EnrollmentPoseEvaluator()
        evaluator = evaluator.recordingCenterSample(yaw: 0.03, pitch: -0.35)
        evaluator = evaluator.recordingCenterSample(yaw: 0.01, pitch: -0.37)
        evaluator = evaluator.recordingCenterSample(yaw: 0.02, pitch: -0.36)
        evaluator = evaluator.recordingCenterSample(yaw: 0.45, pitch: 0.30)
        evaluator = evaluator.finalizingCenterCalibration()
        #expect(abs(evaluator.neutralYaw - 0.025) < 0.001)
        #expect(abs(evaluator.neutralPitch - (-0.355)) < 0.001)

        // Clamp bounds check.
        let clampedHigh = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.25, pitch: 0.50)
            .finalizingCenterCalibration()
        #expect(clampedHigh.neutralYaw == 0.10)
        #expect(clampedHigh.neutralPitch == 0.35)

        let clampedLow = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: -0.25, pitch: -0.60)
            .finalizingCenterCalibration()
        #expect(clampedLow.neutralYaw == -0.10)
        #expect(clampedLow.neutralPitch == -0.45)

        // Empty calibration safely defaults to (0, 0).
        let empty = EnrollmentPoseEvaluator().finalizingCenterCalibration()
        #expect(empty.isCalibrated)
        #expect(empty.neutralYaw == 0)
        #expect(empty.neutralPitch == 0)
    }

    @Test("Matches all 8 directional sectors in both clockwise and counter-clockwise sweeps")
    func allEightSectorsCWAndCCW() {
        var base = EnrollmentPoseEvaluator()
        for _ in 0..<3 {
            base = base.recordingCenterSample(yaw: 0.0, pitch: -0.36)
        }
        base = base.finalizingCenterCalibration()

        let sectorInputs: [(EnrollmentPose, Float, Float)] = [
            (.top, 0.0, -0.36 - 0.20),
            (.topRight, -0.19, -0.36 - 0.14),
            (.right, -0.27, -0.36),
            (.bottomRight, -0.19, -0.36 + 0.14),
            (.bottom, 0.0, -0.36 + 0.20),
            (.bottomLeft, 0.19, -0.36 + 0.14),
            (.left, 0.27, -0.36),
            (.topLeft, 0.19, -0.36 - 0.14)
        ]

        // Sweep CW, removing each pose as captured.
        var remainingCW = Set(EnrollmentPose.allCases.filter { $0 != .center })
        for (expected, yaw, pitch) in sectorInputs {
            let probe = base.clearedFrame().observing(rawYaw: yaw, rawPitch: pitch)
            let matched = probe.matchingDirection(remaining: remainingCW, stalled: false)
            #expect(matched == expected)
            remainingCW.remove(expected)
        }
        #expect(remainingCW.isEmpty)

        // Sweep CCW, removing each pose as captured.
        var remainingCCW = Set(EnrollmentPose.allCases.filter { $0 != .center })
        for (expected, yaw, pitch) in sectorInputs.reversed() {
            let probe = base.clearedFrame().observing(rawYaw: yaw, rawPitch: pitch)
            let matched = probe.matchingDirection(remaining: remainingCCW, stalled: false)
            #expect(matched == expected)
            remainingCCW.remove(expected)
        }
        #expect(remainingCCW.isEmpty)

        // Opposite direction must never match when only .top remains.
        let lookingDown = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.14)
        #expect(lookingDown.matchingDirection(remaining: [.top], stalled: false) == nil)
    }

    @Test("Applies 0.50 EMA smoothing and preserves calibration across clearedFrame")
    func emaSmoothingAndClearedFrame() {
        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.0, pitch: -0.36)
            .finalizingCenterCalibration()

        // Starting from center, a single noisy spike (-0.30) is damped by 0.50 EMA to -0.15.
        let settled = base.observing(rawYaw: 0.0, rawPitch: -0.36)
        let spiked = settled.observing(rawYaw: -0.30, rawPitch: -0.36)
        #expect(abs((spiked.smoothedYaw ?? 99) - (-0.15)) < 0.001)

        // clearedFrame clears smoothed observation but preserves calibration.
        let cleared = spiked.clearedFrame()
        #expect(cleared.isCalibrated)
        #expect(abs(cleared.neutralPitch - (-0.36)) < 0.001)
        #expect(cleared.smoothedYaw == nil)
        #expect(cleared.smoothedPitch == nil)
    }

    @Test("Computes live headTurn compass vectors and relative excessiveTurn warnings")
    func headTurnAndExcessiveTurn() throws {
        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.0, pitch: -0.36)
            .finalizingCenterCalibration()

        // Uncalibrated evaluator returns nil for headTurn().
        #expect(EnrollmentPoseEvaluator().observing(rawYaw: -0.30, rawPitch: -0.36).headTurn() == nil)

        // Within deadzone (<= 0.15) returns nil.
        let tiny = base.observing(rawYaw: -0.02, rawPitch: -0.36)
        #expect(tiny.headTurn() == nil)

        // Right turn (compass 90 deg).
        let rightTurn = try #require(base.clearedFrame().observing(rawYaw: -0.24, rawPitch: -0.36).headTurn())
        #expect(abs(rightTurn.angle - 90.0) < 1.0)
        #expect(abs(rightTurn.progress - 1.0) < 0.01)

        // Up turn relative to -0.36 (compass 0 deg).
        let upTurn = try #require(base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.53).headTurn())
        #expect(upTurn.angle < 1.0 || upTurn.angle > 359.0)

        // Relative excessiveTurn: looking slightly up at -0.54 (rel -0.18) must NOT trigger excessiveTurn.
        let validUp = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.54)
        #expect(validUp.excessiveTurn(for: nil, remaining: [.top]) == nil)

        // Genuine overshoot: relPitch = -0.42 (raw -0.78) triggers .up, relPitch = +0.42 (raw +0.06) triggers .down.
        let tooUp = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.78)
        #expect(tooUp.excessiveTurn(for: nil, remaining: [.top]) == .up)

        let tooDown = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: 0.06)
        #expect(tooDown.excessiveTurn(for: nil, remaining: [.bottom]) == .down)

        let tooTopRight = base.clearedFrame().observing(rawYaw: -0.55, rawPitch: -0.78)
        #expect(tooTopRight.excessiveTurn(for: nil, remaining: [.topRight]) == .topRight)

        // Post-calibration excessiveTurn(for: .center, ...) must use relative bounds, not uncalibrated bounds.
        let calibratedCenterValidUp = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.65)
        #expect(calibratedCenterValidUp.excessiveTurn(for: .center, remaining: [.top]) == nil)

        let calibratedCenterTooDown = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: 0.06)
        #expect(calibratedCenterTooDown.excessiveTurn(for: .center, remaining: [.bottom]) == .down)
    }

    @Test("Applies stall widening and downward pose match leniency")
    func stalledWideningAndLeniency() {
        // Uncalibrated center stall widening: yaw limit widens 0.18 -> 0.225, pitch clamp pads +-0.08 (-0.53...0.43).
        let uncalibratedEdge = EnrollmentPoseEvaluator().observing(rawYaw: 0.20, rawPitch: -0.50)
        #expect(!uncalibratedEdge.matchesCenter(stalled: false))
        #expect(uncalibratedEdge.matchesCenter(stalled: true))

        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.0, pitch: -0.36)
            .finalizingCenterCalibration()

        // Calibrated center stall widening: yaw 0.20 < 0.225, relPitch 0.17 < 0.1875.
        let calibratedEdge = base.observing(rawYaw: 0.20, rawPitch: -0.36 + 0.17)
        #expect(!calibratedEdge.matchesCenter(stalled: false))
        #expect(calibratedEdge.matchesCenter(stalled: true))

        // Directional magnitude widening: 0.21 / 0.24 = 0.875 (< 1.0 normal, >= 0.8 stalled).
        let partialRight = base.observing(rawYaw: -0.21, rawPitch: -0.36)
        #expect(partialRight.matchingDirection(remaining: [.right], stalled: false) == nil)
        #expect(partialRight.matchingDirection(remaining: [.right], stalled: true) == .right)

        // Directional angular half-width widening: 118 deg (28 deg from .right: > 24 normal, <= 33.75 stalled).
        let angleRad = 118.0 * Double.pi / 180.0
        let x = sin(angleRad) * 1.2
        let y = cos(angleRad) * 1.2
        let angledRight = base.observing(rawYaw: Float(-x) * 0.24, rawPitch: -0.36 + Float(-y) * 0.17)
        #expect(angledRight.matchingDirection(remaining: [.right], stalled: false) == nil)
        #expect(angledRight.matchingDirection(remaining: [.right], stalled: true) == .right)

        // Downward matchLeniency: .bottom (1.2 => 0.833 req) and .bottomLeft (1.5 => 0.667 req).
        let gentleDown = base.observing(rawYaw: 0.0, rawPitch: -0.36 + 0.15)
        #expect(gentleDown.matchingDirection(remaining: [.bottom], stalled: false) == .bottom)
        let symmetricUp = base.observing(rawYaw: 0.0, rawPitch: -0.36 - 0.15)
        #expect(symmetricUp.matchingDirection(remaining: [.top], stalled: false) == nil)

        let gentleBottomLeft = base.observing(rawYaw: 0.12, rawPitch: -0.36 + 0.085)
        #expect(gentleBottomLeft.matchingDirection(remaining: [.bottomLeft], stalled: false) == .bottomLeft)
        let symmetricTopLeft = base.observing(rawYaw: 0.12, rawPitch: -0.36 - 0.085)
        #expect(symmetricTopLeft.matchingDirection(remaining: [.topLeft], stalled: false) == nil)
    }

    @Test("Ignores non-finite inputs and transitions continuously across sectors under EMA")
    func nonFiniteAndContinuousEmaTransitions() {
        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.02, pitch: -0.36)
            .recordingCenterSample(yaw: .nan, pitch: -0.36)
            .recordingCenterSample(yaw: 0.02, pitch: -.infinity)
            .finalizingCenterCalibration()
        #expect(abs(base.neutralYaw - 0.02) < 0.001)
        #expect(abs(base.neutralPitch - (-0.36)) < 0.001)

        let settled = base.observing(rawYaw: 0.02, rawPitch: -0.36)
        let afterNaN = settled.observing(rawYaw: .nan, rawPitch: -0.36)
        #expect(afterNaN.smoothedYaw == nil)
        #expect(afterNaN.smoothedPitch == nil)
        #expect(afterNaN.isCalibrated)

        let afterInf = settled.observing(rawYaw: 0.02, rawPitch: .infinity)
        #expect(afterInf.smoothedYaw == nil)
        #expect(afterInf.smoothedPitch == nil)
        #expect(afterInf.isCalibrated)

        // Continuous multi-frame EMA sector transition across .top -> .topRight -> .right without clearedFrame().
        var sweep = base
        var remaining: Set<EnrollmentPose> = [.top, .topRight, .right]

        let sweepSteps: [(EnrollmentPose, Float, Float, Int)] = [
            (.top, 0.0, -0.58, 3),
            (.topRight, -0.22, -0.52, 4),
            (.right, -0.29, -0.36, 5)
        ]
        for (expected, rawYaw, rawPitch, frames) in sweepSteps {
            var matchedPose: EnrollmentPose?
            for _ in 0..<frames {
                sweep = sweep.observing(rawYaw: rawYaw, rawPitch: rawPitch)
                if let match = sweep.matchingDirection(remaining: remaining, stalled: false) {
                    matchedPose = match
                    remaining.remove(match)
                    break
                }
            }
            #expect(matchedPose == expected)
        }
        #expect(remaining.isEmpty)
    }
}
