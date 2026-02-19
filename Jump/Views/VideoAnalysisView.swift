import SwiftUI
import AVFoundation
import UIKit

/// The primary workspace view for analyzing a jump session.
/// Manages mode switching: detection → person selection → bar marking → review/results.
///
/// Features:
/// - Pinch-to-zoom (up to 4x), pan, double-tap zoom toggle
/// - Mini-map thumbnail when zoomed
/// - Loupe magnifier during bar marking
/// - Tracking timeline with per-frame color coding
/// - Tracking confidence HUD
/// - Review flow for uncertain frames
struct VideoAnalysisView: View {
    let session: JumpSession
    @State private var sessionVM: SessionViewModel
    @State private var playerVM = VideoPlayerViewModel()

    // UI Mode
    @State private var isSelectingPerson = false
    @State private var isMarkingBar = false
    @State private var showBarHeightInput = false
    @State private var showResults = false
    @State private var isReviewTapMode = false

    // Zoom & Pan
    @State private var zoomState = ZoomState()
    @State private var videoContainerSize: CGSize = .zero

    // Bar Marking
    @State private var barMarkPoint1: CGPoint?
    @State private var barMarkPoint2: CGPoint?
    @State private var showBarConfirm = false

    // Loupe (for bar marking precision)
    @State private var loupeTouch: CGPoint?

    // Bar Height
    @State private var selectedUnit: HeightUnit = .meters
    @State private var barHeightText = ""
    @State private var feetText = ""
    @State private var inchesText = ""

    // Haptic feedback
    @State private var lastPhase: JumpPhase?

    // Export
    @State private var showShareSheet = false

    init(session: JumpSession) {
        self.session = session
        self._sessionVM = State(initialValue: SessionViewModel(session: session))
    }

