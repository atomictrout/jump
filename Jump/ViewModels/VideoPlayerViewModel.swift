import SwiftUI
import AVFoundation

@Observable
class VideoPlayerViewModel {
    // MARK: - State

    var currentFrameIndex: Int = 0
    var totalFrames: Int = 0
    var currentFrameImage: CGImage?
    var thumbnails: [UIImage] = []
    var isLoading = false
    var isPlaying = false
    var duration: Double = 0
    var frameRate: Double = 30

    var currentTimestamp: Double {
        guard frameRate > 0 else { return 0 }
        return Double(currentFrameIndex) / frameRate
    }

    // MARK: - Private

    private var videoURL: URL?
    private var imageCache = NSCache<NSNumber, CGImageWrapper>()
    private var playbackTask: Task<Void, Never>?

    init() {
        imageCache.countLimit = 30
    }

    // MARK: - Public Methods

    @MainActor
    func loadVideo(url: URL, session: JumpSession) async {
        isLoading = true
        defer { isLoading = false }

        videoURL = url
        duration = session.duration
        frameRate = session.frameRate
        totalFrames = session.totalFrames

        // Generate thumbnails for scrubber
        do {
            let thumbCount = min(60, max(20, totalFrames / 5))
            thumbnails = try await ThumbnailGenerator.generateThumbnails(
                from: url,
                count: thumbCount
            )
        } catch {
            // Thumbnails are non-critical
            print("Thumbnail generation failed: \(error)")
        }

        // Display first frame
        await seekToFrame(0)
    }

    @MainActor
    func seekToFrame(_ index: Int) async {
        guard let url = videoURL else { return }

        let clampedIndex = max(0, min(index, totalFrames - 1))
        currentFrameIndex = clampedIndex

        // Check cache first
        if let cached = imageCache.object(forKey: NSNumber(value: clampedIndex)) {
            currentFrameImage = cached.image
            return
        }

        // Extract frame
        do {
            let image = try await VideoFrameExtractor.extractFrame(
                from: url,
                frameIndex: clampedIndex,
                frameRate: frameRate
            )
            currentFrameImage = image
            imageCache.setObject(CGImageWrapper(image: image), forKey: NSNumber(value: clampedIndex))
        } catch {
            print("Frame extraction failed for index \(clampedIndex): \(error)")
        }
    }

    @MainActor
    func stepForward() async {
        await seekToFrame(currentFrameIndex + 1)
    }

    @MainActor
    func stepBackward() async {
        await seekToFrame(currentFrameIndex - 1)
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    // MARK: - Playback

    private func startPlayback() {
        isPlaying = true
        playbackTask = Task { @MainActor in
            let frameDuration = 1.0 / frameRate
            while isPlaying && currentFrameIndex < totalFrames - 1 {
                await seekToFrame(currentFrameIndex + 1)
                try? await Task.sleep(for: .seconds(frameDuration))
            }
            isPlaying = false
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }
}

/// Wrapper to store CGImage in NSCache
class CGImageWrapper {
    let image: CGImage
    init(image: CGImage) {
        self.image = image
    }
}
