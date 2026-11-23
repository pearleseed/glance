//
//  ArcFaceEmbedder.swift
//  glance
//
//  Requires a canonically-aligned 112x112 input (see FaceAligner) — unlike VisionFeaturePrintEmbedder, accuracy depends on alignment.
//

import CoreGraphics
import CoreML
import CoreVideo

enum ArcFaceEmbedderError: LocalizedError {
    case modelNotFound
    case modelLoadFailed(String)
    case pixelBufferCreationFailed
    case unexpectedInputSize(got: (Int, Int), expected: Int)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return
                "ArcFace.mlpackage/mlmodelc not found in the app bundle. Run tools/convert_arcface.py, "
                + "then add glance/Models/ArcFace.mlpackage to the Xcode project."
        case .modelLoadFailed(let detail):
            return "Failed to load the ArcFace Core ML model: \(detail)"
        case .pixelBufferCreationFailed:
            return "Couldn't prepare the aligned face image for Core ML."
        case .unexpectedInputSize(let got, let expected):
            return
                "ArcFaceEmbedder expects a \(expected)x\(expected) aligned image, got \(got.0)x\(got.1). Run the face through FaceAligner first."
        case .unexpectedOutput(let detail):
            return "ArcFace model produced an unexpected output: \(detail)"
        }
    }
}

nonisolated final class ArcFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    nonisolated let name = "ArcFace (w600k_mbf)"
    nonisolated let modelIdentifier = "arcface-w600k_mbf-v1"
    nonisolated let embeddingDimension = 512
    nonisolated let requiresAlignment = true
    nonisolated let isUnlockCapable = true

    private static let inputSize = FaceAligner.outputSize
    private static let inputName = "input_image"
    private static let outputName = "embedding"
    private static let deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

    // Loaded once and reused — model load dominates a single inference.
    private let model: MLModel
    private let pixelBufferPool: CVPixelBufferPool

    /// Throws immediately if the model isn't bundled, so callers can fall back to `VisionFeaturePrintEmbedder`.
    init() throws {
        guard let modelURL = Self.locateModel() else {
            throw ArcFaceEmbedderError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ArcFaceEmbedderError.modelLoadFailed(error.localizedDescription)
        }

        guard let pool = Self.makePixelBufferPool(size: Self.inputSize) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        pixelBufferPool = pool
    }

    /// Both names are checked in case the file was added under a different name.
    private static func locateModel() -> URL? {
        for name in ["ArcFace", "w600k_mbf"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                return url
            }
        }
        return nil
    }

    private static func makePixelBufferPool(size: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// `MLModel.prediction(from:)` is synchronous/blocking — callers run embedders off the main actor.
    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        guard face.width == Self.inputSize, face.height == Self.inputSize else {
            throw ArcFaceEmbedderError.unexpectedInputSize(got: (face.width, face.height), expected: Self.inputSize)
        }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        try Self.render(face, into: pixelBuffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw ArcFaceEmbedderError.unexpectedOutput("no '\(Self.outputName)' output found")
        }
        guard multiArray.count == embeddingDimension else {
            throw ArcFaceEmbedderError.unexpectedOutput(
                "expected \(embeddingDimension) floats, got \(multiArray.count)")
        }

        let raw = Self.floatVector(from: multiArray)
        return FaceEmbedding.l2Normalized(raw)
    }

    private static func render(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: deviceRGBColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Uses a direct buffer copy for contiguous Float32 storage (avoiding 512 NSNumber boxings per inference),
    /// falling back to `MLMultiArray` subscripting when storage is non-contiguous or uses another numeric type.
    private static func floatVector(from array: MLMultiArray) -> [Float] {
        let count = array.count
        guard count > 0 else { return [] }
        if array.dataType == .float32, isContiguous(array) {
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            result[index] = array[index].floatValue
        }
        return result
    }

    private static func isContiguous(_ array: MLMultiArray) -> Bool {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count == strides.count, !shape.isEmpty else { return false }
        var expectedStride = 1
        for dim in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[dim] > 1 && strides[dim] != expectedStride {
                return false
            }
            expectedStride *= max(shape[dim], 1)
        }
        return true
    }
}