    var body: some View {
        ZStack {
            Color.jumpBackgroundTop.ignoresSafeArea()

            VStack(spacing: 0) {
                // Video frame display
                videoFrameView
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.55)
                    .clipped()

                // Phase timeline (if phases available)
                if !sessionVM.phases.isEmpty {
                    PhaseTimelineView(
                        phases: sessionVM.phases,
                        currentFrame: playerVM.currentFrameIndex,
                        totalFrames: sessionVM.totalFrames,
                        onSeekToFrame: { frame in
                            Task { await playerVM.seekToFrame(frame) }
                        }
                    )
                    .frame(height: 32)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                // Tracking timeline (if assignments exist)
                if !sessionVM.assignments.isEmpty {
                    TrackingTimelineView(
                        assignments: sessionVM.assignments,
                        currentFrame: playerVM.currentFrameIndex,
                        totalFrames: sessionVM.totalFrames,
                        onSeekToFrame: { frame in
                            Task { await playerVM.seekToFrame(frame) }
                        }
                    )
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                // Scrubber
                FrameScrubberView(
                    currentFrame: $playerVM.currentFrameIndex,
                    totalFrames: playerVM.totalFrames,
                    onSeek: { frame in
                        Task { await playerVM.seekToFrame(frame) }
                    }
                )
                .frame(height: 56)
                .padding(.horizontal)
                .padding(.vertical, 4)

                // Frame info + playback controls
                frameInfoBar
                    .padding(.horizontal)

                // Control buttons
                controlBar
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Workflow hint
                workflowHint
                    .padding(.horizontal)
                    .padding(.top, 8)

                Spacer()
            }
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await playerVM.loadVideo(session: session)

            // Auto-start pose detection if not done
            if !session.poseDetectionComplete {
                await sessionVM.startPoseDetection()
            }
        }
        .overlay {
            if sessionVM.isDetecting {
                processingOverlay
            }
        }
        .overlay {
            if sessionVM.isReviewingFlaggedFrames {
                reviewBannerOverlay
            } else if isSelectingPerson {
                personSelectionBanner
            }
        }
        .overlay {
            if isMarkingBar {
                barMarkingBanner
            }
        }
        .sheet(isPresented: $showBarHeightInput) {
            barHeightInputSheet
        }
        .sheet(isPresented: $showResults) {
            if let result = sessionVM.analysisResult {
                ResultsPagingView(
                    result: result,
                    session: session,
                    allFramePoses: sessionVM.allFramePoses,
                    assignments: sessionVM.assignments,
                    onJumpToFrame: { frame in
                        showResults = false
                        Task { await playerVM.seekToFrame(frame) }
                    }
                )
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = sessionVM.exportedVideoURL {
                ShareSheetView(items: [url])
            }
        }
        .onChange(of: sessionVM.exportedVideoURL) { _, newURL in
            if newURL != nil {
                showShareSheet = true
            }
        }
        .alert("Error", isPresented: $sessionVM.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionVM.errorMessage ?? "An unknown error occurred.")
        }
        .onChange(of: playerVM.currentFrameIndex) { _, newFrame in
            // Haptic feedback on phase boundary crossing
            guard !sessionVM.phases.isEmpty,
                  !UIAccessibility.isReduceMotionEnabled else { return }
            let newPhase = sessionVM.phase(at: newFrame)
            if let newPhase, newPhase != lastPhase, lastPhase != nil {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            lastPhase = newPhase
        }
    }

    // MARK: - Video Frame View

    private var videoFrameView: some View {
        GeometryReader { geo in
            let containerSize = geo.size

            ZStack {
                Color.black

                if let image = playerVM.currentFrameImage {
                    // Image + overlays group — zoom/pan applied as a single transform
                    ZStack {
                        Image(decorative: image, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: containerSize.width, height: containerSize.height)

                        // Skeleton overlay
                        skeletonOverlay(in: containerSize)

                        // Bar marking overlay (crosshairs, connecting line)
                        if isMarkingBar {
                            barMarkingOverlay(in: containerSize)
                        }
                    }
                    .scaleEffect(zoomState.scale)
                    .offset(zoomState.offset)
                    .gesture(zoomAndPanGesture(in: containerSize))
                    .onTapGesture(count: 2) { location in
                        zoomState.toggleZoom(at: location, in: containerSize)
                    }
                    .onTapGesture { location in
                        let videoLocation = transformedLocation(location, in: containerSize)
                        handleTap(at: videoLocation, in: containerSize)
                    }

                    // Loupe magnifier (for bar marking precision)
                    if isMarkingBar, let touch = loupeTouch, let img = playerVM.currentFrameImage {
                        LoupeView(
                            image: img,
                            touchPoint: touch,
                            videoSize: fittedVideoSize(in: containerSize),
                            videoOffset: CGPoint(
                                x: fittedVideoOffset(in: containerSize).x,
                                y: fittedVideoOffset(in: containerSize).y
                            )
                        )
                    }

                    // Tracking confidence HUD (top-right)
                    if !sessionVM.assignments.isEmpty {
                        VStack {
                            HStack {
                                Spacer()
                                TrackingConfidenceHUD(
                                    assignment: sessionVM.assignment(at: playerVM.currentFrameIndex),
                                    personCount: sessionVM.personCount(at: playerVM.currentFrameIndex)
                                )
                                .padding(8)
                            }
                            Spacer()
                        }
                    }

                    // Mini-map (bottom-right, when zoomed)
                    if zoomState.isZoomed {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                MiniMapView(
                                    frameImage: image,
                                    zoomScale: zoomState.scale,
                                    panOffset: zoomState.offset,
                                    containerSize: containerSize
                                )
                                .padding(8)
                            }
                        }
                    }
                }
            }
            .onAppear { videoContainerSize = containerSize }
            .onChange(of: containerSize) { _, newSize in videoContainerSize = newSize }
        }
    }

    // MARK: - Zoom & Pan Gesture

    private func zoomAndPanGesture(in containerSize: CGSize) -> some Gesture {
        let pinch = MagnificationGesture()
            .onChanged { value in
                let newScale = zoomState.anchorScale * value
                zoomState.scale = min(max(newScale, ZoomState.minScale), ZoomState.maxScale)
            }
            .onEnded { _ in
                zoomState.anchorScale = zoomState.scale
                if zoomState.scale <= 1.01 {
                    zoomState.reset()
                } else {
                    zoomState.clampOffset(containerSize: containerSize)
                }
            }

        let pan = DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard zoomState.isZoomed else { return }
                zoomState.offset = CGSize(
                    width: zoomState.anchorOffset.width + value.translation.width,
                    height: zoomState.anchorOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                zoomState.clampOffset(containerSize: containerSize)
            }

        return pinch.simultaneously(with: pan)
    }

