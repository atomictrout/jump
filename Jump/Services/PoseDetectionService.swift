import Vision
import AVFoundation
import Foundation
import CoreGraphics

// MARK: - Smart Tracking Engine

/// Intelligent person tracking that automatically follows the athlete
/// and only asks for user input when there's ambiguity.
struct SmartTrackingEngine {
    
    // MARK: - Types
    
    /// A decision point where user input is needed
    struct DecisionPoint: Identifiable, Sendable {
        let id = UUID()
        let frameIndex: Int
        let reason: Reason
        let availablePeople: [BodyPose]
        
        enum Reason: Sendable {
            case initialSelection
            case newPersonEntered
            case multipleOverlapping
            case lowTrackingConfidence
            case athleteLeftFrame
        }
        
        var reasonText: String {
            switch reason {
            case .initialSelection: return "Select the athlete to track"
            case .newPersonEntered: return "New person entered frame. Which is the athlete?"
            case .multipleOverlapping: return "People overlapping. Confirm athlete selection"
            case .lowTrackingConfidence: return "Tracking uncertain. Verify correct person"
            case .athleteLeftFrame: return "Athlete may have left. Is this person the athlete?"
            }
        }
    }
    
    /// Result of smart tracking
    struct TrackingResult: Sendable {
        let trackedPoses: [BodyPose]
        let decisionPoints: [DecisionPoint]
        let autoTrackedFrames: Set<Int>
    }
    
    /// Person identity characteristics
    struct PersonIdentity: Sendable {
        let avgHeight: CGFloat
        let avgWidth: CGFloat
        let avgCenterY: CGFloat
        
        init(from pose: BodyPose) {
            let bbox = pose.boundingBox ?? .zero
            self.avgHeight = bbox.height
            self.avgWidth = bbox.width
            self.avgCenterY = bbox.midY
        }
    }
    
    // MARK: - Main Algorithm
    
    static func autoTrack(allFrameObservations: [FrameObservations]) -> TrackingResult {
        var trackedPoses: [BodyPose] = []
        var decisionPoints: [DecisionPoint] = []
        var autoTrackedFrames: Set<Int> = []
        var lastTrackedPose: BodyPose?
        var athleteIdentity: PersonIdentity?
        
        for (frameIndex, frame) in allFrameObservations.enumerated() {
            let poses = frame.observations
            
            if poses.isEmpty {
                trackedPoses.append(.empty(frameIndex: frameIndex, timestamp: frame.timestamp))
                continue
            }
            
            if poses.count == 1 {
                let pose = poses[0]
                if athleteIdentity == nil {
                    athleteIdentity = PersonIdentity(from: pose)
                    decisionPoints.append(DecisionPoint(
                        frameIndex: frameIndex,
                        reason: .initialSelection,
                        availablePeople: poses
                    ))
                } else if let lastPose = lastTrackedPose,
                          matchesPerson(pose, identity: athleteIdentity!, lastPose: lastPose) {
                    autoTrackedFrames.insert(frameIndex)
                } else {
                    decisionPoints.append(DecisionPoint(
                        frameIndex: frameIndex,
                        reason: .athleteLeftFrame,
                        availablePeople: poses
                    ))
                }
                trackedPoses.append(pose)
                lastTrackedPose = pose
                continue
            }
            
            if let lastPose = lastTrackedPose, let identity = athleteIdentity {
                let (bestMatch, confidence) = findBestMatch(among: poses, identity: identity, lastPose: lastPose)
                if confidence > 0.75 {
                    trackedPoses.append(bestMatch)
                    lastTrackedPose = bestMatch
                    autoTrackedFrames.insert(frameIndex)
                } else {
                    decisionPoints.append(DecisionPoint(
                        frameIndex: frameIndex,
                        reason: confidence > 0.4 ? .multipleOverlapping : .lowTrackingConfidence,
                        availablePeople: poses
                    ))
                    trackedPoses.append(.empty(frameIndex: frameIndex, timestamp: frame.timestamp))
                }
            } else {
                decisionPoints.append(DecisionPoint(
                    frameIndex: frameIndex,
                    reason: .initialSelection,
                    availablePeople: poses
                ))
                trackedPoses.append(.empty(frameIndex: frameIndex, timestamp: frame.timestamp))
            }
        }
        
        return TrackingResult(trackedPoses: trackedPoses, decisionPoints: decisionPoints, autoTrackedFrames: autoTrackedFrames)
    }
    
