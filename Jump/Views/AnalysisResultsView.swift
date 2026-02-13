import SwiftUI

struct AnalysisResultsView: View {
    let result: AnalysisResult
    let session: JumpSession
    let onJumpToFrame: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var analysisVM = AnalysisViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Jump Result Banner (Success / Fail)
                    if let success = result.measurements.jumpSuccess {
                        jumpResultBanner(success: success)
                            .padding(.horizontal)
                    }

                    // Phase Timeline
                    phaseTimeline
                        .padding(.horizontal)

                    // Measurements
                    measurementsSection
                        .padding(.horizontal)

                    // Jump Height & Bar Status
                    let heights = analysisVM.heightDisplays(from: result.measurements)
                    if !heights.isEmpty {
                        heightSection(heights: heights)
                            .padding(.horizontal)
                    }

                    // Performance Metrics
                    let performance = analysisVM.performanceDisplays(from: result.measurements)
                    if !performance.isEmpty {
                        performanceSection(metrics: performance)
                            .padding(.horizontal)
                    }

                    // Errors
                    if !result.errors.isEmpty {
                        errorsSection
                            .padding(.horizontal)
                    }

                    // Recommendations
                    recommendationsSection
                        .padding(.horizontal)

                    Spacer(minLength: 40)
                }
                .padding(.top)
            }
            .background(Color.jumpBackgroundTop)
            .navigationTitle("Analysis Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.jumpAccent)
                }
            }
        }
    }

    // MARK: - Phase Timeline

    private var phaseTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Jump Phases", systemImage: "timeline.selection")
                .font(.headline)
                .foregroundStyle(.white)

            // Timeline bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(result.phases) { phase in
                        let width = phaseWidth(phase, totalFrames: session.totalFrames, containerWidth: geo.size.width)

                        Button {
                            onJumpToFrame(phase.startFrame)
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(phase.phase.color)
                                .frame(width: max(width, 20))
                                .overlay {
                                    if width > 40 {
                                        Text(phase.phase.rawValue)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(1)
                                    }
                                }
                        }
                    }
                }
            }
            .frame(height: 32)

            // Phase legend
            HStack(spacing: 12) {
                ForEach(result.phases) { phase in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(phase.phase.color)
                            .frame(width: 8, height: 8)
                        Text(phase.phase.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.jumpSubtle)
                    }
                }
            }
        }
        .jumpCard()
    }

    private func phaseWidth(_ phase: DetectedPhase, totalFrames: Int, containerWidth: CGFloat) -> CGFloat {
        guard totalFrames > 0 else { return 0 }
        let proportion = CGFloat(phase.frameCount) / CGFloat(totalFrames)
        return (containerWidth - CGFloat(result.phases.count - 1) * 2 - 32) * proportion
    }

    // MARK: - Measurements

    private var measurementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Measurements", systemImage: "ruler")
                .font(.headline)
                .foregroundStyle(.white)

            let displays = analysisVM.measurementDisplays(from: result.measurements)

            ForEach(displays) { measurement in
                HStack {
                    Image(systemName: measurement.status.icon)
                        .foregroundStyle(measurement.status.color)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(measurement.name)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text("Ideal: \(measurement.idealRangeText)")
                            .font(.caption)
                            .foregroundStyle(.jumpSubtle)
                    }

                    Spacer()

                    Text(measurement.formattedValue)
                        .font(.system(.title3, design: .monospaced).bold())
                        .foregroundStyle(measurement.status.color)
                }
                .padding(.vertical, 4)

                if measurement.id != displays.last?.id {
                    Divider()
                        .overlay(Color.jumpSubtle.opacity(0.3))
                }
            }
        }
        .jumpCard()
    }

    // MARK: - Jump Height

    private func heightSection(heights: [AnalysisViewModel.HeightDisplay]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Jump Height", systemImage: "arrow.up.circle")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(heights) { height in
                HStack {
                    Image(systemName: height.icon)
                        .foregroundStyle(height.color)
                        .frame(width: 24)

                    Text(height.name)
                        .font(.subheadline)
                        .foregroundStyle(.white)

                    Spacer()

                    Text(height.formattedValue)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(height.color)
                }
                .padding(.vertical, 4)

                if height.id != heights.last?.id {
                    Divider()
                        .overlay(Color.jumpSubtle.opacity(0.3))
                }
            }
        }
        .jumpCard()
    }

    // MARK: - Performance Metrics

    private func performanceSection(metrics: [AnalysisViewModel.PerformanceDisplay]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Performance", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(metrics) { metric in
                HStack {
                    Image(systemName: metric.icon)
                        .foregroundStyle(metric.color)
                        .frame(width: 24)

                    Text(metric.name)
                        .font(.subheadline)
                        .foregroundStyle(.white)

                    Spacer()

                    Text(metric.formattedValue)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(metric.color)
                }
                .padding(.vertical, 4)

                if metric.id != metrics.last?.id {
                    Divider()
                        .overlay(Color.jumpSubtle.opacity(0.3))
                }
            }
        }
        .jumpCard()
    }

    // MARK: - Errors

    private var errorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Detected Issues", systemImage: "exclamationmark.triangle")
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
                            Text("Go to Frame \(error.frameRange.lowerBound + 1)")
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
                Text(success ? "Bar stayed up — successful jump!" : "Bar was knocked — review technique below")
                    .font(.caption)
                    .foregroundStyle(.jumpSubtle)
            }

            Spacer()
        }
        .padding()
        .background((success ? Color.green : Color.red).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Recommendations

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
                            .frame(width: 36, height: 36)
                        Text("\(rec.priority)")
                            .font(.system(.headline, design: .rounded).bold())
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
                .padding()
                .background(Color.jumpCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .jumpCard()
    }
}
