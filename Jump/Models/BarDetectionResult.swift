import CoreGraphics

struct BarDetectionResult: Sendable {
    let barLineStart: CGPoint     // normalized Vision coordinates (0-1, bottom-left origin)
    let barLineEnd: CGPoint       // normalized Vision coordinates
    let confidence: Double        // 0.0 to 1.0
    let frameIndex: Int           // frame where bar was detected

    /// Average Y position of the bar (in normalized coordinates)
    var barY: CGFloat {
        (barLineStart.y + barLineEnd.y) / 2.0
    }

    /// Angle of the bar line in degrees (0 = perfectly horizontal)
    var barAngle: Double {
        atan2(
            Double(barLineEnd.y - barLineStart.y),
            Double(barLineEnd.x - barLineStart.x)
        ) * 180 / .pi
    }

    /// Width of the bar in normalized coordinates
    var barWidth: CGFloat {
        barLineStart.distance(to: barLineEnd)
    }
}
