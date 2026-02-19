import CoreGraphics
import Foundation

/// Center of Mass calculator using de Leva (1996) 14-segment body model.
///
/// Validated for high jump analysis (Virmavirta et al. 2022).
/// Maps directly to MediaPipe BlazePose 33 landmarks.
struct COMCalculator {

    enum Sex: String, Sendable, Codable {
        case male, female
    }

    /// Segment definition for the 14-segment model.
    private struct Segment {
        let name: String
        let proximal: [BodyPose.JointName]   // Single joint or pair to average
        let distal: [BodyPose.JointName]     // Single joint or pair to average
        let massFractionMale: Double
        let massFractionFemale: Double
        let comProximalMale: Double           // COM as fraction from proximal end
        let comProximalFemale: Double
    }

    /// The 14 body segments with de Leva (1996) parameters.
    private static let segments: [Segment] = [
        // Head + Neck
        Segment(
            name: "Head+Neck",
            proximal: [.leftShoulder, .rightShoulder],
            distal: [.nose],
            massFractionMale: 0.0694,
            massFractionFemale: 0.0668,
            comProximalMale: 0.500,
            comProximalFemale: 0.500
        ),
        // Trunk
        Segment(
            name: "Trunk",
            proximal: [.leftShoulder, .rightShoulder],
            distal: [.leftHip, .rightHip],
            massFractionMale: 0.4346,
            massFractionFemale: 0.4257,
            comProximalMale: 0.514,
            comProximalFemale: 0.493
        ),
        // Left Upper Arm
        Segment(
            name: "L Upper Arm",
            proximal: [.leftShoulder],
            distal: [.leftElbow],
            massFractionMale: 0.0271,
            massFractionFemale: 0.0255,
            comProximalMale: 0.577,
            comProximalFemale: 0.575
        ),
        // Right Upper Arm
        Segment(
            name: "R Upper Arm",
            proximal: [.rightShoulder],
            distal: [.rightElbow],
            massFractionMale: 0.0271,
            massFractionFemale: 0.0255,
            comProximalMale: 0.577,
            comProximalFemale: 0.575
        ),
        // Left Forearm
        Segment(
            name: "L Forearm",
            proximal: [.leftElbow],
            distal: [.leftWrist],
            massFractionMale: 0.0162,
            massFractionFemale: 0.0138,
            comProximalMale: 0.457,
            comProximalFemale: 0.456
        ),
        // Right Forearm
        Segment(
            name: "R Forearm",
            proximal: [.rightElbow],
            distal: [.rightWrist],
            massFractionMale: 0.0162,
            massFractionFemale: 0.0138,
            comProximalMale: 0.457,
            comProximalFemale: 0.456
        ),
        // Left Hand
        Segment(
            name: "L Hand",
            proximal: [.leftWrist],
            distal: [.leftPinky, .leftIndex],
            massFractionMale: 0.0061,
            massFractionFemale: 0.0056,
            comProximalMale: 0.790,
            comProximalFemale: 0.742
        ),
        // Right Hand
        Segment(
            name: "R Hand",
            proximal: [.rightWrist],
            distal: [.rightPinky, .rightIndex],
            massFractionMale: 0.0061,
            massFractionFemale: 0.0056,
            comProximalMale: 0.790,
            comProximalFemale: 0.742
        ),
        // Left Thigh
        Segment(
            name: "L Thigh",
            proximal: [.leftHip],
            distal: [.leftKnee],
            massFractionMale: 0.1416,
            massFractionFemale: 0.1478,
            comProximalMale: 0.410,
            comProximalFemale: 0.369
        ),
        // Right Thigh
        Segment(
            name: "R Thigh",
            proximal: [.rightHip],
            distal: [.rightKnee],
            massFractionMale: 0.1416,
            massFractionFemale: 0.1478,
            comProximalMale: 0.410,
            comProximalFemale: 0.369
        ),
        // Left Shank
        Segment(
            name: "L Shank",
            proximal: [.leftKnee],
            distal: [.leftAnkle],
            massFractionMale: 0.0433,
            massFractionFemale: 0.0481,
            comProximalMale: 0.440,
            comProximalFemale: 0.437
        ),
        // Right Shank
        Segment(
            name: "R Shank",
            proximal: [.rightKnee],
            distal: [.rightAnkle],
            massFractionMale: 0.0433,
            massFractionFemale: 0.0481,
            comProximalMale: 0.440,
            comProximalFemale: 0.437
        ),
        // Left Foot
        Segment(
            name: "L Foot",
            proximal: [.leftHeel],
            distal: [.leftFootIndex],
            massFractionMale: 0.0137,
            massFractionFemale: 0.0129,
            comProximalMale: 0.442,
            comProximalFemale: 0.401
        ),
        // Right Foot
        Segment(
            name: "R Foot",
            proximal: [.rightHeel],
            distal: [.rightFootIndex],
            massFractionMale: 0.0137,
            massFractionFemale: 0.0129,
            comProximalMale: 0.442,
            comProximalFemale: 0.401
        ),
    ]

    /// Calculate whole-body center of mass from a pose.
    ///
    /// Returns nil if insufficient landmarks are available.
    static func calculateCOM(pose: BodyPose, sex: Sex = .male) -> CGPoint? {
        var totalX: Double = 0
        var totalY: Double = 0
        var totalMass: Double = 0

        for segment in segments {
            // Get proximal point (average if multiple joints)
            guard let proximal = averagePoint(joints: segment.proximal, pose: pose) else { continue }
            guard let distal = averagePoint(joints: segment.distal, pose: pose) else { continue }

            let massFraction = sex == .male ? segment.massFractionMale : segment.massFractionFemale
            let comFraction = sex == .male ? segment.comProximalMale : segment.comProximalFemale

            // Segment COM = proximal + comFraction * (distal - proximal)
            let segmentCOMX = Double(proximal.x) + comFraction * Double(distal.x - proximal.x)
            let segmentCOMY = Double(proximal.y) + comFraction * Double(distal.y - proximal.y)

            totalX += massFraction * segmentCOMX
            totalY += massFraction * segmentCOMY
            totalMass += massFraction
        }

        guard totalMass > 0.5 else { return nil }  // Need at least ~50% of body mass

        return CGPoint(
            x: totalX / totalMass,
            y: totalY / totalMass
        )
    }

    /// Average point from one or more joint landmarks.
    private static func averagePoint(joints: [BodyPose.JointName], pose: BodyPose) -> CGPoint? {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var count = 0

        for joint in joints {
            if let pos = pose.joints[joint], pos.confidence > 0.2 {
                sumX += pos.point.x
                sumY += pos.point.y
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return CGPoint(x: sumX / CGFloat(count), y: sumY / CGFloat(count))
    }
}
