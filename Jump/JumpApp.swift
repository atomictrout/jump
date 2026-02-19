import SwiftUI
import SwiftData

@main
struct JumpApp: App {
    @AppStorage(AppSettingsKey.hasSeenOnboarding) private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .preferredColorScheme(.dark)
            .fullScreenCover(isPresented: .init(
                get: { !hasSeenOnboarding },
                set: { _ in }
            )) {
                OnboardingView {
                    hasSeenOnboarding = true
                }
            }
        }
        .modelContainer(for: JumpSession.self)
    }
}
