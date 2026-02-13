import CoreGraphics
import Foundation

struct AnalysisEngine {

    // MARK: - Main Analysis Entry Point

    static func analyze(
        poses: [BodyPose],
        bar: BarDetectionResult?,
        barHeightMeters: Double? = nil,
        frameRate: Double
    ) -> AnalysisResult {
        guard !poses.isEmpty else {
            return AnalysisResult(
                phases: [],
                measurements: JumpMeasurements(),
                errors: [],
                recommendations: [
                    Recommendation(
                        id: UUID(),
                        title: "No Pose Data",
                        detail: "Process the video first to detect body poses.",
                        relatedError: nil,
                        priority: 1
                    )
                ]
            )
        }

        // 1. Smooth pose data
        let smoothedPoses = smoothPoses(poses)

        // 2. Find key frames
        let takeoffFrame = findTakeoffFrame(poses: smoothedPoses)
        let landingFrame = findLandingFrame(poses: smoothedPoses, after: takeoffFrame)
        let penultimateFrame = findPenultimateStep(poses: smoothedPoses, before: takeoffFrame)
        let peakFrame = findPeakFrame(poses: smoothedPoses, takeoff: takeoffFrame, landing: landingFrame)

        // 3. Build phases
        let phases = buildPhases(
            totalFrames: poses.count,
            penultimate: penultimateFrame,
            takeoff: takeoffFrame,
            landing: landingFrame
        )

        // 4. Compute measurements
        var measurements = computeMeasurements(
            poses: smoothedPoses,
            takeoffFrame: takeoffFrame,
            landingFrame: landingFrame,
            penultimateFrame: penultimateFrame,
            peakFrame: peakFrame,
            bar: bar,
            frameRate: frameRate
        )

        // 4b. Compute real-world measurements if bar height is known
        if let barHeightMeters, let bar {
            computeRealWorldMeasurements(
                measurements: &measurements,
                poses: smoothedPoses,
                takeoffFrame: takeoffFrame,
                bar: bar,
                barHeightMeters: barHeightMeters
            )
        }

        // 5. Detect errors
        let errors = detectErrors(
            measurements: measurements,
            poses: smoothedPoses,
            phases: phases,
            takeoffFrame: takeoffFrame,
            peakFrame: peakFrame,
            bar: bar
        )

        // 6. Generate recommendations
        let recommendations = generateRecommendations(from: errors)

        return AnalysisResult(
            phases: phases,
            measurements: measurements,
            errors: errors,
            recommendations: recommendations
        )
    }

    // MARK: - Pose Smoothing

    /// Apply 3-frame moving average to reduce joint position noise
    private static func smoothPoses(_ poses: [BodyPose]) -> [BodyPose] {
        guard poses.count >= 3 else { return poses }

        var smoothed: [BodyPose] = []

        for i in 0..<poses.count {
            let windowStart = max(0, i - 1)
            let windowEnd = min(poses.count - 1, i + 1)
            let window = Array(poses[windowStart...windowEnd])

            var smoothedJoints: [BodyPose.JointName: BodyPose.JointPosition] = [:]

            for jointName in BodyPose.JointName.allCases {
                let validPositions = window.compactMap { $0.joints[jointName] }
                guard !validPositions.isEmpty else { continue }

                let avgX = validPositions.map(\.point.x).reduce(0, +) / CGFloat(validPositions.count)
                let avgY = validPositions.map(\.point.y).reduce(0, +) / CGFloat(validPositions.count)
                let avgConf = validPositions.map(\.confidence).reduce(0, +) / Float(validPositions.count)

                smoothedJoints[jointName] = BodyPose.JointPosition(
                    point: CGPoint(x: avgX, y: avgY),
                    confidence: avgConf
                )
            }

            smoothed.append(BodyPose(
                frameIndex: poses[i].frameIndex,
                timestamp: poses[i].timestamp,
                joints: smoothedJoints
            ))
        }

        return smoothed
    }

    // MARK: - Key Frame Detection

