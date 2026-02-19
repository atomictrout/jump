import CoreGraphics
import Foundation

/// Person tracking service that propagates athlete identity across frames.
///
/// Algorithm: bidirectional propagation from anchor frame using:
/// 1. **Skeleton shape similarity** — position-invariant comparison of relative joint offsets
/// 2. **Proximity score** — smooth exponential distance decay (not binary IoU)
/// 3. **Velocity prediction** — predicts where the athlete should be next frame
/// 4. **Anchor comparison** — every candidate is checked against the original user-selected pose
///    to prevent drift to spectators
///
/// User corrections act as hard anchors that constrain propagation.
struct PersonTracker {

    // MARK: - Configuration

    struct Config {
        var highConfidenceThreshold: Float = 0.70
        var uncertainConfidenceThreshold: Float = 0.40
        var proximityWeight: Float = 0.25    // smooth distance-based (replaces IoU)
        var shapeWeight: Float = 0.45        // position-invariant skeleton shape (primary signal)
        var velocityWeight: Float = 0.30     // velocity prediction (best for consecutive frames)
        var minMatchableJoints: Int = 3
        var minMatchScore: Float = 0.35      // raised from 0.2 — reject ambiguous matches
        var scoreGapForUncertain: Float = 0.15 // if best vs second-best within this, mark uncertain
        var anchorWeight: Float = 0.30       // blend: (1-anchorWeight)*previousMatch + anchorWeight*anchorMatch
        var minAnchorSimilarity: Float = 0.25 // below this → force uncertain

        // Velocity-gating: when athlete is moving fast, trust velocity more than shape.
        // This prevents locking onto stationary spectators during approach→flight transition.
        var highVelocityThreshold: CGFloat = 0.02   // per-frame velocity above which adaptive weighting kicks in
        var highVelocityBoost: Float = 0.25          // additional velocity weight when moving fast (taken from shape)
        var velocityConsistencyDecay: Float = 8.0    // exp decay for velocity consistency check
    }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Primary API

    /// Propagate athlete identity from an anchor frame to all other frames.
    ///
    /// - Parameters:
    ///   - anchorFrame: Frame index of the user-selected athlete.
    ///   - anchorPoseIndex: Pose index within that frame.
    ///   - allFramePoses: All detected poses per frame.
    ///   - humanRects: Optional Vision human bounding boxes per frame (top-left origin).
    ///     When provided, gap frames with a nearby human rect are marked `.unreviewedGap`
    ///     instead of `.noAthleteAuto`, signaling they're candidates for crop-and-redetect recovery.
    func propagate(
        from anchorFrame: Int,
        anchorPoseIndex: Int,
        allFramePoses: [[BodyPose]],
        humanRects: [[CGRect]]? = nil
    ) -> [Int: FrameAssignment] {
        var assignments: [Int: FrameAssignment] = [:]
        let totalFrames = allFramePoses.count

        guard anchorFrame < totalFrames,
              anchorPoseIndex < allFramePoses[anchorFrame].count else {
            return assignments
        }

        // Mark the anchor frame as user-confirmed
        assignments[anchorFrame] = .athleteConfirmed(poseIndex: anchorPoseIndex)

        let anchorPose = allFramePoses[anchorFrame][anchorPoseIndex]

        // Propagate forward from anchor
        propagateDirection(
            from: anchorFrame,
            direction: 1,
            startingPose: anchorPose,
            anchorPose: anchorPose,
            allFramePoses: allFramePoses,
            assignments: &assignments,
            humanRects: humanRects
        )

        // Propagate backward from anchor
        propagateDirection(
            from: anchorFrame,
            direction: -1,
            startingPose: anchorPose,
            anchorPose: anchorPose,
            allFramePoses: allFramePoses,
            assignments: &assignments,
            humanRects: humanRects
        )

        // Fill remaining frames as no-athlete
        for frameIndex in 0..<totalFrames {
            if assignments[frameIndex] == nil {
                assignments[frameIndex] = .noAthleteAuto
            }
        }

        // Log summary
        var tracked = 0, uncertain = 0, noAthlete = 0
        for (_, assignment) in assignments {
            switch assignment {
            case .athleteConfirmed, .athleteAuto: tracked += 1
            case .athleteUncertain: uncertain += 1
            default: noAthlete += 1
            }
        }
        print("[PersonTracker] Propagated: \(tracked) tracked, \(uncertain) uncertain, \(noAthlete) noAthlete out of \(totalFrames) frames")

        return assignments
    }

