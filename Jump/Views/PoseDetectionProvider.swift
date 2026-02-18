// Protocol and provider interface for switching between Apple Vision and MediaPipe BlazePose.
//
// USAGE:
// ======
// Switch between pose detection engines at runtime:
//
//   PoseDetectionService.poseEngine = .vision      // Use Apple Vision (default)
//   PoseDetectionService.poseEngine = .blazePose   // Use MediaPipe BlazePose
//
// All existing video processing and tracking code works with either engine automatically.
//
// MEDIAPIPE BLAZEPOSE INTEGRATION:
// =================================
// - Uses Google's official MediaPipe Tasks Vision API
// - Model: pose_landmarker_heavy.task (must be in app bundle)
// - Detects 33 3D body landmarks with high accuracy
// - GPU-accelerated for real-time performance
// - Automatic coordinate conversion (top-left → bottom-left)
// - Calculates neck and root joints from shoulders and hips
//
// SETUP REQUIRED:
// 1. Add to Podfile: pod 'MediaPipeTasksVision', '~> 0.10.14'
// 2. Run: pod install
// 3. Download pose_landmarker_heavy.task and add to Xcode project

import AVFoundation
import Foundation
import UIKit
import MediaPipeTasksVision

/// Protocol for a pose detection engine.
protocol PoseDetectionProvider {
    /// Detect all body poses in a CVPixelBuffer.
    func detectAllPoses(in pixelBuffer: CVPixelBuffer, frameIndex: Int) throws -> [BodyPose]
    /// Collect per-frame observations for a video stream.
    func collectAllObservations(url: URL, session: JumpSession, onProgress: @escaping (Double) -> Void) async throws -> [FrameObservations]
}

// MARK: - Apple Vision Provider

/// Apple Vision-based pose detector (wraps the current PoseDetectionService Vision calls).
class VisionPoseDetectionProvider: PoseDetectionProvider {
    func detectAllPoses(in pixelBuffer: CVPixelBuffer, frameIndex: Int) throws -> [BodyPose] {
        let observations = try PoseDetectionService.detectAllPoses(in: pixelBuffer, frameIndex: frameIndex)
        return observations.map { PoseDetectionService.bodyPose(from: $0, frameIndex: frameIndex, timestamp: 0) }
    }
    func collectAllObservations(url: URL, session: JumpSession, onProgress: @escaping (Double) -> Void) async throws -> [FrameObservations] {
        return try await PoseDetectionService.collectAllObservations(url: url, session: session, onProgress: onProgress)
    }
}

// MARK: - MediaPipe BlazePose Provider

/// MediaPipe BlazePose-based pose detector using official Google MediaPipe Tasks API.
class BlazePoseDetectionProvider: PoseDetectionProvider {
    private var poseLandmarker: PoseLandmarker?
    
    init() {
        // Initialize MediaPipe PoseLandmarker
        guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_heavy", ofType: "task") else {
            print("❌ Error: pose_landmarker_heavy.task not found in bundle")
            print("📥 Download from: https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task")
            return
        }
        
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .image  // Process single images/frames
        options.numPoses = 3  // Detect up to 3 people (optimal for high jump scenarios)
        options.minPoseDetectionConfidence = 0.2  // Very permissive - detect even low-confidence poses
        options.minPosePresenceConfidence = 0.2   // Detect partially visible people
        options.minTrackingConfidence = 0.3
        
