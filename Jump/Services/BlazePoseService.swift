import AVFoundation
import CoreImage
import Foundation
import UIKit
import MediaPipeTasksVision

/// BlazePose-based pose detection service using MediaPipe Tasks Vision API.
///
/// Detects up to 10 people per frame using the `pose_landmarker_heavy.task` model.
/// All landmark coordinates are in normalized MediaPipe format (0-1, origin top-left).
///
/// Also integrates Apple Vision human detection (`VNDetectHumanRectanglesRequest`)
/// to provide bounding boxes for people that BlazePose may miss, and supports
/// crop-and-redetect for recovering poses in specific regions.
final class BlazePoseService {
    /// Primary landmarker — VIDEO mode for full-frame detection with inter-frame tracking.
    private var poseLandmarker: PoseLandmarker?

    /// Secondary landmarker — IMAGE mode, numPoses=1, for crop-and-redetect fallback.
    /// Separate instance because VIDEO mode requires monotonically increasing timestamps
    /// and can't handle interleaved crops.
    private var cropLandmarker: PoseLandmarker?

    /// Shared CIContext for pixel buffer cropping (reused to avoid allocation overhead).
    private let ciContext = CIContext()

    /// Vision service for human bounding box detection.
    let visionService = VisionTrackingService()

    init() {
        guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_heavy", ofType: "task") else {
            print("[BlazePose] Error: pose_landmarker_heavy.task not found in bundle")
            return
        }

        // Primary: VIDEO mode, multi-person
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video
        options.numPoses = 10
        options.minPoseDetectionConfidence = 0.4
        options.minPosePresenceConfidence = 0.3
        options.minTrackingConfidence = 0.3

        do {
            poseLandmarker = try PoseLandmarker(options: options)
        } catch {
            print("[BlazePose] Failed to initialize PoseLandmarker: \(error)")
        }

        // Secondary: IMAGE mode, single person, for crop re-detection
        let cropOptions = PoseLandmarkerOptions()
        cropOptions.baseOptions.modelAssetPath = modelPath
        cropOptions.runningMode = .image
        cropOptions.numPoses = 1
        cropOptions.minPoseDetectionConfidence = 0.3
        cropOptions.minPosePresenceConfidence = 0.2
        cropOptions.minTrackingConfidence = 0.2

