import Foundation
import AVFoundation

struct JumpSession: Identifiable, Sendable {
    let id: UUID
    let videoURL: URL
    let createdAt: Date
    var duration: Double
    var frameRate: Double
    var totalFrames: Int
    var naturalSize: CGSize
    var barHeightMeters: Double?    // known real bar height set by user
    var videoCaption: String?       // raw caption extracted from video metadata

    init(
        id: UUID = UUID(),
        videoURL: URL,
        createdAt: Date = Date(),
        duration: Double = 0,
        frameRate: Double = 30,
        totalFrames: Int = 0,
        naturalSize: CGSize = .zero,
        barHeightMeters: Double? = nil,
        videoCaption: String? = nil
    ) {
        self.id = id
        self.videoURL = videoURL
        self.createdAt = createdAt
        self.duration = duration
        self.frameRate = frameRate
        self.totalFrames = totalFrames
        self.naturalSize = naturalSize
        self.barHeightMeters = barHeightMeters
        self.videoCaption = videoCaption
    }

    /// Load video metadata from the asset, including any caption/description
    static func create(from url: URL) async throws -> JumpSession {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw JumpSessionError.noVideoTrack
        }

        let frameRate = try await Double(videoTrack.load(.nominalFrameRate))
        let naturalSize = try await videoTrack.load(.naturalSize)
        let totalFrames = Int(duration * frameRate)

        // Try to extract caption from video metadata
        var caption: String?
        let metadata = try? await asset.load(.commonMetadata)
        if let metadata {
            // Check for title or description in common metadata
            for item in metadata {
                let key = item.commonKey
                if key == .commonKeyTitle || key == .commonKeyDescription {
                    if let stringValue = try? await item.load(.stringValue), !stringValue.isEmpty {
                        caption = stringValue
                        break
                    }
                }
            }
        }

        return JumpSession(
            videoURL: url,
            duration: duration,
            frameRate: frameRate,
            totalFrames: totalFrames,
            naturalSize: naturalSize,
            videoCaption: caption
        )
    }
}

enum JumpSessionError: LocalizedError {
    case noVideoTrack
    case frameExtractionFailed
    case poseDetectionFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in the selected file."
        case .frameExtractionFailed:
            return "Failed to extract frames from the video."
        case .poseDetectionFailed:
            return "Failed to detect body pose in the video."
        }
    }
}
