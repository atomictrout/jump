import SwiftUI

/// Approach phase summary: speed progression graph, step rhythm strip,
/// curve quality, and approach metrics table.
struct ApproachSummaryView: View {
    let result: AnalysisResult
    let onJumpToFrame: (Int) -> Void

    private var m: JumpMeasurements { result.measurements }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Speed progression chart
                if let speeds = m.approachSpeedProgression, speeds.count >= 2 {
                    speedChart(speeds: speeds)
                        .padding(.horizontal)
                }

                // Step rhythm strip
                if let stepLengths = m.stepLengths, !stepLengths.isEmpty {
                    stepRhythmSection(stepLengths: stepLengths, contactTimes: m.stepContactTimes)
                        .padding(.horizontal)
                }

                // Curve quality
                curveQualitySection
                    .padding(.horizontal)

                // Key metrics
                approachMetricsSection
                    .padding(.horizontal)

                // Penultimate step
                penultimateSection
                    .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding(.top, 12)
        }
        .background(Color.jumpBackgroundTop)
    }

    // MARK: - Speed Progression Chart

    private func speedChart(speeds: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Speed Progression", systemImage: "chart.line.uptrend.xyaxis")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            Canvas { context, size in
                guard speeds.count >= 2 else { return }
                let maxSpeed = speeds.max() ?? 1.0
                let minSpeed = speeds.min() ?? 0.0
                let range = max(maxSpeed - minSpeed, 0.5)
                let padding: CGFloat = 16

                let plotWidth = size.width - padding * 2
                let plotHeight = size.height - padding * 2

                // Draw grid lines
                for i in 0...4 {
                    let y = padding + plotHeight * CGFloat(i) / 4
                    var gridPath = Path()
                    gridPath.move(to: CGPoint(x: padding, y: y))
                    gridPath.addLine(to: CGPoint(x: size.width - padding, y: y))
                    context.stroke(gridPath, with: .color(.jumpSubtle.opacity(0.2)), lineWidth: 0.5)
                }

                // Draw speed line
                var path = Path()
                for (index, speed) in speeds.enumerated() {
                    let x = padding + plotWidth * CGFloat(index) / CGFloat(speeds.count - 1)
                    let normalizedSpeed = (speed - minSpeed) / range
                    let y = padding + plotHeight * (1.0 - CGFloat(normalizedSpeed))

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(.jumpAccent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                // Draw dots
                for (index, speed) in speeds.enumerated() {
                    let x = padding + plotWidth * CGFloat(index) / CGFloat(speeds.count - 1)
                    let normalizedSpeed = (speed - minSpeed) / range
                    let y = padding + plotHeight * (1.0 - CGFloat(normalizedSpeed))
                    let dotRect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.jumpAccent))
                }
            }
            .frame(height: 140)
            .background(Color.jumpCard.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Speed labels
            HStack {
                if let first = speeds.first {
                    Text(String(format: "%.1f m/s", first))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.jumpSubtle)
                }
                Spacer()
                if let last = speeds.last {
                    Text(String(format: "%.1f m/s", last))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.jumpAccent)
                }
            }
        }
        .jumpCard()
    }

    // MARK: - Step Rhythm Strip

    private func stepRhythmSection(stepLengths: [Double], contactTimes: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Step Rhythm", systemImage: "waveform.path")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            let maxLength = stepLengths.max() ?? 1.0

            VStack(spacing: 4) {
                ForEach(Array(stepLengths.enumerated()), id: \.offset) { index, length in
                    HStack(spacing: 8) {
                        Text("Step \(index + 1)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.jumpSubtle)
                            .frame(width: 44, alignment: .leading)

                        GeometryReader { geo in
                            let barWidth = geo.size.width * CGFloat(length / maxLength)
                            let isPenultimate = index == stepLengths.count - 2
                            let isFinal = index == stepLengths.count - 1
                            let barColor: Color = isPenultimate ? .jumpSecondary : (isFinal ? .jumpAccent : .jumpSubtle.opacity(0.6))

                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor)
                                .frame(width: barWidth, height: 14)
                        }
                        .frame(height: 14)

                        Text(String(format: "%.2fm", length))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.jumpSubtle)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            // Legend
            HStack(spacing: 12) {
                legendDot(color: .jumpSecondary, label: "Penultimate")
                legendDot(color: .jumpAccent, label: "Final")
            }
            .padding(.top, 4)
        }
        .jumpCard()
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.jumpSubtle)
        }
    }

    // MARK: - Curve Quality

    private var curveQualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Curve Quality", systemImage: "arrow.turn.right.up")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                // Quality badge
                let quality = curveQualityRating
                Text(quality.label)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(quality.color)
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 2) {
                    if let angle = m.approachAngleToBar {
                        Text(String(format: "Approach angle: %.0f\u{00B0}", angle))
                            .font(.caption)
                            .foregroundStyle(.jumpSubtle)
                    }
                    if let lean = m.inwardBodyLean {
                        Text(String(format: "Inward lean: %.0f\u{00B0}", lean))
                            .font(.caption)
                            .foregroundStyle(.jumpSubtle)
                    }
                    if let radius = m.curveRadius {
                        Text(String(format: "Curve radius: %.1fm", radius))
                            .font(.caption)
                            .foregroundStyle(.jumpSubtle)
                    }
                }

                Spacer()
            }
        }
        .jumpCard()
    }

    private var curveQualityRating: (label: String, color: Color) {
        // Heuristic: approach angle 30-45, lean 15-25, speed not decelerating
        var score = 0
        if let angle = m.approachAngleToBar, (30...45).contains(angle) { score += 1 }
        if let lean = m.inwardBodyLean, (15...25).contains(lean) { score += 1 }
        if let speeds = m.approachSpeedProgression, speeds.count >= 2 {
            if speeds.last ?? 0 >= speeds.first ?? 0 { score += 1 }
        }

        switch score {
        case 3: return ("Good", .green)
        case 2: return ("Needs Work", .yellow)
        default: return ("Poor", .red)
        }
    }

    // MARK: - Approach Metrics

    private var approachMetricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approach Metrics", systemImage: "figure.walk")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                metricRow("Approach Speed", value: m.approachSpeed.map { String(format: "%.1f m/s", $0) })
                metricRow("Step Count", value: m.stepCount.map { "\($0) steps" })
                metricRow("Approach Angle", value: m.approachAngleToBar.map { String(format: "%.0f\u{00B0}", $0) })
                metricRow("Inward Lean", value: m.inwardBodyLean.map { String(format: "%.0f\u{00B0}", $0) })
                metricRow("FT:CT Ratio", value: m.flightToContactRatio.map { String(format: "%.2f", $0) })
            }
        }
        .jumpCard()
    }

    // MARK: - Penultimate Step

    private var penultimateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Penultimate Step", systemImage: "shoe.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                metricRow("COM Height", value: m.penultimateCOMHeight.map { String(format: "%.2fm", $0) })
                metricRow("Shin Angle", value: m.penultimateShinAngle.map { String(format: "%.0f\u{00B0}", $0) })
                metricRow("Knee Angle", value: m.penultimateKneeAngle.map { String(format: "%.0f\u{00B0}", $0) })
                metricRow("Step Duration", value: m.penultimateStepDuration.map { String(format: "%.3fs", $0) })
                metricRow("Step Length", value: m.penultimateStepLength.map { String(format: "%.2fm", $0) })
            }
        }
        .jumpCard()
    }

    // MARK: - Helpers

    private func metricRow(_ name: String, value: String?) -> some View {
        HStack {
            Text(name)
                .font(.caption)
                .foregroundStyle(.jumpSubtle)
            Spacer()
            Text(value ?? "\u{2014}")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(value != nil ? .white : .jumpSubtle.opacity(0.4))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }
}
