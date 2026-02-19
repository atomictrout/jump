import AVFoundation
import CoreGraphics
import Vision

/// Visual person tracking using Apple's Vision framework.
///
/// Provides four capabilities:
/// 1. **Human detection** via `VNDetectHumanRectanglesRequest` — finds person bounding boxes.
/// 2. **Body pose detection** via `VNDetectHumanBodyPoseRequest` — 19-keypoint body poses (fallback).
/// 3. **Object tracking** via `VNTrackObjectRequest` — sub-millisecond frame-to-frame
///    bounding box tracking that follows visual appearance (texture/color), not body shape.
/// 4. **Full tracking pass** — bidirectional tracking from a seed bounding box across an entire video,
///    with inline drift detection to stop tracking when the tracker locks onto the wrong target.
///
/// All public API surfaces use **top-left origin** normalized coordinates (0-1)
/// matching the rest of the app. Vision's internal bottom-left origin is converted internally.
final class VisionTrackingService {

    // MARK: - Tracking State

    private var trackingRequest: VNTrackObjectRequest?
    private var sequenceHandler: VNSequenceRequestHandler?
    private var isTracking = false

    /// Minimum tracker confidence before considering tracking lost.
    /// Set low (0.15) because even a low-confidence tracked box is useful for crop-and-redetect.
    var minTrackingConfidence: Float = 0.15

    // MARK: - Human Detection

