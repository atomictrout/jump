import CoreGraphics
import Foundation

/// Core analysis engine that computes all biomechanical metrics,
/// detects errors, and generates coaching recommendations.
struct AnalysisEngine {

    /// Run full analysis on a jump session.
    func analyze(
        session: JumpSession,
        allFramePoses: [[BodyPose]],
        assignments: [Int: FrameAssignment],
        phases: [JumpPhase],
        calibration: ScaleCalibration?,
        sex: COMCalculator.Sex = .male
    ) -> AnalysisResult {
        // Extract athlete poses per frame
        let athletePoses = extractAthletePoses(allFramePoses: allFramePoses, assignments: assignments)

        // Detect key frames
        let classifier = PhaseClassifier()
        let keyFrames = classifier.detectKeyFrames(poses: athletePoses, frameRate: session.frameRate)

        // Compute COM per frame
        let comPositions = computeCOMTrajectory(poses: athletePoses, sex: sex)

        // Compute measurements
        var measurements = computeMeasurements(
            athletePoses: athletePoses,
            phases: phases,
            keyFrames: keyFrames,
            comPositions: comPositions,
            frameRate: session.frameRate,
            calibration: calibration
        )

        // Set bar info
        measurements.barHeightMeters = session.barHeightMeters
        measurements.cameraAngle = calibration?.cameraAngle

        // Detect errors
        let errors = detectErrors(measurements: measurements, keyFrames: keyFrames, phases: phases)

        // Generate recommendations
        let recommendations = generateRecommendations(errors: errors)

        // Build phase list
        let detectedPhases = buildDetectedPhases(phases: phases, keyFrames: keyFrames)

        // Generate coaching insights
        let insights = generateCoachingInsights(measurements: measurements, errors: errors, keyFrames: keyFrames)

        // Compute clearance profile at bar crossing
        let clearanceProfile = computeClearanceProfile(
            athletePoses: athletePoses,
            keyFrames: keyFrames,
            calibration: calibration
        )

        return AnalysisResult(
            phases: detectedPhases,
            measurements: measurements,
            errors: errors,
            recommendations: recommendations,
            coachingInsights: insights,
            keyFrames: keyFrames,
            clearanceProfile: clearanceProfile
        )
    }

    // MARK: - Athlete Pose Extraction

    private func extractAthletePoses(
        allFramePoses: [[BodyPose]],
        assignments: [Int: FrameAssignment]
    ) -> [BodyPose?] {
        var result: [BodyPose?] = Array(repeating: nil, count: allFramePoses.count)

        for (frameIndex, framePoses) in allFramePoses.enumerated() {
            if let assignment = assignments[frameIndex],
               let poseIndex = assignment.athletePoseIndex,
               poseIndex < framePoses.count {
                result[frameIndex] = framePoses[poseIndex]
            }
        }

        return result
    }

    // MARK: - COM Trajectory

    private func computeCOMTrajectory(
        poses: [BodyPose?],
        sex: COMCalculator.Sex
    ) -> [Int: CGPoint] {
        var comPositions: [Int: CGPoint] = [:]
        for (i, pose) in poses.enumerated() {
            if let pose, let com = COMCalculator.calculateCOM(pose: pose, sex: sex) {
                comPositions[i] = com
            }
        }
        return comPositions
    }

    // MARK: - Measurements