    /// Re-propagate from a user correction outward, stopping at other confirmed frames.
    func rePropagate(
        correction: FrameAssignment,
        at frameIndex: Int,
        allFramePoses: [[BodyPose]],
        existingAssignments: [Int: FrameAssignment]
    ) -> [Int: FrameAssignment] {
        var assignments = existingAssignments
        assignments[frameIndex] = correction

        if let poseIndex = correction.athletePoseIndex,
           frameIndex < allFramePoses.count,
           poseIndex < allFramePoses[frameIndex].count {

            let startPose = allFramePoses[frameIndex][poseIndex]

            // For re-propagation, use the correction pose as anchor too
            propagateDirection(
                from: frameIndex,
                direction: 1,
                startingPose: startPose,
                anchorPose: startPose,
                allFramePoses: allFramePoses,
                assignments: &assignments,
                stopAtConfirmed: true
            )

            propagateDirection(
                from: frameIndex,
                direction: -1,
                startingPose: startPose,
                anchorPose: startPose,
                allFramePoses: allFramePoses,
                assignments: &assignments,
                stopAtConfirmed: true
            )
        }

        return assignments
    }

    // MARK: - Propagation Engine

    private func propagateDirection(
        from startFrame: Int,
        direction: Int,
        startingPose: BodyPose,
        anchorPose: BodyPose,
        allFramePoses: [[BodyPose]],
        assignments: inout [Int: FrameAssignment],
        stopAtConfirmed: Bool = false,
        humanRects: [[CGRect]]? = nil
    ) {
        let totalFrames = allFramePoses.count
        var previousPose = startingPose
        var previousVelocity: CGPoint? = nil
        var smoothedSpeed: CGFloat = 0  // Exponential moving average of |velocity|
        var consecutiveLostFrames = 0
        let maxLostFrames = 30

        var frameIndex = startFrame + direction
        while frameIndex >= 0 && frameIndex < totalFrames {
            if stopAtConfirmed, let existing = assignments[frameIndex], existing.isUserConfirmed {
                break
            }

            let framePoses = allFramePoses[frameIndex]

            if framePoses.isEmpty {
                consecutiveLostFrames += 1
                if consecutiveLostFrames > maxLostFrames {
                    assignments[frameIndex] = .noAthleteAuto
                } else {
                    // Check if Vision detected a human nearby — if so, mark as recoverable gap
                    let hasNearbyHumanRect = hasNearbyHuman(
                        at: frameIndex,
                        predictedFrom: previousPose,
                        velocity: previousVelocity,
                        lostFrames: consecutiveLostFrames,
                        humanRects: humanRects
                    )
                    assignments[frameIndex] = hasNearbyHumanRect ? .unreviewedGap : .noAthleteAuto
                }
                frameIndex += direction
                continue
            }

            // After a gap, use velocity-advanced prediction for better re-matching
            let matchReference: BodyPose
            let matchVelocity: CGPoint?
            if consecutiveLostFrames > 0, let velocity = previousVelocity,
               let prevCOM = previousPose.centerOfMass {
                // Predict where the athlete should be after the gap
                let predictedCOM = CGPoint(
                    x: prevCOM.x + velocity.x * CGFloat(consecutiveLostFrames),
                    y: prevCOM.y + velocity.y * CGFloat(consecutiveLostFrames)
                )
                matchReference = shiftedPose(previousPose, to: predictedCOM)
                matchVelocity = velocity
            } else {
                matchReference = previousPose
                matchVelocity = previousVelocity
            }

            let (bestIndex, bestScore, secondBestScore) = findBestMatch(
                for: matchReference,
                anchorPose: anchorPose,
                among: framePoses,
                previousVelocity: matchVelocity,
                smoothedSpeed: smoothedSpeed
            )

            if let bestIndex, let bestScore {
                let matchedPose = framePoses[bestIndex]

                // Check anchor similarity — prevent drift to spectators
                let anchorSim = skeletonShapeSimilarity(anchorPose, matchedPose)

                // Score gap check — if best and second-best are close, mark uncertain
                let isAmbiguous = secondBestScore != nil &&
                    (bestScore - (secondBestScore ?? 0)) < config.scoreGapForUncertain

                if anchorSim < config.minAnchorSimilarity {
                    // Shape diverged too much from anchor — likely wrong person
                    assignments[frameIndex] = .noAthleteAuto
                    consecutiveLostFrames += 1
                    frameIndex += direction
                    continue
                } else if isAmbiguous || bestScore < config.uncertainConfidenceThreshold {
                    assignments[frameIndex] = .athleteUncertain(poseIndex: bestIndex, confidence: bestScore)
                } else if bestScore >= config.highConfidenceThreshold {
                    assignments[frameIndex] = .athleteAuto(poseIndex: bestIndex, confidence: bestScore)
                } else {
                    assignments[frameIndex] = .athleteUncertain(poseIndex: bestIndex, confidence: bestScore)
                }

                // Update velocity estimate and smoothed speed
                if let prevRoot = previousPose.centerOfMass,
                   let currRoot = matchedPose.centerOfMass {
                    let vel = CGPoint(
                        x: currRoot.x - prevRoot.x,
                        y: currRoot.y - prevRoot.y
                    )
                    previousVelocity = vel
                    let speed = hypot(vel.x, vel.y)
                    // Exponential moving average: 70% old + 30% new
                    smoothedSpeed = smoothedSpeed * 0.7 + speed * 0.3
                }

                previousPose = matchedPose
                consecutiveLostFrames = 0
            } else {
                assignments[frameIndex] = .noAthleteAuto
                consecutiveLostFrames += 1
            }

            if consecutiveLostFrames > maxLostFrames {
                frameIndex += direction
                while frameIndex >= 0 && frameIndex < totalFrames {
                    if !(stopAtConfirmed && (assignments[frameIndex]?.isUserConfirmed ?? false)) {
                        assignments[frameIndex] = .noAthleteAuto
                    }
                    frameIndex += direction
                }
                break
            }

            frameIndex += direction
        }
    }

