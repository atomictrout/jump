import Vision
import AVFoundation
import Foundation

/// Thread-safe collector for poses during video processing.
/// Uses NSLock for safe access from background threads.
private class PoseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _poses: [BodyPose] = []

    var poses: [BodyPose] {
        lock.withLock { _poses }
    }

    init(capacity: Int) {
        _poses.reserveCapacity(capacity)
    }

    func append(_ pose: BodyPose) {
        lock.withLock { _poses.append(pose) }
    }
}

/// Raw observations for a single video frame.
struct FrameObservations: Sendable {
    let frameIndex: Int
    let timestamp: Double
    let observations: [VNHumanBodyPoseObservation]
}

/// Thread-safe collector for raw observations per frame.
private class ObservationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [FrameObservations] = []

    var frames: [FrameObservations] {
        lock.withLock { _frames }
    }

    init(capacity: Int) {
        _frames.reserveCapacity(capacity)
    }

    func append(_ frame: FrameObservations) {
        lock.withLock { _frames.append(frame) }
    }
}

struct PoseDetectionService {

    static let minimumConfidence: Float = 0.1

    /// Check if pose detection is available (not available on some simulators)
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        // Vision pose detection may crash on simulator due to missing model weights
        // Check by attempting a minimal detection
        return _simulatorPoseAvailable
        #else
        return true
        #endif
    }

    #if targetEnvironment(simulator)
    private static let _simulatorPoseAvailable: Bool = {
        // Test with a tiny 1x1 pixel buffer to see if the model loads
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: 1,
            kCVPixelBufferHeightKey as String: 1,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return false }

        do {
            let request = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
            try handler.perform([request])
            return true
        } catch {
            print("Pose detection not available on this simulator: \(error)")
            return false
        }
    }()
    #endif

    // MARK: - Single Person Detection (legacy)

    /// Detect pose in a single CVPixelBuffer frame (returns first person only)
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

        do {
            try handler.perform([request])
        } catch {
            print("Pose detection failed for frame \(frameIndex): \(error.localizedDescription)")
            return .empty(frameIndex: frameIndex, timestamp: timestamp)
        }

        guard let observation = request.results?.first else {
            return .empty(frameIndex: frameIndex, timestamp: timestamp)
        }

        return bodyPose(from: observation, frameIndex: frameIndex, timestamp: timestamp)
    }

    // MARK: - Multi-Person Detection

    /// Detect ALL people in a single frame, returning raw observations
    static func detectAllPoses(
        in pixelBuffer: CVPixelBuffer,
        frameIndex: Int
    ) throws -> [VNHumanBodyPoseObservation] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            print("Pose detection failed for frame \(frameIndex): \(error.localizedDescription)")
            return []
        }

        return request.results ?? []
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

        do {
            try handler.perform([request])
        } catch {
            print("Pose detection failed for frame \(frameIndex): \(error.localizedDescription)")
            return .empty(frameIndex: frameIndex, timestamp: timestamp)
        }

        guard let observation = request.results?.first else {
            return .empty(frameIndex: frameIndex, timestamp: timestamp)
        }

        return bodyPose(from: observation, frameIndex: frameIndex, timestamp: timestamp)
    }

    // MARK: - Video Processing

    /// Process all frames in a video (legacy — no person tracking)
    static func processVideo(
        url: URL,
        session: JumpSession,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [BodyPose] {
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

    /// Process all frames with person tracking — selects the same athlete across frames
    static func processVideoWithTracking(
        url: URL,
        session: JumpSession,
        tracker: PersonTracker,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [BodyPose] {
        let collector = PoseCollector(capacity: session.totalFrames)

        try await VideoFrameExtractor.streamFrames(
            from: url,
            onFrame: { frameIndex, pixelBuffer, timestamp in
                let observations = try detectAllPoses(in: pixelBuffer, frameIndex: frameIndex)

                if let selected = tracker.selectBest(from: observations, frameIndex: frameIndex) {
                    let pose = bodyPose(from: selected, frameIndex: frameIndex, timestamp: timestamp)
                    collector.append(pose)
                } else {
                    collector.append(.empty(frameIndex: frameIndex, timestamp: timestamp))
                }
            },
            onProgress: onProgress
        )

        return collector.poses
    }

    // MARK: - Collect All Observations (for bidirectional re-tracking)

    /// Process all frames and collect raw observations per frame.
    /// This is used for the initial pass — observations are stored so the user
    /// can later select a person and re-track bidirectionally without re-reading the video.
    static func collectAllObservations(
        url: URL,
        session: JumpSession,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [FrameObservations] {
        let collector = ObservationCollector(capacity: session.totalFrames)

        try await VideoFrameExtractor.streamFrames(
            from: url,
            onFrame: { frameIndex, pixelBuffer, timestamp in
                let observations = try detectAllPoses(in: pixelBuffer, frameIndex: frameIndex)
                collector.append(FrameObservations(
                    frameIndex: frameIndex,
                    timestamp: timestamp,
                    observations: observations
                ))
            },
            onProgress: onProgress
        )

        return collector.frames
    }

    /// Re-track from stored observations bidirectionally from a selected frame.
    /// Tracks forward from `startFrame` to end, then backward from `startFrame` to beginning,
    /// stitching results so the selected person is consistently tracked throughout.
    static func retrackBidirectional(
        allFrameObservations: [FrameObservations],
        selectionPoint: CGPoint,
        selectionFrameIndex: Int
    ) -> [BodyPose] {
        let totalFrames = allFrameObservations.count
        guard totalFrames > 0 else { return [] }

        // Create result array
        var poses = [BodyPose](repeating: .empty(frameIndex: 0, timestamp: 0), count: totalFrames)

        // Forward tracker: from selection frame to end
        let forwardTracker = PersonTracker()
        forwardTracker.setManualOverride(point: selectionPoint)

        for i in selectionFrameIndex..<totalFrames {
            let frame = allFrameObservations[i]
            if let selected = forwardTracker.selectBest(from: frame.observations, frameIndex: frame.frameIndex) {
                poses[i] = bodyPose(from: selected, frameIndex: frame.frameIndex, timestamp: frame.timestamp)
            } else {
                poses[i] = .empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp)
            }
        }

        // Backward tracker: from selection frame backward to start
        let backwardTracker = PersonTracker()
        backwardTracker.setManualOverride(point: selectionPoint)

        for i in stride(from: selectionFrameIndex, through: 0, by: -1) {
            let frame = allFrameObservations[i]
            if let selected = backwardTracker.selectBest(from: frame.observations, frameIndex: frame.frameIndex) {
                poses[i] = bodyPose(from: selected, frameIndex: frame.frameIndex, timestamp: frame.timestamp)
            } else {
                poses[i] = .empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp)
            }
        }

        return poses
    }

    /// Re-track using multiple user annotations.
    /// Each annotation is a (frameIndex, visionPoint) pair where the user identified the athlete.
    /// The video is segmented: between annotations, tracking propagates from the nearest annotation.
    /// This gives much better results when a single bidirectional pass loses the person.
    static func retrackWithMultipleAnnotations(
        allFrameObservations: [FrameObservations],
        annotations: [(frame: Int, point: CGPoint)]
    ) -> [BodyPose] {
        let totalFrames = allFrameObservations.count
        guard totalFrames > 0, !annotations.isEmpty else { return [] }

        var poses = [BodyPose](repeating: .empty(frameIndex: 0, timestamp: 0), count: totalFrames)

        // Sort annotations by frame
        let sorted = annotations.sorted { $0.frame < $1.frame }

        // For each annotation, track forward to the midpoint to the next annotation (or end),
        // and backward to the midpoint to the previous annotation (or start).
        for (idx, ann) in sorted.enumerated() {
            let selFrame = min(ann.frame, totalFrames - 1)

            // Determine backward boundary
            let backwardBound: Int
            if idx > 0 {
                backwardBound = (sorted[idx - 1].frame + selFrame) / 2
            } else {
                backwardBound = 0
            }

            // Determine forward boundary
            let forwardBound: Int
            if idx < sorted.count - 1 {
                forwardBound = (selFrame + sorted[idx + 1].frame) / 2
            } else {
                forwardBound = totalFrames - 1
            }

            // Track forward from this annotation
            let forwardTracker = PersonTracker()
            forwardTracker.setManualOverride(point: ann.point)

            for i in selFrame...forwardBound {
                let frame = allFrameObservations[i]
                if let selected = forwardTracker.selectBest(from: frame.observations, frameIndex: frame.frameIndex) {
                    poses[i] = bodyPose(from: selected, frameIndex: frame.frameIndex, timestamp: frame.timestamp)
                } else {
                    poses[i] = .empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp)
                }
            }

            // Track backward from this annotation
            let backwardTracker = PersonTracker()
            backwardTracker.setManualOverride(point: ann.point)

            for i in stride(from: selFrame, through: backwardBound, by: -1) {
                let frame = allFrameObservations[i]
                if let selected = backwardTracker.selectBest(from: frame.observations, frameIndex: frame.frameIndex) {
                    poses[i] = bodyPose(from: selected, frameIndex: frame.frameIndex, timestamp: frame.timestamp)
                } else {
                    poses[i] = .empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp)
                }
            }
        }

        return poses
    }

    /// Simple forward-only tracking from stored observations (used for initial detection pass).
    static func retrackForward(
        allFrameObservations: [FrameObservations],
        tracker: PersonTracker
    ) -> [BodyPose] {
        var poses: [BodyPose] = []
        poses.reserveCapacity(allFrameObservations.count)

        for frame in allFrameObservations {
            if let selected = tracker.selectBest(from: frame.observations, frameIndex: frame.frameIndex) {
                poses.append(bodyPose(from: selected, frameIndex: frame.frameIndex, timestamp: frame.timestamp))
            } else {
                poses.append(.empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp))
            }
        }

        return poses
    }

    // MARK: - Observation → BodyPose Conversion

    /// Convert a VNHumanBodyPoseObservation to our BodyPose model
    static func bodyPose(
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
