//
//  FaceDetector.swift
//  glance
//
//  Converts Vision's normalized (0...1), bottom-left-origin face boxes into pixel-space, top-left-origin `CGRect`s.
//

import CoreGraphics
import Vision

nonisolated struct DetectedFace: Sendable, Equatable {
    /// Pixel-space bounding box, top-left origin — ready to crop with.
    let boundingBox: CGRect
    /// Vision's original normalized box — kept as-is since it's the exact format `layerRectConverted(fromMetadataOutputRect:)` expects.
    let normalizedBoundingBox: CGRect
    /// 0...1 confidence from Vision that this is a face, roughly indicating
    /// image quality/pose suitability for recognition. `nil` if the quality
    /// request didn't produce a result for this face.
    let quality: Float?
    /// Head rotation in radians, when Vision could estimate it. Yaw drives the guided-pose onboarding capture;
    /// roll and pitch are exposed but unused today.
    let yaw: Float?
    let roll: Float?
    let pitch: Float?
    /// Facial landmarks (eyes, nose, mouth, etc.) in top-left/y-down pixel space, when available.
    /// Feeds `FaceAligner` for canonical 112x112 alignment ahead of ArcFace and liveness geometry extraction.
    let landmarks: DetectedFaceLandmarks?
    /// Pixel dimensions of the frame in which `boundingBox` and `landmarks` were detected.
    let imageSize: CGSize

    func withQuality(_ quality: Float?) -> DetectedFace {
        DetectedFace(
            boundingBox: boundingBox,
            normalizedBoundingBox: normalizedBoundingBox,
            quality: quality,
            yaw: yaw,
            roll: roll,
            pitch: pitch,
            landmarks: landmarks,
            imageSize: imageSize
        )
    }
}

/// Pure, synchronous, CPU-bound work — `nonisolated` so it can run on a
/// background task despite the project's default main-actor isolation.
nonisolated enum FaceDetector {
    /// Runs face-rectangle, and optionally landmarks and capture-quality detection on a single frame.
    /// Skipping quality (`includeQuality: false`) omits `VNDetectFaceCaptureQualityRequest` without
    /// altering face boxes or landmarks, so embeddings stay bit-for-bit identical.
    /// Skipping both quality and landmarks (`includeQuality: false, includeLandmarks: false`)
    /// runs only `VNDetectFaceRectanglesRequest` in a single Vision pass.
    static func detectFaces(
        in image: CGImage,
        includeQuality: Bool = true,
        includeLandmarks: Bool = true
    ) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([rectanglesRequest])
        let faceObservations = rectanglesRequest.results ?? []
        guard !faceObservations.isEmpty else { return [] }

        var qualityResults: [VNFaceObservation] = []
        var landmarkResults: [VNFaceObservation] = []
        if includeQuality || includeLandmarks {
            // Chained to the rectangles results (via `inputFaceObservations`) rather than run independently, so results
            // correspond 1:1 in order — avoids the fragility of matching back via boundingBox float equality.
            var requests: [VNRequest] = []
            var qualityRequest: VNDetectFaceCaptureQualityRequest?
            var landmarksRequest: VNDetectFaceLandmarksRequest?
            if includeQuality {
                let request = VNDetectFaceCaptureQualityRequest()
                request.inputFaceObservations = faceObservations
                requests.append(request)
                qualityRequest = request
            }
            if includeLandmarks {
                let request = VNDetectFaceLandmarksRequest()
                request.inputFaceObservations = faceObservations
                requests.append(request)
                landmarksRequest = request
            }
            try handler.perform(requests)
            qualityResults = qualityRequest?.results ?? []
            landmarkResults = landmarksRequest?.results ?? []
        }

        let imageSize = CGSize(width: image.width, height: image.height)

        return faceObservations.enumerated().map { index, observation in
            let pixelRect = convertToImageSpace(observation.boundingBox, imageSize: imageSize)
            let vnLandmarks = landmarkResults.indices.contains(index) ? landmarkResults[index].landmarks : nil
            return DetectedFace(
                boundingBox: pixelRect,
                normalizedBoundingBox: observation.boundingBox,
                quality: qualityResults.indices.contains(index) ? qualityResults[index].faceCaptureQuality : nil,
                yaw: observation.yaw?.floatValue,
                roll: observation.roll?.floatValue,
                pitch: observation.pitch?.floatValue,
                landmarks: vnLandmarks.map { DetectedFaceLandmarks(from: $0, imageSize: imageSize) },
                imageSize: imageSize
            )
        }
    }

    /// Vision's normalized rect has origin at bottom-left; `CGImage.cropping`
    /// expects pixel coordinates with origin at top-left. This flips the Y axis.
    static func convertToImageSpace(_ normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let x = normalizedRect.origin.x * imageSize.width
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let y = (1 - normalizedRect.origin.y) * imageSize.height - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Crops `face` out of `image`, padding slightly around the detected box
    /// so the embedder sees a bit of context beyond just eyes/nose/mouth.
    static func crop(_ face: DetectedFace, from image: CGImage, paddingFraction: CGFloat = 0.2) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let padX = face.boundingBox.width * paddingFraction
        let padY = face.boundingBox.height * paddingFraction
        let padded = face.boundingBox.insetBy(dx: -padX, dy: -padY).intersection(imageBounds)
        guard !padded.isEmpty else { return nil }
        return image.cropping(to: padded)
    }
}

extension DetectedFaceLandmarks {
    /// Converts Vision's bottom-left/y-up landmark regions once into top-left/y-down pixel space.
    fileprivate nonisolated init(from vnLandmarks: VNFaceLandmarks2D, imageSize: CGSize) {
        func extract(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: imageSize).map {
                CGPoint(x: $0.x, y: imageSize.height - $0.y)
            }
        }

        let regionPairs: [(LandmarkRegion, VNFaceLandmarkRegion2D?)] = [
            (.leftEye, vnLandmarks.leftEye),
            (.rightEye, vnLandmarks.rightEye),
            (.leftEyebrow, vnLandmarks.leftEyebrow),
            (.rightEyebrow, vnLandmarks.rightEyebrow),
            (.nose, vnLandmarks.nose),
            (.noseCrest, vnLandmarks.noseCrest),
            (.outerLips, vnLandmarks.outerLips),
            (.innerLips, vnLandmarks.innerLips),
            (.faceContour, vnLandmarks.faceContour),
            (.medianLine, vnLandmarks.medianLine)
        ]

        var extractedRegions: [LandmarkRegion: [CGPoint]] = [:]
        for (regionCase, vnRegion) in regionPairs {
            let points = extract(vnRegion)
            if !points.isEmpty {
                extractedRegions[regionCase] = points
            }
        }

        self.init(
            regions: extractedRegions,
            leftPupil: extract(vnLandmarks.leftPupil),
            rightPupil: extract(vnLandmarks.rightPupil)
        )
    }
}