    /// Create a shifted copy of a pose with all joints offset so the center of mass
    /// lands at the given predicted position. Used for re-matching after gaps.
    private func shiftedPose(_ pose: BodyPose, to predictedCOM: CGPoint) -> BodyPose {
        guard let currentCOM = pose.centerOfMass else { return pose }
        let dx = predictedCOM.x - currentCOM.x
        let dy = predictedCOM.y - currentCOM.y

        var shiftedJoints: [BodyPose.JointName: BodyPose.JointPosition] = [:]
        for (name, joint) in pose.joints {
            shiftedJoints[name] = BodyPose.JointPosition(
                point: CGPoint(x: joint.point.x + dx, y: joint.point.y + dy),
                confidence: joint.confidence
            )
        }

        return BodyPose(
            frameIndex: pose.frameIndex,
            timestamp: pose.timestamp,
            joints: shiftedJoints
        )
    }

    // MARK: - Vision Human Rect Helpers

    /// Check if a Vision human rectangle exists near the predicted athlete position.
    private func hasNearbyHuman(
        at frameIndex: Int,
        predictedFrom previousPose: BodyPose,
        velocity: CGPoint?,
        lostFrames: Int,
        humanRects: [[CGRect]]?
    ) -> Bool {
        guard let humanRects = humanRects,
              frameIndex < humanRects.count,
              !humanRects[frameIndex].isEmpty else { return false }

        guard let prevCOM = previousPose.centerOfMass else { return false }

        let predictedCenter: CGPoint
        if let vel = velocity {
            predictedCenter = CGPoint(
                x: prevCOM.x + vel.x * CGFloat(lostFrames),
                y: prevCOM.y + vel.y * CGFloat(lostFrames)
            )
        } else {
            predictedCenter = prevCOM
        }

        // Dynamic threshold: widens as more frames are lost
        let baseThreshold: CGFloat = 0.20
        let perFrameExpansion: CGFloat = 0.02
        let threshold = min(baseThreshold + perFrameExpansion * CGFloat(lostFrames), 0.45)

        for rect in humanRects[frameIndex] {
            let rectCenter = CGPoint(x: rect.midX, y: rect.midY)
            let distance = hypot(rectCenter.x - predictedCenter.x, rectCenter.y - predictedCenter.y)
            if distance < threshold {
                return true
            }
        }

        return false
    }

    // MARK: - Matching