    /// Find the takeoff frame: last ground contact before sustained upward movement
    private static func findTakeoffFrame(poses: [BodyPose]) -> Int {
        // Track root Y position (in Vision coords, higher Y = higher position)
        let rootYValues = poses.map { $0.joints[.root]?.point.y ?? 0 }

        guard rootYValues.count >= 10 else {
            return poses.count / 2
        }

        // Compute velocity (change in Y between frames)
        var velocities: [Double] = [0]
        for i in 1..<rootYValues.count {
            velocities.append(Double(rootYValues[i] - rootYValues[i - 1]))
        }

        // Smooth velocities
        var smoothVelocities = velocities
        for i in 2..<(velocities.count - 2) {
            smoothVelocities[i] = (velocities[i-2] + velocities[i-1] + velocities[i] +
                                   velocities[i+1] + velocities[i+2]) / 5.0
        }

        // Find the frame where velocity transitions from near-zero/negative to strongly positive
        // AND this upward movement is sustained for at least 3 frames
        var bestTakeoff = poses.count / 2
        var bestScore: Double = 0

        for i in 5..<(smoothVelocities.count - 5) {
            // Check for velocity transition
            let prevAvg = (smoothVelocities[i-3] + smoothVelocities[i-2] + smoothVelocities[i-1]) / 3.0
            let nextAvg = (smoothVelocities[i+1] + smoothVelocities[i+2] + smoothVelocities[i+3]) / 3.0

            // Score: strong upward acceleration from low/negative velocity
            if prevAvg < 0.005 && nextAvg > 0.005 {
                let score = nextAvg - prevAvg
                if score > bestScore {
                    bestScore = score
                    bestTakeoff = i
                }
            }
        }

        return bestTakeoff
    }

    /// Find the landing frame: significant downward movement after flight
    private static func findLandingFrame(poses: [BodyPose], after takeoffFrame: Int) -> Int {
        let rootYValues = poses.map { $0.joints[.root]?.point.y ?? 0 }

        // Find peak after takeoff
        var peakFrame = takeoffFrame
        var peakY: CGFloat = 0

        let searchEnd = min(poses.count, takeoffFrame + poses.count / 2)
        for i in takeoffFrame..<searchEnd {
            if rootYValues[i] > peakY {
                peakY = rootYValues[i]
                peakFrame = i
            }
        }

        // Find where Y drops significantly below peak (landing)
        let threshold = peakY - (peakY - rootYValues[takeoffFrame]) * 0.7

        for i in peakFrame..<searchEnd {
            if rootYValues[i] < threshold {
                return i
            }
        }

        // Fallback: 2 seconds after takeoff
        return min(poses.count - 1, takeoffFrame + Int(60))
    }

    /// Find the penultimate step frame (second-to-last ground contact before takeoff)
    private static func findPenultimateStep(poses: [BodyPose], before takeoffFrame: Int) -> Int {
        // Look at ankle Y values before takeoff to find ground contacts
        let searchStart = max(0, takeoffFrame - 30)

        // Track the lowest ankle position (closer to ground = lower Y in Vision coords)
        var ankleMinima: [Int] = []

        for i in (searchStart + 1)..<takeoffFrame {
            let leftAnkleY = poses[i].joints[.leftAnkle]?.point.y ?? 1.0
            let rightAnkleY = poses[i].joints[.rightAnkle]?.point.y ?? 1.0
            let minAnkleY = min(leftAnkleY, rightAnkleY)

            let prevMinAnkle = min(
                poses[i-1].joints[.leftAnkle]?.point.y ?? 1.0,
                poses[i-1].joints[.rightAnkle]?.point.y ?? 1.0
            )

            if i + 1 < takeoffFrame {
                let nextMinAnkle = min(
                    poses[i+1].joints[.leftAnkle]?.point.y ?? 1.0,
                    poses[i+1].joints[.rightAnkle]?.point.y ?? 1.0
                )

                // Local minimum = lower than neighbors
                if minAnkleY <= prevMinAnkle && minAnkleY <= nextMinAnkle {
                    ankleMinima.append(i)
                }
            }
        }

        // Penultimate = second-to-last minimum before takeoff
        if ankleMinima.count >= 2 {
            return ankleMinima[ankleMinima.count - 2]
        } else if let last = ankleMinima.last {
            return max(searchStart, last - 5)
        }

        // Fallback: 10 frames before takeoff
        return max(0, takeoffFrame - 10)
    }

    /// Find the peak frame (highest point during flight)
    private static func findPeakFrame(poses: [BodyPose], takeoff: Int, landing: Int) -> Int {
        var peakFrame = takeoff
        var peakY: CGFloat = 0

        for i in takeoff...min(landing, poses.count - 1) {
            let rootY = poses[i].joints[.root]?.point.y ?? 0
            if rootY > peakY {
                peakY = rootY
                peakFrame = i
            }
        }

        return peakFrame
    }

