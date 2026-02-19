import SwiftUI

/// Draws bone connections + joint circles for a detected body pose.
/// Uses Canvas for efficient rendering. Color-coded by segment group.
struct SkeletonOverlayView: View {
    let pose: BodyPose
    let viewSize: CGSize
    let offset: CGPoint

    // Appearance configuration
    var color: Color? = nil
    var lineWidth: CGFloat = 3.0
    var opacity: Double = 1.0
    var showJointDots: Bool = true
    var jointRadius: CGFloat = 4.0
    var headRadius: CGFloat = 10.0

    /// When true, ignores the @AppStorage setting and always renders.
    /// Used during person selection where the skeleton must be visible.
    var forceVisible: Bool = false

    @AppStorage(AppSettingsKey.showSkeletonOverlay) private var showSkeleton = true

    var body: some View {
        if !forceVisible && !showSkeleton {
            EmptyView()
        } else {
        Canvas { context, size in
            let convertedJoints = CoordinateConverter.convertPose(
                pose,
                to: viewSize,
                offset: offset
            )

            // Interpolated poses render with reduced opacity and dashed lines
            let effectiveOpacity = pose.isInterpolated ? opacity * 0.5 : opacity
            let dashPattern: [CGFloat] = pose.isInterpolated ? [6, 4] : []

            // Draw bones
            for connection in BodyPose.boneConnections {
                guard let fromPoint = convertedJoints[connection.from],
                      let toPoint = convertedJoints[connection.to] else { continue }

                guard (pose.joints[connection.from]?.confidence ?? 0) > 0.2,
                      (pose.joints[connection.to]?.confidence ?? 0) > 0.2 else { continue }

                let boneColor = color ?? defaultColor(for: connection.group)

                var path = Path()
                path.move(to: fromPoint)
                path.addLine(to: toPoint)

                context.stroke(
                    path,
                    with: .color(boneColor.opacity(effectiveOpacity)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dashPattern)
                )
            }

            // Draw joints
            if showJointDots {
                for (jointName, point) in convertedJoints {
                    guard jointName != .nose else { continue }
                    guard !jointName.isFace else { continue }
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
                        with: .color(jointColor.opacity(effectiveOpacity))
                    )
                }
            }

            // Draw head circle
            if let nosePoint = convertedJoints[.nose],
               (pose.joints[.nose]?.confidence ?? 0) > 0.2 {
                let rect = CGRect(
                    x: nosePoint.x - headRadius,
                    y: nosePoint.y - headRadius,
                    width: headRadius * 2,
                    height: headRadius * 2
                )

                let headColor = color ?? .skeletonHead
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(headColor.opacity(effectiveOpacity)),
                    style: StrokeStyle(lineWidth: 2, dash: dashPattern)
                )
            }
        }
        .allowsHitTesting(false)
        } // end if showSkeleton
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
