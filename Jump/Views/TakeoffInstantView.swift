import SwiftUI
import AVFoundation

/// Hero screen: side-by-side plant + toe-off frames with skeleton overlay,
/// key angles table, and takeoff metrics.
struct TakeoffInstantView: View {
    let result: AnalysisResult
    let session: JumpSession
    let allFramePoses: [[BodyPose]]
    let assignments: [Int: FrameAssignment]
    let onJumpToFrame: (Int) -> Void

    @State private var plantFrameImage: CGImage?
    @State private var toeOffFrameImage: CGImage?

    private var m: JumpMeasurements { result.measurements }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Side-by-side frames
                frameComparison
                    .padding(.horizontal)

                // Jump result banner
                if let success = m.jumpSuccess {
                    jumpBanner(success: success)
                        .padding(.horizontal)
                }

                // Takeoff info chips
                takeoffInfoChips
                    .padding(.horizontal)

                // Key angles table
                anglesTable
                    .padding(.horizontal)

                // Additional metrics
                additionalMetrics
                    .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding(.top, 12)
        }
        .background(Color.jumpBackgroundTop)
        .task { await loadKeyFrameImages() }
    }

    // MARK: - Frame Comparison

    private var frameComparison: some View {
        HStack(spacing: 8) {
            // Plant frame
            frameCard(
                image: plantFrameImage,
                label: "Plant",
                frameIndex: result.keyFrames.takeoffPlant,
                poseIndex: poseIndexAt(result.keyFrames.takeoffPlant)
            )

            // Toe-off frame
            frameCard(
                image: toeOffFrameImage,
                label: "Toe-Off",
                frameIndex: result.keyFrames.toeOff,
                poseIndex: poseIndexAt(result.keyFrames.toeOff)
            )
        }
    }

    private func frameCard(image: CGImage?, label: String, frameIndex: Int?, poseIndex: Int?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Skeleton overlay
                    if let frameIndex, let poseIndex,
                       frameIndex < allFramePoses.count,
                       poseIndex < allFramePoses[frameIndex].count {
                        GeometryReader { geo in
                            let videoSize = geo.size
                            SkeletonOverlayView(
                                pose: allFramePoses[frameIndex][poseIndex],
                                viewSize: videoSize,
                                offset: .zero,
                                color: .athleteCyan,
                                lineWidth: 2.0,
                                opacity: 0.8,
                                showJointDots: true
                            )
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.jumpCard)
                        .overlay {
                            if frameIndex != nil {
                                ProgressView()
                                    .tint(.jumpSubtle)
                            } else {
                                Text("N/A")
                                    .font(.caption)
                                    .foregroundStyle(.jumpSubtle)
                            }
                        }
                }
            }
            .aspectRatio(9/16, contentMode: .fit)

            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.jumpSubtle)
        }
        .onTapGesture {
            if let frameIndex {
                onJumpToFrame(frameIndex)
            }
        }
    }

    // MARK: - Jump Banner

    private func jumpBanner(success: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(success ? .green : .red)

            Text(success ? "CLEARED" : "KNOCKED")
                .font(.headline.bold())
                .foregroundStyle(success ? .green : .red)

            if let part = m.barKnockBodyPart, !success {
                Text("(\(part))")
                    .font(.caption)
                    .foregroundStyle(.jumpSubtle)
            }

            Spacer()

            if let barHeight = m.barHeightMeters {
                Text(String(format: "%.2fm", barHeight))
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .background((m.jumpSuccess == true ? Color.green : Color.red).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Info Chips

    private var takeoffInfoChips: some View {
        HStack(spacing: 12) {
            if let leg = m.takeoffLeg {
                chipView(label: "Takeoff Leg", value: leg.rawValue.uppercased(), color: .athleteCyan)
            }

            if let gct = m.groundContactTime {
                chipView(label: "Contact Time", value: String(format: "%.3fs", gct), color: .jumpSecondary)
            }

            if let angle = m.takeoffAngle {
                chipView(label: "Takeoff Angle", value: String(format: "%.0f\u{00B0}", angle), color: .jumpAccent)
            }
        }
    }

    private func chipView(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.jumpSubtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Angles Table

    private var anglesTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Key Angles", systemImage: "angle")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            VStack(spacing: 0) {
                angleRow("Plant Knee", value: m.takeoffLegKneeAtPlant, ideal: 160...175)
                angleRow("Toe-Off Knee", value: m.takeoffLegKneeAtToeOff, ideal: 170...180)
                angleRow("Drive Knee", value: m.driveKneeAngleAtTakeoff, ideal: 70...90)
                angleRow("Trail Leg at TD", value: m.trailLegKneeAtTouchdown, ideal: 150...170)
                angleRow("Takeoff Angle", value: m.takeoffAngle, ideal: 40...55)
                angleRow("Backward Lean", value: m.backwardLeanAtPlant, ideal: 10...25)
                angleRow("Hip-Shoulder Sep", value: m.hipShoulderSeparationAtTD, ideal: 20...40)
            }
        }
        .jumpCard()
    }

    private func angleRow(_ name: String, value: Double?, ideal: ClosedRange<Double>) -> some View {
        HStack {
            Text(name)
                .font(.caption)
                .foregroundStyle(.jumpSubtle)

            Spacer()

            if let value {
                let status = JumpMeasurements.status(value, idealRange: ideal)
                HStack(spacing: 4) {
                    Text(String(format: "%.0f\u{00B0}", value))
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(status.color)
                    Image(systemName: status.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(status.color)
                }
            } else {
                Text("\u{2014}")
                    .font(.caption)
                    .foregroundStyle(.jumpSubtle.opacity(0.5))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Additional Metrics

    private var additionalMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Takeoff Metrics", systemImage: "speedometer")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let dist = m.takeoffDistanceFromBar {
                    metricTile(label: "Distance from Bar", value: String(format: "%.0fcm", dist * 100), icon: "arrow.left.and.right")
                }
                if let vVel = m.verticalVelocityAtToeOff {
                    metricTile(label: "Vertical Velocity", value: String(format: "%.2fm/s", vVel), icon: "arrow.up")
                }
                if let hVel = m.horizontalVelocityAtToeOff {
                    metricTile(label: "Horiz. Velocity", value: String(format: "%.2fm/s", hVel), icon: "arrow.right")
                }
                if let comHeight = m.comHeightAtToeOff {
                    metricTile(label: "COM at Toe-Off", value: String(format: "%.2fm", comHeight), icon: "figure.stand")
                }
            }
        }
        .jumpCard()
    }

    private func metricTile(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.jumpAccent)
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.jumpSubtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.jumpCard.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Data Loading

    private func loadKeyFrameImages() async {
        guard let videoURL = session.videoURL else { return }

        let trimOffset = session.trimRange?.lowerBound ?? 0

        if let plantFrame = result.keyFrames.takeoffPlant {
            plantFrameImage = try? await VideoFrameExtractor.extractFrame(
                from: videoURL, frameIndex: plantFrame, frameRate: session.frameRate,
                trimStartOffset: trimOffset
            )
        }

        if let toeOffFrame = result.keyFrames.toeOff {
            toeOffFrameImage = try? await VideoFrameExtractor.extractFrame(
                from: videoURL, frameIndex: toeOffFrame, frameRate: session.frameRate,
                trimStartOffset: trimOffset
            )
        }
    }

    private func poseIndexAt(_ frameIndex: Int?) -> Int? {
        guard let frameIndex else { return nil }
        return assignments[frameIndex]?.athletePoseIndex
    }
}
