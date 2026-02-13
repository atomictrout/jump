import SwiftUI

@Observable
class AnalysisViewModel {
    var result: AnalysisResult?

    /// Measurement display data for the results view
    struct MeasurementDisplay: Identifiable {
        let id = UUID()
        let name: String
        let value: Double
        let unit: String
        let idealRange: ClosedRange<Double>
        let status: JumpMeasurements.MeasurementStatus

        var formattedValue: String {
            if unit == "s" {
                return String(format: "%.3f%@", value, unit)
            }
            return "\(Int(value))\(unit)"
        }

        var idealRangeText: String {
            if unit == "s" {
                return String(format: "%.2f - %.2f%@", idealRange.lowerBound, idealRange.upperBound, unit)
            }
            return "\(Int(idealRange.lowerBound)) - \(Int(idealRange.upperBound))\(unit)"
        }
    }

    /// Generate display-friendly measurement list
    func measurementDisplays(from measurements: JumpMeasurements) -> [MeasurementDisplay] {
        var displays: [MeasurementDisplay] = []

        if let value = measurements.takeoffLegAngleAtPlant {
            let range: ClosedRange<Double> = 160...175
            displays.append(MeasurementDisplay(
                name: "Plant Leg Angle",
                value: value,
                unit: "°",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        if let value = measurements.driveKneeAngleAtTakeoff {
            let range: ClosedRange<Double> = 70...90
            displays.append(MeasurementDisplay(
                name: "Drive Knee Angle",
                value: value,
                unit: "°",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        if let value = measurements.torsoLeanDuringCurve {
            let range: ClosedRange<Double> = 10...20
            displays.append(MeasurementDisplay(
                name: "Torso Lean (Approach)",
                value: value,
                unit: "°",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        if let value = measurements.approachAngleToBar {
            let range: ClosedRange<Double> = 28...42
            displays.append(MeasurementDisplay(
                name: "Approach Angle to Bar",
                value: value,
                unit: "°",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        if let value = measurements.hipShoulderSeparationAtTD {
            let range: ClosedRange<Double> = -58...(-34)
            displays.append(MeasurementDisplay(
                name: "Hip-Shoulder Sep. (TD)",
                value: value,
                unit: "°",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        if let value = measurements.hipShoulderSeparationAtTO {
            let range: ClosedRange<Double> = 5...27
            displays.append(MeasurementDisplay(
                name: "Hip-Shoulder Sep. (TO)",
                value: value,
                unit: "°",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        if let value = measurements.backArchAngle {
            let range: ClosedRange<Double> = 100...150
            displays.append(MeasurementDisplay(
                name: "Back Arch Angle",
                value: value,
                unit: "°",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        if let value = measurements.estimatedGroundContactTime {
            let range: ClosedRange<Double> = 0.14...0.18
            displays.append(MeasurementDisplay(
                name: "Ground Contact Time",
                value: value,
                unit: "s",
                idealRange: range,
                status: JumpMeasurements.isIdeal(value, idealRange: range)
            ))
        }

        return displays
    }

    // MARK: - Height Displays

    struct HeightDisplay: Identifiable {
        let id = UUID()
        let name: String
        let formattedValue: String
        let icon: String
        let color: Color
    }

    /// Generate height-related displays (jump rise + bar clearance + bar status)
    /// Prefers real-world units (cm/m) when bar height is known; falls back to % of frame.
    func heightDisplays(from measurements: JumpMeasurements) -> [HeightDisplay] {
        var displays: [HeightDisplay] = []
        let hasRealUnits = measurements.barHeightMeters != nil

        // Bar height (if known)
        if let barHeight = measurements.barHeightMeters {
            displays.append(HeightDisplay(
                name: "Bar Height",
                formattedValue: BarHeightParser.formatHeightFull(barHeight),
                icon: "ruler",
                color: .jumpAccent
            ))
        }

        // Bar knock status
        if measurements.barKnocked {
            let part = measurements.barKnockBodyPart ?? "body"
            displays.append(HeightDisplay(
                name: "Bar Status",
                formattedValue: "Knocked (\(part))",
                icon: "xmark.circle.fill",
                color: .red
            ))
        } else if measurements.peakClearanceOverBar != nil {
            displays.append(HeightDisplay(
                name: "Bar Status",
                formattedValue: "Cleared",
                icon: "checkmark.circle.fill",
                color: .green
            ))
        }

        // Jump rise
        if hasRealUnits, let riseMeters = measurements.jumpRiseMeters {
            let cm = riseMeters * 100
            displays.append(HeightDisplay(
                name: "Jump Rise (Center of Mass)",
                formattedValue: String(format: "%.0fcm", cm),
                icon: "arrow.up",
                color: .jumpAccent
            ))
        } else if let jumpRise = measurements.jumpRise {
            let risePercent = jumpRise * 100
            displays.append(HeightDisplay(
                name: "Jump Rise (Center of Mass)",
                formattedValue: String(format: "%.1f%% of frame", risePercent),
                icon: "arrow.up",
                color: .jumpAccent
            ))
        }

        // Peak clearance over bar
        if hasRealUnits, let clearanceMeters = measurements.peakClearanceMeters {
            let cm = clearanceMeters * 100
            let isAbove = clearanceMeters > 0
            displays.append(HeightDisplay(
                name: "Peak Clearance Over Bar",
                formattedValue: isAbove
                    ? String(format: "+%.1fcm above bar", cm)
                    : String(format: "%.1fcm below bar", cm),
                icon: isAbove ? "checkmark.circle.fill" : "xmark.circle.fill",
                color: isAbove ? .green : .red
            ))
        } else if let clearance = measurements.peakClearanceOverBar {
            let clearancePercent = clearance * 100
            let isAbove = clearance > 0
            displays.append(HeightDisplay(
                name: "Peak Clearance Over Bar",
                formattedValue: isAbove
                    ? String(format: "+%.1f%% above bar", clearancePercent)
                    : String(format: "%.1f%% below bar", clearancePercent),
                icon: isAbove ? "checkmark.circle.fill" : "xmark.circle.fill",
                color: isAbove ? .green : .red
            ))
        }

        // Peak height
        if hasRealUnits, let peakMeters = measurements.peakHeightMeters {
            displays.append(HeightDisplay(
                name: "Peak Height (from ground)",
                formattedValue: String(format: "%.2fm", peakMeters),
                icon: "arrow.up.to.line",
                color: .jumpSubtle
            ))
        } else if let peakHeight = measurements.peakHeight {
            let heightPercent = peakHeight * 100
            displays.append(HeightDisplay(
                name: "Peak Height (in frame)",
                formattedValue: String(format: "%.1f%%", heightPercent),
                icon: "arrow.up.to.line",
                color: .jumpSubtle
            ))
        }

        return displays
    }

    // MARK: - Performance Metrics

    struct PerformanceDisplay: Identifiable {
        let id = UUID()
        let name: String
        let formattedValue: String
        let icon: String
        let color: Color
    }

    /// Generate performance metrics (flight time, speed, etc.)
    func performanceDisplays(from measurements: JumpMeasurements) -> [PerformanceDisplay] {
        var displays: [PerformanceDisplay] = []

        if let flightTime = measurements.flightTime {
            displays.append(PerformanceDisplay(
                name: "Flight Time",
                formattedValue: String(format: "%.2fs", flightTime),
                icon: "timer",
                color: .jumpAccent
            ))
        }

        if let speed = measurements.approachSpeed {
            // Show as relative speed (higher is faster)
            let speedDisplay = speed * 1000  // scale for readability
            displays.append(PerformanceDisplay(
                name: "Approach Speed",
                formattedValue: String(format: "%.1f units/s", speedDisplay),
                icon: "gauge.with.dots.needle.33percent",
                color: .orange
            ))
        }

        if let vertVel = measurements.takeoffVerticalVelocity {
            let velDisplay = vertVel * 1000
            displays.append(PerformanceDisplay(
                name: "Takeoff Vertical Impulse",
                formattedValue: String(format: "%.1f", velDisplay),
                icon: "arrow.up.circle",
                color: velDisplay > 10 ? .green : .yellow
            ))
        }

        if let contactTime = measurements.estimatedGroundContactTime {
            displays.append(PerformanceDisplay(
                name: "Ground Contact Time",
                formattedValue: String(format: "%.3fs", contactTime),
                icon: "shoe.fill",
                color: contactTime < 0.18 ? .green : .yellow
            ))
        }

        if let takeoffDist = measurements.takeoffDistance {
            let distPercent = takeoffDist * 100
            displays.append(PerformanceDisplay(
                name: "Takeoff Distance from Bar",
                formattedValue: String(format: "%.1f%% of frame", distPercent),
                icon: "arrow.left.and.right",
                color: .jumpSubtle
            ))
        }

        if let radius = measurements.jCurveRadius {
            let radiusPercent = radius * 100
            displays.append(PerformanceDisplay(
                name: "J-Curve Radius",
                formattedValue: String(format: "%.1f%% of frame", radiusPercent),
                icon: "arrow.triangle.turn.up.right.circle",
                color: .jumpSubtle
            ))
        }

        return displays
    }
}