        do {
            poseLandmarker = try PoseLandmarker(options: options)
        } catch {
            print("❌ Failed to initialize PoseLandmarker: \(error)")
        }
    }
    
    func detectAllPoses(in pixelBuffer: CVPixelBuffer, frameIndex: Int) throws -> [BodyPose] {
        guard let poseLandmarker = poseLandmarker else {
            throw NSError(
                domain: "BlazePoseDetectionProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "PoseLandmarker not initialized. Ensure pose_landmarker_heavy.task is in your app bundle."]
            )
        }
        
        // Convert CVPixelBuffer to MPImage
        let mpImage = try MPImage(pixelBuffer: pixelBuffer)
        
        // Detect poses
        let result = try poseLandmarker.detect(image: mpImage)
        
        // 🔍 DEBUG LOGGING: Always log for first 5 frames
        if frameIndex < 5 || frameIndex % 30 == 0 {
            print("📊 [BlazePose] Frame \(frameIndex): Detected \(result.landmarks.count) pose(s)")
            if result.landmarks.isEmpty {
                print("  ⚠️ NO POSES DETECTED")
            } else if result.landmarks.count == 1 {
                print("  ⚠️ Only 1 person detected (config allows up to 3)")
            } else {
                print("  ✅ Multiple people detected: \(result.landmarks.count)")
            }
        }
        
        // Convert each detected pose to BodyPose
        var poses: [BodyPose] = []
        for (index, landmarks) in result.landmarks.enumerated() {
            if index < result.worldLandmarks.count {
                let pose = Self.convertToBodyPose(
                    from: landmarks,
                    worldLandmarks: result.worldLandmarks[index],
                    frameIndex: frameIndex,
                    timestamp: 0
                )
                poses.append(pose)
                
                // 🔍 Extra detail for first few frames
                if frameIndex < 5 {
                    print("    Person \(index + 1): \(landmarks.count) landmarks, confidence: \(landmarks.first?.visibility ?? 0)")
                }
            }
        }
        
        return poses
    }
    
    func collectAllObservations(url: URL, session: JumpSession, onProgress: @escaping (Double) -> Void) async throws -> [FrameObservations] {
        guard let poseLandmarker = poseLandmarker else {
            throw NSError(
                domain: "BlazePoseDetectionProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "PoseLandmarker not initialized"]
            )
        }
        
        var frames: [FrameObservations] = []
        
        try await VideoFrameExtractor.streamFrames(
            from: url,
            onFrame: { frameIndex, pixelBuffer, timestamp in
                do {
                    // Convert CVPixelBuffer to MPImage
                    let mpImage = try MPImage(pixelBuffer: pixelBuffer)
                    
                    // Detect poses
                    let result = try poseLandmarker.detect(image: mpImage)
                    
                    // Convert each detected pose to BodyPose
                    var framePoses: [BodyPose] = []
                    for (index, landmarks) in result.landmarks.enumerated() {
                        if index < result.worldLandmarks.count {
                            let pose = Self.convertToBodyPose(
                                from: landmarks,
                                worldLandmarks: result.worldLandmarks[index],
                                frameIndex: frameIndex,
                                timestamp: timestamp
                            )
                            framePoses.append(pose)
                        }
                    }
                    
                    frames.append(FrameObservations(
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        bodyPoses: framePoses
                    ))
                } catch {
                    print("⚠️ Frame \(frameIndex) detection failed: \(error)")
                    frames.append(FrameObservations(
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        bodyPoses: []
                    ))
                }
            },
            onProgress: onProgress
        )
        
        return frames
    }
    
    // MARK: - Landmark Mapping & Conversion
    
    /// MediaPipe BlazePose landmark indices (33 total)
    enum LandmarkIndex: Int {
        case nose = 0
        case leftEyeInner = 1
        case leftEye = 2
        case leftEyeOuter = 3
        case rightEyeInner = 4
        case rightEye = 5
        case rightEyeOuter = 6
        case leftEar = 7
        case rightEar = 8
        case mouthLeft = 9
        case mouthRight = 10
        case leftShoulder = 11
        case rightShoulder = 12
        case leftElbow = 13
        case rightElbow = 14
        case leftWrist = 15
        case rightWrist = 16
        case leftPinky = 17
        case rightPinky = 18
        case leftIndex = 19
        case rightIndex = 20
        case leftThumb = 21
        case rightThumb = 22
        case leftHip = 23
        case rightHip = 24
        case leftKnee = 25
        case rightKnee = 26
        case leftAnkle = 27
        case rightAnkle = 28
        case leftHeel = 29
        case rightHeel = 30
        case leftFootIndex = 31
        case rightFootIndex = 32
    }
    
    /// Convert MediaPipe landmarks to BodyPose.
    static func convertToBodyPose(
        from landmarks: [NormalizedLandmark],
        worldLandmarks: [Landmark],
        frameIndex: Int,
        timestamp: Double
    ) -> BodyPose {
        var joints: [BodyPose.JointName: BodyPose.JointPosition] = [:]
        
        // Map MediaPipe landmarks to BodyPose joints
        let mapping: [(LandmarkIndex, BodyPose.JointName)] = [
            (.nose, .nose),
            (.leftEye, .leftEye),
            (.rightEye, .rightEye),
            (.leftEar, .leftEar),
            (.rightEar, .rightEar),
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
            (.rightAnkle, .rightAnkle)
        ]
        
        for (mpIndex, jointName) in mapping {
            let index = mpIndex.rawValue
            guard index < landmarks.count else { continue }
            
            let landmark = landmarks[index]
            
            // MediaPipe uses top-left origin (0,0), Vision uses bottom-left
            // Flip Y coordinate to match Vision coordinate system
            joints[jointName] = BodyPose.JointPosition(
                point: CGPoint(
                    x: CGFloat(landmark.x),
                    y: CGFloat(1.0 - landmark.y)  // Flip Y
                ),
                confidence: Float(landmark.visibility ?? 0.0)
            )
        }
        
        // Calculate neck position (midpoint of shoulders)
        if let leftShoulder = joints[.leftShoulder],
           let rightShoulder = joints[.rightShoulder] {
            let neckPoint = CGPoint(
                x: (leftShoulder.point.x + rightShoulder.point.x) / 2,
                y: (leftShoulder.point.y + rightShoulder.point.y) / 2
            )
            joints[.neck] = BodyPose.JointPosition(
                point: neckPoint,
                confidence: min(leftShoulder.confidence, rightShoulder.confidence)
            )
        }
        
        // Calculate root position (midpoint of hips)
        if let leftHip = joints[.leftHip],
           let rightHip = joints[.rightHip] {
            let rootPoint = CGPoint(
                x: (leftHip.point.x + rightHip.point.x) / 2,
                y: (leftHip.point.y + rightHip.point.y) / 2
            )
            joints[.root] = BodyPose.JointPosition(
                point: rootPoint,
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
