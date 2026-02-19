import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JumpSession.createdAt, order: .reverse) private var sessions: [JumpSession]
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

            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("Jump")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.jumpSubtle)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showVideoImport = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.jumpAccent)
                }
                .accessibilityLabel("New Analysis")
            }
        }
        .fullScreenCover(isPresented: $showVideoImport) {
            VideoImportView { session in
                modelContext.insert(session)
                selectedSession = session
            }
        }
        .navigationDestination(item: $selectedSession) { session in
            VideoAnalysisView(session: session)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image("HighJumpIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .jumpAccent.opacity(0.3), radius: 16)

                Text("Jump")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("High Jump Analysis")
                    .font(.title3)
                    .foregroundStyle(.jumpSubtle)
            }

            Spacer()

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

                HStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .foregroundStyle(.jumpSecondary)
                    Text("Best results: film from the side, 15-20m away, at hip height")
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 40)
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            ForEach(sessions) { session in
                SessionCardView(session: session)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedSession = session
                    }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    deleteSession(sessions[index])
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func deleteSession(_ session: JumpSession) {
        // Clean up the video file
        if let url = session.videoURL {
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(session)
    }
}

// MARK: - Session Card

struct SessionCardView: View {
    let session: JumpSession

    var body: some View {
        HStack(spacing: 16) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 48, height: 48)
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let height = session.barHeightMeters {
                    Text(String(format: "%.2fm", height))
                        .font(.headline)
                        .foregroundStyle(.white)
                } else {
                    Text("In Progress")
                        .font(.headline)
                        .foregroundStyle(.white)
                }

                Text(session.summaryText)
                    .font(.caption)
                    .foregroundStyle(.jumpSubtle)
                    .lineLimit(1)

                Text(session.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.jumpSubtle.opacity(0.7))
            }

            Spacer()

            if let cleared = session.jumpCleared {
                Image(systemName: cleared ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(cleared ? .green : .red)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.jumpSubtle)
            }
        }
        .padding()
        .background(Color.jumpCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var statusColor: Color {
        if session.analysisComplete { return .green }
        if session.barMarkingComplete { return .jumpSecondary }
        if session.personSelectionComplete { return .jumpAccent }
        return .jumpSubtle
    }

    private var statusIcon: String {
        if session.analysisComplete { return "checkmark.circle.fill" }
        if session.barMarkingComplete { return "ruler" }
        if session.personSelectionComplete { return "person.crop.circle" }
        return "film"
    }
}

// MARK: - JumpSession Hashable (for navigationDestination)

extension JumpSession: Hashable {
    static func == (lhs: JumpSession, rhs: JumpSession) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
