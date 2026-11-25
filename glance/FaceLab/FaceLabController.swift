//
//  FaceLabController.swift
//  glance
//
//  Orchestrates the Face Lab debug tab. Deliberately never touches LockMonitor, KeystrokeInjector, or
//  SecureCredentialManager for *unlocking* — that's handled separately by FaceUnlockCoordinator (off by default).
//

import CoreGraphics
import Foundation
import Observation

struct RecognitionResult: Identifiable {
    let id = UUID()
    let name: String
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest sample. A match must clear the threshold on *both* measures.
    let maxSampleSimilarity: Float
    let isStale: Bool
}

/// One manually-tagged data point for threshold calibration: "this
/// similarity score came from a genuine match" or "from an impostor."
struct CalibrationSample: Identifiable {
    let id = UUID()
    let centroidSimilarity: Float
    let isGenuine: Bool
}

@Observable
@MainActor
final class FaceLabController {
    /// Output of one off-actor Face Lab recognition + liveness extraction pass.
    nonisolated struct ExtractedFrame: Sendable {
        let result: FaceRecognitionResult
        let livenessFrame: LivenessFrame
        let precomputedGeometry: GeometryLivenessResult?

        init(
            result: FaceRecognitionResult,
            livenessFrame: LivenessFrame,
            precomputedGeometry: GeometryLivenessResult? = nil
        ) {
            self.result = result
            self.livenessFrame = livenessFrame
            self.precomputedGeometry = precomputedGeometry
        }
    }

    /// Seam allowing tests to inject delayed or synthetic frame extraction while production reads
    /// per-frame `@MainActor` settings before dispatching work off-actor.
    typealias FrameExtractor =
        @MainActor (
            CameraFrame,
            FaceRecognitionPipeline,
            LivenessAnalyzer.GeometryEvaluationContext?
        ) async throws -> ExtractedFrame

    static let defaultFrameExtractor: FrameExtractor = { cameraFrame, pipeline, geometryContext in
        let strictCloseRangeOnly = GlanceSettings.shared.strictCloseRangeOnly
        return try await Task.detached(priority: .userInitiated) {
            let result = try pipeline.recognize(in: cameraFrame, strictCloseRangeOnly: strictCloseRangeOnly)
            let faceCrop = FaceAuthEvaluator.glareCrop(from: cameraFrame, recognition: result)
            let livenessFrame = LivenessFeatureExtractor.extract(
                from: result, frame: cameraFrame.image, faceCrop: faceCrop
            )
            let precomputedGeometry = geometryContext?.computeGeometry(appending: livenessFrame)
            return ExtractedFrame(
                result: result,
                livenessFrame: livenessFrame,
                precomputedGeometry: precomputedGeometry
            )
        }.value
    }

    let camera: CameraManager
    let store = FaceEnrollmentStore.shared
    let pipeline: FaceRecognitionPipeline

    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var currentResult: FaceRecognitionResult?

    /// Fed live, same as `FaceUnlockCoordinator`'s scan loop — this is exactly what the real unlock path would see.
    private let livenessAnalyzer = LivenessAnalyzer()
    private(set) var currentLiveness = LivenessSnapshot.empty
    /// Diagnostics behind the flat-vs-3D cue, explaining *why* it reads what it reads beyond the cue's own 0...1 level.
    private(set) var currentGeometry = GeometryLivenessResult.empty
    /// Lets the debug view show raw measurements live (not just derived cue levels), to tell a wrong threshold from
    /// a measurement that isn't moving at all.
    private(set) var lastLivenessFrame: LivenessFrame?

    /// Drives mode/tuning locally rather than reading `GlanceSettings`, so experimenting here can't change what
    /// actually unlocks the Mac. Heavy by default since the point of this tab is watching the confirm cues.
    var livenessMode: LivenessMode = .heavy
    var livenessTuning = LivenessTuning.default
    var enabledLivenessCues: Set<LivenessCue> = Set(LivenessCue.allCases)

    func isLivenessCueEnabled(_ cue: LivenessCue) -> Bool {
        enabledLivenessCues.contains(cue)
    }

    func setLivenessCue(_ cue: LivenessCue, enabled: Bool) {
        if enabled {
            enabledLivenessCues.insert(cue)
        } else {
            enabledLivenessCues.remove(cue)
        }
    }

    /// Cue firing latches for a whole scan by design, so re-testing a spoof after one's been caught needs an explicit clear.
    func resetLiveness() {
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        log("Liveness cues reset.")
    }

    var enrollName: String = ""
    /// Raw cosine similarity cutoff (-1...1); typical ArcFace verification cutoffs sit around 0.28-0.40.
    var threshold: Double = 0.6

    private(set) var recognitionResults: [RecognitionResult] = []
    private(set) var bestMatch: RecognitionResult?

    private(set) var logLines: [String] = []
    private(set) var sessionError: String?

    private(set) var captureGeneration: UInt64 = 0
    private var activeProcessingGeneration: UInt64?

    private let frameExtractor: FrameExtractor
    private let isCameraRunning: @MainActor () -> Bool
    private let startCamera: @MainActor () async -> Void
    private let stopCamera: @MainActor () -> Void

