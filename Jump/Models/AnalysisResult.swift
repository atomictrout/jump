import SwiftUI

struct AnalysisResult: Sendable {
    let phases: [DetectedPhase]
    let measurements: JumpMeasurements
    let errors: [DetectedError]
    let recommendations: [Recommendation]
}

// MARK: - Detected Phase

struct DetectedPhase: Identifiable, Sendable {
    let id = UUID()
    let phase: JumpPhase
    let startFrame: Int
    let endFrame: Int
    let keyMetrics: [String: Double]

    var frameCount: Int {
        endFrame - startFrame + 1
    }
}

// MARK: - Measurements

struct JumpMeasurements: Sendable {
    var takeoffLegAngleAtPlant: Double?       // degrees
    var driveKneeAngleAtTakeoff: Double?      // degrees
    var torsoLeanDuringCurve: Double?         // degrees
    var hipShoulderSeparationAtTD: Double?    // degrees
    var hipShoulderSeparationAtTO: Double?    // degrees
    var backArchAngle: Double?               // degrees
    var approachAngleToBar: Double?          // degrees
    var estimatedGroundContactTime: Double?  // seconds
    var approachCurveRadius: Double?         // relative units
    var peakHeight: Double?                  // normalized units

    /// Check if a measurement is within the ideal range
    static func isIdeal(_ value: Double, idealRange: ClosedRange<Double>) -> MeasurementStatus {
        if idealRange.contains(value) {
            return .good
        }

        let lowerMargin = (idealRange.upperBound - idealRange.lowerBound) * 0.3
        let extendedRange = (idealRange.lowerBound - lowerMargin)...(idealRange.upperBound + lowerMargin)

        if extendedRange.contains(value) {
            return .marginal
        }

        return .poor
    }

    enum MeasurementStatus {
        case good, marginal, poor

        var color: Color {
            switch self {
            case .good: return .green
            case .marginal: return .yellow
            case .poor: return .red
            }
        }

        var icon: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .marginal: return "exclamationmark.triangle.fill"
            case .poor: return "xmark.circle.fill"
            }
        }
    }
}

// MARK: - Detected Error

struct DetectedError: Identifiable, Sendable {
    let id: UUID
    let type: ErrorType
    let frameRange: ClosedRange<Int>
    let severity: Severity
    let description: String

    enum ErrorType: String, Sendable, CaseIterable {
        case flatteningCurve = "Flattening the Curve"
        case cuttingCurve = "Cutting the Curve"
        case steppingOutOfCurve = "Stepping Out of Curve"
        case extendedBodyPosition = "Extended Body Position"
        case hammockPosition = "Hammock Position"
        case improperTakeoffAngle = "Improper Takeoff Angle"
        case hipCollapse = "Hip Collapse"
        case insufficientRotation = "Insufficient Rotation"
        case earlyHeadDrop = "Early Head/Chin Drop"
    }

    enum Severity: Int, Sendable, Comparable {
        case minor = 1
        case moderate = 2
        case major = 3

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .minor: return "Minor"
            case .moderate: return "Moderate"
            case .major: return "Major"
            }
        }

        var color: Color {
            switch self {
            case .minor: return .severityMinor
            case .moderate: return .severityModerate
            case .major: return .severityMajor
            }
        }

        var icon: String {
            switch self {
            case .minor: return "exclamationmark.triangle"
            case .moderate: return "exclamationmark.triangle.fill"
            case .major: return "xmark.octagon.fill"
            }
        }
    }
}

// MARK: - Recommendation

struct Recommendation: Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let relatedError: DetectedError.ErrorType?
    let priority: Int  // 1 = highest

    var icon: String {
        switch relatedError {
        case .flatteningCurve, .cuttingCurve, .steppingOutOfCurve:
            return "arrow.triangle.turn.up.right.diamond.fill"
        case .extendedBodyPosition, .improperTakeoffAngle:
            return "figure.stand"
        case .hammockPosition, .hipCollapse:
            return "figure.gymnastics"
        case .insufficientRotation:
            return "arrow.triangle.2.circlepath"
        case .earlyHeadDrop:
            return "eye.fill"
        case nil:
            return "lightbulb.fill"
        }
    }
}