    /// Find the best matching pose among candidates.
    ///
    /// Returns (bestIndex, bestScore, secondBestScore) — secondBestScore is used for
    /// the score gap check to detect ambiguous frames.
    ///
    /// When the athlete is moving fast (`smoothedSpeed` > threshold), velocity matching
    /// is boosted and shape matching is reduced. This prevents locking onto stationary
    /// spectators during approach→flight transition.
    private func findBestMatch(
        for reference: BodyPose,
        anchorPose: BodyPose,
        among candidates: [BodyPose],
        previousVelocity: CGPoint?,
        smoothedSpeed: CGFloat = 0
    ) -> (Int?, Float?, Float?) {
        guard !candidates.isEmpty else { return (nil, nil, nil) }

        // Adaptive weighting: when the athlete is moving fast, trust velocity more than shape.
        // A running athlete should never be matched to a stationary spectator.
        let isHighVelocity = smoothedSpeed > config.highVelocityThreshold && previousVelocity != nil
        let velocityBoost: Float = isHighVelocity ? config.highVelocityBoost : 0

        var bestIndex: Int?
        var bestScore: Float = 0
        var secondBestScore: Float = 0

        for (index, candidate) in candidates.enumerated() {
            let previousMatchScore = matchScore(
                reference: reference,
                candidate: candidate,
                velocity: previousVelocity,
                velocityBoost: velocityBoost
            )

            // During high velocity, reduce anchor weight — the athlete's shape is changing
            // (transitioning from running to jumping), so anchor comparison is less reliable
            let effectiveAnchorWeight = isHighVelocity
                ? config.anchorWeight * 0.5  // halve anchor influence when moving fast
                : config.anchorWeight

            // Blend with anchor comparison to prevent drift
            let anchorMatchScore = matchScore(
                reference: anchorPose,
                candidate: candidate,
                velocity: nil,  // No velocity relative to anchor
                velocityBoost: 0
            )

            let combinedScore = (1.0 - effectiveAnchorWeight) * previousMatchScore + effectiveAnchorWeight * anchorMatchScore

            if combinedScore > bestScore {
                secondBestScore = bestScore
                bestScore = combinedScore
                bestIndex = index
            } else if combinedScore > secondBestScore {
                secondBestScore = combinedScore
            }
        }

        guard bestScore > config.minMatchScore else { return (nil, nil, nil) }
        return (bestIndex, bestScore, candidates.count > 1 ? secondBestScore : nil)
    }

    private func matchScore(
        reference: BodyPose,
        candidate: BodyPose,
        velocity: CGPoint?,
        velocityBoost: Float = 0
    ) -> Float {
        var totalScore: Float = 0

        let proxScore = proximityScore(reference, candidate)
        totalScore += config.proximityWeight * proxScore

        let shapeScore = skeletonShapeSimilarity(reference, candidate)
        // When velocity boost is active, reduce shape weight (athlete's shape is changing during jump)
        totalScore += (config.shapeWeight - velocityBoost) * shapeScore

        if let velocity {
            let velScore = velocityMatchScore(reference, candidate, velocity: velocity)
            // When velocity boost is active, increase velocity weight
            totalScore += (config.velocityWeight + velocityBoost) * velScore

            // Velocity consistency penalty: if the athlete was moving fast but this candidate
            // implies they suddenly stopped, penalize heavily. A spectator standing still near
            // the bar scores near 0 on velocity, and this penalty makes the combined score
            // low enough to reject them.
            if velocityBoost > 0 {
                let speed = hypot(velocity.x, velocity.y)
                if speed > 0.01, let refCOM = reference.centerOfMass, let candCOM = candidate.centerOfMass {
                    let impliedVelocity = CGPoint(x: candCOM.x - refCOM.x, y: candCOM.y - refCOM.y)
                    let impliedSpeed = hypot(impliedVelocity.x, impliedVelocity.y)
                    let speedRatio = impliedSpeed / speed
                    // If candidate implies < 20% of expected speed, apply penalty
                    if speedRatio < 0.2 {
                        let penalty = velocityBoost * 0.5  // knock off up to half the boost as penalty
                        totalScore -= penalty
                    }
                }
            }
        } else {
            // Redistribute velocity weight to shape (most reliable without velocity)
            let redistributed = config.velocityWeight
            totalScore += redistributed * shapeScore
        }

        return max(0, totalScore)
    }

    // MARK: - Matching Components

