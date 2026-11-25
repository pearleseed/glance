//
//  pipeline_benchmark.swift
//  glance (tools)
//
//  Reproducible camera, recognition, and liveness pipeline benchmark harness.
//  Supports both deterministic 1080p synthetic frame playback (`--synthetic`)
//  and real hardware capture (`--live-camera`), isolating Run 1 vs Run 2
//  across `CameraSessionBox.stop()` + settle pauses.
//
//  Compile and run from repository root:
//      TMP_DIR="$(mktemp -d)"
//      xcrun coremlc compile glance/Models/ArcFace.mlpackage "$TMP_DIR"
//      swiftc -swift-version 6 \
//        -target "$(uname -m)-apple-macos14.0" \
//        -default-isolation MainActor \
//        -enable-upcoming-feature MemberImportVisibility \
//        -enable-upcoming-feature InferIsolatedConformances \
//        -enable-upcoming-feature NonisolatedNonsendingByDefault \
//        -O -parse-as-library \
//        -o "$TMP_DIR/pipeline_benchmark" \
//        glance/Core/NotificationObserverBox.swift \
//        glance/Core/GlobalHotKey.swift \
//        glance/AppLock/AppLockBlacklist.swift \
//        glance/AppLock/LockedApp.swift \
//        glance/AppLock/RelockPolicy.swift \
//        glance/Onboarding/OnboardingStep.swift \
//        glance/Settings/SettingsModels.swift \
//        glance/NotchOverlay/AnimationTint.swift \
//        glance/NotchOverlay/NotchPanelStyle.swift \
//        glance/NotchOverlay/NotchGeometry.swift \
//        glance/Onboarding/OnboardingMetrics.swift \
//        glance/NotchOverlay/NotchGeometry+Screen.swift \
//        glance/NotchOverlay/DisplayContext.swift \
//        glance/Settings/GlanceSettings.swift \
//        glance/Camera/SharedCoreImageContext.swift \
//        glance/Camera/CameraFrame.swift \
//        glance/Camera/CameraCaptureSession.swift \
//        glance/Camera/CameraDeviceCatalog.swift \
//        glance/Camera/CameraManager.swift \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/DeviceBezelDetector.swift \
//        glance/Liveness/GlareFaceRegion.swift \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/GlareCueExtractor.swift \
//        glance/Liveness/LivenessFeatures.swift \
//        glance/Liveness/GeometryLiveness.swift \
//        glance/Liveness/LivenessScoring.swift \
//        glance/Liveness/LivenessCues.swift \
//        glance/Liveness/LivenessAnalyzer.swift \
//        glance/NightBoost/SceneLuminance.swift \
//        glance/NightBoost/LowLightEnhancer.swift \
//        glance/Recognition/FaceEmbedder.swift \
//        glance/Recognition/FaceDetector.swift \
//        glance/Recognition/FaceAligner.swift \
//        glance/Recognition/ArcFaceEmbedder.swift \
//        glance/Recognition/FaceRecognitionPipeline.swift \
//        glance/Security/KeychainManager.swift \
//        glance/Security/SecureFaceStore.swift \
//        glance/Security/SecureCredentialManager.swift \
//        glance/Recognition/FaceEnrollmentStore.swift \
//        glance/Recognition/FaceAuthSession.swift \
//        tools/pipeline_benchmark.swift
//      "$TMP_DIR/pipeline_benchmark" --synthetic --frames 60 --liveness light --night-boost off --cycles 2
//

@preconcurrency import AVFoundation
import CoreFoundation
import CoreGraphics
import CoreImage
import CoreML
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Vision
import os

nonisolated enum BenchmarkMode: String, Codable, Sendable {
    case synthetic
    case liveCamera = "live-camera"
}

nonisolated enum LivenessOption: String, Codable, Sendable {
    case off
    case light
    case heavy

    var livenessMode: LivenessMode? {
        switch self {
        case .off: return nil
        case .light: return .light
        case .heavy: return .heavy
        }
    }
}

nonisolated enum OutputFormat: String, Sendable {
    case both
    case markdown
    case json
}

nonisolated struct BenchmarkConfig: Sendable {
    var mode: BenchmarkMode = .synthetic
    var frames: Int = 60
    var liveness: LivenessOption = .light
    var nightBoost: Bool = false
    var cycles: Int = 2
    var settleSeconds: Double = 2.0
    var modelPath: String?
    var imagePath: String?
    var jsonOutPath: String?
    var format: OutputFormat = .both

    static func parse(arguments: [String]) throws -> BenchmarkConfig {
        var config = BenchmarkConfig()
        var sawSynthetic = false
        var sawLiveCamera = false
        var index = 1

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--synthetic":
                sawSynthetic = true
                config.mode = .synthetic
            case "--live-camera":
                sawLiveCamera = true
                config.mode = .liveCamera
            case "--frames":
                index += 1
                let value = try requireValue(for: arg, at: index, in: arguments)
                guard let parsed = Int(value), parsed >= 1 else {
                    throw BenchmarkError.invalidArgument("--frames must be an integer >= 1 (got '\(value)').")
                }
                config.frames = parsed
            case "--liveness":
                index += 1
                let value = try requireValue(for: arg, at: index, in: arguments)
                guard let parsed = LivenessOption(rawValue: value) else {
                    throw BenchmarkError.invalidArgument("--liveness must be off|light|heavy (got '\(value)').")
                }
                config.liveness = parsed
            case "--night-boost":
                index += 1
                let value = try requireValue(for: arg, at: index, in: arguments)
                switch value {
                case "on": config.nightBoost = true
                case "off": config.nightBoost = false
                default:
                    throw BenchmarkError.invalidArgument("--night-boost must be off|on (got '\(value)').")
                }
            case "--cycles":
                index += 1
                let value = try requireValue(for: arg, at: index, in: arguments)
                guard let parsed = Int(value), parsed >= 1 else {
                    throw BenchmarkError.invalidArgument("--cycles must be an integer >= 1 (got '\(value)').")
                }
                config.cycles = parsed
            case "--settle-seconds":
                index += 1
                let value = try requireValue(for: arg, at: index, in: arguments)
                guard let parsed = Double(value), parsed >= 0, parsed.isFinite else {
                    throw BenchmarkError.invalidArgument("--settle-seconds must be a finite number >= 0.")
                }
                config.settleSeconds = parsed
            case "--model-path":
                index += 1
                config.modelPath = try requireValue(for: arg, at: index, in: arguments)
            case "--image":
                index += 1
                config.imagePath = try requireValue(for: arg, at: index, in: arguments)
            case "--json-out":
                index += 1
                config.jsonOutPath = try requireValue(for: arg, at: index, in: arguments)
            case "--format":
                index += 1
                let value = try requireValue(for: arg, at: index, in: arguments)
                guard let parsed = OutputFormat(rawValue: value) else {
                    throw BenchmarkError.invalidArgument("--format must be both|markdown|json (got '\(value)').")
                }
                config.format = parsed
            case "-h", "--help":
                throw BenchmarkError.helpRequested
            default:
                throw BenchmarkError.invalidArgument("Unknown option '\(arg)'.")
            }
            index += 1
        }

        if sawSynthetic && sawLiveCamera {
            throw BenchmarkError.invalidArgument("Choose either --synthetic or --live-camera, not both.")
        }
        return config
    }

    private static func requireValue(for flag: String, at index: Int, in arguments: [String]) throws -> String {
        guard index < arguments.count else {
            throw BenchmarkError.invalidArgument("Missing value for \(flag).")
        }
        return arguments[index]
    }

    static var usageText: String {
        """
        Usage: pipeline_benchmark [options]

        Options:
          --synthetic                 Run reproducible 1080p synthetic frame pipeline (default)
          --live-camera               Run against hardware camera via CameraManager
          --frames <N>                Usable frames to measure per cycle (default: 60)
          --liveness <off|light|heavy> Liveness mode to benchmark (default: light)
          --night-boost <off|on>      Enable low-light scene luminance & enhancer (default: off)
          --cycles <N>                Number of capture cycles separated by stop + settle (default: 2)
          --settle-seconds <N>        Settle wait after stop() between cycles (default: 2)
          --model-path <path>         Path to ArcFace.mlmodelc, ArcFace.mlpackage, or glance.app
          --image <path>              Portrait image override for --synthetic mode
          --json-out <path>           Write structured JSON report to disk
          --format <both|markdown|json> Output format on stdout (default: both)
          -h, --help                  Show this help
        """
    }
}