    private func computeMeasurements(
        athletePoses: [BodyPose?],
        phases: [JumpPhase],
        keyFrames: AnalysisResult.KeyFrames,
        comPositions: [Int: CGPoint],
        frameRate: Double,
        calibration: ScaleCalibration?
    ) -> JumpMeasurements {
        var m = JumpMeasurements()

        // Takeoff metrics
        if let plantFrame = keyFrames.takeoffPlant,
           let plantPose = athletePoses[safe: plantFrame] as? BodyPose {

            // Takeoff leg knee at plant
            m.takeoffLegKneeAtPlant = plantPose.angle(from: .leftHip, vertex: .leftKnee, to: .leftAnkle)
                ?? plantPose.angle(from: .rightHip, vertex: .rightKnee, to: .rightAnkle)

            // Ankle angle at plant (knee → ankle → foot_index)
            m.ankleAngleAtPlant = plantPose.angle(from: .leftKnee, vertex: .leftAnkle, to: .leftFootIndex)
                ?? plantPose.angle(from: .rightKnee, vertex: .rightAnkle, to: .rightFootIndex)

            // Drive knee angle
            m.driveKneeAngleAtTakeoff = plantPose.angle(from: .rightHip, vertex: .rightKnee, to: .rightAnkle)
                ?? plantPose.angle(from: .leftHip, vertex: .leftKnee, to: .leftAnkle)

            // Hip-shoulder separation at TD
            if let ls = plantPose.jointPoint(.leftShoulder),
               let rs = plantPose.jointPoint(.rightShoulder),
               let lh = plantPose.jointPoint(.leftHip),
               let rh = plantPose.jointPoint(.rightHip) {
                m.hipShoulderSeparationAtTD = AngleCalculator.hipShoulderSeparation(
                    leftShoulder: ls, rightShoulder: rs,
                    leftHip: lh, rightHip: rh
                )
            }
        }

        // Toe-off metrics
        if let toeOffFrame = keyFrames.toeOff,
           let toeOffPose = athletePoses[safe: toeOffFrame] as? BodyPose {

            m.takeoffLegKneeAtToeOff = toeOffPose.angle(from: .leftHip, vertex: .leftKnee, to: .leftAnkle)
                ?? toeOffPose.angle(from: .rightHip, vertex: .rightKnee, to: .rightAnkle)

            m.anklePlantarflexionAtToeOff = toeOffPose.angle(from: .leftKnee, vertex: .leftAnkle, to: .leftFootIndex)
                ?? toeOffPose.angle(from: .rightKnee, vertex: .rightAnkle, to: .rightFootIndex)
        }

        // Ground contact time
        if let plant = keyFrames.takeoffPlant, let toeOff = keyFrames.toeOff {
            m.groundContactTime = Double(toeOff - plant) / frameRate
        }

        // Takeoff angle (COM trajectory)
        if let toeOff = keyFrames.toeOff,
           let comAtToeOff = comPositions[toeOff],
           let comBefore = comPositions[max(0, toeOff - 2)] {
            let dx = comAtToeOff.x - comBefore.x
            let dy = comBefore.y - comAtToeOff.y  // Invert Y for "up" direction
            if abs(dx) > 0.001 {
                m.takeoffAngle = atan2(Double(dy), Double(abs(dx))) * 180.0 / .pi
            }
        }

        // Peak metrics
        if let peakFrame = keyFrames.peakHeight,
           let peakPose = athletePoses[safe: peakFrame] as? BodyPose {

            // Back tilt angle at peak (neck-to-hip vs horizontal)
            if let neck = peakPose.jointPoint(.neck),
               let root = peakPose.jointPoint(.root) {
                let dx = Double(root.x - neck.x)
                let dy = Double(root.y - neck.y)
                m.backTiltAngleAtPeak = atan2(dy, dx) * 180.0 / .pi
            }
        }

        // COM heights for H1/H2/H3
        if let toeOff = keyFrames.toeOff,
           let peakFrame = keyFrames.peakHeight,
           let comToeOff = comPositions[toeOff],
           let comPeak = comPositions[peakFrame],
           let calibration {

            let h1Normalized = calibration.groundY - Double(comToeOff.y)
            let h2Normalized = Double(comToeOff.y) - Double(comPeak.y)  // Rise = decrease in Y

            m.h1 = h1Normalized / calibration.pixelsPerMeter
            m.h2 = h2Normalized / calibration.pixelsPerMeter
            if let barHeight = calibration.barHeightMeters as Double?,
               let h1 = m.h1, let h2 = m.h2 {
                m.h3 = barHeight - h1 - h2
            }

            m.comHeightAtToeOff = m.h1
            m.peakCOMHeight = (calibration.groundY - Double(comPeak.y)) / calibration.pixelsPerMeter

            // COM rise
            m.comRise = m.h2

            // Vertical velocity at toe-off (from COM displacement)
            if toeOff > 0, let comPrev = comPositions[toeOff - 1] {
                let dyNorm = Double(comPrev.y - comToeOff.y)  // Positive = moving up
                let dtSeconds = 1.0 / frameRate
                let dyMeters = dyNorm / calibration.pixelsPerMeter
                m.verticalVelocityAtToeOff = dyMeters / dtSeconds
            }
        }

        // Flight time
        if let toeOff = keyFrames.toeOff, let landing = keyFrames.landing {
            m.flightTime = Double(landing - toeOff) / frameRate
        }

        return m
    }

    // MARK: - Error Detection

