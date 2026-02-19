import CoreGraphics

/// A single person's detected body pose in one frame.
///
/// All joint positions are in **normalized MediaPipe coordinates**:
/// - Range: 0.0 to 1.0
/// - Origin: top-left (same as SwiftUI)
/// - (0,0) = top-left, (1,1) = bottom-right
struct BodyPose: Sendable {
    let frameIndex: Int
    let timestamp: Double
    let joints: [JointName: JointPosition]

    /// Whether this pose was synthesized via interpolation (not directly detected).
    var isInterpolated: Bool = false

    struct JointPosition: Sendable, Codable {
        let point: CGPoint       // normalized 0..1 (MediaPipe coordinates, origin top-left)
        let confidence: Float    // 0.0 to 1.0
    }

    // MARK: - Joint Names (33 BlazePose + 2 computed)

    /// All 33 MediaPipe BlazePose landmarks plus computed neck and root.
    enum JointName: String, CaseIterable, Sendable, Hashable, Codable {
        // Face
        case nose
        case leftEyeInner, leftEye, leftEyeOuter
        case rightEyeInner, rightEye, rightEyeOuter
        case leftEar, rightEar
        case mouthLeft, mouthRight

        // Upper body
        case leftShoulder, rightShoulder
        case leftElbow, rightElbow
        case leftWrist, rightWrist

        // Hands
        case leftPinky, rightPinky
        case leftIndex, rightIndex
        case leftThumb, rightThumb

        // Lower body
        case leftHip, rightHip
        case leftKnee, rightKnee
        case leftAnkle, rightAnkle

        // Feet (critical for ground contact + ankle angle)
        case leftHeel, rightHeel
        case leftFootIndex, rightFootIndex

        // Computed joints (not directly from BlazePose)
        case neck   // midpoint of shoulders
        case root   // midpoint of hips

        /// The MediaPipe BlazePose landmark index for this joint.
        /// Returns nil for computed joints (neck, root).
        var blazePoseIndex: Int? {
            switch self {
            case .nose: return 0
            case .leftEyeInner: return 1
            case .leftEye: return 2
            case .leftEyeOuter: return 3
            case .rightEyeInner: return 4
            case .rightEye: return 5
            case .rightEyeOuter: return 6
            case .leftEar: return 7
            case .rightEar: return 8
            case .mouthLeft: return 9
            case .mouthRight: return 10
            case .leftShoulder: return 11
            case .rightShoulder: return 12
            case .leftElbow: return 13
            case .rightElbow: return 14
            case .leftWrist: return 15
            case .rightWrist: return 16
            case .leftPinky: return 17
            case .rightPinky: return 18
            case .leftIndex: return 19
            case .rightIndex: return 20
            case .leftThumb: return 21
            case .rightThumb: return 22
            case .leftHip: return 23
            case .rightHip: return 24
            case .leftKnee: return 25
            case .rightKnee: return 26
            case .leftAnkle: return 27
            case .rightAnkle: return 28
            case .leftHeel: return 29
            case .rightHeel: return 30
            case .leftFootIndex: return 31
            case .rightFootIndex: return 32
            case .neck, .root: return nil
            }
        }

        /// Whether this is a BlazePose native landmark (vs computed).
        var isNative: Bool {
            blazePoseIndex != nil
        }

