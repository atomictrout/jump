import CoreGraphics
import Foundation

/// Classifies video frames into jump phases based on athlete pose data.
///
/// Uses COM trajectory, foot contact detection, and velocity analysis
/// to detect phase boundaries.
struct PhaseClassifier {

    /// Classify all frames into jump phases.
    ///
    /// - Parameters:
    ///   - athletePoses: Array indexed by frame. nil = no athlete in frame.
    ///   - frameRate: Video frame rate (for timing calculations).
    /// - Returns: Array of JumpPhase per frame.
    func classify(
        athletePoses: [BodyPose?],
        frameRate: Double
    ) -> [JumpPhase] {
        let totalFrames = athletePoses.count
        guard totalFrames > 0 else { return [] }

        var phases = [JumpPhase](repeating: .noAthlete, count: totalFrames)

        // Step 1: Mark frames with no athlete
        for i in 0..<totalFrames {
            if athletePoses[i] != nil {
                phases[i] = .approach  // Default active phase; will be refined
            }
        }

        // Step 2: Detect key frames
        let keyFrames = detectKeyFrames(poses: athletePoses, frameRate: frameRate)

        // Step 3: Assign phases based on key frames
        assignPhases(phases: &phases, keyFrames: keyFrames, totalFrames: totalFrames, poses: athletePoses)

        return phases
    }

    /// Detect key transition frames.
    func detectKeyFrames(
        poses: [BodyPose?],
        frameRate: Double
    ) -> AnalysisResult.KeyFrames {
        var keyFrames = AnalysisResult.KeyFrames()

        // Find first and last athlete frames
        keyFrames.firstAthleteFrame = poses.firstIndex(where: { $0 != nil })
        let lastAthleteFrame = poses.lastIndex(where: { $0 != nil })

        guard let firstFrame = keyFrames.firstAthleteFrame,
              let lastFrame = lastAthleteFrame,
              firstFrame < lastFrame else {
            return keyFrames
        }

        // Compute COM Y trajectory for athlete frames
        let comTrajectory = computeCOMTrajectory(poses: poses, range: firstFrame...lastFrame)

        // Find peak height (minimum Y in top-left coords = highest point)
        if let peakEntry = comTrajectory.min(by: { $0.value < $1.value }) {
            keyFrames.peakHeight = peakEntry.key
        }

        // Find takeoff: last frame before peak where foot is at ground level
        if let peakFrame = keyFrames.peakHeight {
            keyFrames.toeOff = detectToeOff(poses: poses, beforeFrame: peakFrame)
            keyFrames.takeoffPlant = detectPlant(poses: poses, toeOffFrame: keyFrames.toeOff, frameRate: frameRate)
        }

        // Find landing: first frame after peak where COM drops significantly
        if let peakFrame = keyFrames.peakHeight {
            keyFrames.landing = detectLanding(poses: poses, afterFrame: peakFrame, comTrajectory: comTrajectory)
        }

        // Find penultimate: frame before takeoff with deepest COM
        if let plantFrame = keyFrames.takeoffPlant {
            keyFrames.penultimateContact = detectPenultimate(poses: poses, beforeFrame: plantFrame, comTrajectory: comTrajectory)
        }

        return keyFrames
    }

    // MARK: - Key Frame Detection

    private func computeCOMTrajectory(poses: [BodyPose?], range: ClosedRange<Int>) -> [Int: CGFloat] {
        var trajectory: [Int: CGFloat] = [:]
        for i in range {
            if let pose = poses[i], let com = pose.centerOfMass {
                trajectory[i] = com.y
            }
        }
        return trajectory
    }

    private func detectToeOff(poses: [BodyPose?], beforeFrame peak: Int) -> Int? {
        // Walk backward from peak to find last frame with foot near ground
        // Ground level = maximum Y value of feet across approach frames
        var maxFootY: CGFloat = 0
        for i in 0..<min(peak, poses.count) {
            if let footY = poses[i]?.lowestFootY {
                maxFootY = max(maxFootY, footY)
            }
        }

        let groundThreshold = maxFootY - 0.02  // Small margin above ground

        // Walk backward from peak
        for i in stride(from: min(peak, poses.count - 1), through: 0, by: -1) {
            guard let pose = poses[i],
                  let footY = pose.lowestFootY else { continue }

            if footY >= groundThreshold {
                return i  // Last frame with feet on ground
            }
        }
        return nil
    }

