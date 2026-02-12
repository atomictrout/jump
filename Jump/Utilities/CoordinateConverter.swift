import CoreGraphics

struct CoordinateConverter {
    /// Convert a Vision normalized point (origin bottom-left, 0-1 range)
    /// to view coordinates (origin top-left).
    ///
    /// Vision coordinate system:
    ///   - Origin: bottom-left
    ///   - Range: (0,0) = bottom-left, (1,1) = top-right
    ///
    /// View coordinate system:
    ///   - Origin: top-left
    ///   - Range: (0,0) = top-left, (width, height) = bottom-right
    static func visionToView(
        point: CGPoint,
        viewSize: CGSize,
        offset: CGPoint = .zero
    ) -> CGPoint {
        let x = point.x * viewSize.width + offset.x
        let y = (1.0 - point.y) * viewSize.height + offset.y
        return CGPoint(x: x, y: y)
    }

    /// Convert view coordinates back to Vision normalized coordinates
    static func viewToVision(
        point: CGPoint,
        viewSize: CGSize,
        offset: CGPoint = .zero
    ) -> CGPoint {
        let x = (point.x - offset.x) / viewSize.width
        let y = 1.0 - ((point.y - offset.y) / viewSize.height)
        return CGPoint(x: x, y: y)
    }

    /// Convert all joints in a pose to view coordinates
    static func convertPose(
        _ pose: BodyPose,
        to viewSize: CGSize,
        offset: CGPoint = .zero
    ) -> [BodyPose.JointName: CGPoint] {
        var converted: [BodyPose.JointName: CGPoint] = [:]
        for (name, joint) in pose.joints {
            converted[name] = visionToView(
                point: joint.point,
                viewSize: viewSize,
                offset: offset
            )
        }
        return converted
    }
}