nonisolated enum BenchmarkError: LocalizedError {
    case helpRequested
    case invalidArgument(String)
    case modelUnavailable(String)
    case imageLoadFailed(String)
    case cameraUnavailable(String)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .invalidArgument(let detail):
            return detail
        case .modelUnavailable(let detail):
            return detail
        case .imageLoadFailed(let detail):
            return detail
        case .cameraUnavailable(let detail):
            return detail
        case .captureFailed(let detail):
            return detail
        }
    }
}

nonisolated struct MemorySnapshot: Codable, Sendable {
    let physFootprintMB: Double
    let residentSizeMB: Double
}

nonisolated struct DistributionStats: Codable, Sendable {
    let count: Int
    let minMs: Double
    let medianMs: Double
    let p95Ms: Double
    let maxMs: Double
    let meanMs: Double

    static func summarize(_ samples: [Double]) -> DistributionStats {
        guard !samples.isEmpty else {
            return DistributionStats(count: 0, minMs: 0, medianMs: 0, p95Ms: 0, maxMs: 0, meanMs: 0)
        }
        let sorted = samples.sorted()
        let count = sorted.count
        let median: Double
        if count.isMultiple(of: 2) {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            median = sorted[count / 2]
        }
        let p95Index = min(count - 1, Int((Double(count - 1) * 0.95).rounded(.toNearestOrAwayFromZero)))
        let mean = sorted.reduce(0, +) / Double(count)
        return DistributionStats(
            count: count,
            minMs: sorted[0],
            medianMs: median,
            p95Ms: sorted[p95Index],
            maxMs: sorted[count - 1],
            meanMs: mean
        )
    }
}

nonisolated struct MemoryCheckpoints: Codable, Sendable {
    let beforeStart: MemorySnapshot
    let peakDuringScan: MemorySnapshot
    let afterStopAndSettle: MemorySnapshot
}

nonisolated struct DroppedFramesSummary: Codable, Sendable {
    let busySkipped: Int
    let coalesced: Int
    let totalDropped: Int
}

nonisolated struct CycleMetrics: Codable, Sendable {
    let cycle: Int
    let framesProcessed: Int
    let facesDetected: Int
    let fivePointAlignments: Int
    let nightBoostEnhancedFrames: Int
    let coldModelLoadMs: Double?
    let warmModelLoadMs: Double?
    let startToFirstFrameMs: Double
    let totalScanDurationMs: Double
    let totalPerFrame: DistributionStats
    let workingRender640: DistributionStats
    let recognition: DistributionStats
    let livenessExtraction: DistributionStats
    let mainThread: DistributionStats
    let droppedFrames: DroppedFramesSummary
    let memory: MemoryCheckpoints
}

nonisolated struct BenchmarkMetadata: Codable, Sendable {
    let timestampISO8601: String
    let mode: BenchmarkMode
    let xcodeVersion: String
    let swiftVersion: String
    let macOSVersion: String
    let architecture: String
    let hardwareModel: String
    let cameraName: String
    let inputResolution: String
    let livenessMode: LivenessOption
    let nightBoost: Bool
    let framesPerCycle: Int
    let cycles: Int
    let settleSeconds: Double
    let modelName: String
    let modelIdentifier: String
    let computeUnits: String
    let usingRealArcFaceModel: Bool
}

nonisolated struct BenchmarkReport: Codable, Sendable {
    let metadata: BenchmarkMetadata
    let processIdleBeforeModel: MemorySnapshot
    let cycles: [CycleMetrics]
}

