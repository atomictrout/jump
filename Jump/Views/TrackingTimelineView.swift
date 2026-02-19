import SwiftUI

/// A thin color-coded timeline showing per-frame athlete tracking status.
/// Each frame is a colored segment: cyan (confirmed/auto), orange (uncertain),
/// gray (no athlete), red (gap). White playhead shows current frame.
struct TrackingTimelineView: View {
    let assignments: [Int: FrameAssignment]
    let currentFrame: Int
    let totalFrames: Int
    let onSeekToFrame: (Int) -> Void

    private let timelineHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.jumpCard)

                // Frame segments — draw using Canvas for efficiency
                Canvas { context, size in
                    guard totalFrames > 0 else { return }
                    let frameWidth = size.width / CGFloat(totalFrames)

                    for frame in 0..<totalFrames {
                        let color = segmentColor(for: frame)
                        let x = CGFloat(frame) * frameWidth
                        let rect = CGRect(x: x, y: 0, width: max(frameWidth, 1), height: size.height)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))

                // Playhead
                if totalFrames > 1 {
                    let x = geo.size.width * CGFloat(currentFrame) / CGFloat(totalFrames - 1)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: timelineHeight + 4)
                        .offset(x: x)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        let frame = Int(fraction * CGFloat(totalFrames - 1))
                        onSeekToFrame(frame)
                    }
            )
        }
        .frame(height: timelineHeight)
    }

    // MARK: - Color Mapping

    private func segmentColor(for frame: Int) -> Color {
        guard let assignment = assignments[frame] else {
            return Color.trackingLost.opacity(0.3) // No assignment yet
        }

        switch assignment.timelineCategory {
        case .athleteConfirmed:
            return .athleteCyan
        case .athleteAuto:
            return .athleteCyan.opacity(0.7)
        case .athleteUncertain:
            return .trackingUncertain
        case .noAthlete:
            return .phaseNoAthlete
        case .gap:
            return .trackingLost
        }
    }
}