    // MARK: - Phase Building

    private static func buildPhases(
        totalFrames: Int,
        penultimate: Int,
        takeoff: Int,
        landing: Int
    ) -> [DetectedPhase] {
        var phases: [DetectedPhase] = []

        // Approach: start to penultimate
        if penultimate > 0 {
            phases.append(DetectedPhase(
                phase: .approach,
                startFrame: 0,
                endFrame: max(0, penultimate - 1),
                keyMetrics: [:]
            ))
        }

        // Penultimate
        phases.append(DetectedPhase(
            phase: .penultimate,
            startFrame: penultimate,
            endFrame: max(penultimate, takeoff - 1),
            keyMetrics: [:]
        ))

        // Takeoff
        phases.append(DetectedPhase(
            phase: .takeoff,
            startFrame: takeoff,
            endFrame: min(takeoff + 3, landing),
            keyMetrics: [:]
        ))

        // Flight
        if takeoff + 4 < landing {
            phases.append(DetectedPhase(
                phase: .flight,
                startFrame: takeoff + 4,
                endFrame: landing,
                keyMetrics: [:]
            ))
        }

        // Landing
        if landing < totalFrames - 1 {
            phases.append(DetectedPhase(
                phase: .landing,
                startFrame: landing + 1,
                endFrame: totalFrames - 1,
                keyMetrics: [:]
            ))
        }

        return phases
    }

    // MARK: - Measurement Computation