nonisolated enum MemorySampler {
    static func capture() -> MemorySnapshot {
        MemorySnapshot(
            physFootprintMB: bytesToMB(readPhysFootprintBytes()),
            residentSizeMB: bytesToMB(readResidentSizeBytes())
        )
    }

    static func maxSnapshot(_ lhs: MemorySnapshot, _ rhs: MemorySnapshot) -> MemorySnapshot {
        MemorySnapshot(
            physFootprintMB: max(lhs.physFootprintMB, rhs.physFootprintMB),
            residentSizeMB: max(lhs.residentSizeMB, rhs.residentSizeMB)
        )
    }

    private static func bytesToMB(_ bytes: UInt64) -> Double {
        Double(bytes) / (1024.0 * 1024.0)
    }

    private static func readPhysFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func readResidentSizeBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

nonisolated enum SystemProbe {
    static func collectMetadata(
        config: BenchmarkConfig,
        cameraName: String,
        inputResolution: String,
        embedder: FaceEmbedder
    ) -> BenchmarkMetadata {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let computeUnits: String
        switch ArcFaceEmbedder.preferredComputeUnits() {
        case .cpuOnly: computeUnits = "cpuOnly"
        case .cpuAndGPU: computeUnits = "cpuAndGPU"
        case .all: computeUnits = "all"
        case .cpuAndNeuralEngine: computeUnits = "cpuAndNeuralEngine"
        @unknown default: computeUnits = "unknown"
        }

        return BenchmarkMetadata(
            timestampISO8601: formatter.string(from: Date()),
            mode: config.mode,
            xcodeVersion: runTool("/usr/bin/xcodebuild", args: ["-version"])
                .replacingOccurrences(of: "\n", with: " "),
            swiftVersion: firstLine(of: runTool("/usr/bin/swift", args: ["--version"])),
            macOSVersion: "\(runTool("/usr/bin/sw_vers", args: ["-productVersion"])) "
                + "(\(runTool("/usr/bin/sw_vers", args: ["-buildVersion"])))",
            architecture: architectureName(),
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            cameraName: cameraName,
            inputResolution: inputResolution,
            livenessMode: config.liveness,
            nightBoost: config.nightBoost,
            framesPerCycle: config.frames,
            cycles: config.cycles,
            settleSeconds: config.settleSeconds,
            modelName: embedder.name,
            modelIdentifier: embedder.modelIdentifier,
            computeUnits: computeUnits,
            usingRealArcFaceModel: embedder.isUnlockCapable
                && embedder.modelIdentifier == ArcFaceEmbedder.modelIdentifier
        )
    }

    static func durationMs(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let elapsed = end - start
        let components = elapsed.components
        return Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
    }

    static func runTool(_ path: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }

    private static func firstLine(of text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
    }

    private static func architectureName() -> String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

nonisolated enum ModelBundleStaging {
    private static let stagedEnvKey = "GLANCE_BENCH_MODEL_STAGED"

    /// Ensures `ArcFace.mlmodelc` is discoverable via `Bundle.main` without modifying `ArcFaceEmbedder`.
    /// When the executable directory already contains `ArcFace.mlmodelc` (and `--model-path` is unset),
    /// returns `nil` and runs in-process. Otherwise stages a temporary directory with a symlinked binary
    /// and compiled `ArcFace.mlmodelc`, runs as a clean child process, and returns its exit code.
    static func runStagedIfNeeded(config: BenchmarkConfig) throws -> Int32? {
        if ProcessInfo.processInfo.environment[stagedEnvKey] == "1" {
            return nil
        }

        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let localCompiled = bundleURL.appendingPathComponent("ArcFace.mlmodelc")
        let resourceCompiled = Bundle.main.resourceURL?.appendingPathComponent("ArcFace.mlmodelc")

        if config.modelPath == nil {
            if fm.fileExists(atPath: localCompiled.path) {
                return nil
            }
            if let resourceCompiled, fm.fileExists(atPath: resourceCompiled.path) {
                return nil
            }
        }

        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("glance-bench-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let modelURL = try resolveOrCompileModel(explicitPath: config.modelPath, into: tempDir)
        let stagedModelURL = tempDir.appendingPathComponent("ArcFace.mlmodelc")
        if modelURL.standardizedFileURL != stagedModelURL.standardizedFileURL {
            try fm.createSymbolicLink(at: stagedModelURL, withDestinationURL: modelURL)
        }

        guard let executableURL = Bundle.main.executableURL else {
            throw BenchmarkError.modelUnavailable("Could not determine benchmark executable path for staging.")
        }
        let stagedExeURL = tempDir.appendingPathComponent(executableURL.lastPathComponent)
        try fm.createSymbolicLink(at: stagedExeURL, withDestinationURL: executableURL)

        let child = Process()
        child.executableURL = stagedExeURL
        child.arguments = Array(CommandLine.arguments.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env[stagedEnvKey] = "1"
        child.environment = env
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus
    }

    private static func resolveOrCompileModel(explicitPath: String?, into tempDir: URL) throws -> URL {
        let fm = FileManager.default
        let candidatePath: String
        if let explicitPath {
            candidatePath = explicitPath
        } else {
            let repoPackage = URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("glance/Models/ArcFace.mlpackage")
            guard fm.fileExists(atPath: repoPackage.path) else {
                throw BenchmarkError.modelUnavailable(
                    "ArcFace.mlmodelc not found next to binary and \(repoPackage.path) does not exist. "
                        + "Pass --model-path <path> or compile ArcFace.mlpackage with xcrun coremlc compile."
                )
            }
            candidatePath = repoPackage.path
        }

        let url = URL(fileURLWithPath: candidatePath).standardizedFileURL
        guard fm.fileExists(atPath: url.path) else {
            throw BenchmarkError.modelUnavailable("Model path does not exist: \(url.path)")
        }

        switch url.pathExtension.lowercased() {
        case "mlmodelc":
            return url
        case "app":
            let bundled = url.appendingPathComponent("Contents/Resources/ArcFace.mlmodelc")
            guard fm.fileExists(atPath: bundled.path) else {
                throw BenchmarkError.modelUnavailable("No ArcFace.mlmodelc inside \(url.path)")
            }
            return bundled
        case "mlpackage", "mlmodel":
            try compileModel(at: url, into: tempDir)
            let compiled = tempDir.appendingPathComponent("ArcFace.mlmodelc")
            if fm.fileExists(atPath: compiled.path) {
                return compiled
            }
            let alt = tempDir.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".mlmodelc"
            )
            if fm.fileExists(atPath: alt.path) {
                return alt
            }
            throw BenchmarkError.modelUnavailable("coremlc compiled \(url.path) but produced no .mlmodelc.")
        default:
            throw BenchmarkError.modelUnavailable(
                "Unsupported --model-path extension '\(url.pathExtension)' (expected .mlmodelc, .mlpackage, or .app)."
            )
        }
    }

    private static func compileModel(at sourceURL: URL, into outputDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["coremlc", "compile", sourceURL.path, outputDir.path]
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderrData, as: UTF8.self)
            throw BenchmarkError.modelUnavailable("xcrun coremlc compile failed: \(detail)")
        }
    }
}

nonisolated final class SyntheticFrameStream: @unchecked Sendable {
    static let frameWidth = 1920
    static let frameHeight = 1080
    private static let tileSize = 640
    private static let keyframeCount = 16
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bgraBitmapInfo =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private let keyframes: [CGImage]
    private let pixelBufferPool: CVPixelBufferPool
    let sourceLabel: String

    init(imagePath: String?) throws {
        let prepContext = CIContext()
        if let imagePath {
            let url = URL(fileURLWithPath: imagePath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw BenchmarkError.imageLoadFailed("Failed to load portrait image at '\(imagePath)'.")
            }
            let rectRequest = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([rectRequest])
            if (rectRequest.results ?? []).isEmpty {
                fputs(
                    "Warning: Vision detected 0 faces in '\(imagePath)'; recognition stages may fail.\n",
                    stderr
                )
            }
            self.keyframes = [Self.fitIntoTile(image)]
            self.sourceLabel = "Synthetic 1080p (\(url.lastPathComponent))"
        } else {
            self.keyframes = (0..<Self.keyframeCount).map {
                Self.renderProceduralFaceKeyframe(index: $0, ciContext: prepContext)
            }
            self.sourceLabel = "Synthetic 1080p Procedural Portrait"
        }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.frameWidth,
            kCVPixelBufferHeightKey as String: Self.frameHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw BenchmarkError.captureFailed("Failed to create 1080p CVPixelBufferPool (status: \(status)).")
        }
        self.pixelBufferPool = pool
    }

    func makePixelBuffer(tickIndex: Int) -> CVPixelBuffer? {
        var bufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &bufferOut)
        guard status == kCVReturnSuccess, let buffer = bufferOut else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Self.frameWidth,
                height: Self.frameHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: Self.srgbSpace,
                bitmapInfo: Self.bgraBitmapInfo
            )
        else { return nil }

        // Dark indoor background (~0.13 mean luminance across 1080p) so `--night-boost on`
        // exercises `LowLightEnhancer` while `--night-boost off` runs raw Two-Phase recognition.
        context.setFillColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: Self.frameWidth, height: Self.frameHeight))

        let keyframe = keyframes[tickIndex % keyframes.count]
        let phase = Double(tickIndex) * 0.35
        let dx = sin(phase) * 14.0
        let dy = cos(phase * 0.7) * 8.0
        let scale = 1.0 + sin(phase * 0.4) * 0.03
        let drawSize = CGFloat(Self.tileSize) * scale
        let originX = (CGFloat(Self.frameWidth) - drawSize) / 2.0 + dx
        let originY = (CGFloat(Self.frameHeight) - drawSize) / 2.0 + dy
        context.draw(keyframe, in: CGRect(x: originX, y: originY, width: drawSize, height: drawSize))
        return buffer
    }

    private static func fitIntoTile(_ image: CGImage) -> CGImage {
        let size = tileSize
        guard
            let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: srgbSpace,
                bitmapInfo: bgraBitmapInfo
            )
        else { return image }
        context.setFillColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let aspect = CGFloat(image.width) / max(CGFloat(image.height), 1)
        let drawRect: CGRect
        if aspect >= 1.0 {
            let h = CGFloat(size) / aspect
            drawRect = CGRect(x: 0, y: (CGFloat(size) - h) / 2.0, width: CGFloat(size), height: h)
        } else {
            let w = CGFloat(size) * aspect
            drawRect = CGRect(x: (CGFloat(size) - w) / 2.0, y: 0, width: w, height: CGFloat(size))
        }
        context.draw(image, in: drawRect)
        return context.makeImage() ?? image
    }

    private static func renderProceduralFaceKeyframe(index: Int, ciContext: CIContext) -> CGImage {
        let size = tileSize
        guard
            let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: srgbSpace,
                bitmapInfo: bgraBitmapInfo
            )
        else {
            fatalError("Failed to create synthetic portrait context")
        }

        let scale = CGFloat(size) / 640.0
        context.setFillColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: scale, y: -scale)

        let angle = (Double(index) / Double(keyframeCount)) * 2.0 * .pi
        let yawShift = sin(angle) * 10.0
        drawPortrait(in: context, yawShift: yawShift)

        guard let raw = context.makeImage() else {
            fatalError("Failed to materialize synthetic portrait")
        }
        let blurred = CIImage(cgImage: raw)
            .applyingGaussianBlur(sigma: 1.6)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        return ciContext.createCGImage(blurred, from: blurred.extent) ?? raw
    }

    private static func drawPortrait(in ctx: CGContext, yawShift: Double) {
        // Torso & neck
        ctx.setFillColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 100, y: 460, width: 440, height: 240))
        ctx.setFillColor(red: 0.62, green: 0.46, blue: 0.36, alpha: 1.0)
        ctx.fill(CGRect(x: 265, y: 390, width: 110, height: 110))

        // Hair back & head base
        ctx.setFillColor(red: 0.10, green: 0.07, blue: 0.05, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 175, y: 80, width: 290, height: 290))
        ctx.setFillColor(red: 0.80, green: 0.62, blue: 0.50, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 205, y: 120, width: 230, height: 310))

        // Cheek & forehead highlights
        ctx.setFillColor(red: 0.84, green: 0.68, blue: 0.56, alpha: 0.6)
        ctx.fillEllipse(in: CGRect(x: 225 + yawShift * 0.4, y: 255, width: 70, height: 60))
        ctx.fillEllipse(in: CGRect(x: 345 + yawShift * 0.4, y: 255, width: 70, height: 60))
        ctx.fillEllipse(in: CGRect(x: 255 + yawShift * 0.3, y: 155, width: 130, height: 65))

        // Eye sockets & eyebrows
        ctx.setFillColor(red: 0.55, green: 0.38, blue: 0.30, alpha: 0.5)
        ctx.fillEllipse(in: CGRect(x: 230 + yawShift * 0.5, y: 222, width: 72, height: 42))
        ctx.fillEllipse(in: CGRect(x: 338 + yawShift * 0.5, y: 222, width: 72, height: 42))
        ctx.setFillColor(red: 0.14, green: 0.09, blue: 0.06, alpha: 0.9)
        ctx.fillEllipse(in: CGRect(x: 232 + yawShift * 0.5, y: 210, width: 68, height: 14))
        ctx.fillEllipse(in: CGRect(x: 340 + yawShift * 0.5, y: 210, width: 68, height: 14))

        for eyeX in [266.0, 374.0] {
            let cx = eyeX + yawShift * 0.5
            ctx.setFillColor(red: 0.92, green: 0.91, blue: 0.90, alpha: 1.0)
            ctx.fillEllipse(in: CGRect(x: cx - 22, y: 235, width: 44, height: 18))
            ctx.setFillColor(red: 0.20, green: 0.14, blue: 0.09, alpha: 1.0)
            ctx.fillEllipse(in: CGRect(x: cx - 9, y: 235, width: 18, height: 18))
            ctx.setFillColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1.0)
            ctx.fillEllipse(in: CGRect(x: cx - 4, y: 240, width: 8, height: 8))
            ctx.setFillColor(red: 0.24, green: 0.16, blue: 0.12, alpha: 0.8)
            ctx.fill(CGRect(x: cx - 22, y: 234, width: 44, height: 3))
        }

        // Nose & nostrils (larger shift creates real inter-frame landmark parallax)
        ctx.setFillColor(red: 0.60, green: 0.42, blue: 0.33, alpha: 0.45)
        ctx.fillEllipse(in: CGRect(x: 294 + yawShift, y: 250, width: 52, height: 75))
        ctx.setFillColor(red: 0.86, green: 0.70, blue: 0.59, alpha: 0.8)
        ctx.fillEllipse(in: CGRect(x: 310 + yawShift, y: 245, width: 20, height: 65))
        ctx.setFillColor(red: 0.38, green: 0.24, blue: 0.18, alpha: 0.7)
        ctx.fillEllipse(in: CGRect(x: 304 + yawShift, y: 312, width: 10, height: 8))
        ctx.fillEllipse(in: CGRect(x: 326 + yawShift, y: 312, width: 10, height: 8))

        // Lips & hair fringe
        ctx.setFillColor(red: 0.64, green: 0.32, blue: 0.30, alpha: 0.9)
        ctx.fillEllipse(in: CGRect(x: 280 + yawShift * 0.6, y: 350, width: 80, height: 24))
        ctx.setFillColor(red: 0.36, green: 0.14, blue: 0.14, alpha: 0.9)
        ctx.fill(CGRect(x: 284 + yawShift * 0.6, y: 360, width: 72, height: 3))
        ctx.setFillColor(red: 0.10, green: 0.07, blue: 0.05, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 195, y: 90, width: 250, height: 90))
    }
}

