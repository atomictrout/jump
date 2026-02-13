import AVFoundation
import CoreImage
import UIKit

struct VideoFrameExtractor {

    /// Extract a single frame image at a specific time for display
    static func extractImage(from url: URL, at time: CMTime) async throws -> CGImage {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let (image, _) = try await generator.image(at: time)
        return image
    }

    /// Extract frame at a specific frame index given the frame rate
    static func extractFrame(from url: URL, frameIndex: Int, frameRate: Double) async throws -> CGImage {
        let seconds = Double(frameIndex) / frameRate
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try await extractImage(from: url, at: time)
    }

    /// Stream all frames from a video for processing.
    /// Calls the handler for each frame with (frameIndex, pixelBuffer, timestamp).
    /// Uses autoreleasepool to manage memory.
    static func streamFrames(
        from url: URL,
        onFrame: @escaping (Int, CVPixelBuffer, Double) throws -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw JumpSessionError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )
        readerOutput.alwaysCopiesSampleData = false

        reader.add(readerOutput)

        guard reader.startReading() else {
            throw JumpSessionError.frameExtractionFailed
        }

        var frameIndex = 0
        let frameRate = try await Double(videoTrack.load(.nominalFrameRate))
        let totalFrames = Int(duration * frameRate)

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            // Process frame inside autoreleasepool to manage ObjC temporaries
            try autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                try onFrame(frameIndex, pixelBuffer, timestamp)
            }

            frameIndex += 1
            if totalFrames > 0 {
                onProgress(Double(frameIndex) / Double(totalFrames))
            }

            // Yield periodically so progress updates and UI can process
            if frameIndex % 10 == 0 {
                await Task.yield()
            }
        }

        if reader.status == .failed, let error = reader.error {
            throw error
        }
    }

    /// Extract a CGImage from a CVPixelBuffer
    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