    /// Convert a screen-space tap point back to video-space coordinates,
    /// undoing the zoom/pan transform.
    private func transformedLocation(_ location: CGPoint, in containerSize: CGSize) -> CGPoint {
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        // Undo offset, then undo scale
        let x = (location.x - center.x - zoomState.offset.width) / zoomState.scale + center.x
        let y = (location.y - center.y - zoomState.offset.height) / zoomState.scale + center.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Skeleton Overlay

    @ViewBuilder
    private func skeletonOverlay(in containerSize: CGSize) -> some View {
        let videoSize = fittedVideoSize(in: containerSize)
        let videoOffset = fittedVideoOffset(in: containerSize)
        let allPoses = sessionVM.posesAtFrame(playerVM.currentFrameIndex)
        let athleteIndex = sessionVM.assignment(at: playerVM.currentFrameIndex)?.athletePoseIndex

        ZStack {
            // Draw all detected people (faded)
            ForEach(allPoses.indices, id: \.self) { index in
                let pose = allPoses[index]
                let isAthlete = index == athleteIndex
                SkeletonOverlayView(
                    pose: pose,
                    viewSize: videoSize,
                    offset: videoOffset,
                    color: isAthlete ? .athleteCyan : Color.personColor(at: index),
                    lineWidth: isAthlete ? 3.0 : 2.0,
                    opacity: isAthlete ? 1.0 : 0.4,
                    showJointDots: isAthlete,
                    forceVisible: isSelectingPerson
                )
            }

            // Athlete path overlay: approach trail (green), takeoff X (red), flight arc (magenta)
            if session.personSelectionComplete {
                athletePathOverlay(
                    currentFrame: playerVM.currentFrameIndex,
                    videoSize: videoSize,
                    videoOffset: videoOffset
                )
            }

            // Debug bounding box overlay: tracked box (yellow), pose box (cyan dashed), trajectory crosshair (orange)
            if sessionVM.showDebugBoundingBox {
                debugBoundingBoxOverlay(
                    frameIndex: playerVM.currentFrameIndex,
                    videoSize: videoSize,
                    videoOffset: videoOffset
                )
            }

            // Bar line overlay
            if let p1 = session.barEndpoint1, let p2 = session.barEndpoint2 {
                barLineOverlay(p1: p1, p2: p2, viewSize: videoSize, offset: videoOffset)
            }
        }
        .allowsHitTesting(false)
    }

    private func barLineOverlay(p1: CGPoint, p2: CGPoint, viewSize: CGSize, offset: CGPoint) -> some View {
        Canvas { context, size in
            let viewP1 = CoordinateConverter.normalizedToView(point: p1, viewSize: viewSize, offset: offset)
            let viewP2 = CoordinateConverter.normalizedToView(point: p2, viewSize: viewSize, offset: offset)

            var path = Path()
            path.move(to: viewP1)
            path.addLine(to: viewP2)

            context.stroke(
                path,
                with: .color(.barLine),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [8, 4])
            )

            for point in [viewP1, viewP2] {
                let dotRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dotRect), with: .color(.barLine))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Debug Bounding Box Overlay

    /// Debug overlay showing tracking state for the current frame.
    ///
    /// - **Yellow solid rect**: VNTrackObjectRequest tracked bounding box
    /// - **Cyan dashed rect**: Athlete pose bounding box (from joint positions)
    /// - **Orange crosshair**: Trajectory model prediction (where gravity says athlete should be)
    private func debugBoundingBoxOverlay(
        frameIndex: Int,
        videoSize: CGSize,
        videoOffset: CGPoint
    ) -> some View {
        Canvas { context, size in
            // Helper to convert a normalized rect to view coordinates
            func normalizedRectToView(_ rect: CGRect) -> CGRect {
                let topLeft = CoordinateConverter.normalizedToView(
                    point: CGPoint(x: rect.minX, y: rect.minY),
                    viewSize: videoSize,
                    offset: videoOffset
                )
                let bottomRight = CoordinateConverter.normalizedToView(
                    point: CGPoint(x: rect.maxX, y: rect.maxY),
                    viewSize: videoSize,
                    offset: videoOffset
                )
                return CGRect(
                    x: topLeft.x,
                    y: topLeft.y,
                    width: bottomRight.x - topLeft.x,
                    height: bottomRight.y - topLeft.y
                )
            }

            // 1. Yellow solid rect: VNTrackObjectRequest tracked box
            if frameIndex < sessionVM.allFrameTrackedBoxes.count,
               let trackedBox = sessionVM.allFrameTrackedBoxes[frameIndex] {
                let viewRect = normalizedRectToView(trackedBox)
                context.stroke(
                    Path(viewRect),
                    with: .color(.yellow.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 2.0)
                )
            }

            // 2. Cyan dashed rect: Athlete pose bounding box
            if let athletePose = sessionVM.athletePose(at: frameIndex),
               let poseBox = athletePose.boundingBox {
                let viewRect = normalizedRectToView(poseBox)
                context.stroke(
                    Path(viewRect),
                    with: .color(.cyan.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
                )
            }

            // 3. Orange crosshair: Trajectory prediction
            if let model = sessionVM.trajectoryModel {
                let predicted = model.predictCenter(at: frameIndex)
                let viewPoint = CoordinateConverter.normalizedToView(
                    point: predicted,
                    viewSize: videoSize,
                    offset: videoOffset
                )
                let crossSize: CGFloat = 10

                // Horizontal line
                var hPath = Path()
                hPath.move(to: CGPoint(x: viewPoint.x - crossSize, y: viewPoint.y))
                hPath.addLine(to: CGPoint(x: viewPoint.x + crossSize, y: viewPoint.y))
                context.stroke(hPath, with: .color(.orange), style: StrokeStyle(lineWidth: 2.0))

                // Vertical line
                var vPath = Path()
                vPath.move(to: CGPoint(x: viewPoint.x, y: viewPoint.y - crossSize))
                vPath.addLine(to: CGPoint(x: viewPoint.x, y: viewPoint.y + crossSize))
                context.stroke(vPath, with: .color(.orange), style: StrokeStyle(lineWidth: 2.0))

                // Small circle at center
                let dotRect = CGRect(x: viewPoint.x - 3, y: viewPoint.y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: dotRect), with: .color(.orange.opacity(0.6)))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Athlete Path Overlay

    /// Draw the athlete's approach path (green), takeoff X (red), and flight arc (magenta).
    ///
    /// Uses the cached path from SessionViewModel. Shows a progressive trail up to
    /// the current frame so the path builds up as you scrub through the video.
    private func athletePathOverlay(
        currentFrame: Int,
        videoSize: CGSize,
        videoOffset: CGPoint
    ) -> some View {
        let pathPoints = sessionVM.cachedAthletePath
        let takeoffFrame = sessionVM.cachedTakeoffFrame

        return Canvas { context, _ in
            guard !pathPoints.isEmpty else { return }

            // Helper to convert normalized point to view coordinates
            func toView(_ point: CGPoint) -> CGPoint {
                CoordinateConverter.normalizedToView(
                    point: point,
                    viewSize: videoSize,
                    offset: videoOffset
                )
            }

            // Filter to points up to current frame
            let visible = pathPoints.filter { $0.frameIndex <= currentFrame }
            guard !visible.isEmpty else { return }

            let ground = visible.filter { !$0.isAirborne }
            let airborne = visible.filter { $0.isAirborne }

            // --- Green approach path (foot contact) ---
            if ground.count >= 2 {
                var path = Path()
                var started = false
                for point in ground {
                    guard let foot = point.footContact else { continue }
                    let vp = toView(foot)
                    if !started {
                        path.move(to: vp)
                        started = true
                    } else {
                        path.addLine(to: vp)
                    }
                }
                if started {
                    context.stroke(path, with: .color(.green.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 2.5))
                }

                // Small dots
                for point in ground {
                    guard let foot = point.footContact else { continue }
                    let vp = toView(foot)
                    context.fill(Path(ellipseIn: CGRect(x: vp.x - 2, y: vp.y - 2, width: 4, height: 4)),
                                 with: .color(.green.opacity(0.5)))
                }
            }

            // --- Red X at takeoff ---
            if let tf = takeoffFrame, tf <= currentFrame {
                let takeoffPoint: CGPoint?
                if let lastGround = ground.last?.footContact {
                    takeoffPoint = lastGround
                } else if let firstAir = airborne.first?.centerOfMass {
                    takeoffPoint = firstAir
                } else {
                    takeoffPoint = nil
                }

                if let tp = takeoffPoint {
                    let vp = toView(tp)
                    let xSize: CGFloat = 10

                    var x1 = Path()
                    x1.move(to: CGPoint(x: vp.x - xSize, y: vp.y - xSize))
                    x1.addLine(to: CGPoint(x: vp.x + xSize, y: vp.y + xSize))
                    context.stroke(x1, with: .color(.red), style: StrokeStyle(lineWidth: 3.0))

                    var x2 = Path()
                    x2.move(to: CGPoint(x: vp.x + xSize, y: vp.y - xSize))
                    x2.addLine(to: CGPoint(x: vp.x - xSize, y: vp.y + xSize))
                    context.stroke(x2, with: .color(.red), style: StrokeStyle(lineWidth: 3.0))
                }
            }

            // --- Magenta flight arc (center of mass) ---
            if airborne.count >= 2 {
                var path = Path()
                var started = false
                for point in airborne {
                    guard let com = point.centerOfMass else { continue }
                    let vp = toView(com)
                    if !started {
                        path.move(to: vp)
                        started = true
                    } else {
                        path.addLine(to: vp)
                    }
                }
                if started {
                    context.stroke(path, with: .color(.purple.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 2.5))
                }

                // Dots at each COM point
                for point in airborne {
                    guard let com = point.centerOfMass else { continue }
                    let vp = toView(com)
                    context.fill(Path(ellipseIn: CGRect(x: vp.x - 3, y: vp.y - 3, width: 6, height: 6)),
                                 with: .color(.purple.opacity(0.6)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bar Marking Overlay

    @ViewBuilder
    private func barMarkingOverlay(in containerSize: CGSize) -> some View {
        ZStack {
            Canvas { context, _ in
                if let p1 = barMarkPoint1, let p2 = barMarkPoint2 {
                    var line = Path()
                    line.move(to: p1)
                    line.addLine(to: p2)
                    context.stroke(line, with: .color(.barLine.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 3]))
                }
            }
            .allowsHitTesting(false)

            if let p1 = barMarkPoint1 {
                crosshairView
                    .position(p1)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                barMarkPoint1 = value.location
                                loupeTouch = value.location
                            }
                            .onEnded { _ in loupeTouch = nil }
                    )
            }

            if let p2 = barMarkPoint2 {
                crosshairView
                    .position(p2)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                barMarkPoint2 = value.location
                                loupeTouch = value.location
                            }
                            .onEnded { _ in loupeTouch = nil }
                    )
            }
        }
    }

    private var crosshairView: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let arm: CGFloat = 20

            let circleRect = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
            context.stroke(Path(ellipseIn: circleRect), with: .color(.barLine.opacity(0.6)), lineWidth: 1)

            for (dx, dy) in [(arm, 0), (-arm, 0), (0, arm), (0, -arm)] as [(CGFloat, CGFloat)] {
                var line = Path()
                line.move(to: CGPoint(x: center.x + (dx > 0 ? 5 : dx < 0 ? -5 : 0),
                                       y: center.y + (dy > 0 ? 5 : dy < 0 ? -5 : 0)))
                line.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
                context.stroke(line, with: .color(.barLine.opacity(0.9)), lineWidth: 1)
            }
        }
        .frame(width: 50, height: 50)
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: sessionVM.detectionProgress) {
                    Text("Detecting poses...")
                        .font(.headline)
                        .foregroundStyle(.white)
                } currentValueLabel: {
                    // Frame counter
                    Text("\(sessionVM.detectedFrameCount) / \(sessionVM.totalFrameCount)")
                        .font(.system(.title2, design: .monospaced).bold())
                        .foregroundStyle(.jumpAccent)
                }
                .tint(.jumpAccent)
                .frame(width: 220)

                // ETA
                if let eta = sessionVM.estimatedTimeRemaining, eta > 1 {
                    Text("~\(Int(eta))s remaining")
                        .font(.caption)
                        .foregroundStyle(.jumpSubtle)
                }

                // Cancel button
                Button {
                    sessionVM.cancelDetection()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Capsule())
                }
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
                Image(systemName: "hand.tap")
                    .foregroundStyle(.athleteCyan)
                Text("Tap the athlete's skeleton to select")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)

                Spacer()

                if !sessionVM.assignments.isEmpty {
                    Button {
                        sessionVM.confirmPersonSelection()
                        isSelectingPerson = false
                    } label: {
                        Text("Confirm")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.green.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                Button {
                    isSelectingPerson = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Spacer()
        }
    }

    // MARK: - Review Banner

    private var reviewBannerOverlay: some View {
        VStack {
            ReviewBannerView(
                currentReviewFrame: sessionVM.currentReviewFrame ?? 0,
                totalReviewFrames: sessionVM.uncertainFrames.count,
                reviewProgress: sessionVM.reviewProgress,
                currentAssignment: sessionVM.assignment(at: sessionVM.currentReviewFrame ?? playerVM.currentFrameIndex),
                personCount: sessionVM.personCount(at: sessionVM.currentReviewFrame ?? playerVM.currentFrameIndex),
                onTapSkeleton: {
                    isReviewTapMode = true
                },
                onNoAthlete: {
                    guard let frame = sessionVM.currentReviewFrame else { return }
                    if let nextFrame = sessionVM.applyReviewCorrection(.noAthleteConfirmed, at: frame) {
                        Task { await playerVM.seekToFrame(nextFrame) }
                    }
                },
                onKeep: {
                    guard let frame = sessionVM.currentReviewFrame else { return }
                    // Keep the current assignment as-is — mark as confirmed
                    if let poseIndex = sessionVM.assignment(at: frame)?.athletePoseIndex {
                        if let nextFrame = sessionVM.applyReviewCorrection(.athleteConfirmed(poseIndex: poseIndex), at: frame) {
                            Task { await playerVM.seekToFrame(nextFrame) }
                        }
                    } else if let nextFrame = sessionVM.nextReviewFrame() {
                        Task { await playerVM.seekToFrame(nextFrame) }
                    }
                },
                onPrevious: {
                    if let frame = sessionVM.previousReviewFrame() {
                        Task { await playerVM.seekToFrame(frame) }
                    }
                },
                onNext: {
                    if let frame = sessionVM.nextReviewFrame() {
                        Task { await playerVM.seekToFrame(frame) }
                    }
                },
                onDone: {
                    sessionVM.finishReview()
                    isReviewTapMode = false
                }
            )

            Spacer()
        }
    }

    // MARK: - Bar Marking Banner

    private var barMarkingBanner: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "ruler")
                    .foregroundStyle(.barLine)
                Text(barMarkInstructionText)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)