private nonisolated final class SyntheticFrameProducer: @unchecked Sendable {
    private struct TimingState: Sendable {
        var nextFrameID: UInt64 = 0
        var tickIndex: Int = 0
        var busySkipped: Int = 0
        var coalesced: Int = 0
        var workingRenderMsByID: [UInt64: Double] = [:]
        var publishMainMsByID: [UInt64: Double] = [:]
    }

    private let stream: SyntheticFrameStream
    private let queue: DispatchQueue
    private let framePublisher: CameraFramePublisher
    private let sessionBox: CameraSessionBox
    private let frameWaiter = CameraFrameWaiter(isActive: false)
    private let pendingState = OSAllocatedUnfairLock(
        initialState: PendingCameraFrameState(publishesFrames: true, isCapturing: false)
    )
    private let timingState = OSAllocatedUnfairLock(initialState: TimingState())
    private var timer: DispatchSourceTimer?

    init(stream: SyntheticFrameStream) {
        self.stream = stream
        self.queue = DispatchQueue(label: "com.pearleseed.glance.benchmark.synthetic")
        let publisher = CameraFramePublisher(publishesFrames: true)
        self.framePublisher = publisher
        self.sessionBox = CameraSessionBox(framePublisher: publisher, queue: queue)
        // Materialize lazy AVCaptureSession so `CameraSessionBox.stop()` executes its
        // full `SharedCoreImageContext.clearCaches()` path between cycles without TCC access.
        queue.sync {
            _ = sessionBox.session
        }
    }

    func setConsumerBusy(_ busy: Bool) {
        pendingState.withLock { $0.isConsumerBusy = busy }
    }

    func start() {
        timingState.withLock { state in
            state.tickIndex = 0
            state.busySkipped = 0
            state.coalesced = 0
            state.workingRenderMsByID.removeAll()
            state.publishMainMsByID.removeAll()
        }
        frameWaiter.start()
        pendingState.withLock { $0.beginCapture() }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 30 fps camera cadence (~33.33 ms)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            self?.emitTick()
        }
        self.timer = timer
        timer.resume()
    }

    func stopAndClearCaches() {
        queue.sync {
            timer?.cancel()
            timer = nil
            pendingState.withLock { $0.endCapture() }
            frameWaiter.stop()
            sessionBox.stop()
        }
    }

    func nextFrame(after lastFrameID: UInt64?, until deadline: ContinuousClock.Instant) async -> CameraFrame? {
        let epoch = frameWaiter.currentEpoch
        return await frameWaiter.nextFrame(after: lastFrameID, until: deadline, expectedEpoch: epoch)
    }

    func takePerFrameProducerTimings(for frameID: UInt64) -> (workingRenderMs: Double, publishMainMs: Double) {
        timingState.withLock { state in
            let renderMs = state.workingRenderMsByID.removeValue(forKey: frameID) ?? 0
            let publishMs = state.publishMainMsByID.removeValue(forKey: frameID) ?? 0
            return (renderMs, publishMs)
        }
    }

    func droppedSummary() -> DroppedFramesSummary {
        timingState.withLock { state in
            DroppedFramesSummary(
                busySkipped: state.busySkipped,
                coalesced: state.coalesced,
                totalDropped: state.busySkipped + state.coalesced
            )
        }
    }

    private func emitTick() {
        let generation: UInt64? = pendingState.withLock { state in
            guard state.shouldRenderSample else { return nil }
            return state.captureGeneration
        }
        guard let generation else {
            timingState.withLock { $0.busySkipped += 1 }
            return
        }

        let tickIndex = timingState.withLock { state -> Int in
            let current = state.tickIndex
            state.tickIndex += 1
            return current
        }

        guard let pixelBuffer = stream.makePixelBuffer(tickIndex: tickIndex) else { return }

        let clock = ContinuousClock()
        let renderStart = clock.now
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = sourceImage.extent
        var ciImage = sourceImage
        let maxLongEdge: CGFloat = 640
        let longEdge = max(ciImage.extent.width, ciImage.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = SharedCoreImageContext.srgb.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }
        let renderMs = SystemProbe.durationMs(from: renderStart, to: clock.now)

        let frameID = timingState.withLock { state -> UInt64 in
            state.nextFrameID &+= 1
            state.workingRenderMsByID[state.nextFrameID] = renderMs
            return state.nextFrameID
        }

        let frame = CameraFrame(
            id: frameID,
            image: cgImage,
            source: sourceImage,
            sourceSize: sourceExtent.size
        )

        let enqueueResult = pendingState.withLock { state -> (shouldSchedule: Bool, overwritten: Bool) in
            let hadPending = state.pendingFrame != nil
            let scheduled = state.enqueueIfActive(frame, generation: generation)
            let isActive = state.publishesFrames && state.isCapturing && state.captureGeneration == generation
            return (scheduled, isActive && hadPending)
        }
        if enqueueResult.overwritten {
            timingState.withLock { $0.coalesced += 1 }
        }

        if enqueueResult.shouldSchedule {
            let pendingState = self.pendingState
            let frameWaiter = self.frameWaiter
            let timingState = self.timingState
            Task { @MainActor in
                let publishStart = ContinuousClock.now
                let drained = pendingState.withLock { $0.drainPending() }
                if let drained {
                    let publishMs = SystemProbe.durationMs(from: publishStart, to: ContinuousClock.now)
                    timingState.withLock { $0.publishMainMsByID[drained.id] = publishMs }
                    frameWaiter.deliver(drained)
                }
            }
        }
    }
}

