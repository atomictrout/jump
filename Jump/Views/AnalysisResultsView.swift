import SwiftUI

/// Full analysis results display.
/// Shows phase timeline, measurements, errors, recommendations, and coaching insights.
struct ResultsDisplayView: View {
    let result: AnalysisResult
    let session: JumpSession
    let onJumpToFrame: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Jump Result Banner
                if let success = result.measurements.jumpSuccess {
                    jumpResultBanner(success: success)
                }

                // Key Metrics Header
                keyMetricsGrid

                // Measurements by Phase
                measurementsSection

                // Height Decomposition
                heightSection

                // Errors
                if !result.errors.isEmpty {
                    errorsSection
                }

                // Recommendations
                if !result.recommendations.isEmpty {
                    recommendationsSection
                }

                // Coaching Insights
                if !result.coachingInsights.isEmpty {
                    coachingSection
                }

                Spacer(minLength: 40)
            }
            .padding()
        }
        .background(Color.jumpBackgroundTop)
    }

    // MARK: - Jump Result Banner

    private func jumpResultBanner(success: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(success ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(success ? "CLEARED" : "KNOCKED")
                    .font(.headline.bold())
                    .foregroundStyle(success ? .green : .red)
                if let part = result.measurements.barKnockBodyPart, !success {
                    Text("Contact: \(part)")
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                }
            }

            Spacer()

            if let barHeight = result.measurements.barHeightMeters {
                Text(String(format: "%.2fm", barHeight))
                    .font(.system(.title, design: .rounded).bold())
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .background((success ? Color.green : Color.red).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Key Metrics Grid

    private var keyMetricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if let angle = result.measurements.takeoffAngle {
                metricCell(label: "Takeoff Angle", value: String(format: "%.0f\u{00B0}", angle), icon: "arrow.up.forward.circle")
            }
            if let clearance = result.measurements.clearanceOverBar {
                let sign = clearance >= 0 ? "+" : ""
                metricCell(label: "Bar Clearance", value: String(format: "%@%.0fcm", sign, clearance * 100), icon: "arrow.up.to.line")
            }
            if let gct = result.measurements.groundContactTime {
                metricCell(label: "Ground Contact", value: String(format: "%.3fs", gct), icon: "shoe.fill")
            }
            if let flightTime = result.measurements.flightTime {
                metricCell(label: "Flight Time", value: String(format: "%.2fs", flightTime), icon: "timer")
            }
        }
    }

    private func metricCell(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.jumpAccent)
            Text(value)
                .font(.system(.title2, design: .monospaced).bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.jumpSubtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.jumpCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Measurements Section

    private var measurementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Measurements", systemImage: "ruler")
                .font(.headline)
                .foregroundStyle(.white)

            let displays = buildMeasurementDisplays()
            ForEach(Array(displays.enumerated()), id: \.offset) { _, item in
                HStack {
                    Image(systemName: item.statusIcon)
                        .foregroundStyle(item.statusColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text("Ideal: \(item.idealRange)")
                            .font(.caption)
                            .foregroundStyle(.jumpSubtle)
                    }

                    Spacer()

                    Text(item.formattedValue)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(item.statusColor)
                }
                .padding(.vertical, 4)
            }
        }
        .jumpCard()
    }

    // MARK: - Height Section

    private var heightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Height Analysis", systemImage: "arrow.up.circle")
                .font(.headline)
                .foregroundStyle(.white)

            if let h1 = result.measurements.h1, let h2 = result.measurements.h2, let h3 = result.measurements.h3 {
                VStack(spacing: 8) {
                    heightBar(label: "H1 (COM at takeoff)", value: h1, color: .jumpAccent)
                    heightBar(label: "H2 (COM rise)", value: h2, color: .phaseFlight)
                    heightBar(label: "H3 (clearance efficiency)", value: h3, color: h3 < 0 ? .green : .red)
                }
            }

            if let peak = result.measurements.peakCOMHeight {
                HStack {
                    Text("Peak COM Height")
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                    Spacer()
                    Text(String(format: "%.2fm", peak))
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(.white)
                }
            }
        }
        .jumpCard()
    }

    private func heightBar(label: String, value: Double, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.jumpSubtle)
                .frame(width: 160, alignment: .leading)

            Spacer()

            Text(String(format: "%.0fcm", value * 100))
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(color)
        }
    }

    // MARK: - Errors Section

    private var errorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Detected Issues (\(result.errors.count))", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(result.errors) { error in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: error.severity.icon)
                            .foregroundStyle(error.severity.color)
                        Text(error.type.rawValue)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        Text(error.severity.label)
                            .font(.caption.bold())
                            .foregroundStyle(error.severity.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(error.severity.color.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    Text(error.description)
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        onJumpToFrame(error.frameRange.lowerBound)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle")
                            Text("Frame \(error.frameRange.lowerBound + 1)")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.jumpAccent)
                    }
                }
                .padding()
                .background(error.severity.color.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .jumpCard()
    }

    // MARK: - Recommendations Section

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recommendations", systemImage: "lightbulb.fill")
                .font(.headline)
                .foregroundStyle(.jumpSecondary)

            ForEach(result.recommendations) { rec in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.jumpSecondary.opacity(0.2))
                            .frame(width: 32, height: 32)
                        Text("\(rec.priority)")
                            .font(.system(.subheadline, design: .rounded).bold())
                            .foregroundStyle(.jumpSecondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Text(rec.detail)
                            .font(.caption)
                            .foregroundStyle(.jumpSubtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .jumpCard()
    }

    // MARK: - Coaching Section

    private var coachingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Coaching Insights", systemImage: "questionmark.circle")
                .font(.headline)
                .foregroundStyle(.phaseFlight)

            ForEach(result.coachingInsights) { insight in
                VStack(alignment: .leading, spacing: 8) {
                    Text(insight.question)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(insight.answer)
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                        .fixedSize(horizontal: false, vertical: true)

                    if let frameIndex = insight.relatedFrameIndex {
                        Button {
                            onJumpToFrame(frameIndex)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.circle")
                                Text("See Frame")
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.jumpAccent)
                        }
                    }
                }
                .padding()
                .background(Color.phaseFlight.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .jumpCard()
    }

    // MARK: - Measurement Display Helpers

    private struct MeasurementDisplayItem {
        let name: String
        let formattedValue: String
        let idealRange: String
        let statusIcon: String
        let statusColor: Color
    }

    private func buildMeasurementDisplays() -> [MeasurementDisplayItem] {
        var items: [MeasurementDisplayItem] = []
        let m = result.measurements

        func add(_ name: String, value: Double?, unit: String, ideal: ClosedRange<Double>) {
            guard let val = value else { return }
            let status = JumpMeasurements.status(val, idealRange: ideal)
            let formatted: String
            if unit == "s" {
                formatted = String(format: "%.3f%@", val, unit)
            } else {
                formatted = "\(Int(val))\(unit)"
            }
            let idealText: String
            if unit == "s" {
                idealText = String(format: "%.2f - %.2f%@", ideal.lowerBound, ideal.upperBound, unit)
            } else {
                idealText = "\(Int(ideal.lowerBound)) - \(Int(ideal.upperBound))\(unit)"
            }
            items.append(MeasurementDisplayItem(
                name: name, formattedValue: formatted, idealRange: idealText,
                statusIcon: status.icon, statusColor: status.color
            ))
        }

        add("Takeoff Knee at Plant", value: m.takeoffLegKneeAtPlant, unit: "\u{00B0}", ideal: 160...175)
        add("Takeoff Knee at Toe-Off", value: m.takeoffLegKneeAtToeOff, unit: "\u{00B0}", ideal: 170...180)
        add("Drive Knee Angle", value: m.driveKneeAngleAtTakeoff, unit: "\u{00B0}", ideal: 70...90)
        add("Backward Lean at Plant", value: m.backwardLeanAtPlant, unit: "\u{00B0}", ideal: 10...25)
        add("Takeoff Angle", value: m.takeoffAngle, unit: "\u{00B0}", ideal: 40...55)
        add("Ground Contact Time", value: m.groundContactTime, unit: "s", ideal: 0.14...0.18)

        return items
    }
}