        /// Whether this joint is part of the face (excluded from skeleton drawing).
        var isFace: Bool {
            switch self {
            case .leftEyeInner, .leftEye, .leftEyeOuter,
                 .rightEyeInner, .rightEye, .rightEyeOuter,
                 .leftEar, .rightEar, .mouthLeft, .mouthRight:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Skeleton Connections

    struct BoneConnection: Sendable {
        let from: JointName
        let to: JointName
        let group: SegmentGroup
    }

    enum SegmentGroup: Sendable {
        case torso
        case leftLeg
        case rightLeg
        case leftArm
        case rightArm
        case head

        var segmentName: String {
            switch self {
            case .torso: return "Torso"
            case .leftLeg: return "Left Leg"
            case .rightLeg: return "Right Leg"
            case .leftArm: return "Left Arm"
            case .rightArm: return "Right Arm"
            case .head: return "Head"
            }
        }
    }

    /// Major skeleton bones for overlay drawing (face connections omitted per spec).
    static let boneConnections: [BoneConnection] = [
        // Torso
        BoneConnection(from: .leftShoulder, to: .rightShoulder, group: .torso),
        BoneConnection(from: .leftShoulder, to: .leftHip, group: .torso),
        BoneConnection(from: .rightShoulder, to: .rightHip, group: .torso),
        BoneConnection(from: .leftHip, to: .rightHip, group: .torso),

        // Left arm
        BoneConnection(from: .leftShoulder, to: .leftElbow, group: .leftArm),
        BoneConnection(from: .leftElbow, to: .leftWrist, group: .leftArm),

        // Right arm
        BoneConnection(from: .rightShoulder, to: .rightElbow, group: .rightArm),
        BoneConnection(from: .rightElbow, to: .rightWrist, group: .rightArm),

        // Left leg
        BoneConnection(from: .leftHip, to: .leftKnee, group: .leftLeg),
        BoneConnection(from: .leftKnee, to: .leftAnkle, group: .leftLeg),
        BoneConnection(from: .leftAnkle, to: .leftHeel, group: .leftLeg),
        BoneConnection(from: .leftAnkle, to: .leftFootIndex, group: .leftLeg),
        BoneConnection(from: .leftHeel, to: .leftFootIndex, group: .leftLeg),

        // Right leg
        BoneConnection(from: .rightHip, to: .rightKnee, group: .rightLeg),
        BoneConnection(from: .rightKnee, to: .rightAnkle, group: .rightLeg),
        BoneConnection(from: .rightAnkle, to: .rightHeel, group: .rightLeg),
        BoneConnection(from: .rightAnkle, to: .rightFootIndex, group: .rightLeg),
        BoneConnection(from: .rightHeel, to: .rightFootIndex, group: .rightLeg),

        // Head/Neck
        BoneConnection(from: .neck, to: .nose, group: .head),
    ]

    // MARK: - Computed Properties

    /// Check if enough joints are detected for meaningful analysis.
    var hasMinimumConfidence: Bool {
        let requiredJoints: [JointName] = [.root, .neck]
        let hasCore = requiredJoints.allSatisfy { name in
            guard let joint = joints[name] else { return false }
            return joint.confidence > 0.2
        }

        // Also need at least one leg
        let hasLeg = ((joints[.leftKnee]?.confidence ?? 0) > 0.2 && (joints[.leftAnkle]?.confidence ?? 0) > 0.2) ||
                     ((joints[.rightKnee]?.confidence ?? 0) > 0.2 && (joints[.rightAnkle]?.confidence ?? 0) > 0.2)

        return hasCore && hasLeg
    }

    /// Compute angle at a joint vertex.
    func angle(from a: JointName, vertex: JointName, to b: JointName) -> Double? {
        guard let pointA = joints[a]?.point,
              let pointV = joints[vertex]?.point,
              let pointB = joints[b]?.point else { return nil }

        return AngleCalculator.angle(pointA: pointA, vertex: pointV, pointC: pointB)
    }

    /// Bounding box of all detected joints (normalized coordinates, origin top-left).
    var boundingBox: CGRect? {
        let validJoints = joints.values.filter { $0.confidence > 0.1 }
        guard validJoints.count >= 3 else { return nil }

        var minX: CGFloat = 1.0
        var maxX: CGFloat = 0.0
        var minY: CGFloat = 1.0
        var maxY: CGFloat = 0.0

        for joint in validJoints {
            minX = min(minX, joint.point.x)
            maxX = max(maxX, joint.point.x)
            minY = min(minY, joint.point.y)
            maxY = max(maxY, joint.point.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Get the center of mass approximation (root joint or midpoint of hips).
    var centerOfMass: CGPoint? {
        if let root = joints[.root]?.point {
            return root
        }
        guard let leftHip = joints[.leftHip]?.point,
              let rightHip = joints[.rightHip]?.point else { return nil }
        return leftHip.midpoint(to: rightHip)
    }

    /// Average confidence across all detected joints.
    var averageConfidence: Float {
        let confidences = joints.values.map { $0.confidence }
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Float(confidences.count)
    }

    /// Helper to get a specific joint point.
    func jointPoint(_ name: JointName) -> CGPoint? {
        joints[name]?.point
    }

    /// Count of joints with confidence above threshold.
    func jointCount(aboveConfidence threshold: Float = 0.1) -> Int {
        joints.values.filter { $0.confidence > threshold }.count
    }

    /// Get the lowest foot Y position (highest on screen in top-left coords = largest Y).
    /// In top-left coordinates, larger Y = lower on screen = closer to ground.
    var lowestFootY: CGFloat? {
        let footJoints: [JointName] = [.leftHeel, .rightHeel, .leftFootIndex, .rightFootIndex, .leftAnkle, .rightAnkle]
        let validFootPoints = footJoints.compactMap { joints[$0] }.filter { $0.confidence > 0.2 }
        guard !validFootPoints.isEmpty else { return nil }
        return validFootPoints.map { $0.point.y }.max()  // max Y = lowest on screen
    }

    /// Get the highest point Y (head/nose area — smallest Y in top-left coords).
    var highestPointY: CGFloat? {
        if let nose = joints[.nose], nose.confidence > 0.2 {
            return nose.point.y
        }
        let headJoints: [JointName] = [.leftEar, .rightEar, .leftEye, .rightEye]
        let validHeadPoints = headJoints.compactMap { joints[$0] }.filter { $0.confidence > 0.2 }
        guard !validHeadPoints.isEmpty else { return nil }
        return validHeadPoints.map { $0.point.y }.min()  // min Y = highest on screen
    }
}

// MARK: - Empty Pose

extension BodyPose {
    /// Create an empty pose (no joints detected) for a given frame.
    static func empty(frameIndex: Int, timestamp: Double) -> BodyPose {
        BodyPose(frameIndex: frameIndex, timestamp: timestamp, joints: [:])
    }
}
