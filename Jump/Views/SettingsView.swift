import SwiftUI
import SwiftData

/// App settings screen with measurement units, sex, display toggles, and data management.
struct SettingsView: View {
    @AppStorage(AppSettingsKey.measurementUnit) private var measurementUnit = MeasurementUnit.metric.rawValue
    @AppStorage(AppSettingsKey.athleteSex) private var athleteSex = AthleteSex.notSpecified.rawValue
    @AppStorage(AppSettingsKey.showSkeletonOverlay) private var showSkeleton = true
    @AppStorage(AppSettingsKey.showAngleBadges) private var showAngles = true
    @AppStorage(AppSettingsKey.hasSeenOnboarding) private var hasSeenOnboarding = false

    @Environment(\.modelContext) private var modelContext
    @Query private var sessions: [JumpSession]

    @State private var showClearDataAlert = false

    var body: some View {
        List {
            // MARK: - Measurement Section
            Section {
                Picker("Units", selection: $measurementUnit) {
                    ForEach(MeasurementUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit.rawValue)
                    }
                }

                Picker("Athlete", selection: $athleteSex) {
                    ForEach(AthleteSex.allCases) { sex in
                        Text(sex.displayName).tag(sex.rawValue)
                    }
                }
            } header: {
                Text("Measurement")
            } footer: {
                Text("Athlete sex affects center-of-mass calculations (de Leva 1996 body segment parameters).")
            }

            // MARK: - Display Section
            Section("Display") {
                Toggle("Skeleton Overlay", isOn: $showSkeleton)
                Toggle("Angle Badges", isOn: $showAngles)
            }

            // MARK: - Data Section
            Section {
                Button {
                    hasSeenOnboarding = false
                } label: {
                    Label("Show Walkthrough", systemImage: "book.pages")
                        .foregroundStyle(.jumpAccent)
                }

                Button(role: .destructive) {
                    showClearDataAlert = true
                } label: {
                    Label("Clear All Data", systemImage: "trash")
                }
            } header: {
                Text("Data")
            } footer: {
                Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s") stored")
            }

            // MARK: - About Section
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear All Data?", isPresented: $showClearDataAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                clearAllData()
            }
        } message: {
            Text("This will permanently delete all \(sessions.count) session(s) and their video files. This cannot be undone.")
        }
    }

    private func clearAllData() {
        for session in sessions {
            if let url = session.videoURL {
                try? FileManager.default.removeItem(at: url)
            }
            modelContext.delete(session)
        }
    }
}
