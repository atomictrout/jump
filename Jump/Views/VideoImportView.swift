import SwiftUI
import PhotosUI
import AVFoundation

struct VideoImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var pendingSession: JumpSession?
    @State private var showTrimView = false

    let onSessionCreated: (JumpSession) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.jumpBackgroundTop.ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    VStack(spacing: 8) {
                        Text("Select Video")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("Record a new jump or choose an existing video")
                            .font(.subheadline)
                            .foregroundStyle(.jumpSubtle)
                    }

                    Spacer()

                    VStack(spacing: 16) {
                        ImportOptionButton(
                            icon: "video.fill",
                            title: "Record Video",
                            subtitle: "Use your camera to film a jump",
                            color: .jumpAccent
                        ) {
                            showCamera = true
                        }

                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .videos,
                            photoLibrary: .shared()
                        ) {
                            HStack(spacing: 16) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(Color.jumpSecondary.opacity(0.2))
                                    .foregroundStyle(.jumpSecondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Photo Library")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text("Select an existing video")
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
                    .padding(.horizontal, 24)

                    Spacer()

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
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.jumpAccent)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraRecorderView { url in
                    Task { await handleVideoSelected(url: url) }
                }
            }
            .onChange(of: selectedPhotoItem) { _, item in
                if let item {
                    Task { await loadVideo(from: item) }
                }
            }
            .overlay {
                if isLoading {
                    LoadingOverlay(message: "Preparing video...")
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showTrimView) {
                if let session = pendingSession {
                    VideoTrimView(session: session) { trimRange in
                        if let range = trimRange {
                            session.trimStartSeconds = range.lowerBound
                            session.trimEndSeconds = range.upperBound
                            // Update totalFrames to reflect trimmed duration
                            let trimmedDuration = range.upperBound - range.lowerBound
                            session.totalFrames = Int(trimmedDuration * session.frameRate)
                        }
                        dismiss()
                        onSessionCreated(session)
                    }
                }
            }
        }
    }

    // MARK: - Video Handling

    @MainActor
    private func handleVideoSelected(url: URL) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let destinationURL = documentsURL.appendingPathComponent("jump_\(UUID().uuidString).mov")

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: url, to: destinationURL)

            let session = try await JumpSession.create(from: destinationURL)
            pendingSession = session
            showTrimView = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func loadVideo(from item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }

        do {
            guard let videoData = try await item.loadTransferable(type: VideoTransferable.self) else {
                throw VideoImportError.loadFailed
            }
            let session = try await JumpSession.create(from: videoData.url)
            pendingSession = session
            showTrimView = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Video Transferable

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { transferable in
            SentTransferredFile(transferable.url)
        } importing: { received in
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let destinationURL = documentsURL.appendingPathComponent("jump_\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destinationURL)
            return VideoTransferable(url: destinationURL)
        }
    }
}

enum VideoImportError: LocalizedError {
    case loadFailed
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "Failed to load the selected video."
        case .copyFailed: return "Failed to save the video file."
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
            Color.black.opacity(0.6).ignoresSafeArea()
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
