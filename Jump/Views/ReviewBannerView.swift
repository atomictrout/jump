import SwiftUI

/// Banner overlay shown when reviewing flagged (uncertain) tracking frames.
/// Provides action buttons for the user to correct or confirm assignments.
struct ReviewBannerView: View {
    let currentReviewFrame: Int
    let totalReviewFrames: Int
    let reviewProgress: String
    let currentAssignment: FrameAssignment?
    let personCount: Int

    // Actions
    let onTapSkeleton: () -> Void       // Switch to tap-to-select mode
    let onNoAthlete: () -> Void         // Mark frame as no athlete
    let onKeep: () -> Void              // Accept the current assignment
    let onPrevious: () -> Void          // Go to previous flagged frame
    let onNext: () -> Void              // Skip / go to next
    let onDone: () -> Void              // Finish review

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(.trackingUncertain)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Review Tracking")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(reviewProgress)
                        .font(.caption2)
                        .foregroundStyle(.jumpSubtle)
                }

                Spacer()

                Button(action: onDone) {
                    Text("Done")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.green.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Action buttons row
            HStack(spacing: 8) {
                // Tap skeleton to re-select
                actionButton(
                    icon: "hand.tap",
                    label: "Tap",
                    color: .athleteCyan,
                    action: onTapSkeleton
                )

                // No athlete in this frame
                actionButton(
                    icon: "person.slash",
                    label: "No Athlete",
                    color: .jumpSubtle,
                    action: onNoAthlete
                )

                // Keep current assignment
                actionButton(
                    icon: "checkmark",
                    label: "Keep",
                    color: .trackingLocked,
                    action: onKeep
                )

                Spacer()

                // Navigation
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                        .font(.body.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Color.jumpCard)
                        .clipShape(Circle())
                }

                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                        .font(.body.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Color.jumpCard)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func actionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
        }
    }
}
