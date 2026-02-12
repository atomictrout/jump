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
}
