//
//  LivenessFeatures.swift
//  glance
//
//  Vision-facing half of liveness: turns a `FaceRecognitionResult` into a plain,
//  Vision-free `LivenessFrame` — keeps the decision logic compilable standalone.
//

import CoreGraphics
import Vision

nonisolated enum LivenessFeatureExtractor {
    /// Never fails — a face with no landmarks still yields a frame; cues that need landmarks abstain.
    ///
    /// - Parameter frame: the full camera frame, not `result.alignedImage` (a tightly-cropped
    ///   112x112 warp with no room around the face for `DeviceBezelDetector` to see a device edge).
    static func extract(
        from result: FaceRecognitionResult, frame: CGImage, faceCrop: CGImage? = nil, timestamp: Date = Date()
    ) -> LivenessFrame {
        let workingFace = result.face
        let useNativeCropLandmarks =
            result.nativeCropFace?.landmarks != nil && result.nativeCropWorkingRect != nil
        let landmarkFace = useNativeCropLandmarks ? result.nativeCropFace! : workingFace
        let mappingRect = useNativeCropLandmarks ? result.nativeCropWorkingRect : nil
        let landmarkImageSize = landmarkFace.imageSize
        let yaw = workingFace.yaw ?? result.nativeCropFace?.yaw

        let deviceOverlap = DeviceBezelDetector.detect(in: frame, faceBoundingBox: workingFace.boundingBox)
            .faceOverlapFraction
        let glare = faceCrop.flatMap {
            extractGlare(
                faceCrop: $0,
                landmarkFace: landmarkFace,
                workingFace: workingFace,
                mappingRect: mappingRect
            )
        }

        guard let landmarks = landmarkFace.landmarks else {
            return LivenessFrame(
                timestamp: timestamp, landmarks: [], interocularDistance: nil,
                yaw: yaw,
                leftEyeAspectRatio: nil, rightEyeAspectRatio: nil,
                noseOffsetRatio: nil,
                hasReliableLandmarks: false,
                deviceOverlapFraction: deviceOverlap,
                glare: glare
            )
        }

        let points = LandmarkGeometry.allPoints(
            from: landmarks, imageSize: landmarkImageSize, mappedTo: mappingRect
        )
        let interocular = LandmarkGeometry.interocularDistance(
            from: landmarks, imageSize: landmarkImageSize, mappedTo: mappingRect
        )
        let leftEAR = landmarks.leftEye.flatMap {
            LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: landmarkImageSize, mappedTo: mappingRect)
        }
        let rightEAR = landmarks.rightEye.flatMap {
            LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: landmarkImageSize, mappedTo: mappingRect)
        }

        let eyeLeft = LandmarkGeometry.eyeCenter(
            pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: landmarkImageSize, mappedTo: mappingRect)
        let eyeRight = LandmarkGeometry.eyeCenter(
            pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: landmarkImageSize, mappedTo: mappingRect)

        var noseOffsetRatio: CGFloat?
        if let eyeLeft, let eyeRight,
            let nose = landmarks.nose,
            let noseCenter = LandmarkGeometry.centroid(
                of: nose, imageSize: landmarkImageSize, mappedTo: mappingRect)
        {
            noseOffsetRatio = LandmarkGeometry.eyeAlignedNoseOffsetRatio(
                eyeA: eyeLeft, eyeB: eyeRight, noseCenter: noseCenter
            )
        }

        return LivenessFrame(
            timestamp: timestamp,
            landmarks: points,
            interocularDistance: interocular,
            yaw: yaw,
            leftEyeAspectRatio: leftEAR, rightEyeAspectRatio: rightEAR,
            noseOffsetRatio: noseOffsetRatio,
            hasReliableLandmarks: result.alignmentTier == .fivePoint,
            deviceOverlapFraction: deviceOverlap,
            glare: glare
        )
    }

    private static func extractGlare(
        faceCrop: CGImage,
        landmarkFace: DetectedFace,
        workingFace: DetectedFace,
        mappingRect: CGRect?
    ) -> GlareSample? {
        let faceRegion = landmarkFace.landmarks?.faceContour.flatMap { contour in
            let points = LandmarkGeometry.imagePoints(
                of: contour,
                imageSize: landmarkFace.imageSize,
                mappedTo: mappingRect
            )
            return GlareFaceRegion.polygon(
                contour: points,
                faceBounds: workingFace.boundingBox,
                imageSize: workingFace.imageSize
            )
        }
        return GlareCueExtractor.extract(faceCrop: faceCrop, faceRegion: faceRegion)
    }
}
