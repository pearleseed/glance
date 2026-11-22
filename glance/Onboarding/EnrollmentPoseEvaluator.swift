//
//  EnrollmentPoseEvaluator.swift
//  glance
//
//  Pure value-type pose calibration and omni-directional circular sector matcher for
//  Face ID-style onboarding enrollment. Zero AppKit/SwiftUI dependencies so it compiles
//  and runs directly in standalone CLI self-tests.
//

import Foundation

/// A single guided head pose captured during enrollment — center plus the
/// 8 compass directions.
nonisolated enum EnrollmentPose: Int, CaseIterable, Hashable, Sendable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    nonisolated enum YawBand: Sendable { case left, none, right }
    nonisolated enum PitchBand: Sendable { case up, none, down }

    static let directionalPoses: [EnrollmentPose] = allCases.filter { $0 != .center }

    var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: return .left
        case .right, .topRight, .bottomRight: return .right
        case .center, .top, .bottom: return .none
        }
    }

    var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: return .up
        case .bottom, .bottomLeft, .bottomRight: return .down
        case .center, .left, .right: return .none
        }
    }

    /// Compass angle (0 = up, clockwise) this pose's ring sector is centered
    /// on. `nil` for center, which pulses the whole ring instead of
    /// claiming a sector.
    var compassAngle: Double? {
        switch self {
        case .center: return nil
        case .left: return 270
        case .topLeft: return 315
        case .top: return 0
        case .topRight: return 45
        case .right: return 90
        case .bottomRight: return 135
        case .bottom: return 180
        case .bottomLeft: return 225
        }
    }

    var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .left: return "Turn your head slightly left"
        case .topLeft: return "Turn your head to the top left"
        case .top: return "Turn your head slightly up"
        case .topRight: return "Turn your head to the top right"
        case .right: return "Turn your head slightly right"
        case .bottomRight: return "Turn your head to the bottom right"
        case .bottom: return "Turn your head slightly down"
        case .bottomLeft: return "Turn your head to the bottom left"
        }
    }

    /// Relaxes this pose's turn threshold so downward gazes (often closer to chest/keyboard)
    /// require slightly less angular travel than upward/sideways turns.
    var matchLeniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: return 1.5
        case .bottom: return 1.2
        default: return 1
        }
    }

    /// Persisted alongside each sample so a saved identity records which
    /// pose each embedding came from.
    var name: String {
        switch self {
        case .center: return "center"
        case .left: return "left"
        case .topLeft: return "top_left"
        case .top: return "top"
        case .topRight: return "top_right"
        case .right: return "right"
        case .bottomRight: return "bottom_right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom_left"
        }
    }
}

/// Where the head is currently turned relative to calibrated neutral, for the ring's live indicator.
nonisolated struct EnrollmentHeadTurn: Equatable, Sendable {
    /// Compass angle (0 = up, clockwise) — same frame as `EnrollmentPose.compassAngle`.
    let angle: Double
    /// How far the turn has gone toward the capture threshold, 0...1.
    let progress: Double
}

/// Extreme head turn outside enrollment's reliable embedding envelope.
nonisolated enum EnrollmentExcessiveTurn: Equatable, Sendable {
    case left, topLeft, up, topRight, right, bottomRight, down, bottomLeft

    var instruction: String {
        switch self {
        case .left: return "Too far left"
        case .topLeft: return "Too far toward the top left"
        case .up: return "Too far up"
        case .topRight: return "Too far toward the top right"
        case .right: return "Too far right"
        case .bottomRight: return "Too far toward the bottom right"
        case .down: return "Too far down"
        case .bottomLeft: return "Too far toward the bottom left"
        }
    }
}

