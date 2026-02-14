import Vision
import CoreGraphics

/// Tracks a single athlete across video frames by matching bounding boxes.
/// Uses velocity prediction + individual joint matching + bbox scoring for robust matching.
/// Thread-safe via NSLock for use from background processing threads.
final class PersonTracker: @unchecked Sendable {

    private let lock = NSLock()

    /// The bounding box of the currently tracked person (normalized Vision coords)
    private var _trackedBBox: CGRect?
    /// The centroid of the tracked person
    private var _trackedCentroid: CGPoint?
    /// Previous centroid (for velocity estimation)
    private var _previousCentroid: CGPoint?
    /// Estimated velocity (centroid displacement per frame)
    private var _velocity: CGPoint = .zero
    /// Manual override point (user tapped to select a person)
    private var _manualOverridePoint: CGPoint?
    /// Whether a manual override has been set
    private var _hasManualOverride = false
    /// Key joint positions from the last tracked observation (for joint-level matching)
    private var _trackedJoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]

    // MARK: - Configuration

    /// Maximum centroid distance (normalized) to consider a match between frames
    private let matchThreshold: CGFloat = 0.25

    /// Weight for centrality score in initial selection (0-1)
    private let centralityWeight: CGFloat = 0.4
    /// Weight for size score in initial selection (0-1)
    private let sizeWeight: CGFloat = 0.6

    // Match scoring weights — distance is HEAVILY weighted to avoid switching to nearby bystanders
    /// Weight for distance from predicted position
    private let distanceWeight: CGFloat = 0.65
    /// Weight for individual joint position continuity
    private let jointContinuityWeight: CGFloat = 0.20
    /// Weight for bbox size similarity
    private let sizeSimilarityWeight: CGFloat = 0.05
    /// Weight for motion consistency (penalizes stationary candidates when tracker has velocity)
    private let motionConsistencyWeight: CGFloat = 0.10

    /// Key joints to track for continuity (stable, high-confidence joints)
    private let trackingJoints: [VNHumanBodyPoseObservation.JointName] = [
        .root, .neck, .leftHip, .rightHip, .leftShoulder, .rightShoulder
    ]

    // MARK: - Public Interface

    /// Reset tracking state for a new video
    func reset() {
        lock.withLock {
            _trackedBBox = nil
            _trackedCentroid = nil
            _previousCentroid = nil
            _velocity = .zero
            _manualOverridePoint = nil
            _hasManualOverride = false
            _isLocked = false
            _framesSinceEstablished = 0
            _consecutiveMisses = 0
            _trackedJoints = [:]
        }
    }

    /// Set a manual override point — the person nearest this point will be selected.
    /// Point should be in Vision normalized coordinates (0-1, bottom-left origin).
    func setManualOverride(point: CGPoint) {
        lock.withLock {
            _manualOverridePoint = point
            _hasManualOverride = true
            // Reset tracking so next frame re-selects
            _trackedBBox = nil
            _trackedCentroid = nil
            _previousCentroid = nil
            _velocity = .zero
            _trackedJoints = [:]
        }
    }

    /// Whether a person has been initially selected (after first few frames)
    private var _isLocked = false

    /// Number of frames since tracking was established
    private var _framesSinceEstablished = 0

    /// Frames needed before we "lock on" and reject non-matching people
    private let lockAfterFrames = 5

    /// Number of consecutive frames where no match was found
    private var _consecutiveMisses = 0

    /// After this many consecutive misses, assume the person has left and re-lock next appearance
    private let reacquireAfterMisses = 30

    /// Result from selectBest that includes confidence information
    struct TrackingResult {
        let observation: VNHumanBodyPoseObservation
        /// 0.0 = very uncertain (multiple nearby people, large jump), 1.0 = very confident
        let confidence: CGFloat
    }

    /// Select the best observation, returning both the observation and a confidence score.
    func selectBestWithConfidence(
        from observations: [VNHumanBodyPoseObservation],
        frameIndex: Int
    ) -> TrackingResult? {
        guard let obs = selectBest(from: observations, frameIndex: frameIndex) else { return nil }
        let conf = lock.withLock { _lastMatchConfidence }
        return TrackingResult(observation: obs, confidence: conf)
    }

    /// Confidence of the last match (set inside selectBest)
    private var _lastMatchConfidence: CGFloat = 1.0

    /// Select the best observation from a set of detected people for the given frame.
    /// Returns nil if no observations match the tracked athlete (avoids annotating bystanders).
    func selectBest(
        from observations: [VNHumanBodyPoseObservation],
        frameIndex: Int
    ) -> VNHumanBodyPoseObservation? {
        guard !observations.isEmpty else {
            lock.withLock {
                _consecutiveMisses += 1
                if _consecutiveMisses >= reacquireAfterMisses {
                    _isLocked = false
                    _framesSinceEstablished = 0
                }
            }
            return nil
        }

        return lock.withLock {
            // If manual override is set, find the person nearest the override point
            if _hasManualOverride, let overridePoint = _manualOverridePoint {
                let selected = selectNearest(to: overridePoint, from: observations)
                if let selected {
                    updateTrackingUnlocked(for: selected)
                    _isLocked = true
                    _framesSinceEstablished = lockAfterFrames
                    _consecutiveMisses = 0
                    _lastMatchConfidence = 1.0  // Manual selection = full confidence
                    _hasManualOverride = false
                    _manualOverridePoint = nil
                }
                return selected
            }

            // If we have a tracked person, match using multi-signal scoring
            if let trackedCentroid = _trackedCentroid, let trackedBBox = _trackedBBox {
                let matched = matchByScoringUnlocked(
                    trackedCentroid: trackedCentroid,
                    trackedBBox: trackedBBox,
                    from: observations,
                    frameIndex: frameIndex
                )
                if let matched {
                    updateTrackingUnlocked(for: matched)
                    _framesSinceEstablished += 1
                    if _framesSinceEstablished >= lockAfterFrames {
                        _isLocked = true
                    }
                    _consecutiveMisses = 0
                    return matched
                }

                // No match within threshold
                _consecutiveMisses += 1
                _lastMatchConfidence = 0.0
                if _consecutiveMisses >= reacquireAfterMisses {
                    _isLocked = false
                    _framesSinceEstablished = 0
                }

                if _isLocked {
                    return nil
                }
            }

            // Initial selection: score by centrality + size
            let selected = initialSelection(from: observations)
            if let selected {
                updateTrackingUnlocked(for: selected)
                _framesSinceEstablished = 1
                _consecutiveMisses = 0
                _lastMatchConfidence = observations.count == 1 ? 0.9 : 0.6
            }
            return selected
        }
    }

    // MARK: - Private

    /// Compute bounding box from an observation's recognized points
    private func boundingBox(for observation: VNHumanBodyPoseObservation) -> CGRect? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }

        var minX: CGFloat = 1.0
        var maxX: CGFloat = 0.0
        var minY: CGFloat = 1.0
        var maxY: CGFloat = 0.0
        var count = 0

        for (_, point) in points {
            guard point.confidence > 0.1 else { continue }
            minX = min(minX, point.location.x)
            maxX = max(maxX, point.location.x)
            minY = min(minY, point.location.y)
            maxY = max(maxY, point.location.y)
            count += 1
        }

        guard count >= 3 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Centroid of a bounding box
    private func centroid(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Distance between two points
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Predicted position of the tracked person based on velocity
    private var predictedCentroid: CGPoint? {
        guard let centroid = _trackedCentroid else { return nil }
        return CGPoint(
            x: centroid.x + _velocity.x,
            y: centroid.y + _velocity.y
        )
    }

    /// Extract key joint positions from an observation
    private func extractKeyJoints(from observation: VNHumanBodyPoseObservation) -> [VNHumanBodyPoseObservation.JointName: CGPoint] {
        var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        for jointName in trackingJoints {
            if let point = try? observation.recognizedPoint(jointName),
               point.confidence > 0.1 {
                joints[jointName] = point.location
            }
        }
        return joints
    }

    /// Compute average displacement of matching joints between tracked and candidate observations.
    /// Returns 0 if no matching joints found (fallback to centroid-only matching).
    private func jointDisplacement(
        candidate: VNHumanBodyPoseObservation,
        predicted velocity: CGPoint
    ) -> CGFloat {
        let candidateJoints = extractKeyJoints(from: candidate)
        guard !_trackedJoints.isEmpty && !candidateJoints.isEmpty else { return 0 }

        var totalDist: CGFloat = 0
        var matchCount = 0

        for (jointName, prevPos) in _trackedJoints {
            guard let candPos = candidateJoints[jointName] else { continue }
            // Predicted joint position = previous position + velocity
            let predictedPos = CGPoint(x: prevPos.x + velocity.x, y: prevPos.y + velocity.y)
            totalDist += distance(predictedPos, candPos)
            matchCount += 1
        }

        return matchCount > 0 ? totalDist / CGFloat(matchCount) : 0
    }

    /// Initial selection: pick the person with highest combined centrality + size score
    private func initialSelection(from observations: [VNHumanBodyPoseObservation]) -> VNHumanBodyPoseObservation? {
        var bestScore: CGFloat = -1
        var bestObs: VNHumanBodyPoseObservation?

        var areas: [(VNHumanBodyPoseObservation, CGRect)] = []
        var maxArea: CGFloat = 0

        for obs in observations {
            guard let bbox = boundingBox(for: obs) else { continue }
            let area = bbox.width * bbox.height
            areas.append((obs, bbox))
            maxArea = max(maxArea, area)
        }

        guard maxArea > 0 else { return observations.first }

        let imageCenter = CGPoint(x: 0.5, y: 0.5)

        for (obs, bbox) in areas {
            let center = centroid(of: bbox)
            let area = bbox.width * bbox.height

            let dist = distance(center, imageCenter)
            let centralityScore = max(0, 1.0 - dist / 0.707)
            let sizeScore = area / maxArea

            let totalScore = centralityWeight * centralityScore + sizeWeight * sizeScore

            if totalScore > bestScore {
                bestScore = totalScore
                bestObs = obs
            }
        }

        return bestObs
    }

    /// Multi-signal matching using centroid distance, joint continuity, and bbox size.
    /// Distance is weighted very heavily (70%) because during crossovers, shape changes
    /// dramatically for the athlete while the bystander stays similar.
    private func matchByScoringUnlocked(
        trackedCentroid: CGPoint,
        trackedBBox: CGRect,
        from observations: [VNHumanBodyPoseObservation],
        frameIndex: Int
    ) -> VNHumanBodyPoseObservation? {
        let targetPoint = predictedCentroid ?? trackedCentroid
        let trackedArea = trackedBBox.width * trackedBBox.height

        struct Candidate {
            let observation: VNHumanBodyPoseObservation
            let score: CGFloat
            let dist: CGFloat
            let jointDist: CGFloat
        }

        var candidates: [Candidate] = []

        // Expected speed of the tracked person (how fast they were moving)
        let trackerSpeed = sqrt(_velocity.x * _velocity.x + _velocity.y * _velocity.y)

        for obs in observations {
            guard let bbox = boundingBox(for: obs) else { continue }
            let center = centroid(of: bbox)
            let dist = distance(center, targetPoint)

            // Skip if way too far from predicted position
            if dist > matchThreshold * 1.5 { continue }

            let area = bbox.width * bbox.height

            // 1. Distance score: normalized by threshold (0 = perfect, 1 = at threshold)
            let distScore = dist / matchThreshold

            // 2. Joint continuity: how well do individual joints match predicted positions?
            let jDist = jointDisplacement(candidate: obs, predicted: _velocity)
            let jointScore = jDist / matchThreshold

            // 3. Size similarity
            let sizeRatio: CGFloat
            if trackedArea > 0 && area > 0 {
                let ratio = min(area, trackedArea) / max(area, trackedArea)
                sizeRatio = 1.0 - ratio
            } else {
                sizeRatio = 0.5
            }

            // 4. Motion consistency: if tracker is moving, penalize candidates that appear
            //    stationary relative to the tracker's PREVIOUS position.
            //    A bystander near the predicted position will be close to targetPoint but also
            //    close to trackedCentroid (because they didn't move). The real athlete should
            //    have moved AWAY from the previous centroid by roughly the velocity amount.
            let motionScore: CGFloat
            if trackerSpeed > 0.01 {
                // How far is this candidate from the tracker's PREVIOUS centroid?
                let distFromPrev = distance(center, trackedCentroid)
                // Expected: candidate should be ~trackerSpeed away from previous centroid
                // If candidate is very close to previous centroid, they didn't move (bystander)
                let expectedDist = trackerSpeed
                if distFromPrev < expectedDist * 0.3 {
                    // Candidate barely moved from where tracker was — likely stationary bystander
                    motionScore = 1.0
                } else {
                    motionScore = 0.0
                }
            } else {
                motionScore = 0.0  // No velocity established yet, don't penalize
            }

            // Combined score (lower is better)
            let totalScore = distanceWeight * distScore
                + jointContinuityWeight * jointScore
                + sizeSimilarityWeight * sizeRatio
                + motionConsistencyWeight * motionScore

            candidates.append(Candidate(
                observation: obs,
                score: totalScore,
                dist: dist,
                jointDist: jDist
            ))
        }

        // Sort by score
        candidates.sort { $0.score < $1.score }

        guard let best = candidates.first, best.dist <= matchThreshold else {
            _lastMatchConfidence = 0.0
            return nil
        }

        // Compute confidence
        let distConfidence = max(0, 1.0 - best.dist / matchThreshold)

        // Ambiguity: how close is second-best to best?
        let ambiguityConfidence: CGFloat
        if candidates.count <= 1 {
            ambiguityConfidence = 1.0
        } else {
            let margin = candidates[1].score - best.score
            // If both are very close in score, confidence is LOW
            ambiguityConfidence = min(1.0, margin / 0.15)
        }

        // Displacement confidence: if we moved much more than expected, something is off
        let expectedDisplacement = sqrt(_velocity.x * _velocity.x + _velocity.y * _velocity.y)
        let actualDisplacement = best.dist
        let displacementRatio = expectedDisplacement > 0.001
            ? actualDisplacement / max(expectedDisplacement, 0.01)
            : (actualDisplacement > 0.05 ? 0.3 : 1.0)  // No velocity yet: penalize large jumps
        let displacementConfidence = max(0, min(1.0, 2.0 - displacementRatio))

        _lastMatchConfidence = 0.30 * distConfidence
            + 0.40 * ambiguityConfidence
            + 0.30 * displacementConfidence

        #if DEBUG
        if candidates.count > 1 {
            let secondDist = candidates[1].dist
            print("[Tracker] frame=\(frameIndex) candidates=\(candidates.count) " +
                  "bestDist=\(String(format: "%.3f", best.dist)) " +
                  "2ndDist=\(String(format: "%.3f", secondDist)) " +
                  "bestScore=\(String(format: "%.3f", best.score)) " +
                  "2ndScore=\(String(format: "%.3f", candidates[1].score)) " +
                  "conf=\(String(format: "%.2f", _lastMatchConfidence)) " +
                  "vel=(\(String(format: "%.3f", _velocity.x)),\(String(format: "%.3f", _velocity.y)))")
        }
        #endif

        return best.observation
    }

    /// Find the observation nearest to a specific point (for manual override).
    private func selectNearest(
        to point: CGPoint,
        from observations: [VNHumanBodyPoseObservation]
    ) -> VNHumanBodyPoseObservation? {
        var bestScore: CGFloat = .greatestFiniteMagnitude
        var bestObs: VNHumanBodyPoseObservation?

        for obs in observations {
            guard let bbox = boundingBox(for: obs) else { continue }

            let expandedBBox = bbox.insetBy(dx: -0.03, dy: -0.03)
            let containsTap = expandedBBox.contains(point)

            let jointDist = nearestJointDistance(to: point, observation: obs)
            let center = centroid(of: bbox)
            let centroidDist = distance(center, point)

            let score: CGFloat
            if containsTap {
                score = jointDist * 0.5
            } else {
                score = centroidDist + 0.5
            }

            if score < bestScore {
                bestScore = score
                bestObs = obs
            }
        }

        return bestObs
    }

    /// Find the distance from a point to the nearest visible joint in an observation
    private func nearestJointDistance(
        to point: CGPoint,
        observation: VNHumanBodyPoseObservation
    ) -> CGFloat {
        guard let points = try? observation.recognizedPoints(.all) else { return .greatestFiniteMagnitude }

        var minDist: CGFloat = .greatestFiniteMagnitude
        for (_, jointPoint) in points {
            guard jointPoint.confidence > 0.1 else { continue }
            let dist = distance(jointPoint.location, point)
            minDist = min(minDist, dist)
        }
        return minDist
    }

    /// Update tracking state with velocity estimation (caller must hold lock)
    private func updateTrackingUnlocked(for observation: VNHumanBodyPoseObservation) {
        if let bbox = boundingBox(for: observation) {
            let newCentroid = centroid(of: bbox)

            // Update velocity estimate
            if let prevCentroid = _trackedCentroid {
                let newVelocity = CGPoint(
                    x: newCentroid.x - prevCentroid.x,
                    y: newCentroid.y - prevCentroid.y
                )
                // Exponential smoothing to reduce noise
                let alpha: CGFloat = 0.5
                _velocity = CGPoint(
                    x: alpha * newVelocity.x + (1 - alpha) * _velocity.x,
                    y: alpha * newVelocity.y + (1 - alpha) * _velocity.y
                )
            }

            _previousCentroid = _trackedCentroid
            _trackedBBox = bbox
            _trackedCentroid = newCentroid
            // Store individual joint positions for continuity matching
            _trackedJoints = extractKeyJoints(from: observation)
        }
    }

    /// Update tracking state (acquires lock)
    private func updateTracking(for observation: VNHumanBodyPoseObservation) {
        lock.withLock {
            updateTrackingUnlocked(for: observation)
        }
    }
}
// MARK: - BodyPose Support

