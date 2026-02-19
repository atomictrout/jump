import AVFoundation
import CoreImage
import UIKit

struct VideoFrameExtractor {

    /// Extract a single frame image at a specific time for display.
    static func extractImage(from url: URL, at time: CMTime) async throws -> CGImage {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let (image, _) = try await generator.image(at: time)
        return image
    }

    /// Extract frame at a specific frame index given the frame rate.
    ///
    /// - Parameter trimStartOffset: When working with trimmed video, frame 0 corresponds to
    ///   `trimStartOffset` seconds in the original video. Pass 0 for untrimmed.
    static func extractFrame(from url: URL, frameIndex: Int, frameRate: Double, trimStartOffset: Double = 0) async throws -> CGImage {
        let seconds = Double(frameIndex) / frameRate + trimStartOffset
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try await extractImage(from: url, at: time)
    }

    /// Extract a single frame as a CVPixelBuffer at a specific frame index.
    /// Used for crop-and-redetect recovery pass where we need the raw pixel buffer.
    ///
    /// - Parameter trimStartOffset: When working with trimmed video, frame 0 corresponds to
    ///   `trimStartOffset` seconds in the original video. Pass 0 for untrimmed.
    static func extractPixelBuffer(from url: URL, frameIndex: Int, frameRate: Double, trimStartOffset: Double = 0) async throws -> CVPixelBuffer {
        let asset = AVAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw JumpSessionError.noVideoTrack
        }

        let targetSeconds = Double(frameIndex) / frameRate + trimStartOffset
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        let reader = try AVAssetReader(asset: asset)
        // Read a very small time range around the target frame
        let frameDuration = CMTime(seconds: 1.0 / frameRate, preferredTimescale: 600)
        let startTime = CMTimeMaximum(targetTime - frameDuration, .zero)
        let endTime = targetTime + frameDuration + frameDuration
        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )
        readerOutput.alwaysCopiesSampleData = true  // We need the buffer to outlive the sample

        reader.add(readerOutput)
        guard reader.startReading() else {
            throw JumpSessionError.frameExtractionFailed
        }

        // Read frames until we find the closest one to our target time
        var bestBuffer: CVPixelBuffer?
        var bestTimeDiff: Double = .infinity

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let diff = abs(pts - targetSeconds)
            if diff < bestTimeDiff {
                bestTimeDiff = diff
                bestBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                // Copy the pixel buffer since the sample buffer will be released
                if let source = bestBuffer {
                    bestBuffer = Self.copyPixelBuffer(source)
                }
            }
            // If we've passed the target, stop
            if pts > targetSeconds + (1.0 / frameRate) {
                break
            }
        }

        guard let result = bestBuffer else {
            throw JumpSessionError.frameExtractionFailed
        }
        return result
    }

    /// Deep-copy a CVPixelBuffer so it outlives the source CMSampleBuffer.
    /// Used internally for pixel buffer extraction and by VisionTrackingService for backward tracking.
    static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)

        var copy: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &copy)
        guard status == kCVReturnSuccess, let dest = copy else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        let srcAddress = CVPixelBufferGetBaseAddress(source)
        let destAddress = CVPixelBufferGetBaseAddress(dest)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(source)

        memcpy(destAddress, srcAddress, bytesPerRow * height)
        return dest
    }

    /// Stream all frames from a video for processing.
    ///
    /// - Parameters:
    ///   - url: Video file URL.
    ///   - trimRange: Optional time range (seconds) to restrict processing. nil = full video.
    ///   - onFrame: Called for each frame with (frameIndex, pixelBuffer, timestamp).
    ///   - onProgress: Called with 0.0-1.0 progress.
    static func streamFrames(
        from url: URL,
        trimRange: ClosedRange<Double>? = nil,
        onFrame: @escaping (Int, CVPixelBuffer, Double) throws -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw JumpSessionError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)

        // Apply trim range if specified
        if let trimRange {
            let startTime = CMTime(seconds: trimRange.lowerBound, preferredTimescale: 600)
            let endTime = CMTime(seconds: min(trimRange.upperBound, duration), preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: startTime, end: endTime)
        }

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
        let effectiveDuration = trimRange.map { $0.upperBound - $0.lowerBound } ?? duration
        let totalFrames = max(1, Int(effectiveDuration * frameRate))

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                try onFrame(frameIndex, pixelBuffer, timestamp)
            }

            frameIndex += 1
            if totalFrames > 0 {
                onProgress(min(1.0, Double(frameIndex) / Double(totalFrames)))
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

    /// Get video metadata without processing frames.
    static func videoInfo(from url: URL) async throws -> (duration: Double, frameRate: Double, totalFrames: Int, size: CGSize) {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw JumpSessionError.noVideoTrack
        }
        let frameRate = try await Double(videoTrack.load(.nominalFrameRate))
        let size = try await videoTrack.load(.naturalSize)
        let totalFrames = Int(duration * frameRate)
        return (duration, frameRate, totalFrames, size)
    }

    /// Extract a CGImage from a CVPixelBuffer.
    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