extension SyntheticFrameProducer: FrameBackpressureTarget {}

private nonisolated struct ExtractedFrameResult: @unchecked Sendable {
    let recognition: FaceRecognitionResult?
    let livenessFrame: LivenessFrame?
    let precomputedGeometry: GeometryLivenessResult?
    let geometryGeneration: UInt64?
    let nightBoostEnhanced: Bool
    let recognitionMs: Double
    let livenessMs: Double
}

private nonisolated enum StageRunner {
    static func renderWorkingFrame640(from source: CIImage) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        var ciImage = source
        let maxLongEdge: CGFloat = 640
        let longEdge = max(ciImage.extent.width, ciImage.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        _ = SharedCoreImageContext.srgb.createCGImage(ciImage, from: ciImage.extent)
        return SystemProbe.durationMs(from: start, to: clock.now)
    }

    static func extractStages(
        from frame: CameraFrame,
        pipeline: FaceRecognitionPipeline,
        previousBoundingBox: CGRect?,
        livenessEnabled: Bool,
        nightBoostEnabled: Bool,
        geometryContext: LivenessAnalyzer.GeometryEvaluationContext?
    ) async -> ExtractedFrameResult {
        await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let recStart = clock.now
            let measuredLuminance = nightBoostEnabled ? SceneLuminance.meanLuminance(of: frame.image) : nil
            let didEnhance: Bool
            let recognitionResult: FaceRecognitionResult?
            if let measuredLuminance, measuredLuminance < SceneLuminance.enhanceThreshold {
                didEnhance = true
                let enhanced = LowLightEnhancer.enhance(frame.image, meanLuminance: measuredLuminance)
                recognitionResult = try? pipeline.recognize(
                    in: enhanced,
                    preferNear: previousBoundingBox,
                    includeQuality: false,
                    strictCloseRangeOnly: false
                )
            } else {
                didEnhance = false
                recognitionResult = try? pipeline.recognize(
                    in: frame,
                    preferNear: previousBoundingBox,
                    includeQuality: false,
                    strictCloseRangeOnly: false
                )
            }
            let recMs = SystemProbe.durationMs(from: recStart, to: clock.now)

            guard let result = recognitionResult, livenessEnabled else {
                return ExtractedFrameResult(
                    recognition: recognitionResult,
                    livenessFrame: nil,
                    precomputedGeometry: nil,
                    geometryGeneration: nil,
                    nightBoostEnhanced: didEnhance,
                    recognitionMs: recMs,
                    livenessMs: 0
                )
            }

            let liveStart = clock.now
            let faceCrop = FaceAuthEvaluator.glareCrop(from: frame, recognition: result)
            let livenessFrame = LivenessFeatureExtractor.extract(
                from: result,
                frame: frame.image,
                faceCrop: faceCrop
            )
            let precomputedGeometry = geometryContext?.computeGeometry(appending: livenessFrame)
            let liveMs = SystemProbe.durationMs(from: liveStart, to: clock.now)

            return ExtractedFrameResult(
                recognition: result,
                livenessFrame: livenessFrame,
                precomputedGeometry: precomputedGeometry,
                geometryGeneration: geometryContext?.generation,
                nightBoostEnhanced: didEnhance,
                recognitionMs: recMs,
                livenessMs: liveMs
            )
        }.value
    }
}

@MainActor
private final class CycleAccumulator {
    var totalFrameSamples: [Double] = []
    var workingRenderSamples: [Double] = []
    var recognitionSamples: [Double] = []
    var livenessSamples: [Double] = []
    var mainThreadSamples: [Double] = []
    var facesDetected = 0
    var fivePointAlignments = 0
    var nightBoostEnhancedFrames = 0
    var enrolledIdentity: [FaceIdentity] = []
    var previousBoundingBox: CGRect?
    var peakMemory: MemorySnapshot

    init(initialMemory: MemorySnapshot) {
        self.peakMemory = initialMemory
    }

    func recordMemoryPeak() {
        peakMemory = MemorySampler.maxSnapshot(peakMemory, MemorySampler.capture())
    }

    func evaluateOnMainActor(
        extracted: ExtractedFrameResult,
        pipeline: FaceRecognitionPipeline,
        livenessAnalyzer: LivenessAnalyzer?,
        livenessEnabled: Bool,
        publishMainMs: Double,
        workingRenderMs: Double
    ) {
        let evalStart = ContinuousClock.now
        if let result = extracted.recognition {
            facesDetected += 1
            if result.alignmentTier == .fivePoint {
                fivePointAlignments += 1
            }
            if enrolledIdentity.isEmpty {
                let sample = FaceSample(
                    embedding: result.embedding,
                    pose: "center",
                    capturedAt: Date(),
                    quality: result.quality
                )
                enrolledIdentity = [
                    FaceIdentity(
                        id: UUID(),
                        name: "BenchmarkSubject",
                        samples: [sample],
                        modelIdentifier: pipeline.currentEmbedder().modelIdentifier,
                        embeddingDimension: result.embedding.count,
                        createdAt: Date()
                    )
                ]
            }
            previousBoundingBox = result.face.normalizedBoundingBox
            let scored = pipeline.score(result.embedding, against: enrolledIdentity)
            _ = pipeline.bestMatch(in: scored, threshold: 0.62)
            if livenessEnabled, let livenessFrame = extracted.livenessFrame {
                _ = livenessAnalyzer?.observe(
                    livenessFrame,
                    precomputedGeometry: extracted.precomputedGeometry,
                    sourceGeneration: extracted.geometryGeneration
                )
            }
        } else {
            previousBoundingBox = nil
        }
        let evalMainMs = SystemProbe.durationMs(from: evalStart, to: ContinuousClock.now)

        if extracted.nightBoostEnhanced {
            nightBoostEnhancedFrames += 1
        }
        let mainMs = publishMainMs + evalMainMs
        let totalMs = workingRenderMs + extracted.recognitionMs + extracted.livenessMs + mainMs
        workingRenderSamples.append(workingRenderMs)
        recognitionSamples.append(extracted.recognitionMs)
        livenessSamples.append(extracted.livenessMs)
        mainThreadSamples.append(mainMs)
        totalFrameSamples.append(totalMs)
        recordMemoryPeak()
    }
}