    static func matchesPerson(_ pose: BodyPose, identity: PersonIdentity, lastPose: BodyPose) -> Bool {
        guard let bbox = pose.boundingBox, let lastBbox = lastPose.boundingBox else { return false }
        let iou = intersectionOverUnion(lastBbox, bbox)
        if iou > 0.5 { return true }
        let heightRatio = bbox.height / identity.avgHeight
        if heightRatio < 0.7 || heightRatio > 1.3 { return false }
        let movement = sqrt(pow(bbox.midX - lastBbox.midX, 2) + pow(bbox.midY - lastBbox.midY, 2))
        if movement > 0.3 { return false }
        return true
    }
    
    static func findBestMatch(among poses: [BodyPose], identity: PersonIdentity, lastPose: BodyPose) -> (pose: BodyPose, confidence: CGFloat) {
        var bestPose = poses[0]
        var bestScore: CGFloat = 0
        for pose in poses {
            var score: CGFloat = 0
            var weights: CGFloat = 0
            if let bbox = pose.boundingBox, let lastBbox = lastPose.boundingBox {
                let iou = intersectionOverUnion(lastBbox, bbox)
                score += iou * 0.6
                weights += 0.6
                let distance = sqrt(pow(bbox.midX - lastBbox.midX, 2) + pow(bbox.midY - lastBbox.midY, 2))
                score += max(0, 1.0 - distance * 3) * 0.2
                weights += 0.2
            }
            if let bbox = pose.boundingBox {
                let heightSim = 1.0 - abs(bbox.height - identity.avgHeight) / identity.avgHeight
                score += max(0, heightSim) * 0.2
                weights += 0.2
            }
            let normalizedScore = weights > 0 ? score / weights : 0
            if normalizedScore > bestScore {
                bestScore = normalizedScore
                bestPose = pose
            }
        }
        return (bestPose, bestScore)
    }
    
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        if intersection.isNull { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

/// Enum to select the pose detection engine.
/// Can be toggled at runtime or via feature flag to switch between Vision and BlazePose.
extension PoseDetectionService {
    enum PoseEngineType {
        case vision, blazePose
    }

    /// Current pose detection engine.
    /// Default is `.vision` (Apple Vision framework).
    ///
    /// To switch to QuickPose/BlazePose:
    /// 1. Complete the QuickPose integration in `BlazePoseDetectionProvider`
    /// 2. Change this property: `PoseDetectionService.poseEngine = .blazePose`
    ///
    /// The switch is global and affects all pose detection operations.
    static var poseEngine: PoseEngineType = .vision
}

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
/// Stores BodyPose objects that work with both Vision and QuickPose engines.
struct FrameObservations: Sendable {
    let frameIndex: Int
    let timestamp: Double
    let observations: [BodyPose]
    
    /// Initializer for BodyPose observations (used by QuickPose and after Vision conversion)
    init(frameIndex: Int, timestamp: Double, bodyPoses: [BodyPose]) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.observations = bodyPoses
    }
    
    /// Legacy initializer for Vision framework (converts VNHumanBodyPoseObservation to BodyPose)
    init(frameIndex: Int, timestamp: Double, visionObservations: [VNHumanBodyPoseObservation]) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.observations = visionObservations.map {
            PoseDetectionService.bodyPose(from: $0, frameIndex: frameIndex, timestamp: timestamp)
        }
    }
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

/// Result from retracking that includes both poses and uncertain frame indices.
struct RetrackResult {
    let poses: [BodyPose]
    /// Frame indices where tracking confidence was low and user review may be needed.
    /// Sorted by confidence (lowest first) so the most uncertain frame is first.
    let uncertainFrameIndices: [Int]
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
    /// NOTE: Vision's VNDetectHumanBodyPoseRequest is optimized for single-person detection.
    /// For true multi-person scenarios, this uses a workaround strategy.
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
            print("⚠️ Pose detection failed for frame \(frameIndex): \(error.localizedDescription)")
            return []
        }