    private static func computeMeasurements(
        poses: [BodyPose],
        takeoffFrame: Int,
        landingFrame: Int,
        penultimateFrame: Int,
        peakFrame: Int,
        bar: BarDetectionResult?,
        frameRate: Double
    ) -> JumpMeasurements {
        var m = JumpMeasurements()

        let takeoffPose = poses.indices.contains(takeoffFrame) ? poses[takeoffFrame] : nil
        let penultimatePose = poses.indices.contains(penultimateFrame) ? poses[penultimateFrame] : nil
        let peakPose = poses.indices.contains(peakFrame) ? poses[peakFrame] : nil

        // Takeoff leg angle at plant
        // Determine which leg is the plant leg (the one with ankle closer to ground at takeoff)
        if let pose = takeoffPose {
            let (plantSide, _) = determinePlantLeg(pose: pose)

            if plantSide == .left {
                m.takeoffLegAngleAtPlant = pose.angle(from: .leftHip, vertex: .leftKnee, to: .leftAnkle)
                m.driveKneeAngleAtTakeoff = pose.angle(from: .rightHip, vertex: .rightKnee, to: .rightAnkle)
            } else {
                m.takeoffLegAngleAtPlant = pose.angle(from: .rightHip, vertex: .rightKnee, to: .rightAnkle)
                m.driveKneeAngleAtTakeoff = pose.angle(from: .leftHip, vertex: .leftKnee, to: .leftAnkle)
            }
        }

        // Torso lean during approach curve (average of last 10 approach frames)
        let approachEnd = max(0, penultimateFrame - 1)
        let approachStart = max(0, approachEnd - 10)
        if approachEnd > approachStart {
            var leans: [Double] = []
            for i in approachStart...approachEnd {
                if let neck = poses[i].joints[.neck]?.point,
                   let root = poses[i].joints[.root]?.point {
                    let lean = AngleCalculator.angleFromVertical(top: neck, bottom: root)
                    leans.append(lean)
                }
            }
            if !leans.isEmpty {
                m.torsoLeanDuringCurve = leans.reduce(0, +) / Double(leans.count)
            }
        }

        // Hip-shoulder separation at penultimate touchdown
        if let pose = penultimatePose {
            if let ls = pose.joints[.leftShoulder]?.point,
               let rs = pose.joints[.rightShoulder]?.point,
               let lh = pose.joints[.leftHip]?.point,
               let rh = pose.joints[.rightHip]?.point {
                m.hipShoulderSeparationAtTD = AngleCalculator.hipShoulderSeparation(
                    leftShoulder: ls, rightShoulder: rs,
                    leftHip: lh, rightHip: rh
                )
            }
        }

        // Hip-shoulder separation at takeoff
        if let pose = takeoffPose {
            if let ls = pose.joints[.leftShoulder]?.point,
               let rs = pose.joints[.rightShoulder]?.point,
               let lh = pose.joints[.leftHip]?.point,
               let rh = pose.joints[.rightHip]?.point {
                m.hipShoulderSeparationAtTO = AngleCalculator.hipShoulderSeparation(
                    leftShoulder: ls, rightShoulder: rs,
                    leftHip: lh, rightHip: rh
                )
            }
        }

        // Back arch angle at peak
        if let pose = peakPose {
            // Measure the angle at root (hip) formed by neck and knee
            let leftKneeAngle = pose.angle(from: .neck, vertex: .root, to: .leftKnee)
            let rightKneeAngle = pose.angle(from: .neck, vertex: .root, to: .rightKnee)
            if let left = leftKneeAngle, let right = rightKneeAngle {
                m.backArchAngle = min(left, right)
            } else {
                m.backArchAngle = leftKneeAngle ?? rightKneeAngle
            }
        }

        // Approach angle to bar
        if let bar = bar {
            let approachPoints = (max(0, takeoffFrame - 10)..<takeoffFrame).compactMap { i -> CGPoint? in
                poses.indices.contains(i) ? poses[i].joints[.root]?.point : nil
            }
            m.approachAngleToBar = AngleCalculator.approachAngleToBar(
                trajectoryPoints: approachPoints,
                barStart: bar.barLineStart,
                barEnd: bar.barLineEnd
            )
        }

        // Ground contact time
        // Estimate from ankle velocity: plant frame to frame where ankle leaves ground
        m.estimatedGroundContactTime = Double(min(6, max(3, takeoffFrame - penultimateFrame))) / frameRate

        // Peak height (normalized)
        if let peakRoot = peakPose?.joints[.root]?.point.y {
            m.peakHeight = Double(peakRoot)
        }

        // Jump rise: how much the root Y increased from takeoff to peak
        if let takeoffRoot = takeoffPose?.joints[.root]?.point.y,
           let peakRoot = peakPose?.joints[.root]?.point.y {
            m.jumpRise = Double(peakRoot - takeoffRoot)
        }

        // Peak clearance over bar
        // Compare the athlete's highest point (peak of root/neck/nose at peak frame)
        // to the bar Y position. Both in Vision normalized coords.
        if let bar = bar, let peakPose = peakPose {
            // Use the highest joint at peak frame for clearance calculation
            let candidateJoints: [BodyPose.JointName] = [.root, .neck, .nose, .leftHip, .rightHip]
            var maxY: CGFloat = 0
            for jointName in candidateJoints {
                if let y = peakPose.joints[jointName]?.point.y, y > maxY {
                    maxY = y
                }
            }
            // barY is in Vision coords (higher Y = higher position)
            let barY = bar.barY
            m.peakClearanceOverBar = Double(maxY - barY)
        }

        // ──────────────────────────────────────────────────
        // Bar knock detection
        // Check if any body part crosses through the bar plane during flight
        // ──────────────────────────────────────────────────
        if let bar = bar {
            let barY = bar.barY
            let barXMin = min(bar.barLineStart.x, bar.barLineEnd.x)
            let barXMax = max(bar.barLineStart.x, bar.barLineEnd.x)
            let barYTolerance: CGFloat = 0.015  // ~1.5% of frame height

            // Check joints that commonly knock the bar
            let knockJoints: [(BodyPose.JointName, String)] = [
                (.root, "hips"), (.leftHip, "hips"), (.rightHip, "hips"),
                (.leftKnee, "trail leg"), (.rightKnee, "trail leg"),
                (.leftAnkle, "trail leg"), (.rightAnkle, "trail leg"),
                (.leftShoulder, "shoulders"), (.rightShoulder, "shoulders"),
                (.leftElbow, "arms"), (.rightElbow, "arms"),
            ]

            let flightStart = takeoffFrame + 2
            let flightEnd = min(poses.count - 1, landingFrame)

            for i in flightStart...flightEnd {
                let pose = poses[i]
                for (jointName, partName) in knockJoints {
                    guard let joint = pose.joints[jointName],
                          joint.confidence > 0.2 else { continue }

                    let jx = joint.point.x
                    let jy = joint.point.y

                    // Joint must be horizontally within the bar span
                    guard jx >= barXMin - 0.05 && jx <= barXMax + 0.05 else { continue }

                    // Joint must be within tolerance of bar Y (crossing the bar plane)
                    if abs(jy - barY) < barYTolerance {
                        m.barKnocked = true
                        m.barKnockFrame = i
                        m.barKnockBodyPart = partName
                        break
                    }
                }
                if m.barKnocked { break }
            }

            // Takeoff distance from bar (horizontal distance from root at takeoff to bar center X)
            if let takeoffRoot = takeoffPose?.joints[.root]?.point {
                let barCenterX = (bar.barLineStart.x + bar.barLineEnd.x) / 2.0
                m.takeoffDistance = Double(abs(takeoffRoot.x - barCenterX))
            }
        }

        // Set jump success/fail based on bar knock detection
        if bar != nil {
            m.jumpSuccess = !m.barKnocked
        }

        // ──────────────────────────────────────────────────
        // Flight time
        // ──────────────────────────────────────────────────
        let flightFrames = landingFrame - takeoffFrame
        if flightFrames > 0 {
            m.flightTime = Double(flightFrames) / frameRate
        }

        // ──────────────────────────────────────────────────
        // Approach speed (average root displacement per frame in last 15 approach frames)
        // ──────────────────────────────────────────────────
        let speedStart = max(0, takeoffFrame - 15)
        let speedEnd = max(speedStart + 1, takeoffFrame - 1)
        if speedEnd > speedStart {
            var totalDisplacement: Double = 0
            var count = 0
            for i in speedStart..<speedEnd {
                guard let p1 = poses[i].joints[.root]?.point,
                      let p2 = poses[i + 1].joints[.root]?.point else { continue }
                let dx = Double(p2.x - p1.x)
                let dy = Double(p2.y - p1.y)
                totalDisplacement += sqrt(dx * dx + dy * dy)
                count += 1
            }
            if count > 0 {
                m.approachSpeed = totalDisplacement / Double(count)
            }
        }

        // ──────────────────────────────────────────────────
        // Takeoff vertical velocity (root Y velocity at takeoff, units/frame)
        // ──────────────────────────────────────────────────
        if takeoffFrame + 2 < poses.count {
            if let y0 = poses[takeoffFrame].joints[.root]?.point.y,
               let y2 = poses[min(takeoffFrame + 2, poses.count - 1)].joints[.root]?.point.y {
                m.takeoffVerticalVelocity = Double(y2 - y0) / 2.0
            }
        }

        // ──────────────────────────────────────────────────
        // J-Curve radius estimation
        // Fit circle to last 8 root positions before takeoff
        // ──────────────────────────────────────────────────
        let curveStart = max(0, takeoffFrame - 8)
        if takeoffFrame - curveStart >= 4 {
            let curvePoints = (curveStart..<takeoffFrame).compactMap { i -> CGPoint? in
                poses.indices.contains(i) ? poses[i].joints[.root]?.point : nil
            }
            if curvePoints.count >= 4 {
                m.jCurveRadius = estimateCurveRadius(points: curvePoints)
            }
        }

        return m
    }

