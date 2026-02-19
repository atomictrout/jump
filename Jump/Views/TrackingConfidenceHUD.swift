import SwiftUI

/// A small capsule badge displayed in the top-right of the video frame
/// showing the tracking status for the current frame.
///
/// Displays: colored status dot, status label, person count.
struct TrackingConfidenceHUD: View {
    let assignment: FrameAssignment?
    let personCount: Int

    var body: some View {
        HStack(spacing: 6) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Status label
            Text(statusLabel)
                .font(.system(.caption2, design: .rounded).bold())
                .foregroundStyle(.white)

            // Person count
            if personCount > 1 {
                Text("·")
                    .foregroundStyle(.white.opacity(0.5))
                Text("\(personCount)p")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.jumpSubtle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(statusColor.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Status Computation

    private var statusLabel: String {
        guard let assignment else { return "No Data" }

        switch assignment {
        case .athleteConfirmed:
            return "Locked"
        case .athleteAuto(_, let confidence):
            return confidence >= 0.7 ? "Tracking" : "Low Conf"
        case .athleteUncertain:
            return "Uncertain"
        case .noAthleteConfirmed, .noAthleteAuto:
            return "No Athlete"
        case .athleteNoPose:
            return "No Pose"
        case .unreviewedGap:
            return "Lost"
        }
    }

    private var statusColor: Color {
        guard let assignment else { return .jumpSubtle }

        switch assignment {
        case .athleteConfirmed:
            return .trackingLocked
        case .athleteAuto(_, let confidence):
            return confidence >= 0.7 ? .trackingTracking : .trackingUncertain
        case .athleteUncertain:
            return .trackingUncertain
        case .noAthleteConfirmed, .noAthleteAuto:
            return .jumpSubtle
        case .athleteNoPose:
            return .trackingLost
        case .unreviewedGap:
            return .trackingLost
        }
    }
}
