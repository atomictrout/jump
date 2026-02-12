import SwiftUI

/// Draws angle arc indicators at joint positions on the video overlay
struct AngleBadgeView: View {
    let pose: BodyPose
    let viewSize: CGSize
    let offset: CGPoint
    let measurements: JumpMeasurements?

    var body: some View {
        Canvas { context, size in
            let joints = CoordinateConverter.convertPose(pose, to: viewSize, offset: offset)

            // Draw key angles if available
            drawAngleArc(
                context: &context,
                joints: joints,
                from: .leftHip, vertex: .leftKnee, to: .leftAnkle,
                label: "L Knee",
                color: .skeletonLegs
            )

            drawAngleArc(
                context: &context,
                joints: joints,
                from: .rightHip, vertex: .rightKnee, to: .rightAnkle,
                label: "R Knee",
                color: .skeletonLegs
            )

            drawAngleArc(
                context: &context,
                joints: joints,
                from: .leftShoulder, vertex: .leftElbow, to: .leftWrist,
                label: nil,
                color: .skeletonArms
            )

            drawAngleArc(
                context: &context,
                joints: joints,
                from: .rightShoulder, vertex: .rightElbow, to: .rightWrist,
                label: nil,
                color: .skeletonArms
            )
        }
        .allowsHitTesting(false)
    }

    private func drawAngleArc(
        context: inout GraphicsContext,
        joints: [BodyPose.JointName: CGPoint],
        from: BodyPose.JointName,
        vertex: BodyPose.JointName,
        to: BodyPose.JointName,
        label: String?,
        color: Color
    ) {
        guard let pointA = joints[from],
              let pointV = joints[vertex],
              let pointB = joints[to],
              let confA = pose.joints[from]?.confidence, confA > 0.3,
              let confV = pose.joints[vertex]?.confidence, confV > 0.3,
              let confB = pose.joints[to]?.confidence, confB > 0.3 else { return }

        let angle = AngleCalculator.angle(pointA: pointA, vertex: pointV, pointC: pointB)

        // Draw arc
        let radius: CGFloat = 20
        let startAngle = Angle(radians: atan2(Double(pointA.y - pointV.y), Double(pointA.x - pointV.x)))
        let endAngle = Angle(radians: atan2(Double(pointB.y - pointV.y), Double(pointB.x - pointV.x)))

        var arcPath = Path()
        arcPath.addArc(
            center: pointV,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )

        context.stroke(
            arcPath,
            with: .color(color.opacity(0.6)),
            style: StrokeStyle(lineWidth: 1.5)
        )

        // Draw angle label
        let midAngle = Angle(degrees: (startAngle.degrees + endAngle.degrees) / 2)
        let labelOffset: CGFloat = radius + 14
        let labelX = pointV.x + cos(midAngle.radians) * labelOffset
        let labelY = pointV.y + sin(midAngle.radians) * labelOffset

        let text = Text("\(Int(angle))°")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)

        context.draw(
            context.resolve(text),
            at: CGPoint(x: labelX, y: labelY)
        )
    }
}