@MainActor
private enum PipelineBenchmarkRunner {
    static func run(config: BenchmarkConfig) async throws -> BenchmarkReport {
        let idleBeforeModel = MemorySampler.capture()
        let (primaryEmbedder, coldModelLoadMs, warmModelLoadMs) = try loadAndTimeEmbedders()

        let pipeline = FaceRecognitionPipeline(
            embedder: primaryEmbedder,
            usingFallbackEmbedder: false,
            fallbackReason: nil
        )

        switch config.mode {
        case .synthetic:
            return try await runSynthetic(
                config: config,
                pipeline: pipeline,
                primaryEmbedder: primaryEmbedder,
                idleBeforeModel: idleBeforeModel,
                coldModelLoadMs: coldModelLoadMs,
                warmModelLoadMs: warmModelLoadMs
            )
        case .liveCamera:
            return try await runLiveCamera(
                config: config,
                pipeline: pipeline,
                primaryEmbedder: primaryEmbedder,
                idleBeforeModel: idleBeforeModel,
                coldModelLoadMs: coldModelLoadMs,
                warmModelLoadMs: warmModelLoadMs
            )
        }
    }

    private static func loadAndTimeEmbedders() throws -> (
        embedder: ArcFaceEmbedder,
        coldMs: Double,
        warmMs: Double
    ) {
        let coldStart = ContinuousClock.now
        let primaryEmbedder: ArcFaceEmbedder
        do {
            primaryEmbedder = try ArcFaceEmbedder()
        } catch {
            throw BenchmarkError.modelUnavailable(error.localizedDescription)
        }
        let coldMs = SystemProbe.durationMs(from: coldStart, to: ContinuousClock.now)

        let warmMs: Double = try autoreleasepool {
            let warmStart = ContinuousClock.now
            do {
                _ = try ArcFaceEmbedder()
            } catch {
                throw BenchmarkError.modelUnavailable(error.localizedDescription)
            }
            return SystemProbe.durationMs(from: warmStart, to: ContinuousClock.now)
        }
        return (primaryEmbedder, coldMs, warmMs)
    }

    private static func runSynthetic(
        config: BenchmarkConfig,
        pipeline: FaceRecognitionPipeline,
        primaryEmbedder: ArcFaceEmbedder,
        idleBeforeModel: MemorySnapshot,
        coldModelLoadMs: Double,
        warmModelLoadMs: Double
    ) async throws -> BenchmarkReport {
        let stream = try SyntheticFrameStream(imagePath: config.imagePath)
        let producer = SyntheticFrameProducer(stream: stream)
        let evaluator = FaceAuthEvaluator(
            pipeline: pipeline,
            livenessEnabled: config.liveness != .off,
            livenessModeProvider: { config.liveness.livenessMode ?? .light }
        )

        let metadata = SystemProbe.collectMetadata(
            config: config,
            cameraName: stream.sourceLabel,
            inputResolution: "\(SyntheticFrameStream.frameWidth)x\(SyntheticFrameStream.frameHeight)",
            embedder: primaryEmbedder
        )

        var cycleResults: [CycleMetrics] = []
        for cycleIndex in 1...config.cycles {
            let beforeStart = MemorySampler.capture()
            let accumulator = CycleAccumulator(initialMemory: beforeStart)
            let livenessAnalyzer = makeLivenessAnalyzer(for: config.liveness)
            let livenessEnabled = config.liveness != .off

            let samplerTask = startMemorySampler(updating: accumulator)
            let scanStart = ContinuousClock.now
            producer.start()

            var startToFirstFrameMs = 0.0
            var lastFrameID: UInt64?
            let deadline = ContinuousClock.now + .seconds(max(30, config.frames * 2))

            for frameOffset in 0..<config.frames {
                guard let frame = await producer.nextFrame(after: lastFrameID, until: deadline) else {
                    samplerTask.cancel()
                    producer.stopAndClearCaches()
                    throw BenchmarkError.captureFailed("Synthetic frame waiter timed out at frame \(frameOffset).")
                }
                if frameOffset == 0 {
                    startToFirstFrameMs = SystemProbe.durationMs(from: scanStart, to: ContinuousClock.now)
                }
                lastFrameID = frame.id

                let producerTimings = producer.takePerFrameProducerTimings(for: frame.id)
                let preExtractStart = ContinuousClock.now
                let previousBox = accumulator.previousBoundingBox
                let geometryContext = livenessAnalyzer?.heavyGeometryContextIfNeeded()
                let preExtractMs = SystemProbe.durationMs(from: preExtractStart, to: ContinuousClock.now)

                let extracted = await runBackpressuredExtraction(
                    evaluator: evaluator,
                    target: producer,
                    frame: frame,
                    pipeline: pipeline,
                    previousBox: previousBox,
                    livenessEnabled: livenessEnabled,
                    nightBoostEnabled: config.nightBoost,
                    geometryContext: geometryContext
                )

                accumulator.evaluateOnMainActor(
                    extracted: extracted,
                    pipeline: pipeline,
                    livenessAnalyzer: livenessAnalyzer,
                    livenessEnabled: livenessEnabled,
                    publishMainMs: producerTimings.publishMainMs + preExtractMs,
                    workingRenderMs: producerTimings.workingRenderMs
                )
            }

            let totalScanDurationMs = SystemProbe.durationMs(from: scanStart, to: ContinuousClock.now)
            samplerTask.cancel()
            let dropped = producer.droppedSummary()
            producer.stopAndClearCaches()

            if config.settleSeconds > 0 {
                try? await Task.sleep(for: .milliseconds(Int((config.settleSeconds * 1000.0).rounded())))
            }
            let afterStop = MemorySampler.capture()

            cycleResults.append(
                buildCycleMetrics(
                    cycle: cycleIndex,
                    framesProcessed: config.frames,
                    coldModelLoadMs: cycleIndex == 1 ? coldModelLoadMs : nil,
                    warmModelLoadMs: cycleIndex == 1 ? warmModelLoadMs : nil,
                    startToFirstFrameMs: startToFirstFrameMs,
                    totalScanDurationMs: totalScanDurationMs,
                    dropped: dropped,
                    beforeStart: beforeStart,
                    afterStop: afterStop,
                    accumulator: accumulator
                )
            )
        }

        return BenchmarkReport(
            metadata: metadata,
            processIdleBeforeModel: idleBeforeModel,
            cycles: cycleResults
        )
    }

