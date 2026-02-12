import CoreGraphics
import Foundation

struct AngleCalculator {
    /// Angle at vertex point B, formed by rays BA and BC.
    /// Returns degrees (0-180).
    static func angle(pointA: CGPoint, vertex: CGPoint, pointC: CGPoint) -> Double {
        let vectorBA = CGPoint(x: pointA.x - vertex.x, y: pointA.y - vertex.y)
        let vectorBC = CGPoint(x: pointC.x - vertex.x, y: pointC.y - vertex.y)

        let dotProduct = Double(vectorBA.dot(vectorBC))
        let magBA = Double(vectorBA.magnitude)
        let magBC = Double(vectorBC.magnitude)

        guard magBA > 0 && magBC > 0 else { return 0 }

        let cosAngle = max(-1.0, min(1.0, dotProduct / (magBA * magBC)))
        return acos(cosAngle) * 180.0 / .pi
    }

    /// Angle of a limb segment from the vertical axis (gravity direction).
    /// In screen coordinates, vertical is positive-Y (downward).
    /// Returns degrees: 0 = perfectly vertical, 90 = horizontal.
    static func angleFromVertical(top: CGPoint, bottom: CGPoint) -> Double {
        let dx = Double(bottom.x - top.x)
        let dy = Double(bottom.y - top.y)
        return abs(atan2(dx, dy) * 180.0 / .pi)
    }

    /// Hip-shoulder separation angle.
    /// Approximated from 2D view: angle between shoulder line and hip line.
    /// Positive = shoulders rotated ahead of hips, Negative = shoulders behind hips.
    static func hipShoulderSeparation(
        leftShoulder: CGPoint, rightShoulder: CGPoint,
        leftHip: CGPoint, rightHip: CGPoint
    ) -> Double {
        let shoulderAngle = atan2(
            Double(rightShoulder.y - leftShoulder.y),
            Double(rightShoulder.x - leftShoulder.x)
        )
        let hipAngle = atan2(
            Double(rightHip.y - leftHip.y),
            Double(rightHip.x - leftHip.x)
        )
        var diff = (shoulderAngle - hipAngle) * 180.0 / .pi
        // Normalize to -180...180
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return diff
    }

    /// Approach angle relative to the bar line.
    /// Uses the trajectory of the root joint over the last N frames.
    /// Returns degrees (0 = parallel to bar, 90 = perpendicular to bar).
    static func approachAngleToBar(
        trajectoryPoints: [CGPoint],
        barStart: CGPoint,
        barEnd: CGPoint
    ) -> Double? {
        guard trajectoryPoints.count >= 3 else { return nil }

        // Direction of travel: use last 3 points
        let last = trajectoryPoints.suffix(3)
        let points = Array(last)
        let direction = CGPoint(
            x: points[2].x - points[0].x,
            y: points[2].y - points[0].y
        )

        let barDirection = CGPoint(
            x: barEnd.x - barStart.x,
            y: barEnd.y - barStart.y
        )

        let dotProduct = Double(direction.dot(barDirection))
        let magDir = Double(direction.magnitude)
        let magBar = Double(barDirection.magnitude)

        guard magDir > 0 && magBar > 0 else { return nil }

        let cosAngle = max(-1.0, min(1.0, dotProduct / (magDir * magBar)))
        let angle = acos(cosAngle) * 180.0 / .pi

        // Return the acute angle
        return angle > 90 ? 180 - angle : angle
    }
}