extension PersonTracker {
    /// Result struct for BodyPose tracking
    struct BodyPoseTrackingResult {
        let pose: BodyPose
        /// 0.0 = very uncertain (multiple nearby people, large jump), 1.0 = very confident
        let confidence: CGFloat
    }
    
    /// Select the best BodyPose, returning both the pose and a confidence score.
    func selectBestWithConfidence(
        from poses: [BodyPose],
        frameIndex: Int
    ) -> BodyPoseTrackingResult? {
        guard let selected = selectBest(from: poses, frameIndex: frameIndex) else { return nil }
        let conf = lock.withLock { _lastMatchConfidence }
        return BodyPoseTrackingResult(pose: selected, confidence: conf)
    }
    
    /// Select the best BodyPose from a set of detected people for the given frame.
    /// Returns nil if no poses match the tracked athlete.
    func selectBest(
        from poses: [BodyPose],
        frameIndex: Int
    ) -> BodyPose? {
        guard !poses.isEmpty else {
            lock.withLock {
                _consecutiveMisses += 1
                if _consecutiveMisses >= reacquireAfterMisses {
                    _isLocked = false
                    _framesSinceEstablished = 0
                }
            }
            return nil
        }
        
        return lock.withLock {
            // If manual override is set, find the person nearest the override point
            if _hasManualOverride, let overridePoint = _manualOverridePoint {
                let selected = selectNearestBodyPose(to: overridePoint, from: poses)
                if let selected {
                    updateTrackingUnlocked(for: selected)
                    _isLocked = true
                    _framesSinceEstablished = lockAfterFrames
                    _consecutiveMisses = 0
                    _lastMatchConfidence = 1.0
                    _hasManualOverride = false
                    _manualOverridePoint = nil
                }
                return selected
            }
            
            // If we have a tracked person, match using multi-signal scoring
            if let trackedCentroid = _trackedCentroid, let trackedBBox = _trackedBBox {
                let matched = matchBodyPoseByScoringUnlocked(
                    trackedCentroid: trackedCentroid,
                    trackedBBox: trackedBBox,
                    from: poses,
                    frameIndex: frameIndex
                )
                if let matched {
                    updateTrackingUnlocked(for: matched)
                    _framesSinceEstablished += 1
                    if _framesSinceEstablished >= lockAfterFrames {
                        _isLocked = true
                    }
                    _consecutiveMisses = 0
                    return matched
                }
                
                // No match within threshold
                _consecutiveMisses += 1
                _lastMatchConfidence = 0.0
                if _consecutiveMisses >= reacquireAfterMisses {
                    _isLocked = false
                    _framesSinceEstablished = 0
                }
                
                if _isLocked {
                    return nil
                }
            }
            
            // Initial selection: score by centrality + size
            let selected = initialBodyPoseSelection(from: poses)
            if let selected {
                updateTrackingUnlocked(for: selected)
                _framesSinceEstablished = 1
                _consecutiveMisses = 0
                _lastMatchConfidence = poses.count == 1 ? 0.9 : 0.6
            }
            return selected
        }
    }
    