/// Calibrates the user's neutral head orientation from `.center` samples (absorbing tilted
/// laptop lid webcams) and evaluates continuous 360-degree circular head sweeps.
nonisolated struct EnrollmentPoseEvaluator: Equatable, Sendable {
    static let emaAlpha: Float = 0.50
    static let neutralYawClamp: ClosedRange<Float> = -0.10...0.10
    static let neutralPitchClamp: ClosedRange<Float> = -0.45...0.35

    static let yawInnerThreshold: Float = 0.24
    static let yawCenterTolerance: Float = 0.18
    static let yawOuterCap: Float = 0.51
    static let pitchInnerThreshold: Float = 0.17
    static let pitchCenterTolerance: Float = 0.15
    static let pitchOuterCap: Float = 0.37
    static let uncalibratedPitchExcessiveMargin: Float = 0.15
    static let uncalibratedCenterPitchStallPad: Float = 0.08
    static let stallWidenFactor: Float = 1.25
    static let headTurnDeadzone: Double = 0.15
    static let sectorHalfWidthDegrees: Double = 24.0
    static let stalledSectorHalfWidthDegrees: Double = 33.75

    private(set) var isCalibrated = false
    private(set) var neutralYaw: Float = 0
    private(set) var neutralPitch: Float = 0
    private(set) var smoothedYaw: Float?
    private(set) var smoothedPitch: Float?

    private var centerYawSamples: [Float] = []
    private var centerPitchSamples: [Float] = []

    var relativeYaw: Float? { smoothedYaw.map { $0 - neutralYaw } }
    var relativePitch: Float? { smoothedPitch.map { $0 - neutralPitch } }

    /// Applies EMA smoothing over incoming raw `(yaw, pitch)` angles.
    func observing(rawYaw: Float, rawPitch: Float) -> EnrollmentPoseEvaluator {
        guard rawYaw.isFinite, rawPitch.isFinite else { return clearedFrame() }
        var next = self
        if let prevYaw = smoothedYaw, let prevPitch = smoothedPitch {
            next.smoothedYaw = Self.emaAlpha * rawYaw + (1 - Self.emaAlpha) * prevYaw
            next.smoothedPitch = Self.emaAlpha * rawPitch + (1 - Self.emaAlpha) * prevPitch
        } else {
            next.smoothedYaw = rawYaw
            next.smoothedPitch = rawPitch
        }
        return next
    }

    /// Resets the current smoothed observation (e.g. face lost or too far) without discarding calibration.
    func clearedFrame() -> EnrollmentPoseEvaluator {
        var next = self
        next.smoothedYaw = nil
        next.smoothedPitch = nil
        return next
    }

    /// Records a frontal sample used to establish neutral `(yaw, pitch)` once `.center` finishes.
    func recordingCenterSample(yaw: Float, pitch: Float) -> EnrollmentPoseEvaluator {
        guard yaw.isFinite, pitch.isFinite else { return self }
        var next = self
        next.centerYawSamples.append(yaw)
        next.centerPitchSamples.append(pitch)
        return next
    }

    /// Computes median neutral `(yaw, pitch)` clamped to realistic camera-tilt bounds.
    func finalizingCenterCalibration() -> EnrollmentPoseEvaluator {
        var next = self
        let medianYaw = Self.median(of: centerYawSamples) ?? 0
        let medianPitch = Self.median(of: centerPitchSamples) ?? 0
        next.neutralYaw = Self.clamp(medianYaw, to: Self.neutralYawClamp)
        next.neutralPitch = Self.clamp(medianPitch, to: Self.neutralPitchClamp)
        next.isCalibrated = true
        return next
    }

    /// Returns whether the smoothed observation is centered enough for frontal capture.
    /// Before calibration, accepts realistic laptop-lid pitch angles (`-0.45...0.35` rad).
    func matchesCenter(stalled: Bool) -> Bool {
        guard let smoothedYaw, let smoothedPitch else { return false }
        let factor: Float = stalled ? Self.stallWidenFactor : 1.0
        let yawLimit = Self.yawCenterTolerance * factor

        if isCalibrated {
            let relYaw = smoothedYaw - neutralYaw
            let relPitch = smoothedPitch - neutralPitch
            return abs(relYaw) < yawLimit && abs(relPitch) < Self.pitchCenterTolerance * factor
        }

        let pitchPad: Float = stalled ? Self.uncalibratedCenterPitchStallPad : 0
        let pitchMin = Self.neutralPitchClamp.lowerBound - pitchPad
        let pitchMax = Self.neutralPitchClamp.upperBound + pitchPad
        return abs(smoothedYaw) < yawLimit && smoothedPitch >= pitchMin && smoothedPitch <= pitchMax
    }

    /// Matches whichever remaining directional sector the user is currently turning toward,
    /// supporting continuous clockwise, counter-clockwise, or arbitrary order sweeps.
    func matchingDirection(remaining: Set<EnrollmentPose>, stalled: Bool) -> EnrollmentPose? {
        let candidates = EnrollmentPose.directionalPoses.filter { remaining.contains($0) }
        guard !candidates.isEmpty, let turn = normalizedTurnVector() else { return nil }

        let maxDelta = stalled ? Self.stalledSectorHalfWidthDegrees : Self.sectorHalfWidthDegrees
        var bestPose: EnrollmentPose?
        var bestDelta = Double.greatestFiniteMagnitude
        for pose in candidates {
            guard let sectorAngle = pose.compassAngle else { continue }
            let delta = Self.angularDistance(turn.angle, sectorAngle)
            if delta <= maxDelta && delta < bestDelta {
                bestDelta = delta
                bestPose = pose
            }
        }

        guard let matched = bestPose else { return nil }
        let stallFactor: Float = stalled ? Self.stallWidenFactor : 1.0
        let requiredMagnitude = 1.0 / Double(stallFactor * matched.matchLeniency)
        return turn.magnitude >= requiredMagnitude ? matched : nil
    }

    /// Live compass direction and normalized turn progress relative to calibrated neutral.
    func headTurn() -> EnrollmentHeadTurn? {
        guard isCalibrated, let turn = normalizedTurnVector() else { return nil }
        return EnrollmentHeadTurn(angle: turn.angle, progress: min(turn.magnitude, 1))
    }

    private func normalizedTurnVector() -> (magnitude: Double, angle: Double)? {
        guard let relYaw = relativeYaw, let relPitch = relativePitch else { return nil }
        // Vision uses +yaw for left turn and +pitch for looking down; negate both for screen compass space.
        let x = Double(-relYaw / Self.yawInnerThreshold)
        let y = Double(-relPitch / Self.pitchInnerThreshold)
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > Self.headTurnDeadzone else { return nil }
        return (magnitude, Self.normalizedCompassDegrees(x: x, y: y))
    }

    /// Reports excessive head turn relative to calibrated `(neutralYaw, neutralPitch)`, or relative
    /// to the realistic laptop camera pitch range (`-0.45...0.35`) while calibrating `.center`.
    func excessiveTurn(for pose: EnrollmentPose?, remaining: Set<EnrollmentPose>) -> EnrollmentExcessiveTurn? {
        guard let smoothedYaw, let smoothedPitch else { return nil }

        let isCenterPhase = !isCalibrated || pose == .center
        if isCenterPhase {
            let yawOvershoot = abs(smoothedYaw) / Self.yawOuterCap
            let pitchExcess: Float
            if smoothedPitch < Self.neutralPitchClamp.lowerBound {
                pitchExcess = smoothedPitch - Self.neutralPitchClamp.lowerBound
            } else if smoothedPitch > Self.neutralPitchClamp.upperBound {
                pitchExcess = smoothedPitch - Self.neutralPitchClamp.upperBound
            } else {
                pitchExcess = 0
            }
            let pitchOvershoot = abs(pitchExcess) / Self.uncalibratedPitchExcessiveMargin
            return Self.classifyExcessiveTurn(
                yaw: smoothedYaw,
                pitch: pitchExcess,
                yawOvershoot: yawOvershoot,
                pitchOvershoot: pitchOvershoot
            )
        }

        guard !remaining.isEmpty else { return nil }
        let relYaw = smoothedYaw - neutralYaw
        let relPitch = smoothedPitch - neutralPitch
        let yawOvershoot = abs(relYaw) / Self.yawOuterCap
        let pitchOvershoot = abs(relPitch) / Self.pitchOuterCap
        return Self.classifyExcessiveTurn(
            yaw: relYaw,
            pitch: relPitch,
            yawOvershoot: yawOvershoot,
            pitchOvershoot: pitchOvershoot
        )
    }

    private static func classifyExcessiveTurn(
        yaw: Float,
        pitch: Float,
        yawOvershoot: Float,
        pitchOvershoot: Float
    ) -> EnrollmentExcessiveTurn? {
        guard max(yawOvershoot, pitchOvershoot) >= 1 else { return nil }

        let yawExceeded = yawOvershoot >= 1
        let pitchExceeded = pitchOvershoot >= 1
        if yawExceeded, pitchExceeded {
            switch (yaw > 0, pitch < 0) {
            case (true, true): return .topLeft
            case (false, true): return .topRight
            case (false, false): return .bottomRight
            case (true, false): return .bottomLeft
            }
        }

        if yawOvershoot >= pitchOvershoot {
            return yaw > 0 ? .left : .right
        }
        return pitch < 0 ? .up : .down
    }

    private static func normalizedCompassDegrees(x: Double, y: Double) -> Double {
        let degrees = atan2(x, y) * 180.0 / .pi
        return degrees < 0 ? degrees + 360.0 : degrees
    }

    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        var delta = abs(a - b)
        if delta > 180.0 { delta = 360.0 - delta }
        return delta
    }

    private static func median(of values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func clamp(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