        do {
            cropLandmarker = try PoseLandmarker(options: cropOptions)
        } catch {
            print("[BlazePose] Failed to initialize crop PoseLandmarker: \(error)")
        }
    }

    /// Whether the service is ready to detect poses.
    var isReady: Bool { poseLandmarker != nil }

    // MARK: - Single Frame Detection

    /// Detect all poses in a single video frame.
    /// Uses VIDEO running mode with inter-frame tracking for better continuity.
    func detectPoses(in pixelBuffer: CVPixelBuffer, frameIndex: Int, timestamp: Double = 0) throws -> [BodyPose] {
        guard let poseLandmarker = poseLandmarker else {
            throw BlazePoseError.notInitialized
        }

        let mpImage = try MPImage(pixelBuffer: pixelBuffer)
        let timestampMs = Int(timestamp * 1000)
        let result = try poseLandmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestampMs)

        var poses: [BodyPose] = []
        for (index, landmarks) in result.landmarks.enumerated() {
            guard index < result.worldLandmarks.count else { continue }
            let pose = Self.convertToBodyPose(
                from: landmarks,
                frameIndex: frameIndex,
                timestamp: timestamp
            )
            poses.append(pose)
        }

        return poses
    }

    // MARK: - Full Video Processing

    /// Result of video processing — poses and Vision human bounding boxes per frame.
    struct VideoProcessingResult {
        /// Detected poses per frame: `allFramePoses[frameIndex] = [poses]`
        var allFramePoses: [[BodyPose]]
        /// Vision human bounding boxes per frame (top-left origin, normalized).
        var allFrameHumanRects: [[CGRect]]
    }

    /// Process all frames of a video, detecting poses and human bounding boxes.
    ///
    /// Runs BlazePose for full pose estimation AND Apple Vision for human rectangle
    /// detection on every frame. Vision uses a different model that can detect people
    /// in unusual positions where BlazePose fails.
    ///
    /// - Parameters:
    ///   - url: Video file URL.
    ///   - trimRange: Optional time range (seconds) to process.
    ///   - onProgress: Called with (currentFrame, totalFrames).
    /// - Returns: Combined poses and human bounding boxes per frame.
    func processVideo(
        url: URL,
        trimRange: ClosedRange<Double>? = nil,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> VideoProcessingResult {
        guard poseLandmarker != nil else {
            throw BlazePoseError.notInitialized
        }

        // Pre-compute total frames to avoid async calls in the progress closure
        let videoInfo = try await VideoFrameExtractor.videoInfo(from: url)
        let estimatedTotal: Int
        if let trimRange {
            let trimmedDuration = trimRange.upperBound - trimRange.lowerBound
            estimatedTotal = max(1, Int(trimmedDuration * videoInfo.frameRate))
        } else {
            estimatedTotal = videoInfo.totalFrames
        }

        var allFramePoses: [[BodyPose]] = []
        var allFrameHumanRects: [[CGRect]] = []
        let lock = NSLock()

        try await VideoFrameExtractor.streamFrames(
            from: url,
            trimRange: trimRange,
            onFrame: { frameIndex, pixelBuffer, timestamp in
                // 1. BlazePose detection
                var poses: [BodyPose] = []
                do {
                    poses = try self.detectPoses(
                        in: pixelBuffer,
                        frameIndex: frameIndex,
                        timestamp: timestamp
                    )
                } catch {
                    print("[BlazePose] Frame \(frameIndex) detection failed: \(error)")
                }

                // 2. Apple VNDetectHumanBodyPoseRequest fallback when BlazePose finds no one.
                // Runs on ANE (~5ms), detects 19 keypoints. Handles some unusual body positions
                // better than BlazePose (e.g., partially inverted during Fosbury Flop).
                if poses.isEmpty {
                    do {
                        let applePoses = try self.visionService.detectBodyPoses(
                            in: pixelBuffer,
                            frameIndex: frameIndex,
                            timestamp: timestamp
                        )
                        if !applePoses.isEmpty {
                            poses = applePoses
                            print("[BlazePose] Frame \(frameIndex): Apple pose fallback found \(applePoses.count) person(s)")
                        }
                    } catch {
                        // Non-fatal — Apple pose is supplementary
                    }
                }

                // 3. Vision human rectangle detection (runs on ANE, ~5-15ms overhead)
                var humanRects: [CGRect] = []
                do {
                    humanRects = try self.visionService.detectHumans(in: pixelBuffer)
                } catch {
                    // Non-fatal — Vision detection is supplementary
                    print("[Vision] Frame \(frameIndex) human detection failed: \(error)")
                }

                lock.lock()
                while allFramePoses.count <= frameIndex {
                    allFramePoses.append([])
                }
                while allFrameHumanRects.count <= frameIndex {
                    allFrameHumanRects.append([])
                }
                allFramePoses[frameIndex] = poses
                allFrameHumanRects[frameIndex] = humanRects
                lock.unlock()
            },
            onProgress: { progress in
                let current = Int(progress * Double(estimatedTotal))
                onProgress(current, estimatedTotal)
            }
        )

        return VideoProcessingResult(
            allFramePoses: allFramePoses,
            allFrameHumanRects: allFrameHumanRects
        )
    }

    // MARK: - Crop and Re-detect

    /// Re-detect a pose within a specific region of a pixel buffer.
    ///
    /// Uses the secondary (IMAGE mode, numPoses=1) PoseLandmarker to detect a single
    /// person within a cropped region. The crop region is expanded by 1.25x to provide
    /// context around the person.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The full video frame.
    ///   - region: Bounding box to crop (top-left origin, normalized 0-1).
    ///   - frameIndex: Frame index for the resulting BodyPose.
    ///   - timestamp: Timestamp for the resulting BodyPose.
    /// - Returns: Detected pose with coordinates mapped back to full-frame, or nil.
    func redetectInRegion(
        pixelBuffer: CVPixelBuffer,
        region: CGRect,
        frameIndex: Int,
        timestamp: Double
    ) throws -> BodyPose? {
        guard let cropLandmarker = cropLandmarker else {
            throw BlazePoseError.notInitialized
        }

        // Expand region by 1.25x and clamp to [0,1]
        let expandFactor: CGFloat = 1.25
        let expandedWidth = region.width * expandFactor
        let expandedHeight = region.height * expandFactor
        let expandedX = max(0, region.midX - expandedWidth / 2)
        let expandedY = max(0, region.midY - expandedHeight / 2)
        let expandedRegion = CGRect(
            x: expandedX,
            y: expandedY,
            width: min(expandedWidth, 1.0 - expandedX),
            height: min(expandedHeight, 1.0 - expandedY)
        )

        // Crop the pixel buffer
        guard let croppedBuffer = cropPixelBuffer(pixelBuffer, to: expandedRegion) else {
            return nil
        }

        // Run pose detection on cropped region
        let mpImage = try MPImage(pixelBuffer: croppedBuffer)
        let result = try cropLandmarker.detect(image: mpImage)

        guard let landmarks = result.landmarks.first else {
            return nil
        }

        // Convert landmarks and map back to full-frame coordinates
        let cropPose = Self.convertToBodyPose(
            from: landmarks,
            frameIndex: frameIndex,
            timestamp: timestamp
        )

        // Remap: crop-local normalized → full-frame normalized
        var remappedJoints: [BodyPose.JointName: BodyPose.JointPosition] = [:]
        for (name, joint) in cropPose.joints {
            let fullX = expandedRegion.origin.x + joint.point.x * expandedRegion.width
            let fullY = expandedRegion.origin.y + joint.point.y * expandedRegion.height
            remappedJoints[name] = BodyPose.JointPosition(
                point: CGPoint(x: fullX, y: fullY),
                confidence: joint.confidence
            )
        }

        return BodyPose(
            frameIndex: frameIndex,
            timestamp: timestamp,
            joints: remappedJoints
        )
    }

    /// Crop a CVPixelBuffer to a normalized region (top-left origin).
    private func cropPixelBuffer(_ pixelBuffer: CVPixelBuffer, to region: CGRect) -> CVPixelBuffer? {
        let fullWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let fullHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // Convert normalized region to pixel coordinates
        let pixelRect = CGRect(
            x: region.origin.x * fullWidth,
            y: region.origin.y * fullHeight,
            width: region.width * fullWidth,
            height: region.height * fullHeight
        ).integral

        guard pixelRect.width > 0, pixelRect.height > 0 else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: CGRect(
            x: pixelRect.origin.x,
            y: fullHeight - pixelRect.origin.y - pixelRect.height, // CIImage uses bottom-left origin
            width: pixelRect.width,
            height: pixelRect.height
        ))

        // Translate to origin (cropped CIImage retains original coordinates)
        let translatedImage = ciImage.transformed(by: CGAffineTransform(
            translationX: -ciImage.extent.origin.x,
            y: -ciImage.extent.origin.y
        ))

        // Render to a new pixel buffer
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(pixelRect.width),
            Int(pixelRect.height),
            kCVPixelFormatType_32BGRA,
            nil,
            &outputBuffer
        )

        guard status == kCVReturnSuccess, let output = outputBuffer else { return nil }

        ciContext.render(translatedImage, to: output)
        return output
    }

    // MARK: - Landmark Conversion

    /// Map of BlazePose landmark index to BodyPose.JointName.
    private static let landmarkMapping: [(Int, BodyPose.JointName)] = [
        (0, .nose),
        (1, .leftEyeInner),
        (2, .leftEye),
        (3, .leftEyeOuter),
        (4, .rightEyeInner),
        (5, .rightEye),
        (6, .rightEyeOuter),
        (7, .leftEar),
        (8, .rightEar),
        (9, .mouthLeft),
        (10, .mouthRight),
        (11, .leftShoulder),
        (12, .rightShoulder),
        (13, .leftElbow),
        (14, .rightElbow),
        (15, .leftWrist),
        (16, .rightWrist),
        (17, .leftPinky),
        (18, .rightPinky),
        (19, .leftIndex),
        (20, .rightIndex),
        (21, .leftThumb),
        (22, .rightThumb),
        (23, .leftHip),
        (24, .rightHip),
        (25, .leftKnee),
        (26, .rightKnee),
        (27, .leftAnkle),
        (28, .rightAnkle),
        (29, .leftHeel),
        (30, .rightHeel),
        (31, .leftFootIndex),
        (32, .rightFootIndex),
    ]

    /// Convert MediaPipe landmarks to BodyPose.
    ///
    /// MediaPipe coordinates are already top-left origin (0-1 normalized),
    /// matching our app's coordinate convention. NO Y-flip needed.
    static func convertToBodyPose(
        from landmarks: [NormalizedLandmark],
        frameIndex: Int,
        timestamp: Double
    ) -> BodyPose {
        var joints: [BodyPose.JointName: BodyPose.JointPosition] = [:]

        // Map all 33 native landmarks
        for (mpIndex, jointName) in landmarkMapping {
            guard mpIndex < landmarks.count else { continue }
            let landmark = landmarks[mpIndex]

            joints[jointName] = BodyPose.JointPosition(
                point: CGPoint(
                    x: CGFloat(landmark.x),
                    y: CGFloat(landmark.y)   // NO Y-flip — MediaPipe is already top-left origin
                ),
                confidence: landmark.visibility?.floatValue ?? 0.0
            )
        }

        // Compute neck position (midpoint of shoulders)
        if let leftShoulder = joints[.leftShoulder],
           let rightShoulder = joints[.rightShoulder] {
            joints[.neck] = BodyPose.JointPosition(
                point: CGPoint(
                    x: (leftShoulder.point.x + rightShoulder.point.x) / 2,
                    y: (leftShoulder.point.y + rightShoulder.point.y) / 2
                ),
                confidence: min(leftShoulder.confidence, rightShoulder.confidence)
            )
        }

        // Compute root position (midpoint of hips)
        if let leftHip = joints[.leftHip],
           let rightHip = joints[.rightHip] {
            joints[.root] = BodyPose.JointPosition(
                point: CGPoint(
                    x: (leftHip.point.x + rightHip.point.x) / 2,
                    y: (leftHip.point.y + rightHip.point.y) / 2
                ),
                confidence: min(leftHip.confidence, rightHip.confidence)
            )
        }

        return BodyPose(
            frameIndex: frameIndex,
            timestamp: timestamp,
            joints: joints
        )
    }
}

// MARK: - Errors

enum BlazePoseError: LocalizedError {
    case notInitialized
    case detectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "PoseLandmarker not initialized. Ensure pose_landmarker_heavy.task is in your app bundle."
        case .detectionFailed(let detail):
            return "Pose detection failed: \(detail)"
        }
    }
}