    /// Determine which leg is the plant leg at takeoff
    private static func determinePlantLeg(pose: BodyPose) -> (side: Side, confidence: Double) {
        let leftAnkleY = pose.joints[.leftAnkle]?.point.y ?? 0.5
        let rightAnkleY = pose.joints[.rightAnkle]?.point.y ?? 0.5

        // In Vision coordinates, lower Y = closer to bottom of image = closer to ground
        if leftAnkleY < rightAnkleY {
            return (.left, Double(abs(rightAnkleY - leftAnkleY)))
        } else {
            return (.right, Double(abs(leftAnkleY - rightAnkleY)))
        }
    }

    enum Side { case left, right }

    // MARK: - Error Detection

    private static func detectErrors(
        measurements: JumpMeasurements,
        poses: [BodyPose],
        phases: [DetectedPhase],
        takeoffFrame: Int,
        peakFrame: Int,
        bar: BarDetectionResult?
    ) -> [DetectedError] {
        var errors: [DetectedError] = []

        let approachPhase = phases.first { $0.phase == .approach }
        let flightPhase = phases.first { $0.phase == .flight }

        // 1. Extended body position (drive knee too straight at takeoff)
        if let driveKnee = measurements.driveKneeAngleAtTakeoff, driveKnee > 120 {
            let severity: DetectedError.Severity = driveKnee > 150 ? .major : .moderate
            errors.append(DetectedError(
                id: UUID(),
                type: .extendedBodyPosition,
                frameRange: takeoffFrame...min(takeoffFrame + 3, poses.count - 1),
                severity: severity,
                description: "Drive knee angle is \(Int(driveKnee))°. A more compact drive knee (70-90°) generates greater upward force at takeoff."
            ))
        }

        // 2. Improper takeoff angle
        if let torsoLean = measurements.torsoLeanDuringCurve {
            if torsoLean > 30 {
                errors.append(DetectedError(
                    id: UUID(),
                    type: .improperTakeoffAngle,
                    frameRange: (approachPhase?.startFrame ?? 0)...(approachPhase?.endFrame ?? takeoffFrame),
                    severity: .major,
                    description: "Excessive torso lean of \(Int(torsoLean))° during approach. Maintain 10-20° lean to stay balanced through the curve."
                ))
            } else if torsoLean < 5 {
                errors.append(DetectedError(
                    id: UUID(),
                    type: .improperTakeoffAngle,
                    frameRange: (approachPhase?.startFrame ?? 0)...(approachPhase?.endFrame ?? takeoffFrame),
                    severity: .moderate,
                    description: "Insufficient torso lean (\(Int(torsoLean))°). A 10-20° inward lean helps generate rotation for bar clearance."
                ))
            }
        }

        // 3. Takeoff leg not fully extended
        if let plantAngle = measurements.takeoffLegAngleAtPlant {
            if plantAngle < 155 {
                let severity: DetectedError.Severity = plantAngle < 140 ? .major : .moderate
                errors.append(DetectedError(
                    id: UUID(),
                    type: .improperTakeoffAngle,
                    frameRange: takeoffFrame...min(takeoffFrame + 2, poses.count - 1),
                    severity: severity,
                    description: "Plant leg angle is \(Int(plantAngle))° at takeoff. A nearly straight plant leg (160-175°) provides a better lever for vertical force."
                ))
            }
        }

        // 4. Approach angle to bar
        if let approachAngle = measurements.approachAngleToBar {
            if approachAngle < 20 {
                errors.append(DetectedError(
                    id: UUID(),
                    type: .flatteningCurve,
                    frameRange: (approachPhase?.startFrame ?? 0)...(approachPhase?.endFrame ?? takeoffFrame),
                    severity: .moderate,
                    description: "Approach angle is only \(Int(approachAngle))° to the bar. Running too parallel reduces clearance efficiency. Aim for ~35° angle."
                ))
            } else if approachAngle > 55 {
                errors.append(DetectedError(
                    id: UUID(),
                    type: .cuttingCurve,
                    frameRange: (approachPhase?.startFrame ?? 0)...(approachPhase?.endFrame ?? takeoffFrame),
                    severity: .moderate,
                    description: "Approach angle is \(Int(approachAngle))° — running too perpendicular to the bar. This reduces horizontal speed conversion. Aim for ~35°."
                ))
            }
        }

        // 5. Back arch / hammock position
        if let backArch = measurements.backArchAngle {
            if backArch > 160 {
                errors.append(DetectedError(
                    id: UUID(),
                    type: .hammockPosition,
                    frameRange: (flightPhase?.startFrame ?? peakFrame)...(flightPhase?.endFrame ?? min(peakFrame + 5, poses.count - 1)),
                    severity: .moderate,
                    description: "Body is too flat over the bar (arch angle \(Int(backArch))°). A deeper back arch clears the bar more efficiently."
                ))
            }
        }

        // 6. Early head drop
        if peakFrame + 3 < poses.count {
            let peakNoseY = poses[peakFrame].joints[.nose]?.point.y ?? 0
            let postNoseY = poses[min(peakFrame + 3, poses.count - 1)].joints[.nose]?.point.y ?? 0
            let peakRootY = poses[peakFrame].joints[.root]?.point.y ?? 0
            let postRootY = poses[min(peakFrame + 3, poses.count - 1)].joints[.root]?.point.y ?? 0

            let noseDropRate = Double(peakNoseY - postNoseY)
            let rootDropRate = Double(peakRootY - postRootY)

            if noseDropRate > rootDropRate * 1.5 && noseDropRate > 0.02 {
                errors.append(DetectedError(
                    id: UUID(),
                    type: .earlyHeadDrop,
                    frameRange: peakFrame...min(peakFrame + 5, poses.count - 1),
                    severity: .moderate,
                    description: "Head drops faster than hips after peak. Keep chin level and eyes up until hips clear the bar to maintain arch."
                ))
            }
        }

        // 7. Hip collapse during flight
        if let flightRange = flightPhase {
            for i in stride(from: flightRange.startFrame, through: min(flightRange.endFrame, poses.count - 1), by: 2) {
                let pose = poses[i]
                if let hipAngle = pose.angle(from: .leftShoulder, vertex: .root, to: .leftKnee) ?? pose.angle(from: .rightShoulder, vertex: .root, to: .rightKnee) {
                    if hipAngle < 140 {
                        errors.append(DetectedError(
                            id: UUID(),
                            type: .hipCollapse,
                            frameRange: flightRange.startFrame...flightRange.endFrame,
                            severity: hipAngle < 120 ? .major : .moderate,
                            description: "Hips are collapsing during bar clearance (angle: \(Int(hipAngle))°). Drive hips upward and maintain extension over the bar."
                        ))
                        break // Only report once
                    }
                }
            }
        }

        // 8. Bar knock detection
        if measurements.barKnocked, let knockFrame = measurements.barKnockFrame {
            let partName = measurements.barKnockBodyPart ?? "body"
            errors.append(DetectedError(
                id: UUID(),
                type: .barKnock,
                frameRange: knockFrame...min(knockFrame + 3, poses.count - 1),
                severity: .major,
                description: "Bar knocked by \(partName) at frame \(knockFrame + 1). The \(partName) passed through the bar plane during clearance."
            ))
        }

        return errors.sorted { $0.severity > $1.severity }
    }

