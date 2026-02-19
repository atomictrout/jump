import SwiftUI

/// 4-card walkthrough shown on first launch.
/// Introduces the app workflow: Record → Select → Analyze → Coach.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentPage = 0

    private let cards: [(icon: String, title: String, subtitle: String, color: Color)] = [
        ("video.fill", "Record", "Film a high jump from the side,\n15-20 meters away at hip height.", .jumpAccent),
        ("person.crop.circle.badge.checkmark", "Select & Mark", "Tap to identify the athlete.\nMark the bar for calibration.", .athleteCyan),
        ("waveform.path.ecg", "Analyze", "Automatic pose detection and\nbiomechanical analysis.", .jumpSecondary),
        ("lightbulb.fill", "Coach", "Get technique feedback,\nangle measurements, and insights.", .phaseFlight),
    ]

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [.jumpBackgroundTop, .jumpBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    Button("Skip") {
                        onComplete()
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.jumpSubtle)
                    .padding()
                }

                Spacer()

                // Paged cards
                TabView(selection: $currentPage) {
                    ForEach(0..<cards.count, id: \.self) { index in
                        cardView(for: cards[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 400)

                Spacer()

                // Bottom button
                if currentPage == cards.count - 1 {
                    Button {
                        onComplete()
                    } label: {
                        Text("Get Started")
                            .font(.headline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.jumpAccent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                } else {
                    Button {
                        withAnimation { currentPage += 1 }
                    } label: {
                        Text("Next")
                            .font(.headline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.jumpCard)
                            .foregroundStyle(.jumpAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: - Card View

    private func cardView(for card: (icon: String, title: String, subtitle: String, color: Color)) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(card.color.opacity(0.15))
                    .frame(width: 120, height: 120)
                Image(systemName: card.icon)
                    .font(.system(size: 48))
                    .foregroundStyle(card.color)
            }

            Text(card.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(card.subtitle)
                .font(.body)
                .foregroundStyle(.jumpSubtle)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(.horizontal, 32)
    }
}
