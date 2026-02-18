import SwiftUI
import AVFoundation
import Foundation

enum HeightUnit: String, CaseIterable {
    case feetInches = "Feet & Inches"
    case meters = "Meters"
    case centimeters = "Centimeters"
}

struct VideoAnalysisView: View {
    let session: JumpSession
    @State private var playerVM = VideoPlayerViewModel()
    @State private var poseVM = PoseDetectionViewModel()
    
    // UI State
    @State private var isSelectingPerson = false
    @State private var isMarkingBar = false
    @State private var showAnalysisResults = false
    @State private var showBarHeightInput = false
    @State private var showBarConfirm = false
    @State private var showThumbnailSheet = false
    @State private var showDecisionSheet = false
    
    // Bar Marking
    @State private var barMarkPoint1: CGPoint?
    @State private var barMarkPoint2: CGPoint?
    
    // Bar Height Input
    @State private var selectedUnit: HeightUnit = .meters
    @State private var barHeightText = ""
    @State private var feetText = ""
    @State private var inchesText = ""
    @State private var suggestedBarHeight: Double?
    
    // Zoom State
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var zoomOffset: CGSize = .zero
    @State private var lastZoomOffset: CGSize = .zero
    
    // Decision Points
    @State private var currentDecision: SmartTrackingEngine.DecisionPoint?
    
    private let barDragFingerOffset: CGFloat = 50

    var body: some View {
        ZStack {
            Color.jumpBackgroundTop.ignoresSafeArea()

            VStack(spacing: 0) {
                // Video frame display
                videoFrameView
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.7)
                    .clipped()

                // Scrubber only
                FrameScrubberView(viewModel: playerVM)
                    .frame(height: 56)
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                // Control buttons
                controlBar
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                
                // Workflow hint
                workflowHint
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                Spacer()
            }
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // 🔧 DEBUG: Re-detection button
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task {
                        await poseVM.detectAllPeople(url: session.videoURL, session: session)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.cyan)
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { poseVM.showError },
            set: { poseVM.showError = $0 }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(poseVM.errorMessage ?? "An unknown error occurred.")
        }
        .task {
            if let stored = UserDefaults.standard.string(forKey: "poseEngine"), stored == "blazePose" {
                PoseDetectionService.poseEngine = .blazePose
            } else {
                PoseDetectionService.poseEngine = .vision
            }
            await playerVM.loadVideo(url: session.videoURL, session: session)
            // Auto-start pose detection - detect ALL people without tracking
            await poseVM.detectAllPeople(url: session.videoURL, session: session)
        }
        .overlay {
            if poseVM.isProcessing {
                processingOverlay
            }
        }
        .overlay {
            if isSelectingPerson {
                personSelectionBanner
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
                        .contentShape(Rectangle())  // Make entire image tappable
                        .onTapGesture { location in
                            if isSelectingPerson {
                                handleTap(at: location, in: geo.size)
                            }
                        }
                        .overlay {
                            // Always show ALL detected people with numbers
                            let allPoses = poseVM.getAllPosesAtFrame(playerVM.currentFrameIndex)
                            if !allPoses.isEmpty && poseVM.hasDetected {
                                AllPeopleReviewOverlay(
                                    allPoses: allPoses,
                                    trackedPersonIndex: poseVM.currentlyTrackedPersonIndex(at: playerVM.currentFrameIndex),
                                    viewSize: fittedVideoSize(in: geo.size),
                                    offset: fittedVideoOffset(in: geo.size),
                                    onSelectPerson: isSelectingPerson ? { selectedPose in
                                        // User tapped a skeleton - select that specific pose
                                        poseVM.selectSpecificPose(selectedPose, at: playerVM.currentFrameIndex)
                                    } : nil
                                )
                            }
                            
                            // Tracking Status HUD
                            trackingStatusHUD
                                .allowsHitTesting(false)  // Don't intercept taps
                        }
                }
            }
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
    
    private func fittedVideoSize(in containerSize: CGSize) -> CGSize {
        guard session.naturalSize != .zero else { return containerSize }
        let videoAspect = session.naturalSize.width / session.naturalSize.height
        let containerAspect = containerSize.width / containerSize.height

        if videoAspect > containerAspect {
            let height = containerSize.width / videoAspect
            return CGSize(width: containerSize.width, height: height)
        } else {
            let width = containerSize.height * videoAspect
            return CGSize(width: width, height: containerSize.height)
        }
    }

