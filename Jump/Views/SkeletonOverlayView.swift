import SwiftUI

struct SkeletonOverlayView: View {
    let pose: BodyPose
    let viewSize: CGSize
    let offset: CGPoint
    let barDetection: BarDetectionResult?

    // Configuration
    var boneLineWidth: CGFloat = 3.0
    var jointRadius: CGFloat = 4.0
    var headRadius: CGFloat = 10.0
    
    // Multi-person support: override colors
    var color: Color? = nil
    var lineWidth: CGFloat? = nil
    var opacity: Double = 1.0

    var body: some View {
        Canvas { context, size in
            let convertedJoints = CoordinateConverter.convertPose(
                pose,
                to: viewSize,
                offset: offset
            )

            // Draw bones
            drawBones(context: &context, joints: convertedJoints)

            // Draw joints
            drawJoints(context: &context, joints: convertedJoints)

            // Draw head circle
            drawHead(context: &context, joints: convertedJoints)

            // Draw bar if detected
            if let bar = barDetection {
                drawBar(context: &context, bar: bar)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drawing

    private func drawBones(
        context: inout GraphicsContext,
        joints: [BodyPose.JointName: CGPoint]
    ) {
        for connection in BodyPose.boneConnections {
            guard let fromPoint = joints[connection.from],
                  let toPoint = joints[connection.to] else { continue }

            // Check confidence
            guard (pose.joints[connection.from]?.confidence ?? 0) > 0.2,
                  (pose.joints[connection.to]?.confidence ?? 0) > 0.2 else { continue }

            let boneColor = color ?? defaultColor(for: connection.group)
            let width = lineWidth ?? boneLineWidth

            var path = Path()
            path.move(to: fromPoint)
            path.addLine(to: toPoint)

            context.stroke(
                path,
                with: .color(boneColor.opacity(opacity)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }
    }

    private func drawJoints(
        context: inout GraphicsContext,
        joints: [BodyPose.JointName: CGPoint]
    ) {
        for (jointName, point) in joints {
            guard jointName != .nose else { continue } // Nose is drawn as head
            guard (pose.joints[jointName]?.confidence ?? 0) > 0.2 else { continue }

            let rect = CGRect(
                x: point.x - jointRadius,
                y: point.y - jointRadius,
                width: jointRadius * 2,
                height: jointRadius * 2
            )

            let jointColor = color ?? .skeletonJoint
            context.fill(
                Path(ellipseIn: rect),
                with: .color(jointColor.opacity(opacity))
            )
        }
    }

    private func drawHead(
        context: inout GraphicsContext,
        joints: [BodyPose.JointName: CGPoint]
    ) {
        guard let nosePoint = joints[.nose],
              (pose.joints[.nose]?.confidence ?? 0) > 0.2 else { return }

        let rect = CGRect(
            x: nosePoint.x - headRadius,
            y: nosePoint.y - headRadius,
            width: headRadius * 2,
            height: headRadius * 2
        )

        let headColor = color ?? .skeletonHead
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(headColor.opacity(opacity)),
            style: StrokeStyle(lineWidth: 2)
        )
    }

    private func drawBar(
        context: inout GraphicsContext,
        bar: BarDetectionResult
    ) {
        let startPoint = CoordinateConverter.visionToView(
            point: bar.barLineStart,
            viewSize: viewSize,
            offset: offset
        )
        let endPoint = CoordinateConverter.visionToView(
            point: bar.barLineEnd,
            viewSize: viewSize,
            offset: offset
        )

        var path = Path()
        path.move(to: startPoint)
        path.addLine(to: endPoint)

        context.stroke(
            path,
            with: .color(.barLine),
            style: StrokeStyle(
                lineWidth: 2.5,
                lineCap: .round,
                dash: [8, 4]
            )
        )

        // Bar endpoint dots (small)
        for point in [startPoint, endPoint] {
            let dotRect = CGRect(
                x: point.x - 3,
                y: point.y - 3,
                width: 6,
                height: 6
            )
            context.fill(
                Path(ellipseIn: dotRect),
                with: .color(.barLine)
            )
        }
    }

    // MARK: - Colors

    private func defaultColor(for group: BodyPose.SegmentGroup) -> Color {
        switch group {
        case .torso: return .skeletonTorso
        case .leftLeg, .rightLeg: return .skeletonLegs
        case .leftArm, .rightArm: return .skeletonArms
        case .head: return .skeletonHead
        }
    }
}
