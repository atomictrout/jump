import Foundation
import SwiftUI

struct HomeView: View {
    @State private var showVideoImport = false
    @State private var selectedSession: JumpSession?
    @State private var showSettings = false
    @State private var poseEngineSelection: PoseEngineSetting = {
        if let stored = UserDefaults.standard.string(forKey: "poseEngine"),
           let setting = PoseEngineSetting(rawValue: stored) {
            return setting
        } else {
            return .vision
        }
    }()

    enum PoseEngineSetting: String, CaseIterable, Identifiable {
        case vision, blazePose
        var id: String { rawValue }
        var label: String {
            switch self {
            case .vision: return "Apple Vision"
            case .blazePose: return "MediaPipe BlazePose"
            }
        }
    }

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
                    Image("HighJumpIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .shadow(color: .jumpAccent.opacity(0.3), radius: 16)

                    Text("Jump")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    HStack {
                        Text("High Jump Analysis")
                            .font(.title3)
                            .foregroundStyle(.jumpSubtle)
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.horizontal)
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
        .overlay(alignment: .topTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.jumpSubtle)
                    .font(.title2)
                    .accessibilityLabel("Settings")
                    .padding(.top, UIApplication.shared.windows.first?.safeAreaInsets.top ?? 16)
                    .padding(.trailing, 16)
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
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .onAppear {
            PoseDetectionService.poseEngine = poseEngineSelection == .blazePose ? .blazePose : .vision
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Pose Engine") {
                    Picker("Select Pose Engine", selection: $poseEngineSelection) {
                        ForEach(PoseEngineSetting.allCases) { setting in
                            Text(setting.label).tag(setting)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: poseEngineSelection) { newValue in
                        PoseDetectionService.poseEngine = newValue == .blazePose ? .blazePose : .vision
                        UserDefaults.standard.set(newValue.rawValue, forKey: "poseEngine")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showSettings = false
                    }
                }
            }
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