    // MARK: - BodyPose Helper Methods
    
    private func selectNearestBodyPose(to point: CGPoint, from poses: [BodyPose]) -> BodyPose? {
        var nearest: BodyPose?
        var minDist = CGFloat.infinity
        
        for pose in poses {
            guard let centerOfMass = pose.centerOfMass else { continue }
            let dist = distance(centerOfMass, point)
            if dist < minDist {
                minDist = dist
                nearest = pose
            }
        }
        
        return nearest
    }
    
    private func matchBodyPoseByScoringUnlocked(
        trackedCentroid: CGPoint,
        trackedBBox: CGRect,
        from poses: [BodyPose],
        frameIndex: Int
    ) -> BodyPose? {
        let predicted = predictedCentroid ?? trackedCentroid
        var bestScore: CGFloat = -1
        var bestPose: BodyPose?
        var bestDistRaw: CGFloat = 0
        
        for pose in poses {
            guard let bbox = pose.boundingBox,
                  let centerOfMass = pose.centerOfMass else { continue }
            
            // Distance from predicted position
            let dist = distance(centerOfMass, predicted)
            let distScore: CGFloat = max(0, 1 - (dist / matchThreshold))
            
            // Size similarity
            let sizeRatio = min(bbox.width, trackedBBox.width) / max(bbox.width, trackedBBox.width)
            let sizeScore = sizeRatio
            
            // Joint continuity (how well joints match previous positions)
            let jointScore = jointContinuityScore(for: pose)
            
            // Motion consistency
            let motionScore = motionConsistencyScore(for: centerOfMass, from: trackedCentroid)
            
            // Combined score
            let score = distanceWeight * distScore +
                        sizeSimilarityWeight * sizeScore +
                        jointContinuityWeight * jointScore +
                        motionConsistencyWeight * motionScore
            
            if score > bestScore {
                bestScore = score
                bestPose = pose
                bestDistRaw = dist
            }
        }
        
        // Confidence based on score and number of candidates
        let normalized = max(0, min(1, bestScore))
        let penaltyForMultiple = poses.count > 1 ? 0.85 : 1.0
        _lastMatchConfidence = normalized * penaltyForMultiple
        
        // Threshold: require minimum score
        guard bestScore > 0.3 else { return nil }
        
        // Additional threshold: if distance jumped too far, reject
        if bestDistRaw > matchThreshold * 1.5 {
            return nil
        }
        
        return bestPose
    }
    