    // MARK: - Recommendations

    private static func generateRecommendations(from errors: [DetectedError]) -> [Recommendation] {
        var recommendations: [Recommendation] = []
        var priority = 1

        // Map each error to coaching recommendations
        for error in errors.prefix(5) {
            let (title, detail) = coachingCue(for: error.type)
            recommendations.append(Recommendation(
                id: UUID(),
                title: title,
                detail: detail,
                relatedError: error.type,
                priority: priority
            ))
            priority += 1
        }

        // If no errors, add general positive feedback
        if recommendations.isEmpty {
            recommendations.append(Recommendation(
                id: UUID(),
                title: "Solid Technique",
                detail: "No major technical errors detected. Focus on consistency and gradually increasing bar height. Review the measurements to find areas for incremental improvement.",
                relatedError: nil,
                priority: 1
            ))
        }

        return recommendations
    }

    private static func coachingCue(for errorType: DetectedError.ErrorType) -> (title: String, detail: String) {
        switch errorType {
        case .flatteningCurve:
            return (
                "Maintain the J-Curve",
                "Focus on running tangent to an arc during the last 3-5 steps. Set a cone at the curve entry point to guide your path. The curve generates the rotation needed for bar clearance."
            )
        case .cuttingCurve:
            return (
                "Widen Your Approach Curve",
                "You're cutting too sharply toward the bar. Start your curve earlier and use a wider arc. This preserves horizontal speed and gives you a better takeoff angle. Aim for approximately 35° approach angle."
            )
        case .steppingOutOfCurve:
            return (
                "Stay on the Curve Path",
                "Your penultimate step is drifting outside the curve. Practice running the full J-curve without looking at the bar. Mark your curve on the ground with tape during training."
            )
        case .extendedBodyPosition:
            return (
                "Drive the Free Knee Up",
                "At takeoff, drive your free knee explosively upward to at least hip height. Think 'knee to chest.' A compact, high knee drive converts forward speed into vertical lift. Practice bounding drills to develop this."
            )
        case .hammockPosition:
            return (
                "Arch Over the Bar",
                "Your body is too flat over the bar (hammock position). As your shoulders cross the bar, push your hips up by squeezing your glutes and driving the hips skyward. Practice bridge exercises to improve back flexibility."
            )
        case .improperTakeoffAngle:
            return (
                "Fix Your Takeoff Angle",
                "Focus on planting your takeoff foot with a nearly straight leg (160-175°) and leaning slightly away from the bar at takeoff. Your lean during the curve should be 10-20° inward — enough to generate rotation but not so much that you fall into the bar."
            )
        case .hipCollapse:
            return (
                "Drive Hips Over the Bar",
                "Your hips are dropping during bar clearance. As your shoulders pass the bar, aggressively drive your hips upward. Squeeze your glutes at the peak. Think about pushing your belt buckle to the sky. Strengthen hip extensors with glute bridges and hip thrusts."
            )
        case .insufficientRotation:
            return (
                "Improve Rotation Off the Ground",
                "You need more rotation at takeoff to turn your back to the bar. This comes from the curved approach and the lean during the last steps. Focus on maintaining your curve and using your arms to initiate the turn. The inside arm drives across your body at takeoff."
            )
        case .earlyHeadDrop:
            return (
                "Keep Your Eyes Up Longer",
                "You're dropping your chin too early, which pulls your hips down before they clear the bar. Keep your eyes looking up and your chin level until you feel your hips pass the bar. Then tuck your chin to lift your legs clear."
            )
        case .barKnock:
            return (
                "Bar Contact Detected",
                "A body part crossed the bar plane during clearance. Review the indicated frame to identify which phase needs improvement. Common causes: insufficient peak height (more explosive takeoff needed), poor arch timing (hips or trail leg catching the bar), or taking off too close/far from the bar."
            )
        }
    }

