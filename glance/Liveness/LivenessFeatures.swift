//
//  LivenessFeatures.swift
//  glance
//
//  Vision-facing half of liveness: turns a `FaceRecognitionResult` into a plain,
//  Vision-free `LivenessFrame` — keeps the decision logic compilable standalone.
//

import CoreGraphics
import Foundation

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
        let leftEAR = landmarks.regions[.leftEye].flatMap {
            LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: landmarkImageSize, mappedTo: mappingRect)
        }
        let rightEAR = landmarks.regions[.rightEye].flatMap {
            LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: landmarkImageSize, mappedTo: mappingRect)
        }
        let noseOffsetRatio = noseOffsetRatio(
            from: landmarks, imageSize: landmarkImageSize, mappedTo: mappingRect
        )

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

    private static func noseOffsetRatio(
        from landmarks: DetectedFaceLandmarks,
        imageSize: CGSize,
        mappedTo mappingRect: CGRect?
    ) -> CGFloat? {
        guard
            let eyeLeft = LandmarkGeometry.eyeCenter(
                pupil: landmarks.leftPupil, eye: landmarks.regions[.leftEye],
                imageSize: imageSize, mappedTo: mappingRect),
            let eyeRight = LandmarkGeometry.eyeCenter(
                pupil: landmarks.rightPupil, eye: landmarks.regions[.rightEye],
                imageSize: imageSize, mappedTo: mappingRect),
            let nose = landmarks.regions[.nose],
            let noseCenter = LandmarkGeometry.centroid(of: nose, imageSize: imageSize, mappedTo: mappingRect)
        else { return nil }
        return LandmarkGeometry.eyeAlignedNoseOffsetRatio(eyeA: eyeLeft, eyeB: eyeRight, noseCenter: noseCenter)
    }

    private static func extractGlare(
        faceCrop: CGImage,
        landmarkFace: DetectedFace,
        workingFace: DetectedFace,
        mappingRect: CGRect?
    ) -> GlareSample? {
        let faceRegion = landmarkFace.landmarks.flatMap { landmarks -> [CGPoint]? in
            let points = LandmarkGeometry.points(
                for: .faceContour,
                in: landmarks,
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
