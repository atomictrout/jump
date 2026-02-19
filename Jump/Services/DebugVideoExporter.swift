import AVFoundation
import CoreGraphics
import CoreImage
import UIKit

/// Exports an annotated debug video with all tracking/detection overlays burned in.
///
/// The exported video includes:
/// - **Cyan skeleton**: Athlete's assigned pose (bones + joints)
/// - **Gray skeletons**: Other detected people (faded)
/// - **Yellow box**: VNTrackObjectRequest tracked bounding box
/// - **Cyan dashed box**: Athlete pose bounding box (from joint positions)
/// - **Orange crosshair**: Trajectory model prediction
/// - **Frame info**: Frame number, timestamp, assignment state, confidence, person count
/// - **Tracking timeline bar**: Color-coded per-frame assignment strip at the bottom
///
/// All overlays are composited at the video's native resolution so small details are visible.
@MainActor
final class DebugVideoExporter {

    // MARK: - Types

    struct ExportProgress {
        let framesProcessed: Int
        let totalFrames: Int
        var progress: Double { Double(framesProcessed) / Double(max(totalFrames, 1)) }
    }

    // MARK: - Export

    /// Export an annotated debug video to a temporary file.
    ///
    /// - Parameters:
    ///   - session: The jump session with video URL and metadata.
    ///   - allFramePoses: All detected poses per frame.
    ///   - assignments: Per-frame athlete assignments.
    ///   - allFrameTrackedBoxes: VNTrackObjectRequest tracked boxes per frame.
    ///   - trajectoryModel: Fitted trajectory model for crosshair overlay.
    ///   - athletePath: Athlete position path points for trail overlay.
    ///   - takeoffFrame: Frame index where takeoff was detected (nil if not detected).
    ///   - onProgress: Progress callback.
    /// - Returns: URL of the exported video file.
    static func exportDebugVideo(
        session: JumpSession,
        allFramePoses: [[BodyPose]],
        assignments: [Int: FrameAssignment],
        allFrameTrackedBoxes: [CGRect?],
        trajectoryModel: TrajectoryValidator.TrajectoryModel?,
        athletePath: [SessionViewModel.AthletePathPoint] = [],
        takeoffFrame: Int? = nil,
        onProgress: @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        guard let videoURL = session.videoURL else {
            throw ExportError.noVideoURL
        }

        let videoSize = session.naturalSize
        guard videoSize.width > 0, videoSize.height > 0 else {
            throw ExportError.invalidVideoSize
        }

        let frameRate = session.frameRate
        let totalFrames = allFramePoses.count

        // Create output URL in temp directory
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jump_debug_\(Int(Date().timeIntervalSince1970)).mp4")

        // Clean up any existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Setup AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(videoSize.width * videoSize.height * 4),
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height)
            ]
        )

        writer.add(writerInput)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Stream frames and composite overlays
        let ciContext = CIContext()

        // Compute trim offset so exported video starts at t=0
        let trimStartOffset = session.trimRange?.lowerBound ?? 0

        try await VideoFrameExtractor.streamFrames(
            from: videoURL,
            trimRange: session.trimRange,
            onFrame: { currentFrame, pixelBuffer, timestamp in
                // Wait for writer to be ready
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                // Relative timestamp (0-based from trim start)
                let relativeTimestamp = timestamp - trimStartOffset

                // Composite debug overlays onto the frame
                let annotatedBuffer = Self.compositeOverlays(
                    onto: pixelBuffer,
                    frameIndex: currentFrame,
                    timestamp: relativeTimestamp,
                    videoSize: videoSize,
                    frameRate: frameRate,
                    totalFrames: totalFrames,
                    allFramePoses: allFramePoses,
                    assignments: assignments,
                    allFrameTrackedBoxes: allFrameTrackedBoxes,
                    trajectoryModel: trajectoryModel,
                    athletePath: athletePath,
                    takeoffFrame: takeoffFrame,
                    ciContext: ciContext
                )

                // Use relative timestamp so exported video starts at t=0, not t=trimStart
                let presentationTime = CMTime(seconds: max(0, relativeTimestamp), preferredTimescale: 600)
                adaptor.append(annotatedBuffer ?? pixelBuffer, withPresentationTime: presentationTime)
            },
            onProgress: { progress in
                let framesProcessed = Int(progress * Double(totalFrames))
                onProgress(ExportProgress(framesProcessed: framesProcessed, totalFrames: totalFrames))
            }
        )

        // Finalize
        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Finalization failed")
        }

        return outputURL
    }

    // MARK: - Frame Compositing

    /// Composite all debug overlays onto a single video frame.
    ///
    /// Uses UIGraphicsImageRenderer which natively handles UIKit's top-left coordinate
    /// system, avoiding CGContext Y-flip issues with text rendering.
    private static func compositeOverlays(
        onto pixelBuffer: CVPixelBuffer,
        frameIndex: Int,
        timestamp: Double,
        videoSize: CGSize,
        frameRate: Double,
        totalFrames: Int,
        allFramePoses: [[BodyPose]],
        assignments: [Int: FrameAssignment],
        allFrameTrackedBoxes: [CGRect?],
        trajectoryModel: TrajectoryValidator.TrajectoryModel?,
        athletePath: [SessionViewModel.AthletePathPoint],
        takeoffFrame: Int?,
        ciContext: CIContext
    ) -> CVPixelBuffer? {
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)

        // Convert pixel buffer to CGImage for base frame.
        // CIImage uses bottom-left origin, so the CGImage it produces has pixels stored
        // bottom-to-top relative to visual orientation.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        // Use UIGraphicsImageRenderer — handles UIKit's top-left coordinate system correctly
        let renderer = UIGraphicsImageRenderer(size: videoSize)
        let composited = renderer.image { rendererContext in
            // Draw the original video frame, flipping the CIImage-derived CGImage right-side-up.
            // CGImage from CIImage has bottom-left origin; UIGraphicsImageRenderer uses top-left.
            // We flip the CGContext for just this draw, then restore for overlays.
            let ctx = rendererContext.cgContext
            ctx.saveGState()
            ctx.translateBy(x: 0, y: videoSize.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: videoSize))
            ctx.restoreGState()

            // Now draw overlays in normal UIKit top-left coordinate system
            let assignment = assignments[frameIndex]
            let athleteIndex = assignment?.athletePoseIndex

            // 1. Draw tracked bounding box (yellow)
            if frameIndex < allFrameTrackedBoxes.count,
               let trackedBox = allFrameTrackedBoxes[frameIndex] {
                let pixelRect = normalizedToPixels(trackedBox, videoSize: videoSize)
                ctx.setStrokeColor(UIColor.yellow.withAlphaComponent(0.8).cgColor)
                ctx.setLineWidth(3.0)
                ctx.stroke(pixelRect)
            }

            // 2. Draw all detected skeletons
            if frameIndex < allFramePoses.count {
                let poses = allFramePoses[frameIndex]
                for (index, pose) in poses.enumerated() {
                    let isAthlete = index == athleteIndex
                    Self.drawSkeleton(
                        context: ctx,
                        pose: pose,
                        videoSize: videoSize,
                        color: isAthlete ? UIColor.cyan : UIColor.gray,
                        lineWidth: isAthlete ? 3.0 : 1.5,
                        alpha: isAthlete ? 1.0 : 0.4,
                        showJoints: isAthlete
                    )

                    // Draw athlete pose bounding box (cyan dashed)
                    if isAthlete, let poseBox = pose.boundingBox {
                        let pixelRect = normalizedToPixels(poseBox, videoSize: videoSize)
                        ctx.setStrokeColor(UIColor.cyan.withAlphaComponent(0.7).cgColor)
                        ctx.setLineWidth(2.0)
                        ctx.setLineDash(phase: 0, lengths: [8, 4])
                        ctx.stroke(pixelRect)
                        ctx.setLineDash(phase: 0, lengths: [])
                    }
                }
            }

            // 3. Draw trajectory crosshair (orange)
            if let model = trajectoryModel {
                let predicted = model.predictCenter(at: frameIndex)
                let pixelPoint = CGPoint(
                    x: predicted.x * videoSize.width,
                    y: predicted.y * videoSize.height
                )
                let crossSize: CGFloat = 15

                ctx.setStrokeColor(UIColor.orange.cgColor)
                ctx.setLineWidth(2.5)

                // Horizontal line
                ctx.move(to: CGPoint(x: pixelPoint.x - crossSize, y: pixelPoint.y))
                ctx.addLine(to: CGPoint(x: pixelPoint.x + crossSize, y: pixelPoint.y))
                ctx.strokePath()

                // Vertical line
                ctx.move(to: CGPoint(x: pixelPoint.x, y: pixelPoint.y - crossSize))
                ctx.addLine(to: CGPoint(x: pixelPoint.x, y: pixelPoint.y + crossSize))
                ctx.strokePath()

                // Circle
                let dotRect = CGRect(x: pixelPoint.x - 4, y: pixelPoint.y - 4, width: 8, height: 8)
                ctx.setFillColor(UIColor.orange.withAlphaComponent(0.6).cgColor)
                ctx.fillEllipse(in: dotRect)
            }

            // 4. Draw athlete path trail and takeoff marker
            Self.drawAthletePath(
                context: ctx,
                currentFrame: frameIndex,
                athletePath: athletePath,
                takeoffFrame: takeoffFrame,
                videoSize: videoSize
            )

            // 5. Draw frame info text (top-left)
            let assignmentText = assignmentDescription(assignment)
            let personCount = frameIndex < allFramePoses.count ? allFramePoses[frameIndex].count : 0
            let confidenceText = assignment.map { String(format: "%.0f%%", $0.confidence * 100) } ?? "—"

            let infoText = "F:\(frameIndex)/\(totalFrames)  T:\(String(format: "%.3f", timestamp))s  " +
                            "[\(assignmentText)]  Conf:\(confidenceText)  People:\(personCount)"

            Self.drawText(
                text: infoText,
                at: CGPoint(x: 10, y: 10),
                fontSize: max(16, videoSize.height / 50),
                color: .white,
                backgroundColor: UIColor.black.withAlphaComponent(0.7)
            )

            // 6. Draw trajectory info (top-right, if model exists)
            if let model = trajectoryModel {
                let predicted = model.predictCenter(at: frameIndex)
                let trajText = "Traj: (\(String(format: "%.3f", predicted.x)), \(String(format: "%.3f", predicted.y)))  " +
                               "R²:\(String(format: "%.3f", model.rSquared))  Anchors:\(model.anchorCount)"

                let font = UIFont.monospacedSystemFont(ofSize: max(14, videoSize.height / 60), weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                let textSize = (trajText as NSString).size(withAttributes: attrs)

                Self.drawText(
                    text: trajText,
                    at: CGPoint(x: videoSize.width - textSize.width - 18, y: 10),
                    fontSize: max(14, videoSize.height / 60),
                    color: .orange,
                    backgroundColor: UIColor.black.withAlphaComponent(0.7)
                )
            }

            // 7. Draw tracking timeline bar (bottom)
            let barHeight: CGFloat = max(12, videoSize.height / 60)
            let barY = videoSize.height - barHeight
            let frameWidth = videoSize.width / CGFloat(max(totalFrames, 1))

            for f in 0..<totalFrames {
                let color: UIColor
                switch assignments[f] {
                case .athleteConfirmed:
                    color = UIColor.cyan
                case .athleteAuto:
                    color = UIColor(red: 0, green: 0.7, blue: 0.7, alpha: 1)
                case .athleteUncertain:
                    color = UIColor.orange
                case .noAthleteConfirmed, .noAthleteAuto:
                    color = UIColor.darkGray
                case .athleteNoPose, .unreviewedGap:
                    color = UIColor.red
                case nil:
                    color = UIColor(white: 0.2, alpha: 1)
                }

                let rect = CGRect(x: CGFloat(f) * frameWidth, y: barY, width: max(frameWidth, 1), height: barHeight)
                ctx.setFillColor(color.cgColor)
                ctx.fill(rect)
            }

            // Current frame indicator on timeline
            let indicatorX = CGFloat(frameIndex) * frameWidth
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: indicatorX - 1, y: barY - 3, width: 3, height: barHeight + 6))
        }

        // Convert composited UIImage to pixel buffer using UIKit drawing
        // This avoids all CGContext/CGImage coordinate system issues.
        return pixelBufferFromUIImage(composited, width: width, height: height)
    }

    // MARK: - Drawing Helpers

    private static func drawSkeleton(
        context: CGContext,
        pose: BodyPose,
        videoSize: CGSize,
        color: UIColor,
        lineWidth: CGFloat,
        alpha: CGFloat,
        showJoints: Bool
    ) {
        let convertedJoints = CoordinateConverter.convertPose(pose, to: videoSize)

        // Draw bones
        context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(lineWidth)

        for connection in BodyPose.boneConnections {
            guard let fromPoint = convertedJoints[connection.from],
                  let toPoint = convertedJoints[connection.to] else { continue }

            guard (pose.joints[connection.from]?.confidence ?? 0) > 0.2,
                  (pose.joints[connection.to]?.confidence ?? 0) > 0.2 else { continue }

            context.move(to: fromPoint)
            context.addLine(to: toPoint)
            context.strokePath()
        }

        // Draw joints
        if showJoints {
            let jointRadius: CGFloat = max(4, videoSize.height / 200)
            context.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)

            for (jointName, point) in convertedJoints {
                guard !jointName.isFace, jointName != .nose else { continue }
                guard (pose.joints[jointName]?.confidence ?? 0) > 0.2 else { continue }

                let rect = CGRect(
                    x: point.x - jointRadius,
                    y: point.y - jointRadius,
                    width: jointRadius * 2,
                    height: jointRadius * 2
                )
                context.fillEllipse(in: rect)
            }

            // Head circle
            if let nosePoint = convertedJoints[.nose],
               (pose.joints[.nose]?.confidence ?? 0) > 0.2 {
                let headRadius: CGFloat = max(10, videoSize.height / 80)
                let rect = CGRect(
                    x: nosePoint.x - headRadius,
                    y: nosePoint.y - headRadius,
                    width: headRadius * 2,
                    height: headRadius * 2
                )
                context.setStrokeColor(UIColor.yellow.withAlphaComponent(alpha).cgColor)
                context.setLineWidth(2.0)
                context.strokeEllipse(in: rect)
            }
        }
    }

    /// Draw the athlete's path trail and takeoff marker.
    ///
    /// - Pre-takeoff: Green trail of foot contact positions (approach path on the ground)
    /// - Takeoff point: Red X marker on the ground
    /// - Post-takeoff: Magenta trail of center of mass (flight trajectory)
    ///
    /// Only draws path points up to the current frame for a progressive reveal effect.
    private static func drawAthletePath(
        context: CGContext,
        currentFrame: Int,
        athletePath: [SessionViewModel.AthletePathPoint],
        takeoffFrame: Int?,
        videoSize: CGSize
    ) {
        guard !athletePath.isEmpty else { return }

        // Filter to points up to the current frame
        let visiblePoints = athletePath.filter { $0.frameIndex <= currentFrame }
        guard !visiblePoints.isEmpty else { return }

        // Split into ground (pre-takeoff) and airborne (post-takeoff) segments
        let groundPoints = visiblePoints.filter { !$0.isAirborne }
        let airbornePoints = visiblePoints.filter { $0.isAirborne }

        // --- Draw ground path (green trail from foot contact) ---
        if groundPoints.count >= 2 {
            context.setStrokeColor(UIColor.green.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(3.0)
            context.setLineDash(phase: 0, lengths: [])

            var started = false
            for point in groundPoints {
                guard let foot = point.footContact else { continue }
                let pixel = CGPoint(x: foot.x * videoSize.width, y: foot.y * videoSize.height)

                if !started {
                    context.move(to: pixel)
                    started = true
                } else {
                    context.addLine(to: pixel)
                }
            }
            if started { context.strokePath() }

            // Draw small dots at each ground contact point
            context.setFillColor(UIColor.green.withAlphaComponent(0.5).cgColor)
            for point in groundPoints {
                guard let foot = point.footContact else { continue }
                let pixel = CGPoint(x: foot.x * videoSize.width, y: foot.y * videoSize.height)
                context.fillEllipse(in: CGRect(x: pixel.x - 2, y: pixel.y - 2, width: 4, height: 4))
            }
        }

        // --- Draw takeoff X marker ---
        if let tf = takeoffFrame, tf <= currentFrame {
            // Find the takeoff point (last ground contact or first airborne COM)
            let takeoffPoint: CGPoint?
            if let lastGround = groundPoints.last?.footContact {
                takeoffPoint = lastGround
            } else if let firstAir = airbornePoints.first?.centerOfMass {
                takeoffPoint = firstAir
            } else {
                takeoffPoint = nil
            }

            if let tp = takeoffPoint {
                let pixel = CGPoint(x: tp.x * videoSize.width, y: tp.y * videoSize.height)
                let xSize: CGFloat = 12

                context.setStrokeColor(UIColor.red.cgColor)
                context.setLineWidth(4.0)

                // Draw X
                context.move(to: CGPoint(x: pixel.x - xSize, y: pixel.y - xSize))
                context.addLine(to: CGPoint(x: pixel.x + xSize, y: pixel.y + xSize))
                context.strokePath()
                context.move(to: CGPoint(x: pixel.x + xSize, y: pixel.y - xSize))
                context.addLine(to: CGPoint(x: pixel.x - xSize, y: pixel.y + xSize))
                context.strokePath()
            }
        }

        // --- Draw flight trajectory (magenta trail from center of mass) ---
        if airbornePoints.count >= 2 {
            context.setStrokeColor(UIColor.magenta.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(3.0)

            var started = false
            for point in airbornePoints {
                guard let com = point.centerOfMass else { continue }
                let pixel = CGPoint(x: com.x * videoSize.width, y: com.y * videoSize.height)

                if !started {
                    context.move(to: pixel)
                    started = true
                } else {
                    context.addLine(to: pixel)
                }
            }
            if started { context.strokePath() }

            // Draw dots at each COM point
            context.setFillColor(UIColor.magenta.withAlphaComponent(0.6).cgColor)
            for point in airbornePoints {
                guard let com = point.centerOfMass else { continue }
                let pixel = CGPoint(x: com.x * videoSize.width, y: com.y * videoSize.height)
                context.fillEllipse(in: CGRect(x: pixel.x - 3, y: pixel.y - 3, width: 6, height: 6))
            }
        }
    }

    /// Draw text with background. Must be called within UIGraphicsImageRenderer block.
    private static func drawText(
        text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        color: UIColor,
        backgroundColor: UIColor
    ) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let nsText = text as NSString
        let textSize = nsText.size(withAttributes: attributes)
        let padding: CGFloat = 4

        // Background
        backgroundColor.setFill()
        UIRectFill(CGRect(
            x: point.x - padding,
            y: point.y - padding,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        ))

        // Text — UIKit coordinate system (top-left origin), works correctly
        nsText.draw(at: point, withAttributes: attributes)
    }

    private static func assignmentDescription(_ assignment: FrameAssignment?) -> String {
        switch assignment {
        case .athleteConfirmed(let idx):
            return "CONFIRMED p\(idx)"
        case .athleteAuto(let idx, _):
            return "AUTO p\(idx)"
        case .athleteUncertain(let idx, _):
            return "UNCERTAIN p\(idx)"
        case .noAthleteConfirmed:
            return "NO_ATHLETE_CONFIRMED"
        case .noAthleteAuto:
            return "NO_ATHLETE"
        case .athleteNoPose:
            return "NO_POSE"
        case .unreviewedGap:
            return "GAP"
        case nil:
            return "NONE"
        }
    }

    private static func normalizedToPixels(_ rect: CGRect, videoSize: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x * videoSize.width,
            y: rect.origin.y * videoSize.height,
            width: rect.width * videoSize.width,
            height: rect.height * videoSize.height
        )
    }

    /// Convert a UIImage to a CVPixelBuffer by drawing with UIKit.
    ///
    /// Uses `UIGraphicsPushContext` + `UIImage.draw(in:)` to render the image into
    /// a pixel-buffer-backed CGContext. UIKit handles all coordinate transforms internally,
    /// eliminating CGImage bottom-left vs top-left origin confusion.
    private static func pixelBufferFromUIImage(_ image: UIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Flip the CGContext to match UIKit's top-left-down coordinate system.
        // CGContext backed by raw memory defaults to bottom-left origin.
        // This transform makes UIImage.draw() render correctly.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // Push this CGContext so UIKit drawing operations target it
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        return buffer
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case noVideoURL
        case invalidVideoSize
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoURL: return "No video URL available."
            case .invalidVideoSize: return "Video has invalid dimensions."
            case .writerFailed(let detail): return "Video export failed: \(detail)"
            }
        }
    }
}
