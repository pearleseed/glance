//
//  LivenessAnalyzer.swift
//  glance
//
//  Rolling-window driver for the liveness cues. Takes `LivenessFrame`, not
//  `FaceRecognitionResult`, keeping this file's dependency graph shallow enough
//  to compile standalone in `tools/liveness_selftest.swift`.
//

import Foundation

@MainActor
final class LivenessAnalyzer {
    nonisolated struct GeometryEvaluationContext: Sendable {
        let window: [LivenessFrame]
        let windowDuration: TimeInterval
        let generation: UInt64
        let includeDiagnostics: Bool

        nonisolated func computeGeometry(appending frame: LivenessFrame) -> GeometryLivenessResult {
            var nextWindow = window
            nextWindow.append(frame)
            nextWindow.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > windowDuration }
            return LivenessAnalyzer.computeHeavyGeometry(
                window: nextWindow,
                includeDiagnostics: includeDiagnostics
            )
        }
    }

    private let windowDuration: TimeInterval

    /// Read fresh on every `observe()`, not captured at init, so a mid-scan Settings change takes effect immediately.
    var modeProvider: () -> LivenessMode = { .light }
    var tuningProvider: () -> LivenessTuning = { .default }
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCuesProvider: () -> Set<LivenessCue> = { Set(LivenessCue.allCases) }
    /// When `true` (used by Face Lab diagnostics), Heavy mode keeps evaluating
    /// confirm cues and geometry even after confirmation is already latched.
    var keepsComputingConfirmCuesAfterConfirmation = false

    private var frames: [LivenessFrame] = []
    private var windowGeneration: UInt64 = 0
    private var evaluator = LivenessEvaluator()
    private(set) var lastSnapshot = LivenessSnapshot.empty
    /// Kept for Face Lab's diagnostics panel (excess ratio, coherence, pair
    /// counts, yaw range) — the numbers behind the flat-vs-3D cue's level.
    private(set) var lastGeometry = GeometryLivenessResult.empty

    init(windowDuration: TimeInterval = 2.0) {
        self.windowDuration = windowDuration
    }

    func reset() {
        frames.removeAll()
        windowGeneration &+= 1
        evaluator.reset()
        lastSnapshot = .empty
        lastGeometry = .empty
    }

    /// Clears confirm cues and rolling window when the tracked identity changes,
    /// keeping any accumulated deny-cue evidence intact.
    func resetConfirmations() {
        frames.removeAll()
        windowGeneration &+= 1
        lastGeometry = .empty
        syncEvaluatorConfig()
        evaluator.resetConfirmations()
        lastSnapshot = evaluator.observeDenyOnly([:])
    }

    /// Snapshots the rolling window when Heavy geometry evaluation is needed so callers
    /// can run `GeometryLiveness` off `@MainActor` alongside feature extraction.
    func heavyGeometryContextIfNeeded() -> GeometryEvaluationContext? {
        syncEvaluatorConfig()
        let alreadyConfirmedInHeavy = lastSnapshot.mode == .heavy && lastSnapshot.decision.isConfirmed
        let needsConfirmCues =
            evaluator.mode == .heavy && (keepsComputingConfirmCuesAfterConfirmation || !alreadyConfirmedInHeavy)
        guard needsConfirmCues else { return nil }
        return GeometryEvaluationContext(
            window: frames,
            windowDuration: windowDuration,
            generation: windowGeneration,
            includeDiagnostics: keepsComputingConfirmCuesAfterConfirmation
        )
    }

    /// Pure off-actor Heavy geometry computation. Safe to run on any background executor.
    nonisolated static func computeHeavyGeometry(
        window: [LivenessFrame],
        tuning: GeometryTuning = .default,
        includeDiagnostics: Bool = false
    ) -> GeometryLivenessResult {
        GeometryLiveness.evaluate(window, tuning: tuning, includeDiagnostics: includeDiagnostics)
    }

    /// Feeds an unmatched frame through deny-only evaluation so spoof cues still
    /// accumulate without advancing confirmation progress.
    @discardableResult
    func observeUnmatched(_ frame: LivenessFrame) -> LivenessSnapshot {
        syncEvaluatorConfig()
        let readings = LivenessCues.denyReadings(window: [frame])
        let snapshot = evaluator.observeDenyOnly(readings)
        lastSnapshot = snapshot
        return snapshot
    }

    /// Call once per frame with a detected face, regardless of whether it matched an identity,
    /// so liveness stays an independent gate. The window is time-pruned (~2s) but the evaluator's
    /// fire counts are not — they accumulate across the whole scan, so a spoof tell can't be waited out.
    @discardableResult
    func observe(
        _ frame: LivenessFrame,
        precomputedGeometry: GeometryLivenessResult? = nil,
        sourceGeneration: UInt64? = nil
    ) -> LivenessSnapshot {
        let snapshotGeneration = windowGeneration
        windowGeneration &+= 1
        frames.append(frame)
        frames.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > windowDuration }

        syncEvaluatorConfig()

        let alreadyConfirmedInHeavy = lastSnapshot.mode == .heavy && lastSnapshot.decision.isConfirmed
        let needsConfirmCues =
            evaluator.mode == .heavy && (keepsComputingConfirmCuesAfterConfirmation || !alreadyConfirmedInHeavy)

        let geometry: GeometryLivenessResult
        let readings: [LivenessCue: CueReading]
        if needsConfirmCues {
            if let precomputedGeometry,
                sourceGeneration.map({ $0 == snapshotGeneration }) ?? true
            {
                geometry = precomputedGeometry
            } else {
                geometry = Self.computeHeavyGeometry(
                    window: frames,
                    includeDiagnostics: keepsComputingConfirmCuesAfterConfirmation
                )
            }
            readings = LivenessCues.readings(window: frames, geometry: geometry)
        } else {
            geometry = .empty
            readings = LivenessCues.denyReadings(window: frames)
        }
        lastGeometry = geometry

        let snapshot = evaluator.observe(readings)
        lastSnapshot = snapshot
        return snapshot
    }

    private func syncEvaluatorConfig() {
        evaluator.mode = modeProvider()
        evaluator.tuning = tuningProvider()
        evaluator.enabledCues = enabledCuesProvider()
    }
}
