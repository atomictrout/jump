import SwiftUI
import AVFoundation
import Foundation

struct VideoAnalysisView: View {
    let session: JumpSession
    @State private var playerVM = VideoPlayerViewModel()
    @State private var poseVM = PoseDetectionViewModel()
    @State private var showAnalysisResults = false
    @State private var showHelp = false

    // Workflow state
    @State private var isSelectingPerson = false
    
    // Smart tracking decision points
    @State private var showDecisionSheet = false
    @State private var currentDecision: SmartTrackingEngine.DecisionPoint?

    // Bar marking state
    @State private var isMarkingBar = false
    @State private var barMarkPoint1: CGPoint?  // View coordinates (pre-zoom)
    @State private var barMarkPoint2: CGPoint?  // View coordinates (pre-zoom)
    @State private var showBarConfirm = false

    // Zoom state for bar marking
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var zoomOffset: CGSize = .zero
    @State private var lastZoomOffset: CGSize = .zero

    // Finger offset when dragging bar crosshairs — crosshair sits above finger so you can see it
    private let barDragFingerOffset: CGFloat = 44

    // Bar height input
    @State private var showBarHeightInput = false
    @State private var barHeightText = ""
    @State private var suggestedBarHeight: Double?
    @State private var selectedUnit: HeightUnit = .meters
    @State private var feetText = ""
    @State private var inchesText = ""

    enum HeightUnit: String, CaseIterable {
        case feetInches = "ft/in"
        case meters = "m"
        case centimeters = "cm"
    }

