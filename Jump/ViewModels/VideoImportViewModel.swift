import SwiftUI
import PhotosUI
import AVFoundation

@Observable
class VideoImportViewModel {
    var selectedPhotoItem: PhotosPickerItem? {
        didSet {
            if let item = selectedPhotoItem {
                Task { await loadVideo(from: item) }
            }
        }
    }

    var session: JumpSession?
    var isLoading = false
    var showError = false
    var errorMessage = ""

    @MainActor
    func handleVideoSelected(url: URL) async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Copy to app documents directory for persistent access
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let destinationURL = documentsURL.appendingPathComponent("jump_\(UUID().uuidString).mov")

            // If the source is a temp file, move it; otherwise copy
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: url, to: destinationURL)

            session = try await JumpSession.create(from: destinationURL)
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
            // Load video data from photo library
            guard let videoData = try await item.loadTransferable(type: VideoTransferable.self) else {
                throw VideoImportError.loadFailed
            }

            session = try await JumpSession.create(from: videoData.url)
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
        case .loadFailed:
            return "Failed to load the selected video."
        case .copyFailed:
            return "Failed to save the video file."
        }
    }
}