    /// Detect all human bounding boxes in a frame.
    ///
    /// Uses `VNDetectHumanRectanglesRequest` which is a simpler/different model than
    /// BlazePose and can detect people in unusual positions (arched, crouched, etc.).
    ///
    /// - Parameter pixelBuffer: The video frame to analyze.
    /// - Returns: Array of bounding boxes in **top-left origin** normalized coordinates.
    func detectHumans(in pixelBuffer: CVPixelBuffer) throws -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        if #available(iOS 15.0, *) {
            request.revision = VNDetectHumanRectanglesRequestRevision2
            request.upperBodyOnly = false
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }

        return results.map { observation in
            Self.visionToTopLeft(observation.boundingBox)
        }
    }

    // MARK: - Object Tracking (Low-Level)

    /// Start tracking an object at the given bounding box.
    ///
    /// - Parameter boundingBox: Initial bounding box in **top-left origin** normalized coordinates.
    func startTracking(boundingBox: CGRect) {
        let visionRect = Self.topLeftToVision(boundingBox)
        let observation = VNDetectedObjectObservation(boundingBox: visionRect)

        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate

        trackingRequest = request
        sequenceHandler = VNSequenceRequestHandler()
        isTracking = true
    }

    /// Track the object into the next frame.
    ///
    /// Must be called synchronously within the frame processing callback since
    /// `CVPixelBuffer` is released after the callback returns.
    ///
    /// - Parameter pixelBuffer: The next video frame.
    /// - Returns: Updated bounding box (top-left origin) and confidence, or nil if tracking lost.
    func trackNextFrame(_ pixelBuffer: CVPixelBuffer) -> (boundingBox: CGRect, confidence: Float)? {
        guard isTracking,
              let request = trackingRequest,
              let handler = sequenceHandler else { return nil }

        do {
            try handler.perform([request], on: pixelBuffer)
        } catch {
            print("[VisionTracking] Tracking failed: \(error)")
            stopTracking()
            return nil
        }

        guard let result = request.results?.first as? VNDetectedObjectObservation else {
            stopTracking()
            return nil
        }

        let confidence = result.confidence

        // Tracking lost if confidence is too low
        guard confidence >= minTrackingConfidence else {
            stopTracking()
            return nil
        }

        // Update the request's input observation for the next frame (Apple Pattern B)
        request.inputObservation = result

        let topLeftRect = Self.visionToTopLeft(result.boundingBox)
        return (boundingBox: topLeftRect, confidence: confidence)
    }

    /// Stop tracking and release resources.
    func stopTracking() {
        trackingRequest = nil
        sequenceHandler = nil
        isTracking = false
    }

    /// Whether tracking is currently active.
    var isCurrentlyTracking: Bool { isTracking }

    // MARK: - Full Tracking Pass

    /// Run a complete bidirectional tracking pass over a video, propagating a bounding box
    /// forward and backward from a seed frame.
    ///
    /// Uses `VNTrackObjectRequest` which tracks visual appearance (texture/color), NOT body shape.
    /// Includes **inline drift detection** to stop the tracker early when it starts drifting
    /// to a spectator or background object.
    ///
    /// - Parameters:
    ///   - url: Video file URL.
    ///   - seedBox: Initial bounding box (top-left origin, normalized).
    ///   - seedFrameIndex: Frame index where the seed box is valid.
    ///   - frameRate: Video frame rate (used for adaptive displacement thresholds).
    ///   - trimRange: Optional trim range in seconds.
    ///   - humanRects: Per-frame Vision human rects for re-seeding when tracker is lost.
    /// - Returns: Dictionary mapping frameIndex to tracked bounding box (top-left origin).
    func runTrackingPass(
        url: URL,
        seedBox: CGRect,
        seedFrameIndex: Int,
        frameRate: Double,
        trimRange: ClosedRange<Double>?,
        humanRects: [[CGRect]]
    ) async throws -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        result[seedFrameIndex] = seedBox

        // Drift detection thresholds (frame-rate adaptive)
        // Max plausible per-frame displacement: athlete ~10m/s, frame ~1m wide in normalized coords
        let maxPerFrameDisplacement: CGFloat = CGFloat(10.0 / max(frameRate, 30.0))
        // Max cumulative drift from seed before declaring tracker unreliable
        let maxCumulativeDrift: CGFloat = 0.30

        let seedCenter = CGPoint(x: seedBox.midX, y: seedBox.midY)

        // --- Forward pass: stream frames from start, skip to seed, track forward ---
        var lastTrackedBox = seedBox
        var seeded = false
        var forwardDriftCount = 0

        try await VideoFrameExtractor.streamFrames(
            from: url,
            trimRange: trimRange,
            onFrame: { frameIndex, pixelBuffer, _ in
                if frameIndex == seedFrameIndex {
                    self.startTracking(boundingBox: seedBox)
                    seeded = true
                    return
                }

                guard seeded, frameIndex > seedFrameIndex else { return }

                if let tracked = self.trackNextFrame(pixelBuffer) {
                    let newCenter = CGPoint(x: tracked.boundingBox.midX, y: tracked.boundingBox.midY)
                    let lastCenter = CGPoint(x: lastTrackedBox.midX, y: lastTrackedBox.midY)

                    // Drift guard A: per-frame displacement check
                    let displacement = hypot(newCenter.x - lastCenter.x, newCenter.y - lastCenter.y)
                    if displacement > maxPerFrameDisplacement {
                        print("[VisionTracking] Forward drift detected at frame \(frameIndex): displacement \(String(format: "%.3f", displacement)) > threshold \(String(format: "%.3f", maxPerFrameDisplacement))")
                        self.stopTracking()
                        forwardDriftCount += 1
                        // Try re-seed
                        if let reseedBox = self.findBestReseedBox(
                            humanRects: frameIndex < humanRects.count ? humanRects[frameIndex] : [],
                            lastKnownBox: lastTrackedBox
                        ) {
                            self.startTracking(boundingBox: reseedBox)
                            if let retracked = self.trackNextFrame(pixelBuffer) {
                                result[frameIndex] = retracked.boundingBox
                                lastTrackedBox = retracked.boundingBox
                            } else {
                                result[frameIndex] = reseedBox
                                lastTrackedBox = reseedBox
                            }
                        }
                        return
                    }

                    // Drift guard B: cumulative drift from seed
                    let cumulativeDrift = hypot(newCenter.x - seedCenter.x, newCenter.y - seedCenter.y)
                    if cumulativeDrift > maxCumulativeDrift {
                        print("[VisionTracking] Forward cumulative drift at frame \(frameIndex): \(String(format: "%.3f", cumulativeDrift)) > \(maxCumulativeDrift)")
                        self.stopTracking()
                        forwardDriftCount += 1
                        // Try re-seed
                        if let reseedBox = self.findBestReseedBox(
                            humanRects: frameIndex < humanRects.count ? humanRects[frameIndex] : [],
                            lastKnownBox: lastTrackedBox
                        ) {
                            self.startTracking(boundingBox: reseedBox)
                            if let retracked = self.trackNextFrame(pixelBuffer) {
                                result[frameIndex] = retracked.boundingBox
                                lastTrackedBox = retracked.boundingBox
                            } else {
                                result[frameIndex] = reseedBox
                                lastTrackedBox = reseedBox
                            }
                        }
                        return
                    }

                    // Tracking looks valid
                    result[frameIndex] = tracked.boundingBox
                    lastTrackedBox = tracked.boundingBox
                } else {
                    // Tracker lost (low confidence) — try to re-seed from Vision human rects
                    if let reseedBox = self.findBestReseedBox(
                        humanRects: frameIndex < humanRects.count ? humanRects[frameIndex] : [],
                        lastKnownBox: lastTrackedBox
                    ) {
                        self.startTracking(boundingBox: reseedBox)
                        if let tracked = self.trackNextFrame(pixelBuffer) {
                            result[frameIndex] = tracked.boundingBox
                            lastTrackedBox = tracked.boundingBox
                        } else {
                            result[frameIndex] = reseedBox
                            lastTrackedBox = reseedBox
                        }
                    }
                }
            },
            onProgress: { _ in }
        )

        self.stopTracking()

        // --- Backward pass: collect frames 0..seedFrameIndex, then iterate in reverse ---
        let maxBackwardFrames = 300
        var backwardDriftCount = 0

        if seedFrameIndex > 0 {
            var collectedFrames: [(Int, CVPixelBuffer)] = []
            collectedFrames.reserveCapacity(min(seedFrameIndex, maxBackwardFrames))

            try await VideoFrameExtractor.streamFrames(
                from: url,
                trimRange: trimRange,
                onFrame: { frameIndex, pixelBuffer, _ in
                    guard frameIndex < seedFrameIndex else { return }
                    guard collectedFrames.count < maxBackwardFrames else { return }
                    if let copy = VideoFrameExtractor.copyPixelBuffer(pixelBuffer) {
                        collectedFrames.append((frameIndex, copy))
                    }
                },
                onProgress: { _ in }
            )

            // Now iterate in reverse from closest-to-anchor backward
            lastTrackedBox = seedBox
            self.startTracking(boundingBox: seedBox)

            for (frameIndex, buffer) in collectedFrames.reversed() {
                if let tracked = self.trackNextFrame(buffer) {
                    let newCenter = CGPoint(x: tracked.boundingBox.midX, y: tracked.boundingBox.midY)
                    let lastCenter = CGPoint(x: lastTrackedBox.midX, y: lastTrackedBox.midY)

                    // Drift guard A: per-frame displacement
                    let displacement = hypot(newCenter.x - lastCenter.x, newCenter.y - lastCenter.y)
                    if displacement > maxPerFrameDisplacement {
                        print("[VisionTracking] Backward drift detected at frame \(frameIndex): displacement \(String(format: "%.3f", displacement))")
                        self.stopTracking()
                        backwardDriftCount += 1
                        if let reseedBox = self.findBestReseedBox(
                            humanRects: frameIndex < humanRects.count ? humanRects[frameIndex] : [],
                            lastKnownBox: lastTrackedBox
                        ) {
                            self.startTracking(boundingBox: reseedBox)
                            if let retracked = self.trackNextFrame(buffer) {
                                result[frameIndex] = retracked.boundingBox
                                lastTrackedBox = retracked.boundingBox
                            } else {
                                result[frameIndex] = reseedBox
                                lastTrackedBox = reseedBox
                            }
                        }
                        continue
                    }

                    // Drift guard B: cumulative drift from seed
                    let cumulativeDrift = hypot(newCenter.x - seedCenter.x, newCenter.y - seedCenter.y)
                    if cumulativeDrift > maxCumulativeDrift {
                        print("[VisionTracking] Backward cumulative drift at frame \(frameIndex): \(String(format: "%.3f", cumulativeDrift))")
                        self.stopTracking()
                        backwardDriftCount += 1
                        if let reseedBox = self.findBestReseedBox(
                            humanRects: frameIndex < humanRects.count ? humanRects[frameIndex] : [],
                            lastKnownBox: lastTrackedBox
                        ) {
                            self.startTracking(boundingBox: reseedBox)
                            if let retracked = self.trackNextFrame(buffer) {
                                result[frameIndex] = retracked.boundingBox
                                lastTrackedBox = retracked.boundingBox
                            } else {
                                result[frameIndex] = reseedBox
                                lastTrackedBox = reseedBox
                            }
                        }
                        continue
                    }

                    result[frameIndex] = tracked.boundingBox
                    lastTrackedBox = tracked.boundingBox
                } else {
                    // Try re-seeding from human rects
                    if let reseedBox = self.findBestReseedBox(
                        humanRects: frameIndex < humanRects.count ? humanRects[frameIndex] : [],
                        lastKnownBox: lastTrackedBox
                    ) {
                        self.startTracking(boundingBox: reseedBox)
                        if let tracked = self.trackNextFrame(buffer) {
                            result[frameIndex] = tracked.boundingBox
                            lastTrackedBox = tracked.boundingBox
                        } else {
                            result[frameIndex] = reseedBox
                            lastTrackedBox = reseedBox
                        }
                    }
                }
            }

            self.stopTracking()
        }

        print("[VisionTracking] Tracking pass complete: \(result.count) frames tracked, drift events: \(forwardDriftCount) forward, \(backwardDriftCount) backward")
        return result
    }

    /// Find the best human rect to re-seed the tracker from.
    ///
    /// Picks the rect closest to the last known tracked position (within 0.35 distance).
    private func findBestReseedBox(
        humanRects: [CGRect],
        lastKnownBox: CGRect
    ) -> CGRect? {
        guard !humanRects.isEmpty else { return nil }

        let lastCenter = CGPoint(x: lastKnownBox.midX, y: lastKnownBox.midY)
        var bestRect: CGRect?
        var bestDistance: CGFloat = .infinity

        for rect in humanRects {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let distance = hypot(center.x - lastCenter.x, center.y - lastCenter.y)
            if distance < bestDistance {
                bestDistance = distance
                bestRect = rect
            }
        }

        guard bestDistance < 0.35 else { return nil }
        return bestRect
    }

    // MARK: - Body Pose Detection (Apple Vision Fallback)

    /// Detect body poses in a frame using Apple's `VNDetectHumanBodyPoseRequest`.
    ///
    /// Returns 19-keypoint body poses for ALL detected people. This is a different model
    /// from both BlazePose and `VNDetectHumanRectanglesRequest`, and may detect the athlete
    /// in positions where BlazePose fails (e.g., during the Fosbury Flop arch).
    ///
    /// - Parameters:
    ///   - pixelBuffer: The video frame to analyze.
    ///   - frameIndex: Frame index for the returned BodyPose objects.
    ///   - timestamp: Timestamp for the returned BodyPose objects.
    /// - Returns: Array of BodyPose objects (one per detected person), in top-left origin coords.
    func detectBodyPoses(
        in pixelBuffer: CVPixelBuffer,
        frameIndex: Int,
        timestamp: Double
    ) throws -> [BodyPose] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        return observations.compactMap { observation in
            Self.convertVisionPoseToBodyPose(observation, frameIndex: frameIndex, timestamp: timestamp)
        }
    }

    /// Convert a Vision body pose observation to our BodyPose model.
    ///
    /// Maps Apple's 19 joints to the corresponding BodyPose.JointName values.
    /// Vision uses bottom-left origin; we convert to top-left origin.
    private static func convertVisionPoseToBodyPose(
        _ observation: VNHumanBodyPoseObservation,
        frameIndex: Int,
        timestamp: Double
    ) -> BodyPose? {
        guard let allPoints = try? observation.recognizedPoints(.all) else { return nil }

        // Mapping from Apple Vision joint keys to our JointName
        let jointMapping: [(VNHumanBodyPoseObservation.JointName, BodyPose.JointName)] = [
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
            (.rightAnkle, .rightAnkle),
        ]

        var joints: [BodyPose.JointName: BodyPose.JointPosition] = [:]

        for (visionKey, bodyPoseKey) in jointMapping {
            guard let point = allPoints[visionKey],
                  point.confidence > 0.1 else { continue }

            // Vision uses bottom-left origin; convert Y to top-left
            let topLeftPoint = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
            joints[bodyPoseKey] = BodyPose.JointPosition(
                point: topLeftPoint,
                confidence: point.confidence
            )
        }

        guard joints.count >= 3 else { return nil }

        // Compute derived joints (neck = shoulder midpoint, root = hip midpoint)
        if let leftShoulder = joints[.leftShoulder], let rightShoulder = joints[.rightShoulder] {
            joints[.neck] = BodyPose.JointPosition(
                point: CGPoint(
                    x: (leftShoulder.point.x + rightShoulder.point.x) / 2,
                    y: (leftShoulder.point.y + rightShoulder.point.y) / 2
                ),
                confidence: min(leftShoulder.confidence, rightShoulder.confidence)
            )
        }

        if let leftHip = joints[.leftHip], let rightHip = joints[.rightHip] {
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

    // MARK: - Coordinate Conversion

    /// Convert a Vision bounding box (bottom-left origin) to top-left origin.
    ///
    /// Vision: origin at bottom-left, y increases upward
    /// App:    origin at top-left, y increases downward
    static func visionToTopLeft(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: 1.0 - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Convert a top-left origin bounding box to Vision coordinates (bottom-left origin).
    static func topLeftToVision(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: 1.0 - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