    private func detectErrors(
        measurements: JumpMeasurements,
        keyFrames: AnalysisResult.KeyFrames,
        phases: [JumpPhase]
    ) -> [DetectedError] {
        var errors: [DetectedError] = []

        let plantFrame = keyFrames.takeoffPlant ?? 0
        let toeOffFrame = keyFrames.toeOff ?? 0
        let peakFrame = keyFrames.peakHeight ?? 0

        // Takeoff leg knee at plant
        if let knee = measurements.takeoffLegKneeAtPlant {
            if knee < 155 {
                errors.append(DetectedError(
                    type: .improperTakeoffAngle,
                    frameRange: plantFrame...plantFrame,
                    severity: .major,
                    description: String(format: "Takeoff leg too bent at plant (%.0f\u{00B0}, ideal 160-175\u{00B0})", knee)
                ))
            }
        }

        // Drive knee too extended
        if let driveKnee = measurements.driveKneeAngleAtTakeoff, driveKnee > 120 {
            errors.append(DetectedError(
                type: .extendedBodyPosition,
                frameRange: plantFrame...toeOffFrame,
                severity: .major,
                description: String(format: "Drive knee too extended (%.0f\u{00B0}, ideal 70-90\u{00B0})", driveKnee)
            ))
        }

        // Ground contact too long
        if let gct = measurements.groundContactTime, gct > 0.19 {
            errors.append(DetectedError(
                type: .longGroundContact,
                frameRange: plantFrame...toeOffFrame,
                severity: .minor,
                description: String(format: "Ground contact time %.3fs (ideal <0.17s)", gct)
            ))
        }

        // Takeoff distance
        if let dist = measurements.takeoffDistanceFromBar {
            if dist < 0.8 {
                errors.append(DetectedError(
                    type: .tooCloseToBar,
                    frameRange: plantFrame...plantFrame,
                    severity: .moderate,
                    description: String(format: "Takeoff %.1fm from bar (too close, ideal 1.0-1.2m)", dist)
                ))
            } else if dist > 1.4 {
                errors.append(DetectedError(
                    type: .tooFarFromBar,
                    frameRange: plantFrame...plantFrame,
                    severity: .moderate,
                    description: String(format: "Takeoff %.1fm from bar (too far, ideal 1.0-1.2m)", dist)
                ))
            }
        }

        // Back tilt at peak (hammock)
        if let backTilt = measurements.backTiltAngleAtPeak, backTilt > 160 {
            errors.append(DetectedError(
                type: .hammockPosition,
                frameRange: peakFrame...peakFrame,
                severity: .major,
                description: "Hammock position detected — body too flat over bar"
            ))
        }

        // Bar knock
        if measurements.barKnocked, let knockFrame = measurements.barKnockFrame {
            errors.append(DetectedError(
                type: .barKnock,
                frameRange: knockFrame...knockFrame,
                severity: .major,
                description: "Bar knocked by \(measurements.barKnockBodyPart ?? "unknown body part")"
            ))
        }

        return errors.sorted { $0.severity > $1.severity }
    }

    // MARK: - Recommendations

    private func generateRecommendations(errors: [DetectedError]) -> [Recommendation] {
        var recs: [Recommendation] = []

        for (index, error) in errors.prefix(5).enumerated() {
            let (title, detail) = recommendationForError(error.type)
            recs.append(Recommendation(
                title: title,
                detail: detail,
                relatedError: error.type,
                priority: index + 1,
                phase: error.type.phase
            ))
        }

        if errors.isEmpty {
            recs.append(Recommendation(
                title: "Good Jump!",
                detail: "No major errors detected. Focus on consistency and incremental improvements.",
                priority: 1
            ))
        }

        return recs
    }

    private func recommendationForError(_ type: DetectedError.ErrorType) -> (String, String) {
        switch type {
        case .improperTakeoffAngle:
            return ("Stiffen Your Plant Leg", "Drive into the ground with a straighter takeoff leg (160-175\u{00B0}). Practice penultimate pop-ups focusing on extending through the knee.")
        case .extendedBodyPosition:
            return ("Drive Your Knee Higher", "Keep the drive knee tight (70-90\u{00B0}) and punch it upward. A loose drive knee reduces jump height.")
        case .longGroundContact:
            return ("Faster Takeoff", "Spend less time on the ground. Practice quick-contact penultimate drills.")
        case .tooCloseToBar:
            return ("Move Your Takeoff Back", "Start your plant foot further from the bar (~1.0-1.2m). Mark your takeoff spot in practice.")
        case .tooFarFromBar:
            return ("Move Your Takeoff Closer", "Your takeoff is too far from the bar. Shorten your last step slightly.")
        case .hammockPosition:
            return ("Improve Your Arch", "Drive hips up over the bar. Think 'hips to the sky' at the peak. Your back should arch, not flatten.")
        case .barKnock:
            return ("Address Bar Contact", "Review the contact frame to identify the cause — most bar knocks come from approach/curve issues, not clearance technique.")
        case .flatteningCurve:
            return ("Tighten Your Curve", "Your approach angle is too shallow. Run a tighter J-curve to build rotation for bar clearance.")
        case .cuttingCurve:
            return ("Widen Your Curve", "Your approach angle is too steep. A gentler curve gives you more time to build speed.")
        case .earlyHeadDrop:
            return ("Keep Your Head Up", "Don't drop your head until your hips clear the bar. Early head drop pulls your legs into the bar.")
        default:
            return ("Review Technique", "Check the flagged frames for areas to improve.")
        }
    }

