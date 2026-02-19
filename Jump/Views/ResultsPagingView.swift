import SwiftUI

/// Paged results container with 4 swipeable tabs:
/// Approach Summary → Takeoff Instant (hero, default) → Peak Instant → Full Details
struct ResultsPagingView: View {
    let result: AnalysisResult
    let session: JumpSession
    let allFramePoses: [[BodyPose]]
    let assignments: [Int: FrameAssignment]
    let onJumpToFrame: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage = 1 // Default to Takeoff (hero screen)

    private let tabLabels = ["Approach", "Takeoff", "Peak", "Details"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector bar
                tabBar

                // Paged content
                TabView(selection: $selectedPage) {
                    ApproachSummaryView(result: result, onJumpToFrame: onJumpToFrame)
                        .tag(0)

                    TakeoffInstantView(
                        result: result,
                        session: session,
                        allFramePoses: allFramePoses,
                        assignments: assignments,
                        onJumpToFrame: onJumpToFrame
                    )
                    .tag(1)

                    PeakInstantView(
                        result: result,
                        session: session,
                        allFramePoses: allFramePoses,
                        assignments: assignments,
                        onJumpToFrame: onJumpToFrame
                    )
                    .tag(2)

                    ResultsDisplayView(result: result, session: session, onJumpToFrame: onJumpToFrame)
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(Color.jumpBackgroundTop)
            .navigationTitle("Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.jumpAccent)
                }
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabLabels.count, id: \.self) { index in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedPage = index
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(tabLabels[index])
                            .font(.caption.bold())
                            .foregroundStyle(selectedPage == index ? .jumpAccent : .jumpSubtle)

                        Rectangle()
                            .fill(selectedPage == index ? Color.jumpAccent : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .background(Color.jumpBackgroundTop)
    }
}
