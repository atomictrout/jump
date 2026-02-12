import SwiftUI
import PhotosUI
import AVFoundation

struct VideoImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = VideoImportViewModel()
    @State private var showCamera = false
    @State private var showPhotoPicker = false

    let onSessionCreated: (JumpSession) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.jumpBackgroundTop.ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    // Header
                    VStack(spacing: 8) {
                        Text("Select Video")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("Record a new jump or choose an existing video")
                            .font(.subheadline)
                            .foregroundStyle(.jumpSubtle)
                    }

                    Spacer()

                    // Import options
                    VStack(spacing: 16) {
                        // Record video
                        ImportOptionButton(
                            icon: "video.fill",
                            title: "Record Video",
                            subtitle: "Use your camera to film a jump",
                            color: .jumpAccent
                        ) {
                            showCamera = true
                        }

                        // Choose from library
                        ImportOptionButton(
                            icon: "photo.on.rectangle",
                            title: "Photo Library",
                            subtitle: "Select an existing video",
                            color: .jumpSecondary
                        ) {
                            showPhotoPicker = true
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    // Tips section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Recording Tips", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundStyle(.jumpSecondary)

                        TipRow(icon: "camera.metering.center.weighted", text: "Position camera perpendicular to the bar")
                        TipRow(icon: "arrow.left.and.right", text: "Stand 15-20 meters from the pit")
                        TipRow(icon: "arrow.up.and.down", text: "Hold camera at hip height")
                        TipRow(icon: "video", text: "Capture the full approach and landing")
                    }
                    .padding()
                    .background(Color.jumpCard)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)

                    Spacer()
                        .frame(height: 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(.jumpAccent)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraRecorderView { url in
                    Task {
                        await viewModel.handleVideoSelected(url: url)
                    }
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $viewModel.selectedPhotoItem,
                matching: .videos,
                photoLibrary: .shared()
            )
            .overlay {
                if viewModel.isLoading {
                    LoadingOverlay(message: "Preparing video...")
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .onChange(of: viewModel.session) { _, session in
                if let session {
                    dismiss()
                    onSessionCreated(session)
                }
            }
        }
    }
}

// MARK: - Subviews

struct ImportOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.2))
                    .foregroundStyle(color)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(.jumpSubtle)
            }
            .padding()
            .background(Color.jumpCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.jumpAccent)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(.jumpSubtle)
        }
    }
}

struct LoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.jumpAccent)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

#Preview {
    VideoImportView { _ in }
}