    // MARK: - Phase Building

    private func buildDetectedPhases(phases: [JumpPhase], keyFrames: AnalysisResult.KeyFrames) -> [DetectedPhase] {
        var result: [DetectedPhase] = []
        guard !phases.isEmpty else { return result }

        var currentPhase = phases[0]
        var startFrame = 0

        for (i, phase) in phases.enumerated() {
            if phase != currentPhase || i == phases.count - 1 {
                let endFrame = (i == phases.count - 1) ? i : i - 1
                if currentPhase != .noAthlete {
                    result.append(DetectedPhase(
                        phase: currentPhase,
                        startFrame: startFrame,
                        endFrame: endFrame,
                        keyMetrics: [:]
                    ))
                }
                currentPhase = phase
                startFrame = i
            }
        }

        return result
    }

    // MARK: - Clearance Profile

    private func computeClearanceProfile(
        athletePoses: [BodyPose?],
        keyFrames: AnalysisResult.KeyFrames,
        calibration: ScaleCalibration?
    ) -> ClearanceProfile? {
        // Use bar crossing frame (or peak height as fallback)
        guard let crossingFrame = keyFrames.barCrossing ?? keyFrames.peakHeight,
              crossingFrame < athletePoses.count,
              let pose = athletePoses[crossingFrame],
              let calibration else { return nil }

        let barY = (calibration.barEndpoint1.y + calibration.barEndpoint2.y) / 2

        let bodyPartJoints: [(String, [BodyPose.JointName])] = [
            ("Head", [.nose]),
            ("Shoulders", [.leftShoulder, .rightShoulder]),
            ("Hips", [.leftHip, .rightHip]),
            ("Knees", [.leftKnee, .rightKnee]),
            ("Feet", [.leftAnkle, .rightAnkle]),
        ]

        var clearances: [String: Double] = [:]

        for (partName, joints) in bodyPartJoints {
            let jointYs = joints.compactMap { pose.joints[$0]?.point.y }
            guard !jointYs.isEmpty else { continue }
            let avgY = jointYs.reduce(0.0) { $0 + Double($1) } / Double(jointYs.count)

            // In normalized coords (top-left origin): lower Y = higher position.
            // barY is bar's normalized Y. If avgY < barY, body part is above bar.
            let normalizedDistance = barY - avgY
            let metersDistance = calibration.normalizedToMeters(CGFloat(normalizedDistance))
            clearances[partName] = metersDistance
        }

        guard !clearances.isEmpty else { return nil }
        return ClearanceProfile(partClearances: clearances)
    }

    // MARK: - Coaching Insights

    private func generateCoachingInsights(
        measurements: JumpMeasurements,
        errors: [DetectedError],
        keyFrames: AnalysisResult.KeyFrames
    ) -> [CoachingInsight] {
        var insights: [CoachingInsight] = []

        // "Is my takeoff leg straight enough?"
        if let knee = measurements.takeoffLegKneeAtPlant {
            let status = knee >= 160 && knee <= 175 ? "Yes" : "Needs work"
            insights.append(CoachingInsight(
                question: "Is my takeoff leg straight enough?",
                answer: "\(status) — your plant knee angle is \(String(format: "%.0f\u{00B0}", knee)) (ideal: 160-175\u{00B0}).",
                phase: .takeoff,
                relatedFrameIndex: keyFrames.takeoffPlant,
                metric: String(format: "%.0f\u{00B0}", knee)
            ))
        }

        // "Am I getting full extension?"
        if let toeOffKnee = measurements.takeoffLegKneeAtToeOff {
            let status = toeOffKnee >= 165 ? "Good extension" : "Incomplete extension"
            insights.append(CoachingInsight(
                question: "Am I getting full extension?",
                answer: "\(status) — knee at toe-off is \(String(format: "%.0f\u{00B0}", toeOffKnee)) (ideal: ~170\u{00B0}).",
                phase: .takeoff,
                relatedFrameIndex: keyFrames.toeOff,
                metric: String(format: "%.0f\u{00B0}", toeOffKnee)
            ))
        }

        // "What should I work on most?"
        if let topError = errors.first {
            insights.append(CoachingInsight(
                question: "What should I work on most?",
                answer: topError.description,
                phase: topError.type.phase,
                relatedFrameIndex: topError.frameRange.lowerBound,
                metric: topError.severity.label
            ))
        }

        return insights
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
