import AVFoundation
import UIKit

struct ThumbnailGenerator {

    /// Generate evenly-spaced thumbnails from a video for the scrubber strip.
    /// Uses AVAssetImageGenerator with a small maximumSize for memory efficiency.
    static func generateThumbnails(
        from url: URL,
        count: Int,
        maxSize: CGSize = CGSize(width: 80, height: 60)
    ) async throws -> [UIImage] {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)

        guard duration.seconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize

        let interval = duration.seconds / Double(count)
        var thumbnails: [UIImage] = []

        for i in 0..<count {
            let time = CMTime(seconds: Double(i) * interval, preferredTimescale: 600)
            do {
                let (cgImage, _) = try await generator.image(at: time)
                thumbnails.append(UIImage(cgImage: cgImage))
            } catch {
                // If a single thumbnail fails, add a placeholder
                thumbnails.append(UIImage())
            }
        }

        return thumbnails
    }
}
