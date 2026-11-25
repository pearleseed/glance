//
//  enrollment_pose_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for `EnrollmentPoseEvaluator` neutral pitch
//  calibration and omni-directional circular matching.
//  Run via `./tools/check.sh --suite enrollment_pose`.
//

import Foundation

@main
struct EnrollmentPoseSelfTest {
    static func main() {
        runBriefCoreTests()
        runUncalibratedLaptopCenterTests()
        runCalibrationMedianAndClampTests()
        runAllEightSectorsCWAndCCWTests()
        runEmaSmoothingAndClearedFrameTests()
        runHeadTurnAndExcessiveTurnTests()
        runStalledWideningAndLeniencyTests()
        runNonFiniteAndContinuousEmaTransitionTests()
        print("PASS: EnrollmentPoseEvaluator neutral pitch calibration & omni-directional circular matching passed.")
    }

    private static func runBriefCoreTests() {
        // 1. Laptop lid camera tilted below eye level (-0.36 rad raw pitch):
        //    Center calibration must absorb -0.36 rad so user looking straight isn't flagged "Too far up"
        var eval = EnrollmentPoseEvaluator()
        for _ in 0..<4 {
            eval = eval.observing(rawYaw: 0.02, rawPitch: -0.36)
            eval = eval.recordingCenterSample(yaw: 0.02, pitch: -0.36)
        }
        eval = eval.finalizingCenterCalibration()
        precondition(eval.isCalibrated, "FAIL: evaluator did not calibrate after center samples")
        precondition(
            abs(eval.neutralPitch - (-0.36)) < 0.05, "FAIL: neutralPitch missed laptop angle: \(eval.neutralPitch)")

        // 2. Omni-directional matching: turning right (+0.28 relative right = -0.28 yaw) matches .right regardless of order
        eval = eval.clearedFrame().observing(rawYaw: -0.28, rawPitch: -0.36)
        let remaining: Set<EnrollmentPose> = [.top, .right, .bottom, .left]
        let matched = eval.matchingDirection(remaining: remaining, stalled: false)
        precondition(
            matched == .right, "FAIL: expected .right omni-directional match, got \(String(describing: matched))")

        // 3. Turning head down relative to calibrated -0.36 baseline (e.g. rawPitch = -0.14 => delta +0.22) matches .bottom
        eval = eval.clearedFrame().observing(rawYaw: 0.01, rawPitch: -0.14)
        let matchedDown = eval.matchingDirection(remaining: remaining, stalled: false)
        precondition(
            matchedDown == .bottom,
            "FAIL: expected .bottom relative to calibrated pitch, got \(String(describing: matchedDown))")
    }

    private static func runUncalibratedLaptopCenterTests() {
        // Steep tilted laptop lid (-0.36 rad and boundary -0.45 rad) must pass center match and never warn "Too far up".
        let tilted = EnrollmentPoseEvaluator().observing(rawYaw: 0.02, rawPitch: -0.36)
        precondition(tilted.matchesCenter(stalled: false), "FAIL: tilted laptop -0.36 rad should match center")
        precondition(
            tilted.excessiveTurn(for: .center, remaining: []) == nil,
            "FAIL: tilted laptop -0.36 rad must not trigger excessiveTurn during center"
        )

        let upperDeskCam = EnrollmentPoseEvaluator().observing(rawYaw: 0.0, rawPitch: 0.35)
        precondition(
            upperDeskCam.matchesCenter(stalled: false), "FAIL: upper clamp boundary +0.35 rad should match center")
        precondition(
            upperDeskCam.excessiveTurn(for: .center, remaining: []) == nil,
            "FAIL: +0.35 rad must not trigger excessiveTurn during center"
        )

        // Genuinely extreme pitch or yaw during uncalibrated center must be rejected.
        let extremeUp = EnrollmentPoseEvaluator().observing(rawYaw: 0.0, rawPitch: -0.65)
        precondition(!extremeUp.matchesCenter(stalled: false), "FAIL: -0.65 rad must not match center")
        precondition(
            extremeUp.excessiveTurn(for: .center, remaining: []) == .up,
            "FAIL: -0.65 rad must warn .up during center"
        )

        let extremeDown = EnrollmentPoseEvaluator().observing(rawYaw: 0.0, rawPitch: 0.55)
        precondition(!extremeDown.matchesCenter(stalled: false), "FAIL: +0.55 rad must not match center")
        precondition(
            extremeDown.excessiveTurn(for: .center, remaining: []) == .down,
            "FAIL: +0.55 rad must warn .down during center"
        )

        let offCenterYaw = EnrollmentPoseEvaluator().observing(rawYaw: 0.25, rawPitch: -0.36)
        precondition(!offCenterYaw.matchesCenter(stalled: false), "FAIL: yaw 0.25 rad must not match center")
    }