    // MARK: - Geometry Helpers

    /// Estimate the radius of curvature from a series of points using Menger curvature.
    /// Returns average radius in normalized coordinates.
    private static func estimateCurveRadius(points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }

        var radii: [Double] = []

        // Sample triplets to estimate curvature
        let step = max(1, points.count / 4)
        for i in stride(from: 0, to: points.count - 2 * step, by: step) {
            let a = points[i]
            let b = points[i + step]
            let c = points[min(i + 2 * step, points.count - 1)]

            // Menger curvature: 4 * area(triangle) / (|AB| * |BC| * |CA|)
            let area = abs(Double(
                (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            )) / 2.0

            let ab = sqrt(pow(Double(b.x - a.x), 2) + pow(Double(b.y - a.y), 2))
            let bc = sqrt(pow(Double(c.x - b.x), 2) + pow(Double(c.y - b.y), 2))
            let ca = sqrt(pow(Double(a.x - c.x), 2) + pow(Double(a.y - c.y), 2))

            let denom = ab * bc * ca
            guard denom > 0.0001 else { continue }

            let curvature = 4.0 * area / denom
            if curvature > 0.001 {
                radii.append(1.0 / curvature)
            }
        }

        guard !radii.isEmpty else { return 0 }
        return radii.reduce(0, +) / Double(radii.count)
    }