    init(
        pipeline: FaceRecognitionPipeline,
        frameExtractor: FrameExtractor? = nil,
        isCameraRunning: (@MainActor () -> Bool)? = nil,
        startCamera: (@MainActor () async -> Void)? = nil,
        stopCamera: (@MainActor () -> Void)? = nil
    ) {
        let camera = CameraManager()
        self.camera = camera
        self.pipeline = pipeline
        self.frameExtractor = frameExtractor ?? Self.defaultFrameExtractor
        self.isCameraRunning = isCameraRunning ?? { camera.isRunning }
        self.startCamera = startCamera ?? { await camera.start() }
        self.stopCamera = stopCamera ?? { camera.stop() }
        observeFrames()
        livenessAnalyzer.keepsComputingConfirmCuesAfterConfirmation = true
        livenessAnalyzer.modeProvider = { [weak self] in self?.livenessMode ?? .heavy }
        livenessAnalyzer.tuningProvider = { [weak self] in self?.livenessTuning ?? .default }
        livenessAnalyzer.enabledCuesProvider = { [weak self] in
            self?.enabledLivenessCues ?? Set(LivenessCue.allCases)
        }
        store.reloadIfUnlocked()
        switch pipeline.loadState {
        case .loading:
            log("Loading ArcFace model…")
            Task { @MainActor [weak self, pipeline] in
                await pipeline.waitUntilReady()
                self?.logPipelineReadyState()
            }
        case .ready, .fallback:
            logPipelineReadyState()
        }
    }

    private func logPipelineReadyState() {
        if pipeline.usingFallbackEmbedder {
            log(
                "ArcFace unavailable (\(pipeline.fallbackReason ?? "unknown reason")) — using Vision Feature Print instead."
            )
        } else {
            log("Using \(pipeline.embedder.name).")
        }
    }

    @discardableResult
    func bumpCaptureGeneration() -> UInt64 {
        captureGeneration &+= 1
        return captureGeneration
    }

    private func stopCaptureSession() {
        bumpCaptureGeneration()
        activeProcessingGeneration = nil
        stopCamera()
    }

    func start() async {
        let generation = bumpCaptureGeneration()
        await startCamera()
        guard generation == captureGeneration else { return }
        if let error = camera.errorMessage {
            log(error)
        } else {
            log("Camera started.")
        }
    }

    func stop() {
        stopCaptureSession()
        detectedFaces = []
        currentResult = nil
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        lastLivenessFrame = nil
        log("Camera stopped.")
    }

    /// Mirrors `POCController.unlockSession()` so Face Lab can unlock the session without leaving this page.
    func unlockSession() async {
        sessionError = nil
        do {
            try await SecureCredentialManager.unlockSession(reason: "Authenticate to use Face Lab")
            store.reloadIfUnlocked()
            log("Session unlocked.")
        } catch {
            sessionError = error.localizedDescription
        }
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeFrames() {
        withObservationTracking {
            _ = camera.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFrames()
                await self?.processLatestFrame()
            }
        }
    }

    /// Skips frames that arrive mid-processing — an "always work on the latest frame" throttle instead of a timer.
    private func processLatestFrame() async {
        guard let cameraFrame = camera.currentFrame else { return }
        await processFrame(cameraFrame)
    }

    /// Runs recognition and liveness extraction for one frame, discarding any results if the capture
    /// generation changed or the camera stopped while off-actor work was in flight.
    func processFrame(_ cameraFrame: CameraFrame) async {
        let generation = captureGeneration
        guard isCameraRunning(), activeProcessingGeneration != generation else { return }
        activeProcessingGeneration = generation
        defer {
            if activeProcessingGeneration == generation {
                activeProcessingGeneration = nil
            }
        }

        let pipeline = self.pipeline
        if pipeline.loadState == .loading {
            await pipeline.waitUntilReady()
            guard isCameraRunning(), generation == captureGeneration else { return }
        }
        let geometryContext = livenessAnalyzer.heavyGeometryContextIfNeeded()
        do {
            let extracted = try await frameExtractor(cameraFrame, pipeline, geometryContext)
            guard isCameraRunning(), generation == captureGeneration else { return }
            detectedFaces = [extracted.result.face]
            currentResult = extracted.result
            lastLivenessFrame = extracted.livenessFrame
            currentLiveness = livenessAnalyzer.observe(
                extracted.livenessFrame,
                precomputedGeometry: extracted.precomputedGeometry,
                sourceGeneration: geometryContext?.generation
            )
            currentGeometry = livenessAnalyzer.lastGeometry
        } catch FaceRecognitionPipelineError.noFaceDetected {
            guard isCameraRunning(), generation == captureGeneration else { return }
            detectedFaces = []
            currentResult = nil
        } catch {
            guard isCameraRunning(), generation == captureGeneration else { return }
            detectedFaces = []
            currentResult = nil
            log("Detection error: \(error.localizedDescription)")
        }
    }

    // MARK: - Enrollment