    private static func runLiveCamera(
        config: BenchmarkConfig,
        pipeline: FaceRecognitionPipeline,
        primaryEmbedder: ArcFaceEmbedder,
        idleBeforeModel: MemorySnapshot,
        coldModelLoadMs: Double,
        warmModelLoadMs: Double
    ) async throws -> BenchmarkReport {
        try await verifyLiveCameraAuthorization()

        let camera = CameraManager(publishesFrames: true)
        let evaluator = FaceAuthEvaluator(
            pipeline: pipeline,
            livenessEnabled: config.liveness != .off,
            livenessModeProvider: { config.liveness.livenessMode ?? .light }
        )

        let device = CameraDeviceCatalog.resolvedDevice()
        let cameraName = device?.localizedName ?? "Unknown Camera"
        var observedResolution = describeActiveFormat(of: device)

        var cycleResults: [CycleMetrics] = []
        for cycleIndex in 1...config.cycles {
            let beforeStart = MemorySampler.capture()
            let accumulator = CycleAccumulator(initialMemory: beforeStart)
            let livenessAnalyzer = makeLivenessAnalyzer(for: config.liveness)
            let livenessEnabled = config.liveness != .off
            let samplerTask = startMemorySampler(updating: accumulator)

            let scanStart = ContinuousClock.now
            await camera.start()
            if let error = camera.errorMessage {
                samplerTask.cancel()
                camera.stop()
                throw BenchmarkError.cameraUnavailable(error)
            }

            var startToFirstFrameMs = 0.0
            var lastFrameID: UInt64?
            var coalescedCount = 0
            let deadline = ContinuousClock.now + .seconds(max(30, config.frames * 2))

            for frameOffset in 0..<config.frames {
                guard let frame = await camera.nextFrame(after: lastFrameID, until: deadline) else {
                    samplerTask.cancel()
                    camera.stop()
                    throw BenchmarkError.captureFailed("Live camera timed out at frame \(frameOffset).")
                }
                if frameOffset == 0 {
                    startToFirstFrameMs = SystemProbe.durationMs(from: scanStart, to: ContinuousClock.now)
                    observedResolution = "\(Int(frame.sourceSize.width))x\(Int(frame.sourceSize.height))"
                } else if let prev = lastFrameID, frame.id > prev + 1 {
                    coalescedCount += Int(frame.id - prev - 1)
                }
                lastFrameID = frame.id

                let preExtractStart = ContinuousClock.now
                let previousBox = accumulator.previousBoundingBox
                let geometryContext = livenessAnalyzer?.heavyGeometryContextIfNeeded()
                let preExtractMs = SystemProbe.durationMs(from: preExtractStart, to: ContinuousClock.now)

                let renderProbeMs = await Task.detached(priority: .userInitiated) {
                    StageRunner.renderWorkingFrame640(from: frame.source)
                }.value

                let extracted = await runBackpressuredExtraction(
                    evaluator: evaluator,
                    target: camera,
                    frame: frame,
                    pipeline: pipeline,
                    previousBox: previousBox,
                    livenessEnabled: livenessEnabled,
                    nightBoostEnabled: config.nightBoost,
                    geometryContext: geometryContext
                )

                accumulator.evaluateOnMainActor(
                    extracted: extracted,
                    pipeline: pipeline,
                    livenessAnalyzer: livenessAnalyzer,
                    livenessEnabled: livenessEnabled,
                    publishMainMs: preExtractMs,
                    workingRenderMs: renderProbeMs
                )
            }

            let totalScanDurationMs = SystemProbe.durationMs(from: scanStart, to: ContinuousClock.now)
            samplerTask.cancel()
            let nominalFPS = maxActiveFrameRate(of: device) ?? 30.0
            let activeCaptureMs = max(0, totalScanDurationMs - startToFirstFrameMs)
            let expectedSamples = Int((activeCaptureMs / 1000.0 * nominalFPS).rounded(.down))
            let estimatedBusySkipped = max(0, expectedSamples - config.frames - coalescedCount)
            let dropped = DroppedFramesSummary(
                busySkipped: estimatedBusySkipped,
                coalesced: coalescedCount,
                totalDropped: estimatedBusySkipped + coalescedCount
            )

            camera.stop()
            if config.settleSeconds > 0 {
                try? await Task.sleep(for: .milliseconds(Int((config.settleSeconds * 1000.0).rounded())))
            }
            let afterStop = MemorySampler.capture()

            cycleResults.append(
                buildCycleMetrics(
                    cycle: cycleIndex,
                    framesProcessed: config.frames,
                    coldModelLoadMs: cycleIndex == 1 ? coldModelLoadMs : nil,
                    warmModelLoadMs: cycleIndex == 1 ? warmModelLoadMs : nil,
                    startToFirstFrameMs: startToFirstFrameMs,
                    totalScanDurationMs: totalScanDurationMs,
                    dropped: dropped,
                    beforeStart: beforeStart,
                    afterStop: afterStop,
                    accumulator: accumulator
                )
            )
        }

        let metadata = SystemProbe.collectMetadata(
            config: config,
            cameraName: cameraName,
            inputResolution: observedResolution,
            embedder: primaryEmbedder
        )
        return BenchmarkReport(
            metadata: metadata,
            processIdleBeforeModel: idleBeforeModel,
            cycles: cycleResults
        )
    }

    private static func verifyLiveCameraAuthorization() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            throw BenchmarkError.cameraUnavailable(
                "Camera permission status is \(status.rawValue) (denied/restricted). "
                    + "Grant camera access or run with --synthetic."
            )
        case .notDetermined:
            let hasUsageDesc = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
            guard hasUsageDesc else {
                throw BenchmarkError.cameraUnavailable(
                    "Camera authorization is notDetermined and this CLI binary lacks NSCameraUsageDescription "
                        + "in its Info.plist (requesting access would abort via TCC). "
                        + "Run inside an app bundle / TCC-granted terminal, or use --synthetic."
                )
            }
            let granted = await requestCameraAccessWithTimeout(seconds: 5)
            guard let granted else {
                throw BenchmarkError.cameraUnavailable(
                    "Camera permission prompt timed out after 5s in headless environment (notDetermined)."
                )
            }
            guard granted else {
                throw BenchmarkError.cameraUnavailable("Camera permission request was denied by user.")
            }
        @unknown default:
            throw BenchmarkError.cameraUnavailable("Unknown camera authorization status (\(status.rawValue)).")
        }
    }

    private static func requestCameraAccessWithTimeout(seconds: Int) async -> Bool? {
        await withCheckedContinuation { continuation in
            let state = OSAllocatedUnfairLock<CheckedContinuation<Bool?, Never>?>(initialState: continuation)
            @Sendable func finish(_ result: Bool?) {
                let pending = state.withLock { slot -> CheckedContinuation<Bool?, Never>? in
                    let cont = slot
                    slot = nil
                    return cont
                }
                pending?.resume(returning: result)
            }
            Task.detached {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                finish(granted)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                finish(nil)
            }
        }
    }

    private static func makeLivenessAnalyzer(for option: LivenessOption) -> LivenessAnalyzer? {
        guard let mode = option.livenessMode else { return nil }
        let analyzer = LivenessAnalyzer()
        analyzer.modeProvider = { mode }
        analyzer.keepsComputingConfirmCuesAfterConfirmation = (mode == .heavy)
        return analyzer
    }

    private static func runBackpressuredExtraction(
        evaluator: FaceAuthEvaluator,
        target: any FrameBackpressureTarget,
        frame: CameraFrame,
        pipeline: FaceRecognitionPipeline,
        previousBox: CGRect?,
        livenessEnabled: Bool,
        nightBoostEnabled: Bool,
        geometryContext: LivenessAnalyzer.GeometryEvaluationContext?
    ) async -> ExtractedFrameResult {
        let stageBox = OSAllocatedUnfairLock<ExtractedFrameResult?>(initialState: nil)
        _ = await evaluator.extractFrameWithBackpressure(
            camera: target,
            isCurrentGeneration: { true },
            extract: {
                let staged = await StageRunner.extractStages(
                    from: frame,
                    pipeline: pipeline,
                    previousBoundingBox: previousBox,
                    livenessEnabled: livenessEnabled,
                    nightBoostEnabled: nightBoostEnabled,
                    geometryContext: geometryContext
                )
                stageBox.withLock { $0 = staged }
                return ExtractedAuthFrame(
                    luminance: nil,
                    recognition: staged.recognition,
                    livenessFrame: staged.livenessFrame,
                    precomputedGeometry: staged.precomputedGeometry,
                    geometryGeneration: staged.geometryGeneration
                )
            }
        )
        return stageBox.withLock { $0 }
            ?? ExtractedFrameResult(
                recognition: nil,
                livenessFrame: nil,
                precomputedGeometry: nil,
                geometryGeneration: nil,
                nightBoostEnhanced: false,
                recognitionMs: 0,
                livenessMs: 0
            )
    }

    private static func startMemorySampler(updating accumulator: CycleAccumulator) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                accumulator.recordMemoryPeak()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func buildCycleMetrics(
        cycle: Int,
        framesProcessed: Int,
        coldModelLoadMs: Double?,
        warmModelLoadMs: Double?,
        startToFirstFrameMs: Double,
        totalScanDurationMs: Double,
        dropped: DroppedFramesSummary,
        beforeStart: MemorySnapshot,
        afterStop: MemorySnapshot,
        accumulator: CycleAccumulator
    ) -> CycleMetrics {
        CycleMetrics(
            cycle: cycle,
            framesProcessed: framesProcessed,
            facesDetected: accumulator.facesDetected,
            fivePointAlignments: accumulator.fivePointAlignments,
            nightBoostEnhancedFrames: accumulator.nightBoostEnhancedFrames,
            coldModelLoadMs: coldModelLoadMs,
            warmModelLoadMs: warmModelLoadMs,
            startToFirstFrameMs: startToFirstFrameMs,
            totalScanDurationMs: totalScanDurationMs,
            totalPerFrame: DistributionStats.summarize(accumulator.totalFrameSamples),
            workingRender640: DistributionStats.summarize(accumulator.workingRenderSamples),
            recognition: DistributionStats.summarize(accumulator.recognitionSamples),
            livenessExtraction: DistributionStats.summarize(accumulator.livenessSamples),
            mainThread: DistributionStats.summarize(accumulator.mainThreadSamples),
            droppedFrames: dropped,
            memory: MemoryCheckpoints(
                beforeStart: beforeStart,
                peakDuringScan: accumulator.peakMemory,
                afterStopAndSettle: afterStop
            )
        )
    }

    private static func describeActiveFormat(of device: AVCaptureDevice?) -> String {
        guard let device else { return "unknown" }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return "\(dims.width)x\(dims.height)"
    }

    private static func maxActiveFrameRate(of device: AVCaptureDevice?) -> Double? {
        device?.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max()
    }
}