                Spacer()

                if showBarConfirm {
                    Button { confirmBarMarking() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                    Button { cancelBarMarking() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        isMarkingBar = false
                        barMarkPoint1 = nil
                        barMarkPoint2 = nil
                        loupeTouch = nil
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
            return "Bar marked \u{2014} Confirm?"
        } else if barMarkPoint1 == nil {
            return "Tap left end of bar"
        } else {
            return "Now tap the right end"
        }
    }

    // MARK: - Frame Info Bar

    private var frameInfoBar: some View {
        HStack {
            Text("Frame \(playerVM.currentFrameIndex + 1)/\(playerVM.totalFrames)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.jumpSubtle)

            if let barHeight = session.barHeightMeters {
                Text(String(format: "Bar: %.2fm", barHeight))
                    .font(.caption2.bold())
                    .foregroundStyle(.barLine)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.barLine.opacity(0.15))
                    .clipShape(Capsule())
            }

            Spacer()

            // Playback controls
            HStack(spacing: 16) {
                Button { Task { await playerVM.stepBackward() } } label: {
                    Image(systemName: "backward.frame.fill")
                        .foregroundStyle(.jumpSubtle)
                }
                Button { playerVM.togglePlayback() } label: {
                    Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.jumpAccent)
                }
                Button { Task { await playerVM.stepForward() } } label: {
                    Image(systemName: "forward.frame.fill")
                        .foregroundStyle(.jumpSubtle)
                }

                // Speed selector
                Menu {
                    ForEach([1.0, 0.5, 0.25], id: \.self) { speed in
                        Button(speed == 1.0 ? "1x" : String(format: "%.2gx", speed)) {
                            playerVM.setPlaybackSpeed(speed)
                        }
                    }
                } label: {
                    Text(playerVM.playbackSpeed == 1.0 ? "1x" : String(format: "%.2gx", playerVM.playbackSpeed))
                        .font(.caption.bold())
                        .foregroundStyle(.jumpAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.jumpAccent.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .font(.title3)

            Spacer()

            Text(playerVM.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.jumpSubtle)
        }
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            // 1. Select person
            Button {
                if isSelectingPerson {
                    isSelectingPerson = false
                } else {
                    isSelectingPerson = true
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                    Text("Person")
                        .font(.caption2)
                }
                .frame(minWidth: 60)
            }
            .buttonStyle(.bordered)
            .tint(session.personSelectionComplete ? .green : (isSelectingPerson ? .athleteCyan : .jumpAccent))
            .disabled(sessionVM.isDetecting || isMarkingBar || sessionVM.allFramePoses.isEmpty)

            // 2. Mark bar
            Button {
                isMarkingBar = true
                barMarkPoint1 = nil
                barMarkPoint2 = nil
                showBarConfirm = false
                loupeTouch = nil
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "ruler")
                        .font(.title3)
                    Text("Bar")
                        .font(.caption2)
                }
                .frame(minWidth: 60)
            }
            .buttonStyle(.bordered)
            .tint(session.barMarkingComplete ? .green : .orange)
            .disabled(!session.personSelectionComplete || sessionVM.isDetecting || isMarkingBar || isSelectingPerson)

            // 3. Review (visible when uncertain frames exist)
            if !sessionVM.uncertainFrames.isEmpty {
                Button {
                    sessionVM.startReview()
                    if let frame = sessionVM.currentReviewFrame {
                        Task { await playerVM.seekToFrame(frame) }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "eye.trianglebadge.exclamationmark")
                            .font(.title3)
                        Text("Review")
                            .font(.caption2)
                    }
                    .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
                .tint(.trackingUncertain)
                .disabled(sessionVM.isDetecting || isMarkingBar || isSelectingPerson)
            }

            // 4. Analyze
            Button {
                sessionVM.runAnalysis()
                if sessionVM.analysisResult != nil {
                    showResults = true
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title3)
                    Text("Analyze")
                        .font(.caption2)
                }
                .frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(.jumpSecondary)
            .disabled(!session.canAnalyze || sessionVM.isDetecting || isSelectingPerson || isMarkingBar)

            // 5. Results (if already analyzed)
            if sessionVM.analysisResult != nil {
                Button {
                    showResults = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "chart.bar.fill")
                            .font(.title3)
                        Text("Results")
                            .font(.caption2)
                    }
                    .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }

            // 6. Export debug video
            if session.personSelectionComplete {
                Button {
                    Task { await sessionVM.exportDebugVideo() }
                } label: {
                    VStack(spacing: 2) {
                        if sessionVM.isExportingDebugVideo {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                        }
                        Text(sessionVM.isExportingDebugVideo ? "\(Int(sessionVM.exportProgress * 100))%" : "Export")
                            .font(.caption2)
                    }
                    .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(sessionVM.isExportingDebugVideo || sessionVM.isDetecting)
            }
        }
    }

