import SwiftUI

struct HomeView: View {
    @State private var showVideoImport = false
    @State private var selectedSession: JumpSession?

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [.jumpBackgroundTop, .jumpBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // App logo / title
                VStack(spacing: 16) {
                    Image(systemName: "figure.track.and.field")
                        .font(.system(size: 72, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.jumpAccent, .jumpSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("Jump")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("High Jump Analysis")
                        .font(.title3)
                        .foregroundStyle(.jumpSubtle)
                }

                Spacer()

                // Action buttons
                VStack(spacing: 16) {
                    Button {
                        showVideoImport = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                            Text("New Analysis")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            LinearGradient(
                                colors: [.jumpAccent, .jumpAccent.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // Camera positioning tip
                    HStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .foregroundStyle(.jumpSecondary)
                        Text("Best results: film from the side, 15-20m away, at hip height")
                            .font(.caption)
                            .foregroundStyle(.jumpSubtle)
                    }
                    .padding(.horizontal)
                }
                .padding(.horizontal, 24)

                Spacer()
                    .frame(height: 40)
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showVideoImport) {
            VideoImportView { session in
                selectedSession = session
            }
        }
        .navigationDestination(item: $selectedSession) { session in
            VideoAnalysisView(session: session)
        }
    }
}

// Make JumpSession conform to Hashable for navigation
extension JumpSession: Hashable {
    static func == (lhs: JumpSession, rhs: JumpSession) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
}