    private func jointContinuityScore(for pose: BodyPose) -> CGFloat {
        guard !_trackedJoints.isEmpty else { return 0.5 }
        
        var totalDist: CGFloat = 0
        var count = 0
        
        let bodyPoseJointMapping: [VNHumanBodyPoseObservation.JointName: BodyPose.JointName] = [
            .root: .root,
            .neck: .neck,
            .leftHip: .leftHip,
            .rightHip: .rightHip,
            .leftShoulder: .leftShoulder,
            .rightShoulder: .rightShoulder
        ]
        
        for (vnJoint, bodyPoseJoint) in bodyPoseJointMapping {
            guard let trackedPoint = _trackedJoints[vnJoint],
                  let currentJoint = pose.joints[bodyPoseJoint] else { continue }
            
            let dist = distance(trackedPoint, currentJoint.point)
            totalDist += dist
            count += 1
        }
        
        guard count > 0 else { return 0.5 }
        let avgDist = totalDist / CGFloat(count)
        return max(0, 1 - (avgDist / 0.15))
    }
    
    private func motionConsistencyScore(for currentCenter: CGPoint, from previousCenter: CGPoint) -> CGFloat {
        // Check if tracker has established velocity
        let trackerSpeed = sqrt(_velocity.x * _velocity.x + _velocity.y * _velocity.y)
        
        guard trackerSpeed > 0.01 else {
            return 0.0  // No velocity established yet, don't penalize
        }
        
        // How far is this candidate from the tracker's PREVIOUS centroid?
        let distFromPrev = distance(currentCenter, previousCenter)
        
        // Expected: candidate should be ~trackerSpeed away from previous centroid
        // If candidate is very close to previous centroid, they didn't move (bystander)
        let expectedDist = trackerSpeed
        if distFromPrev < expectedDist * 0.3 {
            // Candidate barely moved from where tracker was — likely stationary bystander
            return 1.0
        } else {
            return 0.0
        }
    }
    