    func captureSample() {
        guard let result = currentResult else {
            log("No face detected — can't capture a sample.")
            return
        }
        let trimmedName = enrollName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            log("Enter a name before capturing a sample.")
            return
        }
        do {
            try store.addSample(
                name: trimmedName,
                embedding: result.embedding,
                embedder: pipeline.embedder,
                quality: result.quality
            )
            log(
                "Captured sample for \"\(trimmedName)\" (\(result.embedding.count)-dim, \(result.alignmentTier.rawValue), quality \(Self.qualityLabel(result.quality)))."
            )
        } catch {
            log("Couldn't save sample: \(error.localizedDescription)")
        }
    }

    func deleteIdentity(_ identity: FaceIdentity) {
        do {
            try store.delete(identity)
            log("Deleted \"\(identity.name)\".")
        } catch {
            log("Couldn't delete: \(error.localizedDescription)")
        }
    }

    // MARK: - Multi-identity enrollment

    /// Counts only the red band of `FaceIdentity.qualityTier(of:)`, so this debug list and the Your Face tick strip always
    /// agree about what "low" means. Samples with no score count as unrated, never as low.
    func lowQualityCount(in identity: FaceIdentity) -> Int {
        identity.poorQualitySampleCount
    }

    /// Face Lab and onboarding each own a separate `CameraManager` on the same device — stop ours first to avoid
    /// two live sessions with different configurations.
    func startFullOnboarding() {
        stopCaptureSession()
        log("Starting the full onboarding flow.")
        OnboardingController.startFlow(pipeline: pipeline)
    }

    func startAddIdentity() {
        stopCaptureSession()
        log("Starting guided enrollment for a new identity.")
        OnboardingController.startAddIdentity(
            pipeline: pipeline,
            onUnavailable: { [weak self] message in self?.log(message) }
        )
    }

    func startRecapture(of identity: FaceIdentity) {
        stopCaptureSession()
        log("Starting guided re-capture of \"\(identity.name)\".")
        OnboardingController.startRecapture(
            of: identity,
            pipeline: pipeline,
            onUnavailable: { [weak self] message in self?.log(message) }
        )
    }

    static func qualityLabel(_ quality: Float?) -> String {
        guard let quality else { return "—" }
        return String(format: "%.0f%%", quality * 100)
    }

    // MARK: - Recognition

    func recognize() {
        guard let result = currentResult else {
            log("No face detected — can't recognize.")
            recognitionResults = []
            bestMatch = nil
            return
        }
        guard !store.identities.isEmpty else {
            log("No enrolled identities yet — capture a sample first.")
            recognitionResults = []
            bestMatch = nil
            return
        }

        let embedder = pipeline.embedder
        let scored = pipeline.score(result.embedding, against: store.identities)
        recognitionResults = scored.map { s in
            RecognitionResult(
                name: s.identity.name,
                centroidSimilarity: s.centroidSimilarity,
                maxSampleSimilarity: s.maxSampleSimilarity,
                isStale: s.identity.isStale(comparedTo: embedder)
            )
        }

        let matched = pipeline.bestMatch(in: scored, threshold: Float(threshold))
        bestMatch = matched.map {
            RecognitionResult(
                name: $0.identity.name, centroidSimilarity: $0.centroidSimilarity,
                maxSampleSimilarity: $0.maxSampleSimilarity, isStale: false)
        }

        if let best = scored.first {
            let verdict = (bestMatch != nil) ? "MATCH" : "no match"
            let staleNote =
                best.identity.isStale(comparedTo: embedder) ? " [STALE — re-enroll under current model]" : ""
            log(
                "Recognize: best = \(best.identity.name) centroid=\(String(format: "%.3f", best.centroidSimilarity)) max=\(String(format: "%.3f", best.maxSampleSimilarity)) -> \(verdict)\(staleNote)"
            )
        }
    }

    // MARK: - Threshold calibration

    /// Tagged similarity scores collected this session — the actual data a threshold should be picked from, not guessed.
    private(set) var calibrationSamples: [CalibrationSample] = []

    /// Tags the most recent `recognize()` top score as genuine or impostor, using centroid similarity (what the
    /// threshold slider actually gates on).
    func recordCalibrationSample(isGenuine: Bool) {
        guard let top = recognitionResults.first else {
            log("Nothing to record — run Identify first.")
            return
        }
        calibrationSamples.append(CalibrationSample(centroidSimilarity: top.centroidSimilarity, isGenuine: isGenuine))
        log(
            "Calibration: recorded \(isGenuine ? "genuine" : "impostor") sample at \(String(format: "%.3f", top.centroidSimilarity))."
        )
    }

    func clearCalibrationSamples() {
        calibrationSamples.removeAll()
    }

    /// Midpoint between the lowest genuine score and the highest impostor score. Nil until at least one of each is recorded.
    var suggestedThreshold: Float? {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return nil }
        return (minGenuine + maxImpostor) / 2
    }

    /// True if any impostor score is >= any genuine score — no single threshold perfectly separates the two groups yet.
    var calibrationDistributionsOverlap: Bool {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return false }
        return maxImpostor >= minGenuine
    }

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(timestamp)] \(message)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }
}
