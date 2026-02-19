import SwiftUI
import AVFoundation

/// Peak frame view: peak height frame with skeleton overlay,
/// bar clearance metrics, and clearance profile diagram.
struct PeakInstantView: View {
    let result: AnalysisResult
    let session: JumpSession
    let allFramePoses: [[BodyPose]]
    let assignments: [Int: FrameAssignment]
    let onJumpToFrame: (Int) -> Void

    @State private var peakFrameImage: CGImage?

    private var m: JumpMeasurements { result.measurements }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Peak frame with overlay
                peakFrameCard
                    .padding(.horizontal)

                // Jump result
                if let success = m.jumpSuccess {
                    barStatusBanner(success: success)
                        .padding(.horizontal)
                }

                // Height decomposition
                heightDecomposition
                    .padding(.horizontal)

                // Clearance metrics
                clearanceMetrics
                    .padding(.horizontal)

                // Clearance profile
                if let profile = result.clearanceProfile {
                    ClearanceProfileView(profile: profile)
                        .padding(.horizontal)
                }

                // Flight metrics
                flightMetrics
                    .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding(.top, 12)
        }
        .background(Color.jumpBackgroundTop)
        .task { await loadPeakFrame() }
    }

    // MARK: - Peak Frame

    private var peakFrameCard: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image = peakFrameImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Skeleton overlay at peak
                    if let peakFrame = result.keyFrames.peakHeight,
                       let poseIndex = assignments[peakFrame]?.athletePoseIndex,
                       peakFrame < allFramePoses.count,
                       poseIndex < allFramePoses[peakFrame].count {
                        GeometryReader { geo in
                            SkeletonOverlayView(
                                pose: allFramePoses[peakFrame][poseIndex],
                                viewSize: geo.size,
                                offset: .zero,
                                color: .athleteCyan,
                                lineWidth: 2.0,
                                opacity: 0.8,
                                showJointDots: true
                            )
                        }
                    }

                    // Bar line overlay
                    if let p1 = session.barEndpoint1, let p2 = session.barEndpoint2 {
                        GeometryReader { geo in
                            Canvas { context, size in
                                let viewP1 = CGPoint(x: p1.x * size.width, y: p1.y * size.height)
                                let viewP2 = CGPoint(x: p2.x * size.width, y: p2.y * size.height)

                                var path = Path()
                                path.move(to: viewP1)
                                path.addLine(to: viewP2)
                                context.stroke(path, with: .color(.barLine),
                                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 3]))
                            }
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.jumpCard)
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay {
                            if result.keyFrames.peakHeight != nil {
                                ProgressView().tint(.jumpSubtle)
                            } else {
                                Text("Peak frame not detected")
                                    .font(.caption)
                                    .foregroundStyle(.jumpSubtle)
                            }
                        }
                }
            }
            .frame(maxHeight: 260)

            Text("Peak Height")
                .font(.caption2.bold())
                .foregroundStyle(.jumpSubtle)
        }
        .onTapGesture {
            if let frame = result.keyFrames.peakHeight {
                onJumpToFrame(frame)
            }
        }
    }

    // MARK: - Bar Status

    private func barStatusBanner(success: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(success ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(success ? "CLEARED" : "KNOCKED")
                    .font(.headline.bold())
                    .foregroundStyle(success ? .green : .red)
                if let part = m.barKnockBodyPart, !success {
                    Text("Contact: \(part)")
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                }
                if let knockFrame = m.barKnockFrame, !success {
                    Button {
                        onJumpToFrame(knockFrame)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.right.circle")
                            Text("Frame \(knockFrame + 1)")
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(.jumpAccent)
                    }
                }
            }

            Spacer()

            if let barHeight = m.barHeightMeters {
                Text(String(format: "%.2fm", barHeight))
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .background((success ? Color.green : Color.red).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Height Decomposition

    private var heightDecomposition: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Height Analysis", systemImage: "arrow.up.circle")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            if let h1 = m.h1, let h2 = m.h2, let h3 = m.h3 {
                VStack(spacing: 6) {
                    decompositionRow("H1", subtitle: "COM at takeoff", value: h1, color: .jumpAccent)
                    decompositionRow("H2", subtitle: "COM rise", value: h2, color: .phaseFlight)
                    decompositionRow("H3", subtitle: "Clearance efficiency", value: h3, color: h3 < 0 ? .green : .red)
                }
            } else {
                Text("Height decomposition unavailable")
                    .font(.caption)
                    .foregroundStyle(.jumpSubtle)
            }
        }
        .jumpCard()
    }

    private func decompositionRow(_ label: String, subtitle: String, value: Double, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(color)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.jumpSubtle)
            }
            Spacer()
            Text(String(format: "%.0fcm", value * 100))
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundStyle(.white)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Clearance Metrics

    private var clearanceMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Clearance", systemImage: "arrow.up.to.line")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let clearance = m.clearanceOverBar {
                    let sign = clearance >= 0 ? "+" : ""
                    metricTile(label: "COM Clearance", value: String(format: "%@%.0fcm", sign, clearance * 100),
                               color: clearance >= 0 ? .green : .red)
                }
                if let peak = m.peakCOMHeight {
                    metricTile(label: "Peak COM", value: String(format: "%.2fm", peak), color: .jumpAccent)
                }
                if let dist = m.peakCOMDistanceFromBar {
                    metricTile(label: "COM-to-Bar dist", value: String(format: "%.0fcm", dist * 100), color: .jumpSecondary)
                }
                if let tilt = m.backTiltAngleAtPeak {
                    metricTile(label: "Back Tilt", value: String(format: "%.0f\u{00B0}", tilt), color: .phaseFlight)
                }
            }
        }
        .jumpCard()
    }

    private func metricTile(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.jumpSubtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Flight Metrics

    private var flightMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Flight / Landing", systemImage: "airplane.departure")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                metricRow("Flight Time", value: m.flightTime.map { String(format: "%.2fs", $0) })
                metricRow("Knee Bend in Flight", value: m.kneeBendInFlight.map { String(format: "%.0f\u{00B0}", $0) })
                metricRow("Head Drop", value: m.headDropTiming?.rawValue)
                metricRow("Hands Position", value: m.handsPosition?.rawValue)
                metricRow("Landing Zone", value: m.landingZone?.rawValue)
                metricRow("Leg Clearance", value: m.legClearance.map { String(format: "%.0fcm", $0 * 100) })
            }
        }
        .jumpCard()
    }

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

    // MARK: - Loading

    private func loadPeakFrame() async {
        guard let videoURL = session.videoURL,
              let peakFrame = result.keyFrames.peakHeight else { return }
        peakFrameImage = try? await VideoFrameExtractor.extractFrame(
            from: videoURL, frameIndex: peakFrame, frameRate: session.frameRate,
            trimStartOffset: session.trimRange?.lowerBound ?? 0
        )
    }
}