        var allResults = request.results ?? []
        
        // 🔍 CRITICAL DEBUG: Always log for first 5 frames to diagnose issue
        if frameIndex < 5 || frameIndex % 30 == 0 {
            print("📊 Frame \(frameIndex): Vision returned \(allResults.count) pose(s)")
            if allResults.isEmpty {
                print("  ⚠️ NO POSES DETECTED - Video may have issues")
            } else if allResults.count == 1 {
                print("  ⚠️ ONLY 1 PERSON - Trying region-based detection...")
            } else {
                print("  ✅ Vision naturally detected \(allResults.count) people!")
            }
        }
        
        // WORKAROUND: Vision often returns only 1 observation even with multiple people.
        // We can try detecting in different regions to find additional people.
        // This is expensive but necessary for multi-person scenarios.
        if allResults.count <= 1 {
            // Try detecting in left and right halves
            let additionalPoses = try detectInRegions(pixelBuffer: pixelBuffer, frameIndex: frameIndex)
            
            if frameIndex < 5 || frameIndex % 30 == 0 {
                print("  🔍 Region detection found \(additionalPoses.count) additional pose(s)")
            }
            
            // Merge results, removing duplicates based on bounding box overlap
            for newPose in additionalPoses {
                var isDuplicate = false
                for existingPose in allResults {
                    if areDuplicatePoses(existingPose, newPose) {
                        isDuplicate = true
                        break
                    }
                }
                if !isDuplicate {
                    allResults.append(newPose)
                }
            }
            
            if allResults.count > 1 && (frameIndex < 5 || frameIndex % 30 == 0) {
                print("  ✅ FINAL: \(allResults.count) total pose(s) after merging")
            }
        }
        
