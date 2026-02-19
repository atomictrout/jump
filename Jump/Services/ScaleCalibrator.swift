import CoreGraphics
import Foundation

/// Converts between normalized coordinates and real-world measurements
/// using bar height calibration and ground plane detection.
struct ScaleCalibrator {

    /// Calibrate from bar endpoints, bar height, and ground plane.
    ///
    /// Scale derivation:
    /// - Bar Y position (midpoint of endpoints Y) and ground Y give a pixel distance
    /// - Bar height in meters gives the real-world equivalent
    /// - pixelsPerNormalizedUnit = (groundY - barY) / barHeightMeters
    ///
    /// Note: "pixels" here means normalized coordinate units (0-1 range),
    /// not actual screen pixels.
    static func calibrate(
        barEndpoint1: CGPoint,
        barEndpoint2: CGPoint,
        barHeightMeters: Double,
        groundY: Double
    ) -> ScaleCalibration {
        // Bar Y position (in top-left coords, bar is above ground = smaller Y)
        let barY = Double((barEndpoint1.y + barEndpoint2.y) / 2)

        // In top-left coordinates: groundY > barY
        // The vertical distance in normalized units from bar to ground
        let verticalSpanNormalized = groundY - barY

        // pixels per meter = vertical span / bar height
        let pixelsPerMeter: Double
        if verticalSpanNormalized > 0.01 && barHeightMeters > 0.1 {
            pixelsPerMeter = verticalSpanNormalized / barHeightMeters
        } else {
            // Fallback: assume bar is roughly in a typical position
            pixelsPerMeter = 0.3 / barHeightMeters  // Rough estimate
        }

        return ScaleCalibration(
            barEndpoint1: barEndpoint1,
            barEndpoint2: barEndpoint2,
            barHeightMeters: barHeightMeters,
            groundY: groundY,
            pixelsPerMeter: pixelsPerMeter,
            cameraAngle: nil
        )
    }

    /// Estimate ground Y from foot contact points during approach.
    ///
    /// The ground level is the maximum Y value (lowest screen position)
    /// of heel/ankle joints across standing/approach frames.
    static func estimateGroundY(
        from athletePoses: [BodyPose?]
    ) -> Double? {
        var maxFootY: CGFloat = 0
        var footSamples = 0

        for pose in athletePoses.compactMap({ $0 }) {
            let footJoints: [BodyPose.JointName] = [.leftHeel, .rightHeel, .leftAnkle, .rightAnkle]
            for joint in footJoints {
                if let pos = pose.joints[joint], pos.confidence > 0.3 {
                    maxFootY = max(maxFootY, pos.point.y)
                    footSamples += 1
                }
            }
        }

        guard footSamples >= 5 else { return nil }
        return Double(maxFootY)
    }

    /// Estimate athlete height from approach frames where they're standing upright.
    ///
    /// - Parameters:
    ///   - poses: Athlete poses from approach phase.
    ///   - calibration: Scale calibration for converting to meters.
    /// - Returns: Estimated height in meters.
    static func estimateAthleteHeight(
        from poses: [BodyPose],
        calibration: ScaleCalibration
    ) -> Double? {
        var heights: [Double] = []

        for pose in poses {
            guard let topY = pose.highestPointY,
                  let bottomY = pose.lowestFootY else { continue }

            // Height in normalized units (bottom - top, since top-left origin)
            let heightNormalized = bottomY - topY
            guard heightNormalized > 0.05 else { continue }  // Sanity check

            let heightMeters = Double(heightNormalized) / calibration.pixelsPerMeter
            // Sanity check: reasonable human height
            if heightMeters > 1.3 && heightMeters < 2.3 {
                heights.append(heightMeters)
            }
        }

        guard !heights.isEmpty else { return nil }

        // Use median for robustness
        let sorted = heights.sorted()
        return sorted[sorted.count / 2]
    }

    /// Convert a normalized vertical distance to meters.
    static func normalizedToMeters(_ distance: CGFloat, calibration: ScaleCalibration) -> Double {
        Double(distance) / calibration.pixelsPerMeter
    }

    /// Convert meters to normalized distance.
    static func metersToNormalized(_ meters: Double, calibration: ScaleCalibration) -> CGFloat {
        CGFloat(meters * calibration.pixelsPerMeter)
    }
}