    /// Smooth proximity score based on distance between centers of mass.
    ///
    /// Uses exponential decay: exp(-distance * 5.0)
    /// - 0.0 distance → 1.0
    /// - 0.1 distance → 0.61
    /// - 0.2 distance → 0.37
    /// - 0.5 distance → 0.08
    private func proximityScore(_ a: BodyPose, _ b: BodyPose) -> Float {
        guard let comA = a.centerOfMass, let comB = b.centerOfMass else { return 0 }
        let distance = hypot(comA.x - comB.x, comA.y - comB.y)
        return Float(exp(-Double(distance) * 5.0))
    }

    /// Position-invariant skeleton shape similarity.
    ///
    /// Compares relative joint offsets (from center of mass), normalized by skeleton scale.
    /// Two people at different positions but similar body configurations score high.
    /// Two people in different poses (one running, one standing) score low.
    private func skeletonShapeSimilarity(_ a: BodyPose, _ b: BodyPose) -> Float {
        let keyJoints: [BodyPose.JointName] = [
            .leftShoulder, .rightShoulder, .leftHip, .rightHip,
            .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
            .leftElbow, .rightElbow, .leftWrist, .rightWrist
        ]

        guard let comA = a.centerOfMass, let comB = b.centerOfMass else { return 0 }

        // Scale = bounding box diagonal (for normalization)
        let scaleA = a.boundingBox.map { hypot($0.width, $0.height) } ?? 0.3
        let scaleB = b.boundingBox.map { hypot($0.width, $0.height) } ?? 0.3

        var totalSimilarity: CGFloat = 0
        var matchedJoints = 0

        for joint in keyJoints {
            guard let jA = a.joints[joint], jA.confidence > 0.2,
                  let jB = b.joints[joint], jB.confidence > 0.2 else { continue }

            // Relative offset from center of mass, normalized by skeleton scale
            let relA = CGPoint(
                x: (jA.point.x - comA.x) / max(scaleA, 0.01),
                y: (jA.point.y - comA.y) / max(scaleA, 0.01)
            )
            let relB = CGPoint(
                x: (jB.point.x - comB.x) / max(scaleB, 0.01),
                y: (jB.point.y - comB.y) / max(scaleB, 0.01)
            )

            let diff = hypot(relA.x - relB.x, relA.y - relB.y)
            // Softer decay: 1.0 at diff=0, 0.0 at diff=0.5
            let sim = max(0, 1.0 - diff * 2.0)
            totalSimilarity += sim
            matchedJoints += 1
        }

        guard matchedJoints >= config.minMatchableJoints else { return 0 }
        return Float(totalSimilarity / CGFloat(matchedJoints))
    }

    /// Velocity-based match score: how close is the candidate to where velocity predicts?
    private func velocityMatchScore(_ reference: BodyPose, _ candidate: BodyPose, velocity: CGPoint) -> Float {
        guard let refRoot = reference.centerOfMass,
              let candRoot = candidate.centerOfMass else { return 0.5 }

        let predicted = CGPoint(
            x: refRoot.x + velocity.x,
            y: refRoot.y + velocity.y
        )

        let distanceToPredicted = hypot(predicted.x - candRoot.x, predicted.y - candRoot.y)
        // Softer decay than the old *15.0 — score = exp(-distance * 8.0)
        return Float(exp(-Double(distanceToPredicted) * 8.0))
    }

    // MARK: - Summary

    static func summary(
        assignments: [Int: FrameAssignment],
        totalFrames: Int
    ) -> TrackingSummary {
        var tracked = 0
        var uncertain = 0
        var noAthlete = 0
        var gaps = 0

        for frameIndex in 0..<totalFrames {
            switch assignments[frameIndex] {
            case .athleteConfirmed, .athleteAuto:
                tracked += 1
            case .athleteUncertain:
                uncertain += 1
            case .noAthleteConfirmed, .noAthleteAuto:
                noAthlete += 1
            case .unreviewedGap, .athleteNoPose:
                gaps += 1
            case nil:
                noAthlete += 1
            }
        }

        return TrackingSummary(
            totalFrames: totalFrames,
            trackedFrames: tracked,
            uncertainFrames: uncertain,
            noAthleteFrames: noAthlete,
            gapFrames: gaps
        )
    }
}

// MARK: - Tracking Summary

struct TrackingSummary: Sendable {
    let totalFrames: Int
    let trackedFrames: Int
    let uncertainFrames: Int
    let noAthleteFrames: Int
    let gapFrames: Int

    var framesNeedingReview: Int { uncertainFrames + gapFrames }
    var trackingPercentage: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(trackedFrames) / Double(totalFrames) * 100
    }
}
