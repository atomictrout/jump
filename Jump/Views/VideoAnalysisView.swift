import SwiftUI
import AVFoundation

struct VideoAnalysisView: View {
    let session: JumpSession
    @State private var playerVM = VideoPlayerViewModel()
    @State private var poseVM = PoseDetectionViewModel()
    @State private var showAnalysisResults = false

    var body: some View {
        ZStack {
            Color.jumpBackgroundTop.ignoresSafeArea()

            VStack(spacing: 0) {
                // Video frame display
                videoFrameView
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.5)

                // Frame info bar
                frameInfoBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                // Scrubber
                FrameScrubberView(viewModel: playerVM)
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                // Control buttons
                controlBar
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                Spacer()
            }
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await playerVM.loadVideo(url: session.videoURL, session: session)
        }
        .overlay {
            if poseVM.isProcessing {
                processingOverlay
            }
        }
        .sheet(isPresented: $showAnalysisResults) {
            if let result = poseVM.analysisResult {
                AnalysisResultsView(
                    result: result,
                    session: session,
                    onJumpToFrame: { frame in
                        showAnalysisResults = false
                        Task { await playerVM.seekToFrame(frame) }
                    }
                )
            }
        }
    }

    // MARK: - Video Frame

    private var videoFrameView: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let image = playerVM.currentFrameImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay {
                            if let pose = currentPose {
                                SkeletonOverlayView(
                                    pose: pose,
                                    viewSize: fittedVideoSize(in: geo.size),
                                    offset: fittedVideoOffset(in: geo.size),
                                    barDetection: poseVM.barDetection
                                )
                            }
                        }
                }
            }
        }
    }

    // MARK: - Frame Info

    private var frameInfoBar: some View {
        HStack {
            Text("Frame \(playerVM.currentFrameIndex + 1) / \(playerVM.totalFrames)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.jumpSubtle)

            Spacer()

            Text(formatTimestamp(playerVM.currentTimestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.jumpSubtle)

            if let phase = currentPhase {
                Text(phase.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(phase.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(phase.color.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 16) {
            // Step backward
            Button {
                Task { await playerVM.stepBackward() }
            } label: {
                Image(systemName: "backward.frame.fill")
                    .font(.title3)
            }
            .foregroundStyle(.white)

            // Play/Pause
            Button {
                playerVM.togglePlayback()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
            }
            .foregroundStyle(.jumpAccent)

            // Step forward
            Button {
                Task { await playerVM.stepForward() }
            } label: {
                Image(systemName: "forward.frame.fill")
                    .font(.title3)
            }
            .foregroundStyle(.white)

            Spacer()

            // Detect poses
            Button {
                Task { await poseVM.processVideo(url: session.videoURL, session: session) }
            } label: {
                Label("Detect", systemImage: "figure.stand")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.bordered)
            .tint(.jumpAccent)
            .disabled(poseVM.isProcessing || !poseVM.poses.isEmpty)

            // Analyze
            Button {
                poseVM.runAnalysis(frameRate: session.frameRate)
                if poseVM.analysisResult != nil {
                    showAnalysisResults = true
                }
            } label: {
                Label("Analyze", systemImage: "waveform.path.ecg")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.jumpSecondary)
            .disabled(poseVM.poses.isEmpty)
        }
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView(value: poseVM.progress) {
                    Text("Detecting poses...")
                        .font(.headline)
                        .foregroundStyle(.white)
                } currentValueLabel: {
                    Text("\(Int(poseVM.progress * 100))%")
                        .font(.system(.title2, design: .monospaced).bold())
                        .foregroundStyle(.jumpAccent)
                }
                .tint(.jumpAccent)
                .frame(width: 200)
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - Helpers

    private var currentPose: BodyPose? {
        guard !poseVM.poses.isEmpty,
              playerVM.currentFrameIndex < poseVM.poses.count else { return nil }
        let pose = poseVM.poses[playerVM.currentFrameIndex]
        return pose.hasMinimumConfidence ? pose : nil
    }

    private var currentPhase: JumpPhase? {
        guard let result = poseVM.analysisResult else { return nil }
        return result.phases.first { phase in
            (phase.startFrame...phase.endFrame).contains(playerVM.currentFrameIndex)
        }?.phase
    }

    private func fittedVideoSize(in containerSize: CGSize) -> CGSize {
        guard session.naturalSize != .zero else { return containerSize }
        let videoAspect = session.naturalSize.width / session.naturalSize.height
        let containerAspect = containerSize.width / containerSize.height

        if videoAspect > containerAspect {
            let width = containerSize.width
            let height = width / videoAspect
            return CGSize(width: width, height: height)
        } else {
            let height = containerSize.height
            let width = height * videoAspect
            return CGSize(width: width, height: height)
        }
    }

    private func fittedVideoOffset(in containerSize: CGSize) -> CGPoint {
        let fitted = fittedVideoSize(in: containerSize)
        return CGPoint(
            x: (containerSize.width - fitted.width) / 2,
            y: (containerSize.height - fitted.height) / 2
        )
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, frac)
    }
}