    // MARK: - Workflow Hint

    @ViewBuilder
    private var workflowHint: some View {
        // Re-analysis banner (tracking or bar changed after analysis)
        if sessionVM.needsReanalysis && sessionVM.analysisResult != nil {
            HStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                    .foregroundStyle(.orange)
                Text("Settings changed — results are outdated.")
                    .font(.caption2)
                    .foregroundStyle(.jumpSubtle)
                Spacer()
                Button("Re-analyze") {
                    sessionVM.runAnalysis()
                    if sessionVM.analysisResult != nil {
                        showResults = true
                    }
                }
                .font(.caption2.bold())
                .foregroundStyle(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        // 30fps warning banner
        if session.frameRate < 60 && session.poseDetectionComplete {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Low frame rate (\(Int(session.frameRate))fps) \u{2014} measurements may be approximate. Record at 120fps+ for best results.")
                    .font(.caption2)
                    .foregroundStyle(.jumpSubtle)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if sessionVM.isDetecting {
            EmptyView()
        } else if !session.poseDetectionComplete {
            hintCard(icon: "exclamationmark.triangle", title: "Detection Failed",
                     detail: "Pose detection did not complete. Try re-importing the video.")
        } else if !session.personSelectionComplete && !isSelectingPerson {
            hintCard(icon: "person.crop.circle", title: "Step 1: Select Person",
                     detail: "Tap **Person** to identify the jumper. Scrub to a clear frame and tap their skeleton.")
        } else if session.personSelectionComplete && !session.barMarkingComplete && !isMarkingBar {
            hintCard(icon: "ruler", title: "Step 2: Mark Bar",
                     detail: "Tap **Bar** to mark the bar position. Tap each end of the bar for calibration.")
        } else if session.canAnalyze && !session.analysisComplete {
            if let summary = sessionVM.trackingSummaryText {
                hintCard(icon: "eye.trianglebadge.exclamationmark", title: "Tracking Issues",
                         detail: "\(summary). Tap **Review** to fix, or **Analyze** to proceed.")
            } else {
                hintCard(icon: "waveform.path.ecg", title: "Step 3: Analyze",
                         detail: "Tap **Analyze** to get technique feedback and measurements.")
            }
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
            handleBarMarkTap(at: location)
        } else if isSelectingPerson || isReviewTapMode {
            handlePersonSelectTap(at: location, in: containerSize)
        }
    }

    private func handlePersonSelectTap(at location: CGPoint, in containerSize: CGSize) {
        let videoSize = fittedVideoSize(in: containerSize)
        let videoOffset = fittedVideoOffset(in: containerSize)
        let normalizedPoint = CoordinateConverter.viewToNormalized(
            point: location,
            viewSize: videoSize,
            offset: videoOffset
        )

        // Find the closest pose at this frame
        let poses = sessionVM.posesAtFrame(playerVM.currentFrameIndex)
        guard !poses.isEmpty else { return }

        var bestIndex = 0
        var bestDistance = Double.infinity

        for (index, pose) in poses.enumerated() {
            guard let center = pose.centerOfMass else { continue }
            let dist = hypot(Double(normalizedPoint.x - center.x), Double(normalizedPoint.y - center.y))
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = index
            }
        }

        // Select the nearest person if within reasonable distance
        guard bestDistance < 0.15 else { return }

        if isReviewTapMode, sessionVM.isReviewingFlaggedFrames {
            // In review mode — apply correction and advance
            let correction = FrameAssignment.athleteConfirmed(poseIndex: bestIndex)
            if let nextFrame = sessionVM.applyReviewCorrection(correction, at: playerVM.currentFrameIndex) {
                Task { await playerVM.seekToFrame(nextFrame) }
            }
            isReviewTapMode = false
        } else {
            sessionVM.selectAthlete(poseIndex: bestIndex, at: playerVM.currentFrameIndex)
        }
    }

    private func handleBarMarkTap(at location: CGPoint) {
        if barMarkPoint1 == nil {
            barMarkPoint1 = location
        } else if barMarkPoint2 == nil {
            barMarkPoint2 = location
            showBarConfirm = true
        }
    }

    private func confirmBarMarking() {
        guard let p1 = barMarkPoint1, let p2 = barMarkPoint2 else { return }

        // Use the stored videoContainerSize instead of UIScreen.main.bounds
        let containerSize = videoContainerSize
        let videoSize = fittedVideoSize(in: containerSize)
        let videoOffset = fittedVideoOffset(in: containerSize)

        let normalP1 = CoordinateConverter.viewToNormalized(point: p1, viewSize: videoSize, offset: videoOffset)
        let normalP2 = CoordinateConverter.viewToNormalized(point: p2, viewSize: videoSize, offset: videoOffset)

        sessionVM.setBarEndpoints(normalP1, normalP2)

        isMarkingBar = false
        barMarkPoint1 = nil
        barMarkPoint2 = nil
        showBarConfirm = false
        loupeTouch = nil

        // Try to auto-parse bar height from video caption
        if let caption = session.videoCaption, let parsed = BarHeightParser.parseHeight(from: caption) {
            prefillBarHeight(parsed)
        }

        showBarHeightInput = true
    }

    private func cancelBarMarking() {
        barMarkPoint1 = nil
        barMarkPoint2 = nil
        showBarConfirm = false
        loupeTouch = nil
    }

    // MARK: - Bar Height Input

    private var barHeightInputSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Unit", selection: $selectedUnit) {
                    ForEach(HeightUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                switch selectedUnit {
                case .feetInches:
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Feet").font(.caption).foregroundStyle(.secondary)
                            TextField("6", text: $feetText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .font(.title2.monospacedDigit())
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inches").font(.caption).foregroundStyle(.secondary)
                            TextField("2", text: $inchesText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .font(.title2.monospacedDigit())
                        }
                    }
                case .meters:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Height in meters").font(.caption).foregroundStyle(.secondary)
                        TextField("1.85", text: $barHeightText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .font(.title2.monospacedDigit())
                    }
                case .centimeters:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Height in centimeters").font(.caption).foregroundStyle(.secondary)
                        TextField("185", text: $barHeightText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .font(.title2.monospacedDigit())
                    }
                }

                if let parsed = parsedBarHeight {
                    Text(String(format: "%.2fm", parsed))
                        .font(.headline)
                        .foregroundStyle(.jumpAccent)
                }

                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("Bar Height")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { showBarHeightInput = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        if let meters = parsedBarHeight {
                            sessionVM.setBarHeight(meters)
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

    private var parsedBarHeight: Double? {
        switch selectedUnit {
        case .feetInches:
            guard let feet = Double(feetText), let inches = Double(inchesText) else { return nil }
            guard feet >= 0, inches >= 0, inches < 12 else { return nil }
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

    private func prefillBarHeight(_ meters: Double) {
        selectedUnit = .meters
        barHeightText = String(format: "%.2f", meters)
        let totalInches = meters / 0.0254
        feetText = "\(Int(totalInches / 12))"
        inchesText = "\(Int(totalInches.truncatingRemainder(dividingBy: 12)))"
    }

    // MARK: - Layout Helpers

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
}

// MARK: - Height Unit

enum HeightUnit: String, CaseIterable {
    case feetInches = "Feet & Inches"
    case meters = "Meters"
    case centimeters = "Centimeters"
}
