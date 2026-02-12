import CoreGraphics
import Foundation

extension CGPoint {
    /// Distance between two points
    func distance(to other: CGPoint) -> CGFloat {
        let dx = other.x - x
        let dy = other.y - y
        return sqrt(dx * dx + dy * dy)
    }

    /// Midpoint between two points
    func midpoint(to other: CGPoint) -> CGPoint {
        CGPoint(x: (x + other.x) / 2, y: (y + other.y) / 2)
    }

    /// Vector from this point to another
    func vector(to other: CGPoint) -> CGPoint {
        CGPoint(x: other.x - x, y: other.y - y)
    }

    /// Magnitude of this point treated as a vector
    var magnitude: CGFloat {
        sqrt(x * x + y * y)
    }

    /// Normalized unit vector
    var normalized: CGPoint {
        let mag = magnitude
        guard mag > 0 else { return .zero }
        return CGPoint(x: x / mag, y: y / mag)
    }

    /// Dot product with another vector
    func dot(_ other: CGPoint) -> CGFloat {
        x * other.x + y * other.y
    }

    /// Cross product (z-component) with another vector
    func cross(_ other: CGPoint) -> CGFloat {
        x * other.y - y * other.x
    }

    /// Angle of this vector from the positive X axis, in radians
    var angle: CGFloat {
        atan2(y, x)
    }

    /// Angle from vertical (positive Y axis pointing down in screen coords)
    var angleFromVertical: CGFloat {
        atan2(x, y)
    }

    /// Add two points
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    /// Subtract two points
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    /// Scale a point
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    /// Scale a point
    static func * (lhs: CGFloat, rhs: CGPoint) -> CGPoint {
        CGPoint(x: rhs.x * lhs, y: rhs.y * lhs)
    }
}