    // MARK: - Real-World Measurements

    /// Convert normalized measurements to real-world units using bar height as reference.
    ///
    /// The approach: the bar Y in normalized Vision coords represents `barHeightMeters` above ground.
    /// Ground level is estimated as the lowest ankle Y during the approach phase.
    /// Scale factor = barHeightMeters / (barY - groundY)
    private static func computeRealWorldMeasurements(
        measurements: inout JumpMeasurements,
        poses: [BodyPose],
        takeoffFrame: Int,
        bar: BarDetectionResult,
        barHeightMeters: Double
    ) {
        measurements.barHeightMeters = barHeightMeters

        // Estimate ground level: lowest ankle Y position during approach
        // (In Vision coords, lower Y = closer to ground)
        var groundY: CGFloat = 1.0  // start high
        let approachEnd = min(takeoffFrame, poses.count - 1)
        let approachStart = max(0, approachEnd - 30)  // look at last 30 approach frames

        for i in approachStart...approachEnd {
            let pose = poses[i]
            for ankleJoint in [BodyPose.JointName.leftAnkle, .rightAnkle] {
                if let ankle = pose.joints[ankleJoint],
                   ankle.confidence > 0.2,
                   ankle.point.y < groundY {
                    groundY = ankle.point.y
                }
            }
        }

        let barY = bar.barY
        let normalizedBarToGround = barY - groundY

        // Need a meaningful scale — bar must be visibly above ground level
        guard normalizedBarToGround > 0.05 else { return }

        let scale = barHeightMeters / Double(normalizedBarToGround)
        measurements.metersPerNormalizedUnit = scale

        // Convert jump rise to meters
        if let jumpRise = measurements.jumpRise {
            measurements.jumpRiseMeters = jumpRise * scale
        }

        // Convert peak clearance to meters
        if let clearance = measurements.peakClearanceOverBar {
            measurements.peakClearanceMeters = clearance * scale
        }

        // Convert peak height to real height above ground
        if let peakHeight = measurements.peakHeight {
            let normalizedAboveGround = Double(peakHeight) - Double(groundY)
            measurements.peakHeightMeters = normalizedAboveGround * scale
        }
    }
}
