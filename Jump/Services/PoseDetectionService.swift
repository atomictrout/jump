import Vision
import AVFoundation

/// Thread-safe collector for poses during video processing
private class PoseCollector {
    var poses: [BodyPose] = []

    init(capacity: Int) {
        poses.reserveCapacity(capacity)
    }

    func append(_ pose: BodyPose) {
        poses.append(pose)
    }
}

struct PoseDetectionService {

    static let minimumConfidence: Float = 0.1

    /// Detect pose in a single CVPixelBuffer frame
    static func detectPose(
        in pixelBuffer: CVPixelBuffer,
        frameIndex: Int,
        timestamp: Double
    ) throws -> BodyPose {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        try handler.perform([request])

        guard let observation = request.results?.first else {
            return .empty(frameIndex: frameIndex, timestamp: timestamp)
        }

        return bodyPose(from: observation, frameIndex: frameIndex, timestamp: timestamp)
    }

    /// Detect pose in a CGImage
    static func detectPose(
        in cgImage: CGImage,
        frameIndex: Int,
        timestamp: Double
    ) throws -> BodyPose {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]
        )

        try handler.perform([request])

        guard let observation = request.results?.first else {
            return .empty(frameIndex: frameIndex, timestamp: timestamp)
        }

        return bodyPose(from: observation, frameIndex: frameIndex, timestamp: timestamp)
    }

    /// Process all frames in a video
    static func processVideo(
        url: URL,
        session: JumpSession,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [BodyPose] {
        // Use an actor-isolated container to safely collect poses from the streaming callback
        let collector = PoseCollector(capacity: session.totalFrames)

        try await VideoFrameExtractor.streamFrames(
            from: url,
            onFrame: { frameIndex, pixelBuffer, timestamp in
                let pose = try detectPose(
                    in: pixelBuffer,
                    frameIndex: frameIndex,
                    timestamp: timestamp
                )
                collector.append(pose)
            },
            onProgress: onProgress
        )

        return collector.poses
    }

    // MARK: - Private

    private static func bodyPose(
        from observation: VNHumanBodyPoseObservation,
        frameIndex: Int,
        timestamp: Double
    ) -> BodyPose {
        var joints: [BodyPose.JointName: BodyPose.JointPosition] = [:]

        let mapping: [(VNHumanBodyPoseObservation.JointName, BodyPose.JointName)] = [
            (.nose, .nose),
            (.neck, .neck),
            (.leftShoulder, .leftShoulder),
            (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow),
            (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist),
            (.rightWrist, .rightWrist),
            (.leftHip, .leftHip),
            (.rightHip, .rightHip),
            (.leftKnee, .leftKnee),
            (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle),
            (.rightAnkle, .rightAnkle),
            (.leftEye, .leftEye),
            (.rightEye, .rightEye),
            (.leftEar, .leftEar),
            (.rightEar, .rightEar),
            (.root, .root),
        ]

        for (vnJoint, ourJoint) in mapping {
            if let point = try? observation.recognizedPoint(vnJoint),
               point.confidence > minimumConfidence {
                joints[ourJoint] = BodyPose.JointPosition(
                    point: point.location,
                    confidence: point.confidence
                )
            }
        }

        return BodyPose(
            frameIndex: frameIndex,
            timestamp: timestamp,
            joints: joints
        )
    }
}