    var body: some View {
        ZStack {
            Color.jumpBackgroundTop.ignoresSafeArea()

            VStack(spacing: 0) {
                // Video frame display
                videoFrameView
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.5)
                    .clipped()

                // Frame info bar
                frameInfoBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                // Scrubber with annotation + uncertain frame markers
                ZStack(alignment: .top) {
                    FrameScrubberView(viewModel: playerVM)

                    GeometryReader { geo in
                        // Person annotation markers (cyan dots)
                        ForEach(poseVM.personAnnotations.indices, id: \.self) { idx in
                            let ann = poseVM.personAnnotations[idx]
                            let xPos = playerVM.totalFrames > 1
                                ? geo.size.width * CGFloat(ann.frame) / CGFloat(playerVM.totalFrames - 1)
                                : 0
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 6, height: 6)
                                .position(x: xPos, y: 3)
                        }

                        // Uncertain frame markers (orange dots)
                        ForEach(poseVM.uncertainFrameIndices, id: \.self) { frameIdx in
                            let xPos = playerVM.totalFrames > 1
                                ? geo.size.width * CGFloat(frameIdx) / CGFloat(playerVM.totalFrames - 1)
                                : 0
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .position(x: xPos, y: 3)
                        }

                        // Takeoff frame marker (green triangle)
                        if let takeoffFrame = poseVM.takeoffFrameIndex, playerVM.totalFrames > 1 {
                            let xPos = geo.size.width * CGFloat(takeoffFrame) / CGFloat(playerVM.totalFrames - 1)
                            takeoffTriangle
                                .position(x: xPos, y: 3)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .frame(height: 56)
                .padding(.horizontal)
                .padding(.bottom, 8)

                // Control buttons
                controlBar
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                // Workflow hint
                workflowHint
                    .padding(.horizontal)
                    .padding(.top, 4)

                Spacer()
            }

            // "Athlete selected" toast
            if poseVM.showPersonSelected {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Athlete selected")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 120)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: poseVM.showPersonSelected)
            }
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.jumpSubtle)
                }
            }
        }
        .alert("How to Use", isPresented: $showHelp) {
            Button("Got it", role: .cancel) { }
        } message: {
            Text("1. Tap Person — scrub to a clear frame, tap the jumper. Add marks on frames where tracking is wrong. Tap ✓ to confirm.\n2. Tap Bar to mark the bar ends (pinch to zoom), then enter the bar height.\n3. Tap Analyze for technique feedback and measurements.")
        }
        .alert("Error", isPresented: $poseVM.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(poseVM.errorMessage ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $showBarHeightInput) {
            barHeightInputSheet
        }
        .sheet(isPresented: $showDecisionSheet) {
            if let decision = currentDecision,
               let frame = playerVM.currentFrameImage {
                let people = PersonThumbnailGenerator.generateThumbnails(
                    from: frame,
                    poses: decision.availablePeople
                )
                PersonSelectionSheet(
                    detectedPeople: people,
                    reason: decision.reason,
                    onSelect: { selectedPerson in
                        poseVM.handleDecisionSelection(selectedPerson, at: decision.frameIndex)
                        moveToNextDecision()
                    }
                )
            }
        }
        .task {
            if let stored = UserDefaults.standard.string(forKey: "poseEngine"), stored == "blazePose" {
                PoseDetectionService.poseEngine = .blazePose
            } else {
                PoseDetectionService.poseEngine = .vision
            }
            await playerVM.loadVideo(url: session.videoURL, session: session)
        }
        .onChange(of: poseVM.shouldNavigateToUncertain) { _, shouldNavigate in
            if shouldNavigate && !poseVM.uncertainFrameIndices.isEmpty && !isSelectingPerson {
                // Auto-navigate to first uncertain frame after a short delay
                // so the "athlete selected" toast shows first
                Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    navigateToNextUncertain()
                }
            }
        }
        .onChange(of: poseVM.isProcessing) { oldValue, newValue in
            // When processing completes, show first decision point
            if oldValue && !newValue && poseVM.hasMoreDecisionPoints() {
                Task {
                    try? await Task.sleep(for: .seconds(0.3))
                    if let decision = poseVM.getNextDecisionPoint() {
                        currentDecision = decision
                        await playerVM.seekToFrame(decision.frameIndex)
                        showDecisionSheet = true
                    }
                }
            }
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
                            // Skeleton overlay
                            if let pose = currentPose {
                                SkeletonOverlayView(
                                    pose: pose,
                                    viewSize: fittedVideoSize(in: geo.size),
                                    offset: fittedVideoOffset(in: geo.size),
                                    barDetection: poseVM.barDetection
                                )
                            }
                        }
                        .overlay {
                            // Bar marking dots and preview line
                            barMarkingOverlay(in: geo.size)
                        }
                        .scaleEffect(zoomScale)
                        .offset(zoomOffset)
                        .overlay {
                            // Instruction banners (on top of zoom)
                            if isMarkingBar {
                                barMarkingBanner
                            } else if isSelectingPerson {
                                personSelectionBanner
                            } else if poseVM.shouldNavigateToUncertain && !poseVM.uncertainFrameIndices.isEmpty {
                                uncertainReviewBanner
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(zoomAndTapGesture(in: geo.size))
                }

                // Zoom indicator
                if zoomScale > 1.05 {
                    VStack {
                        Spacer()
                        HStack {
                            Text(String(format: "%.1fx", zoomScale))
                                .font(.caption2.bold())
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.5))
                                .clipShape(Capsule())

                            Spacer()

                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    zoomScale = 1.0
                                    lastZoomScale = 1.0
                                    zoomOffset = .zero
                                    lastZoomOffset = .zero
                                }
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(6)
                                    .background(.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    // MARK: - Gestures

    private func zoomAndTapGesture(in containerSize: CGSize) -> some Gesture {
        SimultaneousGesture(
            SimultaneousGesture(
                // Pinch to zoom
                MagnifyGesture()
                    .onChanged { value in
                        let newScale = lastZoomScale * value.magnification
                        zoomScale = min(max(newScale, 1.0), 5.0)
                    }
                    .onEnded { value in
                        lastZoomScale = zoomScale
                        if zoomScale < 1.05 {
                            withAnimation(.easeOut(duration: 0.2)) {
                                zoomScale = 1.0
                                lastZoomScale = 1.0
                                zoomOffset = .zero
                                lastZoomOffset = .zero
                            }
                        }
                    },
                // Drag to pan when zoomed (minimum distance prevents interfering with taps)
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if zoomScale > 1.05 {
                            zoomOffset = CGSize(
                                width: lastZoomOffset.width + value.translation.width,
                                height: lastZoomOffset.height + value.translation.height
                            )
                        }
                    }
                    .onEnded { value in
                        lastZoomOffset = zoomOffset
                    }
            ),
            // Tap gesture — always active, highest priority for single taps
            SpatialTapGesture()
                .onEnded { value in
                    // Convert tap location from zoomed space back to unzoomed space
                    let tapInContainer = value.location
                    let unzoomedTap = CGPoint(
                        x: (tapInContainer.x - containerSize.width / 2 - zoomOffset.width) / zoomScale + containerSize.width / 2,
                        y: (tapInContainer.y - containerSize.height / 2 - zoomOffset.height) / zoomScale + containerSize.height / 2
                    )
                    handleTap(at: unzoomedTap, in: containerSize)
                }
        )
    }

    // MARK: - Bar Marking Overlay

    @ViewBuilder
    private func barMarkingOverlay(in containerSize: CGSize) -> some View {
        ZStack {
            // Canvas for the connecting line
            Canvas { context, size in
                if let p1 = barMarkPoint1, let p2 = barMarkPoint2 {
                    var line = Path()
                    line.move(to: p1)
                    line.addLine(to: p2)
                    context.stroke(
                        line,
                        with: .color(.red.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 3])
                    )
                }
            }
            .allowsHitTesting(false)

            // Draggable crosshair for point 1
            // Offset: crosshair center sits above the finger so you can see it while dragging
            if let p1 = barMarkPoint1 {
                barCrosshairView(point: p1)
                    .position(p1)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                barMarkPoint1 = CGPoint(
                                    x: value.location.x,
                                    y: value.location.y - barDragFingerOffset
                                )
                            }
                    )
            }

            // Draggable crosshair for point 2
            if let p2 = barMarkPoint2 {
                barCrosshairView(point: p2)
                    .position(p2)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                barMarkPoint2 = CGPoint(
                                    x: value.location.x,
                                    y: value.location.y - barDragFingerOffset
                                )
                            }
                    )
            }
        }
    }

    /// Semi-transparent crosshair with 1px lines and no filled dot
    private func barCrosshairView(point: CGPoint) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let armLength: CGFloat = 20

            // Outer circle — semi-transparent for visibility against any background
            let circleRect = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
            context.stroke(Path(ellipseIn: circleRect), with: .color(.cyan.opacity(0.6)), lineWidth: 1)

            // Horizontal crosshair — 1px
            var hLine = Path()
            hLine.move(to: CGPoint(x: center.x - armLength, y: center.y))
            hLine.addLine(to: CGPoint(x: center.x - 5, y: center.y))
            context.stroke(hLine, with: .color(.cyan.opacity(0.9)), lineWidth: 1)

            var hLine2 = Path()
            hLine2.move(to: CGPoint(x: center.x + 5, y: center.y))
            hLine2.addLine(to: CGPoint(x: center.x + armLength, y: center.y))
            context.stroke(hLine2, with: .color(.cyan.opacity(0.9)), lineWidth: 1)

            // Vertical crosshair — 1px
            var vLine = Path()
            vLine.move(to: CGPoint(x: center.x, y: center.y - armLength))
            vLine.addLine(to: CGPoint(x: center.x, y: center.y - 5))
            context.stroke(vLine, with: .color(.cyan.opacity(0.9)), lineWidth: 1)

            var vLine2 = Path()
            vLine2.move(to: CGPoint(x: center.x, y: center.y + 5))
            vLine2.addLine(to: CGPoint(x: center.x, y: center.y + armLength))
            context.stroke(vLine2, with: .color(.cyan.opacity(0.9)), lineWidth: 1)

            // Tiny center dot — 1px
            let dotRect = CGRect(x: center.x - 0.5, y: center.y - 0.5, width: 1, height: 1)
            context.fill(Path(ellipseIn: dotRect), with: .color(.cyan))
        }
        .frame(width: 50, height: 50)
        .contentShape(Circle().size(width: 44, height: 44))
    }

    private var barMarkingBanner: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .foregroundStyle(.cyan)
                Text(barMarkInstructionText)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)

                Spacer()

                if showBarConfirm {
                    // Confirm / Cancel buttons
                    Button {
                        confirmBarMarking()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }

                    Button {
                        cancelBarMarking()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        exitBarMarking()
                    } label: {
                        Text("Cancel")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Spacer()
        }
    }

    private var barMarkInstructionText: String {
        if showBarConfirm {
            return "Bar marked — Confirm?"
        } else if barMarkPoint1 == nil {
            return "Pinch to zoom, tap left end of bar"
        } else {
            return "Now tap the right end"
        }
    }

    // MARK: - Frame Info

    private var frameInfoBar: some View {
        HStack {
            Text("Frame \(playerVM.currentFrameIndex + 1) / \(playerVM.totalFrames)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.jumpSubtle)

            if let barHeight = poseVM.barHeightMeters {
                Text("Bar: \(BarHeightParser.formatHeight(barHeight))")
                    .font(.caption2.bold())
                    .foregroundStyle(.barLine)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.barLine.opacity(0.15))
                    .clipShape(Capsule())
            }

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
        HStack(spacing: 10) {
            // Step backward
            Button {
                Task { await playerVM.stepBackward() }
            } label: {
                Image(systemName: "backward.frame.fill")
                    .font(.body)
            }
            .foregroundStyle(.white)

            // Play/Pause
            Button {
                playerVM.togglePlayback()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .foregroundStyle(.jumpAccent)

            // Step forward
            Button {
                Task { await playerVM.stepForward() }
            } label: {
                Image(systemName: "forward.frame.fill")
                    .font(.body)
            }
            .foregroundStyle(.white)

            Spacer()

            // ── Sequential workflow buttons ──

            // 1. Select person (auto-detects poses first if needed)
            Button {
                if isSelectingPerson {
                    // Already selecting — just exit (confirm via banner ✓)
                    isSelectingPerson = false
                } else {
                    // Enter person selection mode (works even after confirmation to add more annotations)
                    isSelectingPerson = true
                    // Auto-detect if not yet done
                    if !poseVM.hasDetected {
                        Task { await poseVM.processVideo(url: session.videoURL, session: session) }
                    }
                }
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.callout)
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(personButtonTint)
            .disabled(poseVM.isProcessing || isMarkingBar)
            .help("Person")

            // 2. Mark bar
            Button {
                startBarMarking()
            } label: {
                Image(systemName: "ruler")
                    .font(.callout)
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(barButtonTint)
            .disabled(!poseVM.personConfirmed || poseVM.isProcessing || isMarkingBar || isSelectingPerson)
            .help("Bar")

            // 3. Analyze
            Button {
                poseVM.runAnalysis(frameRate: session.frameRate)
                if poseVM.analysisResult != nil {
                    showAnalysisResults = true
                }
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.callout)
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(.jumpSecondary)
            .disabled(!poseVM.personConfirmed || poseVM.barDetection == nil || poseVM.isProcessing || isSelectingPerson || isMarkingBar)
            .help("Analyze")
        }
    }

    private var personButtonTint: Color {
        if poseVM.personConfirmed {
            return .green
        } else if isSelectingPerson {
            return .cyan
        } else {
            return .jumpAccent
        }
    }

    private var barButtonTint: Color {
        if poseVM.barDetection != nil {
            return .green
        } else {
            return .orange
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

    // MARK: - Person Selection Banner

    private var personSelectionBanner: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(personBannerTitle)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(personBannerSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                if !poseVM.personAnnotations.isEmpty {
                    // Undo last annotation
                    Button {
                        poseVM.undoLastAnnotation()
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                    }

                    // Clear all annotations
                    Button {
                        poseVM.clearPersonAnnotations()
                    } label: {
                        Image(systemName: "trash.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }

                    // Confirm
                    Button {
                        poseVM.confirmPerson()
                        isSelectingPerson = false
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                    }
                }

                // Cancel
                Button {
                    isSelectingPerson = false
                } label: {
                    Text("Cancel")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Spacer()
        }
    }

    private var personBannerTitle: String {
        let count = poseVM.personAnnotations.count
        if count == 0 {
            return "Tap the jumper"
        } else if poseVM.personConfirmed {
            return "\(count) mark\(count == 1 ? "" : "s") — add corrections"
        } else {
            return "\(count) mark\(count == 1 ? "" : "s") — add more or confirm"
        }
    }

    private var personBannerSubtitle: String {
        if poseVM.isProcessing {
            return "Detecting poses… you can select after detection completes"
        } else if !poseVM.hasDetected {
            return "Waiting for pose detection…"
        } else if poseVM.personAnnotations.isEmpty {
            return "Scrub to a frame showing the jumper, then tap them"
        } else if poseVM.personConfirmed {
            return "Scrub to frames where skeleton is wrong and tap the correct person"
        } else {
            return "Scrub to frames where tracking is wrong and tap the correct person"
        }
    }

    // MARK: - Uncertain Frame Review Banner

    private var uncertainReviewBanner: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review tracking")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    if let progress = poseVM.uncertainReviewProgress {
                        Text("Uncertain frame \(progress) — tap jumper if wrong")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text("\(poseVM.uncertainFrameCount) frame\(poseVM.uncertainFrameCount == 1 ? "" : "s") need\(poseVM.uncertainFrameCount == 1 ? "s" : "") review")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Spacer()

                // Navigate to next uncertain frame
                Button {
                    navigateToNextUncertain()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                            .font(.caption.bold())
                        Image(systemName: "arrow.right")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.2))
                    .clipShape(Capsule())
                }

                // Dismiss review mode
                Button {
                    poseVM.dismissUncertainReview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Spacer()
        }
    }

    private func navigateToNextUncertain() {
        if let frameIdx = poseVM.nextUncertainFrame() {
            Task { await playerVM.seekToFrame(frameIdx) }
            // Enter person selection mode so user can tap to correct
            isSelectingPerson = true
        } else {
            // No more uncertain frames — dismiss review
            poseVM.dismissUncertainReview()
        }
    }
    
    private func moveToNextDecision() {
        poseVM.advanceToNextDecision()
        
        if let nextDecision = poseVM.getNextDecisionPoint() {
            // Move to next decision
            currentDecision = nextDecision
            Task {
                await playerVM.seekToFrame(nextDecision.frameIndex)
                showDecisionSheet = true
            }
        } else {
            // All decisions made!
            showDecisionSheet = false
        }
    }

    // MARK: - Workflow Hint

    @ViewBuilder
    private var workflowHint: some View {
        if !poseVM.personConfirmed && !isSelectingPerson && !poseVM.isProcessing {
            hintCard(icon: "person.crop.circle", title: "Step 1: Select Person",
                     detail: "Tap **Person** to identify the jumper. Scrub to a clear frame and tap them. Add more marks if tracking is off on other frames.")
        } else if poseVM.personConfirmed && poseVM.barDetection == nil && !isMarkingBar {
            hintCard(icon: "ruler", title: "Step 2: Mark Bar",
                     detail: "Tap **Bar** to mark the bar position. Pinch to zoom for precision, then tap each end of the bar.")
        } else if poseVM.personConfirmed && poseVM.barDetection != nil && poseVM.analysisResult == nil {
            hintCard(icon: "waveform.path.ecg", title: "Step 3: Analyze",
                     detail: "Tap **Analyze** to get technique feedback and jump measurements.")
        }
    }

    private func hintCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.jumpAccent)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
            }

            Text(.init(detail))
                .font(.caption)
                .foregroundStyle(.jumpSubtle)
                .multilineTextAlignment(.center)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.jumpCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint, in containerSize: CGSize) {
        if isMarkingBar {
            handleBarMarkTap(at: location, in: containerSize)
        } else if isSelectingPerson && poseVM.hasDetected {
            // In person selection mode — add annotation (works even during retrack, will queue)
            handlePersonSelectTap(at: location, in: containerSize)
        }
    }

    private func handlePersonSelectTap(at location: CGPoint, in containerSize: CGSize) {
        let videoSize = fittedVideoSize(in: containerSize)
        let videoOffset = fittedVideoOffset(in: containerSize)
        let visionPoint = CoordinateConverter.viewToVision(
            point: location,
            viewSize: videoSize,
            offset: videoOffset
        )

        poseVM.selectPerson(at: visionPoint, frameIndex: playerVM.currentFrameIndex)
    }

    private func handleBarMarkTap(at location: CGPoint, in containerSize: CGSize) {
        if barMarkPoint1 == nil {
            barMarkPoint1 = location
        } else if barMarkPoint2 == nil {
            barMarkPoint2 = location
            showBarConfirm = true
        }
        // If both points already set, ignore additional taps (user must confirm or cancel)
    }

    // MARK: - Bar Marking Actions

    private func startBarMarking() {
        isMarkingBar = true
        barMarkPoint1 = nil
        barMarkPoint2 = nil
        showBarConfirm = false
    }

    private func confirmBarMarking() {
        guard let p1 = barMarkPoint1, let p2 = barMarkPoint2 else { return }

        let containerSize = CGSize(
            width: UIScreen.main.bounds.width,
            height: UIScreen.main.bounds.height * 0.5
        )
        let videoSize = fittedVideoSize(in: containerSize)
        let videoOffset = fittedVideoOffset(in: containerSize)

        let visionP1 = CoordinateConverter.viewToVision(
            point: p1,
            viewSize: videoSize,
            offset: videoOffset
        )
        let visionP2 = CoordinateConverter.viewToVision(
            point: p2,
            viewSize: videoSize,
            offset: videoOffset
        )

        poseVM.setBarManually(
            start: visionP1,
            end: visionP2,
            frameIndex: playerVM.currentFrameIndex
        )

        exitBarMarking()

        // Reset zoom after bar is marked
        withAnimation(.easeOut(duration: 0.2)) {
            zoomScale = 1.0
            lastZoomScale = 1.0
            zoomOffset = .zero
            lastZoomOffset = .zero
        }

        // Try to suggest bar height from video caption
        if let caption = session.videoCaption,
           let parsed = BarHeightParser.parseHeight(from: caption) {
            suggestedBarHeight = parsed
            prefillBarHeight(parsed)
        } else {
            suggestedBarHeight = nil
            barHeightText = ""
            feetText = ""
            inchesText = ""
        }

        // Show bar height input prompt
        showBarHeightInput = true
    }

    private func cancelBarMarking() {
        barMarkPoint1 = nil
        barMarkPoint2 = nil
        showBarConfirm = false
    }

    private func exitBarMarking() {
        isMarkingBar = false
        barMarkPoint1 = nil
        barMarkPoint2 = nil
        showBarConfirm = false
    }

    // MARK: - Bar Height Input Sheet

    private var barHeightInputSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let suggested = suggestedBarHeight {
                    HStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(.jumpAccent)
                        Text("Found \"\(BarHeightParser.formatHeightFull(suggested))\" in video caption")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                // Unit picker
                Picker("Unit", selection: $selectedUnit) {
                    ForEach(HeightUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Input fields based on unit
                switch selectedUnit {
                case .feetInches:
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Feet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("6", text: $feetText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .font(.title2.monospacedDigit())
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("2", text: $inchesText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .font(.title2.monospacedDigit())
                        }
                    }
                case .meters:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Height in meters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("1.85", text: $barHeightText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .font(.title2.monospacedDigit())
                    }
                case .centimeters:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Height in centimeters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("185", text: $barHeightText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .font(.title2.monospacedDigit())
                    }
                }

                // Live preview of parsed height
                if let parsed = parsedBarHeight {
                    Text(BarHeightParser.formatHeightFull(parsed))
                        .font(.headline)
                        .foregroundStyle(.jumpAccent)
                } else if hasBarHeightInput {
                    Text("Enter a valid height")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("Bar Height")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        showBarHeightInput = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        if let meters = parsedBarHeight {
                            poseVM.setBarHeight(meters)
                        }
                        showBarHeightInput = false
                    }
                    .disabled(parsedBarHeight == nil)
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    /// Parse the current bar height input based on selected unit
    private var parsedBarHeight: Double? {
        switch selectedUnit {
        case .feetInches:
            guard let feet = Double(feetText), let inches = Double(inchesText) else { return nil }
            guard feet >= 0 && inches >= 0 && inches < 12 else { return nil }
            let meters = (feet * 12 + inches) * 0.0254
            return meters >= 0.50 && meters <= 2.60 ? meters : nil
        case .meters:
            guard let value = Double(barHeightText) else { return nil }
            return value >= 0.50 && value <= 2.60 ? value : nil
        case .centimeters:
            guard let value = Double(barHeightText) else { return nil }
            let meters = value / 100.0
            return meters >= 0.50 && meters <= 2.60 ? meters : nil
        }
    }

    /// Pre-fill the bar height fields from a parsed value in meters
    private func prefillBarHeight(_ meters: Double) {
        // Default to meters for pre-fill
        selectedUnit = .meters
        barHeightText = String(format: "%.2f", meters)

        // Also compute feet/inches in case user switches
        let totalInches = meters / 0.0254
        feetText = "\(Int(totalInches / 12))"
        inchesText = "\(Int(totalInches.truncatingRemainder(dividingBy: 12)))"
    }

    /// Whether any input has been entered
    private var hasBarHeightInput: Bool {
        switch selectedUnit {
        case .feetInches:
            return !feetText.isEmpty || !inchesText.isEmpty
        case .meters, .centimeters:
            return !barHeightText.isEmpty
        }
    }

    // MARK: - Takeoff Triangle

    private var takeoffTriangle: some View {
        Image(systemName: "arrowtriangle.up.fill")
            .font(.system(size: 8))
            .foregroundStyle(.green)
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

