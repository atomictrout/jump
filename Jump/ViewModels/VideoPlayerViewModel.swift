import SwiftUI
import AVFoundation

/// Manages video frame extraction, playback, and scrubbing.
@Observable
@MainActor
final class VideoPlayerViewModel {
    // MARK: - State

    var currentFrameIndex: Int = 0
    var totalFrames: Int = 0
    var currentFrameImage: CGImage?
    var isLoading = false
    var isPlaying = false
    var duration: Double = 0
    var frameRate: Double = 30
    var playbackSpeed: Double = 1.0

    /// Timestamp relative to the analysis start (trim-aware).
    /// Frame 0 = 0.0s even if the video is trimmed.
    var currentTimestamp: Double {
        guard frameRate > 0 else { return 0 }
        return Double(currentFrameIndex) / frameRate
    }

    /// Absolute timestamp in the original video file (used for frame extraction).
    private var absoluteTimestamp: Double {
        currentTimestamp + trimStartOffset
    }

    var formattedTimestamp: String {
        let seconds = currentTimestamp
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, frac)
    }

    // MARK: - Private

    private var videoURL: URL?
    private var imageCache = NSCache<NSNumber, CGImageWrapper>()
    private var playbackTask: Task<Void, Never>?

    /// Time offset for trimmed videos. Frame 0 of analysis corresponds to this time in the video.
    /// When no trim is applied, this is 0. When trimmed, equals `trimStartSeconds`.
    private var trimStartOffset: Double = 0

    init() {
        imageCache.countLimit = 50
    }

    // MARK: - Setup

    func loadVideo(session: JumpSession) async {
        guard let url = session.videoURL else { return }

        isLoading = true
        defer { isLoading = false }

        videoURL = url
        frameRate = session.frameRate

        // When the video is trimmed, the player frame index 0 must correspond to
        // the trim start, not the beginning of the raw video. This ensures overlays
        // (poses, bounding boxes, path trail) align with the correct video frame.
        if let trimRange = session.trimRange {
            trimStartOffset = trimRange.lowerBound
            let trimmedDuration = trimRange.upperBound - trimRange.lowerBound
            duration = trimmedDuration
            totalFrames = Int(trimmedDuration * frameRate)
        } else {
            trimStartOffset = 0
            duration = session.duration
            totalFrames = session.totalFrames
        }

        // Display first frame
        await seekToFrame(0)
    }

    // MARK: - Frame Navigation

    func seekToFrame(_ index: Int) async {
        guard let url = videoURL else { return }

        let clampedIndex = max(0, min(index, totalFrames - 1))
        currentFrameIndex = clampedIndex

        // Check cache first
        if let cached = imageCache.object(forKey: NSNumber(value: clampedIndex)) {
            currentFrameImage = cached.image
            return
        }

        // Extract frame at the correct absolute time (accounting for trim offset).
        // Frame 0 of the analysis maps to trimStartOffset seconds in the raw video.
        let absoluteSeconds = Double(clampedIndex) / frameRate + trimStartOffset
        let time = CMTime(seconds: absoluteSeconds, preferredTimescale: 600)

        do {
            let image = try await VideoFrameExtractor.extractImage(
                from: url,
                at: time
            )
            currentFrameImage = image
            imageCache.setObject(CGImageWrapper(image: image), forKey: NSNumber(value: clampedIndex))
        } catch {
            print("Frame extraction failed for index \(clampedIndex): \(error)")
        }
    }

    func stepForward() async {
        await seekToFrame(currentFrameIndex + 1)
    }

    func stepBackward() async {
        await seekToFrame(currentFrameIndex - 1)
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
    }

    private func startPlayback() {
        isPlaying = true
        playbackTask = Task { @MainActor in
            let frameDuration = 1.0 / (frameRate * playbackSpeed)
            while isPlaying && currentFrameIndex < totalFrames - 1 {
                await seekToFrame(currentFrameIndex + 1)
                try? await Task.sleep(for: .seconds(frameDuration))
            }
            isPlaying = false
        }
    }

    func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    // MARK: - Cache Management

    func clearCache() {
        imageCache.removeAllObjects()
    }
}

/// Wrapper to store CGImage in NSCache.
final class CGImageWrapper {
    let image: CGImage
    init(image: CGImage) {
        self.image = image
    }
}
