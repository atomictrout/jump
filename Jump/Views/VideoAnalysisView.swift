import SwiftUI
import AVFoundation

struct VideoAnalysisView: View {
    let session: JumpSession
    @State private var playerVM = VideoPlayerViewModel()
    @State private var poseVM = PoseDetectionViewModel()
    @State private var showAnalysisResults = false
    @State private var showHelp = false

    // Workflow state
    @State private var isSelectingPerson = false

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

                // Scrubber
                FrameScrubberView(viewModel: playerVM)
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
            Text("1. Tap Detect to analyze body poses\n2. Tap Person, scrub to a frame with the jumper, tap them. Add more marks on frames where tracking is wrong. Tap ✓ to confirm.\n3. Tap Bar to mark the bar ends (pinch to zoom), then enter the bar height\n4. Tap Analyze for technique feedback and measurements")
        }
        .alert("Error", isPresented: $poseVM.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(poseVM.errorMessage ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $showBarHeightInput) {
            barHeightInputSheet
        }
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
            SimultaneousGesture(
                // Drag to pan when zoomed
                DragGesture()
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
                    },
                // Tap gesture
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
        )
    }

    // MARK: - Bar Marking Overlay

    @ViewBuilder
    private func barMarkingOverlay(in containerSize: CGSize) -> some View {
        Canvas { context, size in
            // Draw first point if set
            if let p1 = barMarkPoint1 {
                drawCrosshairDot(context: &context, at: p1)
            }

            // Draw second point and connecting line
            if let p1 = barMarkPoint1, let p2 = barMarkPoint2 {
                // Line between points
                var line = Path()
                line.move(to: p1)
                line.addLine(to: p2)
                context.stroke(
                    line,
                    with: .color(.red),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 4])
                )

                drawCrosshairDot(context: &context, at: p2)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawCrosshairDot(context: inout GraphicsContext, at point: CGPoint) {
        let dotRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: dotRect), with: .color(.cyan))

        var hLine = Path()
        hLine.move(to: CGPoint(x: point.x - 10, y: point.y))
        hLine.addLine(to: CGPoint(x: point.x + 10, y: point.y))
        context.stroke(hLine, with: .color(.cyan), style: StrokeStyle(lineWidth: 1.5))

        var vLine = Path()
        vLine.move(to: CGPoint(x: point.x, y: point.y - 10))
        vLine.addLine(to: CGPoint(x: point.x, y: point.y + 10))
        context.stroke(vLine, with: .color(.cyan), style: StrokeStyle(lineWidth: 1.5))
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

            // 1. Detect poses
            Button {
                Task { await poseVM.processVideo(url: session.videoURL, session: session) }
            } label: {
                Image(systemName: "figure.stand")
                    .font(.callout)
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(poseVM.hasDetected ? .green : .jumpAccent)
            .disabled(poseVM.isProcessing || poseVM.hasDetected)
            .help("Detect")

            // 2. Select person
            Button {
                if isSelectingPerson {
                    // Already selecting — confirm person
                    poseVM.confirmPerson()
                    isSelectingPerson = false
                } else {
                    // Enter person selection mode
                    isSelectingPerson = true
                }
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.callout)
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(personButtonTint)
            .disabled(!poseVM.hasDetected || poseVM.isProcessing || isMarkingBar)
            .help("Person")

            // 3. Mark bar
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

            // 4. Analyze
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
            return .orange
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
        } else {
            return "\(count) mark\(count == 1 ? "" : "s") — add more or confirm"
        }
    }

    private var personBannerSubtitle: String {
        if poseVM.personAnnotations.isEmpty {
            return "Scrub to a frame showing the jumper, then tap them"
        } else {
            return "Scrub to frames where tracking is wrong and tap the correct person"
        }
    }

    // MARK: - Workflow Hint

    @ViewBuilder
    private var workflowHint: some View {
        if !poseVM.hasDetected && !poseVM.isProcessing {
            hintCard(icon: "figure.stand", title: "Step 1: Detect",
                     detail: "Tap **Detect** to analyze body poses in the video.")
        } else if poseVM.hasDetected && !poseVM.personConfirmed && !isSelectingPerson {
            hintCard(icon: "person.crop.circle", title: "Step 2: Select Person",
                     detail: "Tap **Person** to identify the jumper. Scrub to a clear frame and tap them. Add more marks if tracking is off on other frames.")
        } else if poseVM.personConfirmed && poseVM.barDetection == nil && !isMarkingBar {
            hintCard(icon: "ruler", title: "Step 3: Mark Bar",
                     detail: "Tap **Bar** to mark the bar position. Pinch to zoom for precision, then tap each end of the bar.")
        } else if poseVM.personConfirmed && poseVM.barDetection != nil && poseVM.analysisResult == nil {
            hintCard(icon: "waveform.path.ecg", title: "Step 4: Analyze",
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
        } else if isSelectingPerson && !poseVM.isProcessing {
            // In person selection mode — add annotation
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