    private func fittedVideoOffset(in containerSize: CGSize) -> CGPoint {
        let fitted = fittedVideoSize(in: containerSize)
        return CGPoint(
            x: (containerSize.width - fitted.width) / 2,
            y: (containerSize.height - fitted.height) / 2
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
                VStack(spacing: 2) {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                    Text("Person")
                        .font(.caption2)
                }
                .frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
            .tint(personButtonTint)
            .disabled(poseVM.isProcessing || isMarkingBar)

            // 2. Mark bar
            Button {
                startBarMarking()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "ruler")
                        .font(.title3)
                    Text("Bar")
                        .font(.caption2)
                }
                .frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
            .tint(barButtonTint)
            .disabled(!poseVM.personConfirmed || poseVM.isProcessing || isMarkingBar || isSelectingPerson)

            // 3. Analyze
            Button {
                poseVM.runAnalysis(frameRate: session.frameRate)
                if poseVM.analysisResult != nil {
                    showAnalysisResults = true
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title3)
                    Text("Analyze")
                        .font(.caption2)
                }
                .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(.jumpSecondary)
            .disabled(!poseVM.personConfirmed || poseVM.barDetection == nil || poseVM.isProcessing || isSelectingPerson || isMarkingBar)
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

    // MARK: - Person Selection Banner

    private var personSelectionBanner: some View {
        VStack {
            Spacer()
            
            let allPoses = poseVM.getAllPosesAtFrame(playerVM.currentFrameIndex)
            SelectionConfirmationBar(
                selectedCount: poseVM.personAnnotations.count,
                hasDetections: !allPoses.isEmpty,
                onConfirm: {
                    poseVM.confirmPerson()
                    isSelectingPerson = false
                },
                onShowThumbnails: {
                    showThumbnailSheet = true
                },
                onNoAthlete: {
                    // Mark current frame as "no athlete present"
                    // Use a special coordinate (-1, -1) to indicate "no athlete"
                    poseVM.selectPerson(at: CGPoint(x: -1, y: -1), frameIndex: playerVM.currentFrameIndex)
                },
                onCancel: {
                    isSelectingPerson = false
                }
            )
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
                     detail: "Tap **Person** to identify the jumper. Scrub to a clear frame and tap their skeleton or tap background.")
        } else if poseVM.personConfirmed && poseVM.barDetection == nil && !isMarkingBar {
            hintCard(icon: "ruler", title: "Step 2: Mark Bar",
                     detail: "Tap **Bar** to mark the bar position. Pinch to zoom for precision, then tap each end of the bar.")
        } else if poseVM.personConfirmed && poseVM.barDetection != nil && poseVM.analysisResult == nil {
            hintCard(icon: "waveform.path.ecg", title: "Step 3: Analyze",
                     detail: "Tap **Analyze** to get technique feedback and jump measurements.")
        } else if poseVM.personConfirmed && !isSelectingPerson && !isMarkingBar {
            // Show hint about being able to add more annotations
            hintCard(icon: "plus.circle", title: "Tip: Improve Tracking",
                     detail: "Tap **Person** again to add more annotations on frames where tracking is incorrect. More annotations = better tracking!")
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
    
    @ViewBuilder
    private var decisionPointSheet: some View {
        if let decision = currentDecision,
           let cgImage = playerVM.currentFrameImage {
            let uiImage = UIImage(cgImage: cgImage)
            
            // Get ALL poses at this frame, not just the decision point's availablePeople
            // This ensures we show everyone, even if tracking lost the athlete
            let allPosesAtFrame = poseVM.getAllPosesAtFrame(decision.frameIndex)
            let people = PersonThumbnailGenerator.generateThumbnails(
                from: uiImage,
                poses: allPosesAtFrame
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

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, frac)
    }
    
    // MARK: - Tracking Status HUD
    
    /// Display current tracking status at the top of the video
    private var trackingStatusHUD: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                let count = poseVM.getAllPosesAtFrame(playerVM.currentFrameIndex).count
                let status = poseVM.trackingStatus
                let trackedIndex = poseVM.currentlyTrackedPersonIndex(at: playerVM.currentFrameIndex)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Main status
                    HStack(spacing: 6) {
                        Image(systemName: status.icon)
                            .font(.caption)
                        Text(status.displayText)
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                    
                    // Secondary info
                    if count > 0 {
                        HStack(spacing: 8) {
                            Text("\(count) \(count == 1 ? "person" : "people")")
                                .font(.caption2)
                            
                            if let tracked = trackedIndex {
                                Text("Person #\(tracked + 1)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.green)
                            } else if !poseVM.personAnnotations.isEmpty {
                                Text("\(poseVM.personAnnotations.count) annotation\(poseVM.personAnnotations.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    
                    // Instruction hint
                    if status == .noPerson && count > 0 {
                        Text("Tap skeleton to select")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    } else if status == .badDetection {
                        Text("Add more annotations")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(status.color.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                
                Spacer()
            }
            .padding(12)
            
            Spacer()
        }
    }
}