        return allResults
    }
    
    /// Helper: Detect poses in different regions of the frame
    private static func detectInRegions(
        pixelBuffer: CVPixelBuffer,
        frameIndex: Int
    ) throws -> [VNHumanBodyPoseObservation] {
        var results: [VNHumanBodyPoseObservation] = []
        
        // Define regions to search (normalized coordinates)
        let regions: [CGRect] = [
            CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0),   // Left half
            CGRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)    // Right half
        ]
        
        for (index, region) in regions.enumerated() {
            let request = VNDetectHumanBodyPoseRequest()
            request.regionOfInterest = region
            
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )
            
            do {
                try handler.perform([request])
                
                if let observations = request.results {
                    if frameIndex < 5 {
                        let regionName = index == 0 ? "LEFT" : "RIGHT"
                        print("    🔍 \(regionName) region: found \(observations.count) pose(s)")
                    }
                    results.append(contentsOf: observations)
                }
            } catch {
                if frameIndex < 5 {
                    print("    ⚠️ Region \(index) detection failed: \(error)")
                }
            }
        }
        
        return results
    }
    
    /// Helper: Check if two pose observations are duplicates (same person)
    private static func areDuplicatePoses(
        _ pose1: VNHumanBodyPoseObservation,
        _ pose2: VNHumanBodyPoseObservation
    ) -> Bool {
        // Get center points of poses
        guard let joints1 = try? pose1.recognizedPoints(.all),
              let joints2 = try? pose2.recognizedPoints(.all) else {
            return false
        }
        
        // Compare a few key joints to determine if it's the same person
        let keyJoints: [VNHumanBodyPoseObservation.JointName] = [.nose, .neck, .root]
        var matchCount = 0
        
        for joint in keyJoints {
            if let point1 = joints1[joint], let point2 = joints2[joint],
               point1.confidence > 0.3, point2.confidence > 0.3 {
                let distance = sqrt(pow(point1.location.x - point2.location.x, 2) +
                                  pow(point1.location.y - point2.location.y, 2))
                if distance < 0.1 {  // Within 10% of image
                    matchCount += 1
                }
            }
        }
        
        // If 2+ key joints match, it's likely the same person
        return matchCount >= 2
    }

    /// Dispatch method to detect all poses dynamically based on current poseEngine.
    static func detectAllPosesDynamic(in pixelBuffer: CVPixelBuffer, frameIndex: Int) throws -> [BodyPose] {
        switch poseEngine {
        case .vision:
            let observations = try detectAllPoses(in: pixelBuffer, frameIndex: frameIndex)
            return observations.map { bodyPose(from: $0, frameIndex: frameIndex, timestamp: 0) }
        case .blazePose:
            return try BlazePoseDetectionProvider().detectAllPoses(in: pixelBuffer, frameIndex: frameIndex)
        }
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

        switch poseEngine {
        case .vision:
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
        case .blazePose:
            try await VideoFrameExtractor.streamFrames(
                from: url,
                onFrame: { frameIndex, pixelBuffer, timestamp in
                    let poses = try BlazePoseDetectionProvider().detectAllPoses(in: pixelBuffer, frameIndex: frameIndex)

                    if let selected = tracker.selectBest(from: poses, frameIndex: frameIndex) {
                        collector.append(selected)
                    } else {
                        collector.append(.empty(frameIndex: frameIndex, timestamp: timestamp))
                    }
                },
                onProgress: onProgress
            )
        }

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
        switch poseEngine {
        case .vision:
            let collector = ObservationCollector(capacity: session.totalFrames)

            try await VideoFrameExtractor.streamFrames(
                from: url,
                onFrame: { frameIndex, pixelBuffer, timestamp in
                    let observations = try detectAllPoses(in: pixelBuffer, frameIndex: frameIndex)
                    collector.append(FrameObservations(
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        visionObservations: observations
                    ))
                },
                onProgress: onProgress
            )

            return collector.frames
        case .blazePose:
            return try await BlazePoseDetectionProvider().collectAllObservations(
                url: url,
                session: session,
                onProgress: onProgress
            )
        }
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
                poses[i] = selected
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
                poses[i] = selected
            } else {
                poses[i] = .empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp)
            }
        }

        return poses
    }

    /// Re-track using multiple user annotations.
    /// Each annotation is a (frameIndex, visionPoint) pair where the user identified the athlete.
    /// The video is segmented: between annotations, tracking propagates from the nearest annotation.
    ///
    /// Key design: at the annotation frame, we identify which observation matches (via selectNearest),
    /// then track that specific person forward/backward using centroid + bbox scoring.
    /// The annotation frame is the "anchor" — we find the person there, then propagate.
    ///
    /// Returns a `RetrackResult` with poses and indices of frames where tracking confidence was low.
    static func retrackWithMultipleAnnotations(
        allFrameObservations: [FrameObservations],
        annotations: [(frame: Int, point: CGPoint)]
    ) -> RetrackResult {
        let totalFrames = allFrameObservations.count
        guard totalFrames > 0, !annotations.isEmpty else {
            return RetrackResult(poses: [], uncertainFrameIndices: [])
        }

        var poses = [BodyPose](repeating: .empty(frameIndex: 0, timestamp: 0), count: totalFrames)
        // Track confidence per frame: (frameIndex, confidence)
        var frameConfidences: [(frame: Int, confidence: CGFloat)] = []

        // Confidence threshold: frames below this are flagged for user review.
        // Set fairly high so crossover frames are caught even when the tracker
        // picks a candidate with reasonable distance but wrong identity.
        let uncertaintyThreshold: CGFloat = 0.55

        // Sort annotations by frame
        let sorted = annotations.sorted { $0.frame < $1.frame }
        // Track which frames are annotation frames (user-confirmed, never uncertain)
        let annotationFrames = Set(sorted.map { min($0.frame, totalFrames - 1) })

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

            // First, identify which person at the annotation frame using the tap point
            let anchorFrame = allFrameObservations[selFrame]
            let anchorTracker = PersonTracker()
            anchorTracker.setManualOverride(point: ann.point)
            let anchorPose = anchorTracker.selectBest(from: anchorFrame.observations, frameIndex: anchorFrame.frameIndex)

            if let anchorPose {
                poses[selFrame] = anchorPose
            }

            // Track FORWARD from annotation frame.
            // Initialize tracker with the anchor observation (not just the point).
            let forwardTracker = PersonTracker()
            // Seed the tracker with the anchor person by selecting them at the anchor frame
            forwardTracker.setManualOverride(point: ann.point)
            _ = forwardTracker.selectBest(from: anchorFrame.observations, frameIndex: anchorFrame.frameIndex)
            // Now the tracker is locked onto the right person with their bbox/centroid

            for i in (selFrame + 1)...forwardBound {
                let frame = allFrameObservations[i]
                let distFromAnchor = i - selFrame
                if let result = forwardTracker.selectBestWithConfidence(from: frame.observations, frameIndex: frame.frameIndex) {
                    poses[i] = result.pose
                    if !annotationFrames.contains(i) {
                        // Apply distance decay: confidence decreases further from anchor
                        let decayFactor: CGFloat = max(0.5, 1.0 - CGFloat(distFromAnchor) * 0.008)
                        let adjustedConf = result.confidence * decayFactor
                        // Record confidence for all multi-person frames
                        if frame.observations.count > 1 {
                            frameConfidences.append((frame: i, confidence: adjustedConf))
                        }
                    }
                } else {
                    poses[i] = .empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp)
                    if !frame.observations.isEmpty && !annotationFrames.contains(i) {
                        frameConfidences.append((frame: i, confidence: 0.0))
                    }
                }
            }

            // Track BACKWARD from annotation frame.
            let backwardTracker = PersonTracker()
            backwardTracker.setManualOverride(point: ann.point)
            _ = backwardTracker.selectBest(from: anchorFrame.observations, frameIndex: anchorFrame.frameIndex)

            if selFrame - 1 >= backwardBound {
                for i in stride(from: selFrame - 1, through: backwardBound, by: -1) {
                    let frame = allFrameObservations[i]
                    let distFromAnchor = selFrame - i
                    if let result = backwardTracker.selectBestWithConfidence(from: frame.observations, frameIndex: frame.frameIndex) {
                        poses[i] = result.pose
                        if !annotationFrames.contains(i) {
                            let decayFactor: CGFloat = max(0.5, 1.0 - CGFloat(distFromAnchor) * 0.008)
                            let adjustedConf = result.confidence * decayFactor
                            if frame.observations.count > 1 {
                                frameConfidences.append((frame: i, confidence: adjustedConf))
                            }
                        }
                    } else {
                        poses[i] = .empty(frameIndex: frame.frameIndex, timestamp: frame.timestamp)
                        if !frame.observations.isEmpty && !annotationFrames.contains(i) {
                            frameConfidences.append((frame: i, confidence: 0.0))
                        }
                    }
                }
            }
        }

        // Find uncertain frames: below threshold, deduplicated, sorted by confidence (lowest first)
        // A frame may appear twice (forward + backward pass). Take the lower confidence.
        var minConfByFrame: [Int: CGFloat] = [:]
        for fc in frameConfidences {
            if let existing = minConfByFrame[fc.frame] {
                minConfByFrame[fc.frame] = min(existing, fc.confidence)
            } else {
                minConfByFrame[fc.frame] = fc.confidence
            }
        }

        let uncertainFrames = minConfByFrame
            .filter { $0.value < uncertaintyThreshold }
            .sorted { $0.value < $1.value }  // Most uncertain first
            .map { $0.key }

        // Cluster uncertain frames: only keep one per cluster of consecutive frames
        // (no need to ask user about every single frame in a group)
        // Limit to at most ~8 uncertain frames to avoid overwhelming the user
        let clustered = clusterUncertainFrames(uncertainFrames, minSpacing: 8)
        let limited = Array(clustered.prefix(8))

        return RetrackResult(poses: poses, uncertainFrameIndices: limited)
    }

    /// Cluster uncertain frames so we don't show 20 consecutive orange dots.
    /// Keeps the most uncertain (lowest confidence) frame from each cluster.
    private static func clusterUncertainFrames(_ frames: [Int], minSpacing: Int) -> [Int] {
        guard !frames.isEmpty else { return [] }

        // Frames are already sorted by confidence (lowest first).
        // We greedily pick frames, skipping any that are within `minSpacing` of an already-picked frame.
        var picked: [Int] = []
        for frame in frames {
            let tooClose = picked.contains { abs($0 - frame) < minSpacing }
            if !tooClose {
                picked.append(frame)
            }
        }

        // Sort by frame index for display
        return picked.sorted()
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
                poses.append(selected)
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
