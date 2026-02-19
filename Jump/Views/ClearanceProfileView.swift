import SwiftUI

/// A clearance profile diagram showing per-body-part distance from the bar.
/// Renders a stylized body outline with clearance values at key joints.
struct ClearanceProfileView: View {
    let profile: ClearanceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Body Clearance Profile", systemImage: "figure.and.child.holdinghands")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            // Clearance items sorted by body position (head to feet)
            VStack(spacing: 0) {
                ForEach(sortedParts, id: \.key) { part, clearance in
                    clearanceRow(bodyPart: part, clearance: clearance)
                }
            }

            // Limiter indicator
            if let limiter = profile.limiterBodyPart {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Limiter: **\(limiter)**")
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                }
                .padding(.top, 4)
            }
        }
        .jumpCard()
    }

    // MARK: - Clearance Row

    private func clearanceRow(bodyPart: String, clearance: Double) -> some View {
        let cm = clearance * 100
        let color = clearanceColor(cm: cm)

        return HStack(spacing: 8) {
            // Body part icon
            Image(systemName: iconFor(bodyPart: bodyPart))
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 20)

            // Body part name
            Text(bodyPart)
                .font(.caption)
                .foregroundStyle(.jumpSubtle)
                .frame(width: 80, alignment: .leading)

            // Clearance bar
            GeometryReader { geo in
                let barWidth = min(abs(cm) / 20.0, 1.0) * geo.size.width
                ZStack(alignment: cm >= 0 ? .leading : .trailing) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.jumpCard.opacity(0.4))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.6))
                        .frame(width: barWidth)
                }
            }
            .frame(height: 10)

            // Value
            let sign = cm >= 0 ? "+" : ""
            Text(String(format: "%@%.0fcm", sign, cm))
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundStyle(color)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func clearanceColor(cm: Double) -> Color {
        if cm < 0 { return .red }
        if cm < 5 { return .yellow }
        return .green
    }

    private func iconFor(bodyPart: String) -> String {
        let lower = bodyPart.lowercased()
        if lower.contains("head") { return "brain.head.profile" }
        if lower.contains("shoulder") { return "figure.arms.open" }
        if lower.contains("hip") { return "figure.stand" }
        if lower.contains("knee") { return "figure.walk" }
        if lower.contains("foot") || lower.contains("feet") || lower.contains("ankle") { return "shoe.fill" }
        if lower.contains("hand") || lower.contains("wrist") { return "hand.raised" }
        return "circle"
    }

    private var sortedParts: [(key: String, value: Double)] {
        let order = ["Head", "Shoulders", "Hips", "Knees", "Feet"]
        return profile.partClearances.sorted { a, b in
            let aIdx = order.firstIndex(where: { a.key.lowercased().contains($0.lowercased()) }) ?? 99
            let bIdx = order.firstIndex(where: { b.key.lowercased().contains($0.lowercased()) }) ?? 99
            return aIdx < bIdx
        }
    }
}
