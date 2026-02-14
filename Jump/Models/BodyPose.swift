import CoreGraphics

struct BodyPose: Sendable {
    let frameIndex: Int
    let timestamp: Double

    let joints: [JointName: JointPosition]

    struct JointPosition: Sendable {
        let point: CGPoint       // normalized 0..1 (Vision coordinates, origin bottom-left)
        let confidence: Float    // 0.0 to 1.0
    }

    enum JointName: String, CaseIterable, Sendable, Hashable {
        case nose
        case neck
        case leftShoulder, rightShoulder
        case leftElbow, rightElbow
        case leftWrist, rightWrist
        case leftHip, rightHip
        case leftKnee, rightKnee
        case leftAnkle, rightAnkle
        case leftEye, rightEye
        case leftEar, rightEar
        case root
    }

    // MARK: - Skeleton Connections

    /// Define the bone segments for drawing the skeleton
    struct BoneConnection {
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

    static let boneConnections: [BoneConnection] = [
        // Torso
        BoneConnection(from: .neck, to: .root, group: .torso),
        BoneConnection(from: .leftShoulder, to: .rightShoulder, group: .torso),
        BoneConnection(from: .leftHip, to: .rightHip, group: .torso),

        // Left leg
        BoneConnection(from: .leftHip, to: .leftKnee, group: .leftLeg),
        BoneConnection(from: .leftKnee, to: .leftAnkle, group: .leftLeg),

        // Right leg
        BoneConnection(from: .rightHip, to: .rightKnee, group: .rightLeg),
        BoneConnection(from: .rightKnee, to: .rightAnkle, group: .rightLeg),

        // Left arm
        BoneConnection(from: .leftShoulder, to: .leftElbow, group: .leftArm),
        BoneConnection(from: .leftElbow, to: .leftWrist, group: .leftArm),

        // Right arm
        BoneConnection(from: .rightShoulder, to: .rightElbow, group: .rightArm),
        BoneConnection(from: .rightElbow, to: .rightWrist, group: .rightArm),

        // Head/Neck
        BoneConnection(from: .neck, to: .nose, group: .head),
    ]

    // MARK: - Computed Properties

    /// Check if enough joints are detected for meaningful analysis
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

    /// Compute angle at a joint vertex
    func angle(from a: JointName, vertex: JointName, to b: JointName) -> Double? {
        guard let pointA = joints[a]?.point,
              let pointV = joints[vertex]?.point,
              let pointB = joints[b]?.point else { return nil }

        return AngleCalculator.angle(pointA: pointA, vertex: pointV, pointC: pointB)
    }

    /// Bounding box of all detected joints (normalized Vision coords, origin bottom-left)
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

    /// Get the center of mass approximation (midpoint of hips, or root)
    var centerOfMass: CGPoint? {
        if let root = joints[.root]?.point {
            return root
        }
        guard let leftHip = joints[.leftHip]?.point,
              let rightHip = joints[.rightHip]?.point else { return nil }
        return leftHip.midpoint(to: rightHip)
    }
}

// MARK: - Empty Pose

extension BodyPose {
    /// Create an empty pose (no joints detected) for a given frame
    static func empty(frameIndex: Int, timestamp: Double) -> BodyPose {
        BodyPose(frameIndex: frameIndex, timestamp: timestamp, joints: [:])
    }
}
// MARK: - Person Thumbnail Generator

import UIKit

struct PersonThumbnailGenerator {
    
    struct DetectedPerson: Identifiable {
        let id = UUID()
        let pose: BodyPose
        let thumbnail: UIImage
        let confidence: Float
    }
    
    static func generateThumbnails(from videoFrame: UIImage, poses: [BodyPose]) -> [DetectedPerson] {
        var people: [DetectedPerson] = []
        for pose in poses {
            guard let bbox = pose.boundingBox else { continue }
            if let croppedImage = cropImage(videoFrame, to: bbox) {
                let confidence = calculateAverageConfidence(pose)
                people.append(DetectedPerson(pose: pose, thumbnail: croppedImage, confidence: confidence))
            }
        }
        return people.sorted { $0.confidence > $1.confidence }
    }
    
    private static func cropImage(_ image: UIImage, to bbox: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let cropRect = CGRect(
            x: bbox.minX * imageSize.width,
            y: (1.0 - bbox.maxY) * imageSize.height,
            width: bbox.width * imageSize.width,
            height: bbox.height * imageSize.height
        )
        let padding = min(cropRect.width, cropRect.height) * 0.2
        let paddedRect = cropRect.insetBy(dx: -padding, dy: -padding)
        let clampedRect = CGRect(
            x: max(0, paddedRect.minX),
            y: max(0, paddedRect.minY),
            width: min(paddedRect.width, imageSize.width - max(0, paddedRect.minX)),
            height: min(paddedRect.height, imageSize.height - max(0, paddedRect.minY))
        )
        guard let cropped = cgImage.cropping(to: clampedRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
    
    private static func calculateAverageConfidence(_ pose: BodyPose) -> Float {
        let confidences = pose.joints.values.map { $0.confidence }
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Float(confidences.count)
    }
}

// MARK: - Tracking Correction Manager

import SwiftUI

@Observable
class TrackingCorrectionManager {
    enum FrameStatus {
        case autoTracked(confidence: CGFloat)
        case userConfirmed
        case needsReview
        case incorrect
        case noAthlete
        case empty
    }
    
    struct Issue: Identifiable {
        let id = UUID()
        let frameIndex: Int
        let type: IssueType
        enum IssueType {
            case lowConfidence(CGFloat)
            case potentialSwitch
            case userMarkedWrong
        }
    }
    
    private(set) var frameStatuses: [Int: FrameStatus] = [:]
    private(set) var issues: [Issue] = []
    private(set) var currentIssueIndex: Int?
    
    var hasIssues: Bool { !issues.isEmpty }
    var issueCount: Int { issues.count }
    
    func initialize(from trackingResult: SmartTrackingEngine.TrackingResult) {
        frameStatuses.removeAll()
        issues.removeAll()
        currentIssueIndex = nil
        for frameIndex in trackingResult.autoTrackedFrames {
            frameStatuses[frameIndex] = .autoTracked(confidence: 0.9)
        }
        for decision in trackingResult.decisionPoints {
            frameStatuses[decision.frameIndex] = .needsReview
            issues.append(Issue(frameIndex: decision.frameIndex, type: .lowConfidence(0.5)))
        }
        issues.sort { $0.frameIndex < $1.frameIndex }
    }
    
    func nextIssue() -> Int? {
        guard let current = currentIssueIndex else {
            currentIssueIndex = 0
            return issues.first?.frameIndex
        }
        if current + 1 < issues.count {
            currentIssueIndex = current + 1
            return issues[current + 1].frameIndex
        }
        return nil
    }
    
    func markFrameCorrect(_ frameIndex: Int) {
        frameStatuses[frameIndex] = .userConfirmed
        issues.removeAll { $0.frameIndex == frameIndex }
    }
    
    func status(for frameIndex: Int) -> FrameStatus {
        return frameStatuses[frameIndex] ?? .empty
    }
}