    private func initialBodyPoseSelection(from poses: [BodyPose]) -> BodyPose? {
        var bestScore: CGFloat = -1
        var bestPose: BodyPose?
        
        for pose in poses {
            guard let bbox = pose.boundingBox,
                  let _ = pose.centerOfMass else { continue }
            
            // Centrality: prefer people near the center of frame
            let bboxCenter = centroid(of: bbox)
            let frameCenterDist = distance(bboxCenter, CGPoint(x: 0.5, y: 0.5))
            let centralityScore = max(0, 1 - frameCenterDist)
            
            // Size: prefer larger bounding boxes (athlete is likely close to camera)
            let area = bbox.width * bbox.height
            let sizeScore = min(1, area / 0.3)
            
            let score = centralityWeight * centralityScore + sizeWeight * sizeScore
            
            if score > bestScore {
                bestScore = score
                bestPose = pose
            }
        }
        
        return bestPose
    }
    
    private func updateTrackingUnlocked(for pose: BodyPose) {
        if let bbox = pose.boundingBox,
           let centerOfMass = pose.centerOfMass {
            // Update velocity estimate
            if let prevCentroid = _trackedCentroid {
                let newVelocity = CGPoint(
                    x: centerOfMass.x - prevCentroid.x,
                    y: centerOfMass.y - prevCentroid.y
                )
                // Exponential smoothing
                let alpha: CGFloat = 0.5
                _velocity = CGPoint(
                    x: alpha * newVelocity.x + (1 - alpha) * _velocity.x,
                    y: alpha * newVelocity.y + (1 - alpha) * _velocity.y
                )
            }
            
            _previousCentroid = _trackedCentroid
            _trackedBBox = bbox
            _trackedCentroid = centerOfMass
            
            // Store individual joint positions for continuity matching
            var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
            let bodyPoseJointMapping: [BodyPose.JointName: VNHumanBodyPoseObservation.JointName] = [
                .root: .root,
                .neck: .neck,
                .leftHip: .leftHip,
                .rightHip: .rightHip,
                .leftShoulder: .leftShoulder,
                .rightShoulder: .rightShoulder
            ]
            
            for (bodyPoseJoint, vnJoint) in bodyPoseJointMapping {
                if let joint = pose.joints[bodyPoseJoint], joint.confidence > 0.1 {
                    joints[vnJoint] = joint.point
                }
            }
            _trackedJoints = joints
        }
    }
}