    private static func runCalibrationMedianAndClampTests() {
        // Median rejects single-frame outlier and clamps to (-0.10...0.10, -0.45...0.35).
        var eval = EnrollmentPoseEvaluator()
        eval = eval.recordingCenterSample(yaw: 0.03, pitch: -0.35)
        eval = eval.recordingCenterSample(yaw: 0.01, pitch: -0.37)
        eval = eval.recordingCenterSample(yaw: 0.02, pitch: -0.36)
        eval = eval.recordingCenterSample(yaw: 0.45, pitch: 0.30)  // single outlier
        eval = eval.finalizingCenterCalibration()
        precondition(abs(eval.neutralYaw - 0.025) < 0.001, "FAIL: median yaw wrong: \(eval.neutralYaw)")
        precondition(abs(eval.neutralPitch - (-0.355)) < 0.001, "FAIL: median pitch wrong: \(eval.neutralPitch)")

        // Clamp bounds check.
        let clampedHigh = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.25, pitch: 0.50)
            .finalizingCenterCalibration()
        precondition(clampedHigh.neutralYaw == 0.10, "FAIL: neutralYaw upper clamp failed: \(clampedHigh.neutralYaw)")
        precondition(
            clampedHigh.neutralPitch == 0.35, "FAIL: neutralPitch upper clamp failed: \(clampedHigh.neutralPitch)")

