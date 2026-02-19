import CoreGraphics

/// Converts between normalized MediaPipe coordinates (0-1, origin top-left)
/// and view coordinates (pixel-based, origin top-left).
///
/// Both coordinate systems share the same origin (top-left), so conversion
/// is a simple scale operation — no Y-flipping needed.
struct CoordinateConverter {

    /// Convert a normalized point (0-1 range, origin top-left)
    /// to view coordinates (pixel-based, origin top-left).
    static func normalizedToView(
        point: CGPoint,
        viewSize: CGSize,
        offset: CGPoint = .zero
    ) -> CGPoint {
        CGPoint(
            x: point.x * viewSize.width + offset.x,
            y: point.y * viewSize.height + offset.y
        )
    }

    /// Convert view coordinates back to normalized coordinates.
    static func viewToNormalized(
        point: CGPoint,
        viewSize: CGSize,
        offset: CGPoint = .zero
    ) -> CGPoint {
        CGPoint(
            x: (point.x - offset.x) / viewSize.width,
            y: (point.y - offset.y) / viewSize.height
        )
    }

    /// Convert all joints in a pose to view coordinates.
    static func convertPose(
        _ pose: BodyPose,
        to viewSize: CGSize,
        offset: CGPoint = .zero
    ) -> [BodyPose.JointName: CGPoint] {
        var converted: [BodyPose.JointName: CGPoint] = [:]
        for (name, joint) in pose.joints {
            converted[name] = normalizedToView(
                point: joint.point,
                viewSize: viewSize,
                offset: offset
            )
        }
        return converted
    }

    /// Convert a normalized distance to view pixels.
    static func normalizedToViewDistance(
        _ distance: CGFloat,
        viewHeight: CGFloat
    ) -> CGFloat {
        distance * viewHeight
    }

    /// Convert a view-space point to CGImage pixel coordinates.
    /// Useful for cropping regions from the raw CGImage (e.g., loupe magnifier).
    static func viewToImagePixels(
        point: CGPoint,
        viewSize: CGSize,
        offset: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGPoint {
        let normalizedX = (point.x - offset.x) / viewSize.width
        let normalizedY = (point.y - offset.y) / viewSize.height
        return CGPoint(
            x: normalizedX * CGFloat(imageWidth),
            y: normalizedY * CGFloat(imageHeight)
        )
    }

    // MARK: - Vision Coordinate Conversion

    /// Convert a Vision bounding box (bottom-left origin) to top-left origin.
    ///
    /// Vision framework: origin at bottom-left, y increases upward (0-1 normalized).
    /// App convention: origin at top-left, y increases downward (0-1 normalized).
    static func visionToTopLeft(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: 1.0 - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Convert a top-left origin bounding box to Vision coordinates (bottom-left origin).
    static func topLeftToVision(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: 1.0 - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Compute the view-space fitting rect for video content in a view,
    /// accounting for aspect ratio (letterboxing/pillarboxing).
    static func fittingRect(
        videoSize: CGSize,
        in viewSize: CGSize
    ) -> CGRect {
        let videoAspect = videoSize.width / videoSize.height
        let viewAspect = viewSize.width / viewSize.height

        let fittedSize: CGSize
        if videoAspect > viewAspect {
            // Video is wider — bars top/bottom
            fittedSize = CGSize(
                width: viewSize.width,
                height: viewSize.width / videoAspect
            )
        } else {
            // Video is taller — bars left/right
            fittedSize = CGSize(
                width: viewSize.height * videoAspect,
                height: viewSize.height
            )
        }

        let origin = CGPoint(
            x: (viewSize.width - fittedSize.width) / 2,
            y: (viewSize.height - fittedSize.height) / 2
        )

        return CGRect(origin: origin, size: fittedSize)
    }
}