nonisolated enum ReportFormatter {
    static func encodeJSON(_ report: BenchmarkReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    static func formatMarkdown(_ report: BenchmarkReport) -> String {
        let m = report.metadata
        var lines: [String] = []
        lines.append("## Glance Pipeline Benchmark")
        lines.append("")
        lines.append("- **Timestamp:** \(m.timestampISO8601)")
        lines.append("- **Mode:** \(m.mode.rawValue)")
        lines.append("- **Xcode / Swift:** \(m.xcodeVersion) | \(m.swiftVersion)")
        lines.append("- **macOS / Arch / Model:** macOS \(m.macOSVersion) | \(m.architecture) | \(m.hardwareModel)")
        lines.append("- **Camera / Resolution:** \(m.cameraName) (\(m.inputResolution))")
        lines.append(
            "- **Config:** liveness=\(m.livenessMode.rawValue), nightBoost=\(m.nightBoost ? "on" : "off"), "
                + "frames=\(m.framesPerCycle), cycles=\(m.cycles), settle=\(fmt(m.settleSeconds, 1))s")
        lines.append(
            "- **Model:** \(m.modelName) (`\(m.modelIdentifier)`), compute=\(m.computeUnits), "
                + "realCoreML=\(m.usingRealArcFaceModel)")
        lines.append(
            "- **Process Idle (pre-model):** phys=\(fmt(report.processIdleBeforeModel.physFootprintMB)) MB, "
                + "rss=\(fmt(report.processIdleBeforeModel.residentSizeMB)) MB"
        )
        lines.append("")
        lines.append(
            "| Cycle | Faces/5pt | Cold/Warm Load (ms) | Start->First (ms) | Total Med/P95 (ms) | "
                + "640px Render Med/P95 (ms) | Recognition Med/P95 (ms) | Liveness Med/P95 (ms) | "
                + "MainThread Med/P95 (ms) | Dropped (busy/coal) | Mem Before/Peak/After phys (MB) | "
                + "Mem Before/Peak/After rss (MB) |"
        )
        lines.append(
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        )
        for cycle in report.cycles {
            let facesCell = "\(cycle.facesDetected)/\(cycle.fivePointAlignments)"
            let loadCell =
                cycle.coldModelLoadMs.map { "\(fmt($0)) / \(fmt(cycle.warmModelLoadMs ?? 0))" } ?? "-"
            let dropped =
                "\(cycle.droppedFrames.totalDropped) "
                + "(\(cycle.droppedFrames.busySkipped)/\(cycle.droppedFrames.coalesced))"
            let physMem =
                "\(fmt(cycle.memory.beforeStart.physFootprintMB)) / "
                + "\(fmt(cycle.memory.peakDuringScan.physFootprintMB)) / "
                + "\(fmt(cycle.memory.afterStopAndSettle.physFootprintMB))"
            let rssMem =
                "\(fmt(cycle.memory.beforeStart.residentSizeMB)) / "
                + "\(fmt(cycle.memory.peakDuringScan.residentSizeMB)) / "
                + "\(fmt(cycle.memory.afterStopAndSettle.residentSizeMB))"
            lines.append(
                "| Run \(cycle.cycle) | \(facesCell) | \(loadCell) | \(fmt(cycle.startToFirstFrameMs)) | "
                    + "\(medP95(cycle.totalPerFrame)) | \(medP95(cycle.workingRender640)) | "
                    + "\(medP95(cycle.recognition)) | \(medP95(cycle.livenessExtraction)) | "
                    + "\(medP95(cycle.mainThread)) | \(dropped) | \(physMem) | \(rssMem) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func medP95(_ stats: DistributionStats) -> String {
        "\(fmt(stats.medianMs)) / \(fmt(stats.p95Ms))"
    }

    private static func fmt(_ value: Double, _ places: Int = 2) -> String {
        String(format: "%.\(places)f", value)
    }
}

@main
struct PipelineBenchmarkCLI {
    static func main() async {
        do {
            let config = try BenchmarkConfig.parse(arguments: CommandLine.arguments)
            if let stagedExitCode = try ModelBundleStaging.runStagedIfNeeded(config: config) {
                exit(stagedExitCode)
            }

            let report = try await PipelineBenchmarkRunner.run(config: config)
            let json = try ReportFormatter.encodeJSON(report)

            if let jsonOutPath = config.jsonOutPath {
                let outURL = URL(fileURLWithPath: jsonOutPath)
                let parent = outURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try json.write(to: outURL, atomically: true, encoding: .utf8)
            }

            switch config.format {
            case .markdown:
                print(ReportFormatter.formatMarkdown(report))
            case .json:
                print(json)
            case .both:
                print(ReportFormatter.formatMarkdown(report))
                print("\n```json\n\(json)\n```")
            }
        } catch BenchmarkError.helpRequested {
            print(BenchmarkConfig.usageText)
            exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            if case BenchmarkError.invalidArgument = error {
                fputs("\n\(BenchmarkConfig.usageText)\n", stderr)
            }
            exit(1)
        }
    }
}