    private func detectPlant(poses: [BodyPose?], toeOffFrame: Int?, frameRate: Double) -> Int? {
        guard let toeOff = toeOffFrame else { return nil }

        // Plant is typically 0.16-0.17s before toe-off
        let contactFrames = Int(0.20 * frameRate)  // Look back ~200ms
        let searchStart = max(0, toeOff - contactFrames)

        // Find the frame where heel Y is at its maximum (deepest contact)
        var bestFrame = toeOff
        var maxHeelY: CGFloat = 0

        for i in searchStart...toeOff {
            guard let pose = poses[i] else { continue }
            let heelJoints: [BodyPose.JointName] = [.leftHeel, .rightHeel]
            for joint in heelJoints {
                if let heel = pose.joints[joint], heel.confidence > 0.3 {
                    if heel.point.y > maxHeelY {
                        maxHeelY = heel.point.y
                        bestFrame = i
                    }
                }
            }
        }

        return bestFrame
    }

    private func detectLanding(
        poses: [BodyPose?],
        afterFrame peak: Int,
        comTrajectory: [Int: CGFloat]
    ) -> Int? {
        guard peak < poses.count - 1 else { return nil }

        let peakY = comTrajectory[peak] ?? 0

        // Walk forward from peak to find significant COM drop
        for i in (peak + 1)..<poses.count {
            if let comY = comTrajectory[i] {
                // In top-left coords, landing = COM Y increases significantly
                if comY > peakY + 0.08 {  // ~8% of frame height drop
                    return i
                }
            }
        }

        return nil
    }

    private func detectPenultimate(
        poses: [BodyPose?],
        beforeFrame plant: Int,
        comTrajectory: [Int: CGFloat]
    ) -> Int? {
        // Search backward from plant for the frame with deepest COM (highest Y in top-left)
        let searchRange = max(0, plant - 30)...max(0, plant - 2)
        var deepestFrame: Int?
        var deepestY: CGFloat = 0

        for i in searchRange {
            if let comY = comTrajectory[i], comY > deepestY {
                deepestY = comY
                deepestFrame = i
            }
        }

        return deepestFrame
    }

    // MARK: - Phase Assignment

    private func assignPhases(
        phases: inout [JumpPhase],
        keyFrames: AnalysisResult.KeyFrames,
        totalFrames: Int,
        poses: [BodyPose?]
    ) {
        let penultimate = keyFrames.penultimateContact
        let plant = keyFrames.takeoffPlant
        let toeOff = keyFrames.toeOff
        let peak = keyFrames.peakHeight
        let landing = keyFrames.landing

        for i in 0..<totalFrames {
            // Determine the phase for this frame based on key frame boundaries
            let phase: JumpPhase
            if let landingFrame = landing, i >= landingFrame {
                phase = .landing
            } else if let peakFrame = peak, let toeOffFrame = toeOff, i > toeOffFrame && i <= peakFrame {
                phase = .flight
            } else if let peakFrame = peak, let landingFrame = landing, i > peakFrame && i < landingFrame {
                phase = .flight
            } else if let plantFrame = plant, let toeOffFrame = toeOff, i >= plantFrame && i <= toeOffFrame {
                phase = .takeoff
            } else if let penultimateFrame = penultimate, let plantFrame = plant, i >= penultimateFrame && i < plantFrame {
                phase = .penultimate
            } else if let firstFrame = keyFrames.firstAthleteFrame, i >= firstFrame {
                phase = .approach
            } else {
                phase = .noAthlete
            }

            if poses[i] != nil {
                // Frame has a valid pose — assign the computed phase
                phases[i] = phase
            } else if phase == .flight {
                // During flight, maintain the flight phase even through detection gaps.
                // The athlete is clearly airborne; missing detection is a tracking issue,
                // not evidence of absence.
                phases[i] = .flight
            } else {
                phases[i] = .noAthlete
            }
        }
    }
}