        let clampedLow = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: -0.25, pitch: -0.60)
            .finalizingCenterCalibration()
        precondition(clampedLow.neutralYaw == -0.10, "FAIL: neutralYaw lower clamp failed: \(clampedLow.neutralYaw)")
        precondition(
            clampedLow.neutralPitch == -0.45, "FAIL: neutralPitch lower clamp failed: \(clampedLow.neutralPitch)")

        // Empty calibration safely defaults to (0, 0).
        let empty = EnrollmentPoseEvaluator().finalizingCenterCalibration()
        precondition(
            empty.isCalibrated && empty.neutralYaw == 0 && empty.neutralPitch == 0, "FAIL: empty calibration failed")
    }

    private static func runAllEightSectorsCWAndCCWTests() {
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
            precondition(matched == expected, "FAIL CW: expected \(expected), got \(String(describing: matched))")
            remainingCW.remove(expected)
        }
        precondition(remainingCW.isEmpty, "FAIL CW: remaining not empty")

        // Sweep CCW, removing each pose as captured.
        var remainingCCW = Set(EnrollmentPose.allCases.filter { $0 != .center })
        for (expected, yaw, pitch) in sectorInputs.reversed() {
            let probe = base.clearedFrame().observing(rawYaw: yaw, rawPitch: pitch)
            let matched = probe.matchingDirection(remaining: remainingCCW, stalled: false)
            precondition(matched == expected, "FAIL CCW: expected \(expected), got \(String(describing: matched))")
            remainingCCW.remove(expected)
        }
        precondition(remainingCCW.isEmpty, "FAIL CCW: remaining not empty")

        // Opposite direction must never match when only .top remains.
        let lookingDown = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.14)
        precondition(
            lookingDown.matchingDirection(remaining: [.top], stalled: false) == nil,
            "FAIL: looking down must not match .top"
        )
    }

    private static func runEmaSmoothingAndClearedFrameTests() {
        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.0, pitch: -0.36)
            .finalizingCenterCalibration()

        // Starting from center, a single noisy spike (-0.30) is damped by 0.50 EMA to -0.15.
        let settled = base.observing(rawYaw: 0.0, rawPitch: -0.36)
        let spiked = settled.observing(rawYaw: -0.30, rawPitch: -0.36)
        precondition(
            abs((spiked.smoothedYaw ?? 99) - (-0.15)) < 0.001,
            "FAIL: EMA alpha=0.50 wrong: \(String(describing: spiked.smoothedYaw))")

        // clearedFrame clears smoothed observation but preserves calibration.
        let cleared = spiked.clearedFrame()
        precondition(cleared.isCalibrated, "FAIL: clearedFrame lost calibration")
        precondition(abs(cleared.neutralPitch - (-0.36)) < 0.001, "FAIL: clearedFrame lost neutralPitch")
        precondition(
            cleared.smoothedYaw == nil && cleared.smoothedPitch == nil, "FAIL: clearedFrame did not reset smoothed pose"
        )
    }

    private static func runHeadTurnAndExcessiveTurnTests() {
        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.0, pitch: -0.36)
            .finalizingCenterCalibration()

        // Uncalibrated evaluator returns nil for headTurn().
        precondition(
            EnrollmentPoseEvaluator().observing(rawYaw: -0.30, rawPitch: -0.36).headTurn() == nil,
            "FAIL: uncalibrated evaluator must return nil headTurn()"
        )

        // Within deadzone (<= 0.15) returns nil.
        let tiny = base.observing(rawYaw: -0.02, rawPitch: -0.36)
        precondition(tiny.headTurn() == nil, "FAIL: tiny jitter within deadzone should return nil headTurn()")

        // Right turn (compass 90 deg).
        let rightTurn = base.clearedFrame().observing(rawYaw: -0.24, rawPitch: -0.36).headTurn()
        precondition(rightTurn != nil, "FAIL: expected non-nil right headTurn()")
        precondition(abs(rightTurn!.angle - 90.0) < 1.0, "FAIL: expected 90 deg, got \(rightTurn!.angle)")
        precondition(abs(rightTurn!.progress - 1.0) < 0.01, "FAIL: expected progress ~1.0, got \(rightTurn!.progress)")

        // Up turn relative to -0.36 (compass 0 deg).
        let upTurn = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.53).headTurn()
        precondition(
            upTurn != nil && (upTurn!.angle < 1.0 || upTurn!.angle > 359.0), "FAIL: expected ~0 deg for up turn")

        // Relative excessiveTurn: looking slightly up at -0.54 (rel -0.18) must NOT trigger excessiveTurn.
        let validUp = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.54)
        precondition(
            validUp.excessiveTurn(for: nil, remaining: [.top]) == nil,
            "FAIL: relPitch -0.18 on tilted laptop should not trigger excessiveTurn"
        )

        // Genuine overshoot: relPitch = -0.42 (raw -0.78) triggers .up, relPitch = +0.42 (raw +0.06) triggers .down.
        let tooUp = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.78)
        precondition(tooUp.excessiveTurn(for: nil, remaining: [.top]) == .up, "FAIL: expected .up excessiveTurn")

        let tooDown = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: 0.06)
        precondition(
            tooDown.excessiveTurn(for: nil, remaining: [.bottom]) == .down, "FAIL: expected .down excessiveTurn")

        let tooTopRight = base.clearedFrame().observing(rawYaw: -0.55, rawPitch: -0.78)
        precondition(
            tooTopRight.excessiveTurn(for: nil, remaining: [.topRight]) == .topRight,
            "FAIL: expected .topRight excessiveTurn")

        // Post-calibration excessiveTurn(for: .center, ...) must use relative bounds, not uncalibrated bounds.
        let calibratedCenterValidUp = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: -0.65)
        precondition(
            calibratedCenterValidUp.excessiveTurn(for: .center, remaining: [.top]) == nil,
            "FAIL: calibrated excessiveTurn(for: .center) must evaluate relative pitch (-0.29 within 0.37 cap)"
        )
        let calibratedCenterTooDown = base.clearedFrame().observing(rawYaw: 0.0, rawPitch: 0.06)
        precondition(
            calibratedCenterTooDown.excessiveTurn(for: .center, remaining: [.bottom]) == .down,
            "FAIL: calibrated excessiveTurn(for: .center) must catch relative +0.42 overshoot as .down"
        )
    }

    private static func runStalledWideningAndLeniencyTests() {
        // Uncalibrated center stall widening: yaw limit widens 0.18 -> 0.225, pitch clamp pads by +-0.08 (-0.53...0.43).
        let uncalibratedEdge = EnrollmentPoseEvaluator().observing(rawYaw: 0.20, rawPitch: -0.50)
        precondition(
            !uncalibratedEdge.matchesCenter(stalled: false),
            "FAIL: uncalibrated edge should fail non-stalled center match")
        precondition(
            uncalibratedEdge.matchesCenter(stalled: true), "FAIL: uncalibrated edge should pass stalled center match")

        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.0, pitch: -0.36)
            .finalizingCenterCalibration()

        // Calibrated center stall widening: yaw 0.20 < 0.225, relPitch 0.17 < 0.1875.
        let calibratedEdge = base.observing(rawYaw: 0.20, rawPitch: -0.36 + 0.17)
        precondition(
            !calibratedEdge.matchesCenter(stalled: false), "FAIL: calibrated edge should fail non-stalled center match")
        precondition(
            calibratedEdge.matchesCenter(stalled: true), "FAIL: calibrated edge should pass stalled center match")

        // Directional magnitude widening: 0.21 / 0.24 = 0.875 (< 1.0 normal, >= 0.8 stalled).
        let partialRight = base.observing(rawYaw: -0.21, rawPitch: -0.36)
        precondition(
            partialRight.matchingDirection(remaining: [.right], stalled: false) == nil,
            "FAIL: 0.875 magnitude should not match .right without stall")
        precondition(
            partialRight.matchingDirection(remaining: [.right], stalled: true) == .right,
            "FAIL: 0.875 magnitude should match .right when stalled")

        // Directional angular half-width widening: 118 deg (28 deg from .right: > 24 normal, <= 33.75 stalled).
        let angleRad = 118.0 * Double.pi / 180.0
        let x = sin(angleRad) * 1.2
        let y = cos(angleRad) * 1.2
        let angledRight = base.observing(rawYaw: Float(-x) * 0.24, rawPitch: -0.36 + Float(-y) * 0.17)
        precondition(
            angledRight.matchingDirection(remaining: [.right], stalled: false) == nil,
            "FAIL: 28 deg offset should not match .right without stall")
        precondition(
            angledRight.matchingDirection(remaining: [.right], stalled: true) == .right,
            "FAIL: 28 deg offset should match .right when stalled")

        // Downward matchLeniency: .bottom (1.2 => 0.833 req) and .bottomLeft (1.5 => 0.667 req).
        let gentleDown = base.observing(rawYaw: 0.0, rawPitch: -0.36 + 0.15)
        precondition(
            gentleDown.matchingDirection(remaining: [.bottom], stalled: false) == .bottom,
            "FAIL: downward .bottom leniency did not match")
        let symmetricUp = base.observing(rawYaw: 0.0, rawPitch: -0.36 - 0.15)
        precondition(
            symmetricUp.matchingDirection(remaining: [.top], stalled: false) == nil,
            "FAIL: .top should not inherit .bottom leniency")

        let gentleBottomLeft = base.observing(rawYaw: 0.12, rawPitch: -0.36 + 0.085)
        precondition(
            gentleBottomLeft.matchingDirection(remaining: [.bottomLeft], stalled: false) == .bottomLeft,
            "FAIL: downward .bottomLeft leniency did not match")
        let symmetricTopLeft = base.observing(rawYaw: 0.12, rawPitch: -0.36 - 0.085)
        precondition(
            symmetricTopLeft.matchingDirection(remaining: [.topLeft], stalled: false) == nil,
            "FAIL: .topLeft should not inherit .bottomLeft leniency")
    }

    private static func runNonFiniteAndContinuousEmaTransitionTests() {
        let base = EnrollmentPoseEvaluator()
            .recordingCenterSample(yaw: 0.02, pitch: -0.36)
            .recordingCenterSample(yaw: .nan, pitch: -0.36)
            .recordingCenterSample(yaw: 0.02, pitch: -.infinity)
            .finalizingCenterCalibration()
        precondition(
            abs(base.neutralYaw - 0.02) < 0.001 && abs(base.neutralPitch - (-0.36)) < 0.001,
            "FAIL: non-finite center samples corrupted calibration")

        let settled = base.observing(rawYaw: 0.02, rawPitch: -0.36)
        let afterNaN = settled.observing(rawYaw: .nan, rawPitch: -0.36)
        precondition(
            afterNaN.smoothedYaw == nil && afterNaN.smoothedPitch == nil && afterNaN.isCalibrated,
            "FAIL: NaN observation should clear smoothed frame while preserving calibration")
        let afterInf = settled.observing(rawYaw: 0.02, rawPitch: .infinity)
        precondition(
            afterInf.smoothedYaw == nil && afterInf.smoothedPitch == nil && afterInf.isCalibrated,
            "FAIL: infinite observation should clear smoothed frame while preserving calibration")

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
            precondition(
                matchedPose == expected,
                "FAIL: continuous EMA transition expected \(expected), got \(String(describing: matchedPose))")
        }
        precondition(remaining.isEmpty, "FAIL: continuous EMA sweep left uncaptured sectors: \(remaining)")
    }
}
