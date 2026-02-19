import SwiftUI
import SwiftData

/// Manages a single JumpSession lifecycle:
/// pose detection → person selection → bar marking → analysis.
@Observable
@MainActor
final class SessionViewModel {
    // MARK: - Published State

    /// The active session (persisted via SwiftData).
    let session: JumpSession

    /// Current workflow step.
    enum WorkflowStep: Int, CaseIterable {
        case detecting = 0
        case personSelection = 1
        case barMarking = 2
        case review = 3
    }
    var currentStep: WorkflowStep = .detecting

    // Pose detection
    var isDetecting = false
    var detectionProgress: Double = 0
    var detectedFrameCount: Int = 0
    var totalFrameCount: Int = 0
    var estimatedTimeRemaining: TimeInterval?
    var allFramePoses: [[BodyPose]] = []   // allFramePoses[frameIndex] = [poses in that frame]
    var allFrameHumanRects: [[CGRect]] = [] // Vision human bounding boxes per frame (top-left origin)
    var allFrameTrackedBoxes: [CGRect?] = [] // VNTrackObjectRequest tracked boxes per frame (top-left origin)
    var trajectoryModel: TrajectoryValidator.TrajectoryModel?  // Physics-based trajectory for validation
    var showDebugBoundingBox: Bool = true  // Debug overlay for tracking visualization
    var isRecoveringPoses = false
    var isTrackingPoses = false
    private var detectionTask: Task<Void, Never>?
    private var processingStartTime: Date?

    // Person tracking
    var assignments: [Int: FrameAssignment] = [:]
    var isPersonSelected: Bool { session.personSelectionComplete }

    // Bar marking
    var barEndpoint1: CGPoint?
    var barEndpoint2: CGPoint?
    var isBarMarked: Bool { session.barMarkingComplete }

    // Analysis
    var analysisResult: AnalysisResult?
    var phases: [JumpPhase] = []
    var isAnalyzing = false
    var needsReanalysis = false

    // Review flow
    var isReviewingFlaggedFrames = false
    var currentReviewIndex = 0

    // Debug video export
    var isExportingDebugVideo = false
    var exportProgress: Double = 0
    var exportedVideoURL: URL?

    /// Athlete path data for debug video overlay (computed during export).
    struct AthletePathPoint {
        let frameIndex: Int
        let footContact: CGPoint?   // Average ankle position (normalized), for ground path
        let centerOfMass: CGPoint?  // Hip center (normalized), for flight trajectory
        let isAirborne: Bool        // True after takeoff detected
    }

    // Athlete path for live overlay (computed once after person selection, cached)
    private(set) var cachedAthletePath: [AthletePathPoint] = []
    private(set) var cachedTakeoffFrame: Int?

    /// Recompute and cache the athlete path. Call after assignments change.
    func refreshAthletePath() {
        let (points, takeoff) = computeAthletePath()
        cachedAthletePath = points
        cachedTakeoffFrame = takeoff
    }

    // Error
    var errorMessage: String?
    var showError = false

    // MARK: - Services

    private let blazePoseService = BlazePoseService()
    private let personTracker = PersonTracker()
    private let phaseClassifier = PhaseClassifier()

    // MARK: - Init

    init(session: JumpSession) {
        self.session = session

        // Restore workflow step from session state
        if session.analysisComplete {
            currentStep = .review
        } else if session.barMarkingComplete {
            currentStep = .review
        } else if session.personSelectionComplete {
            currentStep = .barMarking
        } else if session.poseDetectionComplete {
            currentStep = .personSelection
        }
    }

    // MARK: - Pose Detection

    func startPoseDetection() async {
        guard let videoURL = session.videoURL else {
            errorMessage = "Video file is not available."
            showError = true
            return
        }

        // Check if BlazePose service is ready
        guard blazePoseService.isReady else {
            errorMessage = "Pose detection model not found. Ensure 'pose_landmarker_heavy.task' is included in your app bundle."
            showError = true
            return
        }

        isDetecting = true
        detectionProgress = 0
        detectedFrameCount = 0
        totalFrameCount = session.totalFrames
        estimatedTimeRemaining = nil
        processingStartTime = Date()
        currentStep = .detecting

        do {
            let results = try await blazePoseService.processVideo(
                url: videoURL,
                trimRange: session.trimRange
            ) { [weak self] processed, total in
                Task { @MainActor in
                    guard let self else { return }
                    self.detectedFrameCount = processed
                    self.totalFrameCount = total
                    self.detectionProgress = Double(processed) / Double(max(total, 1))

                    // Compute ETA
                    if processed > 10, let startTime = self.processingStartTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let perFrame = elapsed / Double(processed)
                        let remaining = Double(total - processed) * perFrame
                        self.estimatedTimeRemaining = remaining
                    }
                }
            }

            allFramePoses = results.allFramePoses
            allFrameHumanRects = results.allFrameHumanRects
            session.poseDetectionComplete = true

            // Auto-select if only one person detected in entire video (spec §4 line 363)
            let maxPersons = allFramePoses.map { $0.count }.max() ?? 0
            if maxPersons <= 1 {
                if let anchorFrame = allFramePoses.firstIndex(where: { !$0.isEmpty }) {
                    selectAthlete(poseIndex: 0, at: anchorFrame)
                    confirmPersonSelection()
                }
            } else {
                currentStep = .personSelection
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = "Pose detection failed: \(error.localizedDescription)"
                showError = true
            }
        }

        isDetecting = false
        estimatedTimeRemaining = nil
    }

    /// Cancel an in-progress pose detection.
    func cancelDetection() {
        detectionTask?.cancel()
        detectionTask = nil
        isDetecting = false
        estimatedTimeRemaining = nil
    }

    // MARK: - Person Selection

    /// Select an athlete by tapping a pose at a specific frame.
    func selectAthlete(poseIndex: Int, at frameIndex: Int) {
        guard !allFramePoses.isEmpty else { return }

        session.anchorFrameIndex = frameIndex

        // Propagate tracking bidirectionally from anchor
        assignments = personTracker.propagate(
            from: frameIndex,
            anchorPoseIndex: poseIndex,
            allFramePoses: allFramePoses,
            humanRects: allFrameHumanRects.isEmpty ? nil : allFrameHumanRects
        )
    }

    /// Confirm the person selection and advance to bar marking.
    func confirmPersonSelection() {
        Task { @MainActor in
            // 1. Run visual tracking pass: VNTrackObjectRequest propagates a bounding box
            //    from the selected athlete bidirectionally through the video, with inline
            //    drift detection to stop tracking when it starts drifting to spectators.
            await runVisionTrackingPass()
            // 2. Validate tracked boxes against physics-based parabolic trajectory.
            //    Rejects boxes that deviate from where gravity says the athlete should be.
            validateAndRefineTrackedBoxes()
            // 3. Recover missing poses using validated tracked boxes, trajectory predictions,
            //    Apple VNDetectHumanBodyPoseRequest fallback, and human rects.
            await recoverMissingPoses()
            // 4. Fill any remaining short gaps with interpolated poses
            interpolateMissingPoses()
            // 5. Apply smoothing to reduce jitter (works on recovered + interpolated + real poses)
            applySmoothingToAthletePoses()
            // 6. Compute athlete path trail for overlay
            refreshAthletePath()
            session.personSelectionComplete = true
            currentStep = .barMarking
        }
    }

    /// Re-propagate from a user correction at a specific frame.
    func correctAssignment(_ correction: FrameAssignment, at frameIndex: Int) {
        assignments = personTracker.rePropagate(
            correction: correction,
            at: frameIndex,
            allFramePoses: allFramePoses,
            existingAssignments: assignments
        )
        if session.analysisComplete { needsReanalysis = true }
    }

    /// Get the athlete's BodyPose for a specific frame (nil if no athlete assigned).
    func athletePose(at frameIndex: Int) -> BodyPose? {
        guard let assignment = assignments[frameIndex],
              let poseIndex = assignment.athletePoseIndex,
              frameIndex < allFramePoses.count,
              poseIndex < allFramePoses[frameIndex].count else { return nil }
        return allFramePoses[frameIndex][poseIndex]
    }

    /// Frames that need user review (uncertain tracking).
    var uncertainFrames: [Int] {
        assignments.compactMap { frame, assignment in
            assignment.needsReview ? frame : nil
        }.sorted()
    }

    // MARK: - Bar Marking

    func setBarEndpoints(_ p1: CGPoint, _ p2: CGPoint) {
        barEndpoint1 = p1
        barEndpoint2 = p2
        session.setBarEndpoints(p1, p2)
        if session.analysisComplete { needsReanalysis = true }
    }

    func setBarHeight(_ meters: Double) {
        session.barHeightMeters = meters
        session.barMarkingComplete = true
        if session.analysisComplete { needsReanalysis = true }

        if session.personSelectionComplete {
            currentStep = .review
        }
    }

    /// Set the ground Y from auto-detection.
    func setGroundY(_ y: Double) {
        session.groundY = y
    }

    // MARK: - Analysis

    func runAnalysis() {
        guard session.canAnalyze else {
            errorMessage = "Complete all steps before analyzing."
            showError = true
            return
        }

        isAnalyzing = true

        // Fill any remaining detection gaps before analysis
        interpolateMissingPoses()

        // Build the athlete poses array (one per frame, nil if no athlete)
        var athletePoses: [BodyPose?] = []
        for frameIndex in 0..<allFramePoses.count {
            athletePoses.append(athletePose(at: frameIndex))
        }

        // Classify phases
        phases = phaseClassifier.classify(
            athletePoses: athletePoses,
            frameRate: session.frameRate
        )

        // Detect key frames (used internally by AnalysisEngine)
        _ = phaseClassifier.detectKeyFrames(
            poses: athletePoses,
            frameRate: session.frameRate
        )

        // Build calibration
        guard let p1 = session.barEndpoint1,
              let p2 = session.barEndpoint2,
              let barHeight = session.barHeightMeters else {
            isAnalyzing = false
            return
        }

        // Estimate ground Y if not set
        if session.groundY == nil {
            let approachPoses = athletePoses.compactMap { $0 }
            if let groundY = ScaleCalibrator.estimateGroundY(from: approachPoses) {
                session.groundY = groundY
            }
        }

        let groundY = session.groundY ?? 0.95

        let calibration = ScaleCalibrator.calibrate(
            barEndpoint1: p1,
            barEndpoint2: p2,
            barHeightMeters: barHeight,
            groundY: groundY
        )

        // Run analysis
        let analysisEngine = AnalysisEngine()
        let sexSetting = AthleteSex(rawValue: UserDefaults.standard.string(forKey: AppSettingsKey.athleteSex) ?? "") ?? .notSpecified
        let sex = sexSetting.comSex
        let result = analysisEngine.analyze(
            session: session,
            allFramePoses: allFramePoses,
            assignments: assignments,
            phases: phases,
            calibration: calibration,
            sex: sex
        )

        analysisResult = result

        // Store summary on session for list display
        session.takeoffAngle = result.measurements.takeoffAngle
        session.peakClearance = result.measurements.clearanceOverBar
        session.jumpCleared = result.measurements.jumpSuccess
        session.barKnockBodyPart = result.measurements.barKnockBodyPart
        session.analysisComplete = true
        currentStep = .review
        needsReanalysis = false

        isAnalyzing = false
    }

    // MARK: - Review Flow

    /// The current frame being reviewed (nil if not reviewing or no frames to review).
    var currentReviewFrame: Int? {
        let frames = uncertainFrames
        guard isReviewingFlaggedFrames,
              currentReviewIndex >= 0,
              currentReviewIndex < frames.count else { return nil }
        return frames[currentReviewIndex]
    }

    /// Human-readable progress text for review banner.
    var reviewProgress: String {
        let frames = uncertainFrames
        guard !frames.isEmpty else { return "No frames to review" }
        return "Frame \(currentReviewIndex + 1) of \(frames.count)"
    }

    /// Summary text for the workflow hint area.
    var trackingSummaryText: String? {
        let count = uncertainFrames.count
        guard count > 0 else { return nil }
        return "\(count) frame\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") review"
    }

    /// Start reviewing flagged frames from the beginning.
    func startReview() {
        guard !uncertainFrames.isEmpty else { return }
        isReviewingFlaggedFrames = true
        currentReviewIndex = 0
    }

    /// Move to the next flagged frame. Returns the frame index to seek to, or nil if done.
    @discardableResult
    func nextReviewFrame() -> Int? {
        let frames = uncertainFrames
        currentReviewIndex += 1
        if currentReviewIndex >= frames.count {
            // Recalculate — some may have been resolved
            let updatedFrames = uncertainFrames
            if updatedFrames.isEmpty {
                finishReview()
                return nil
            }
            currentReviewIndex = 0
        }
        return currentReviewFrame
    }

    /// Move to the previous flagged frame. Returns the frame index.
    @discardableResult
    func previousReviewFrame() -> Int? {
        let frames = uncertainFrames
        guard !frames.isEmpty else { return nil }
        currentReviewIndex = max(currentReviewIndex - 1, 0)
        return currentReviewFrame
    }

    /// Apply a correction during review and auto-advance.
    /// Returns the next frame to seek to.
    @discardableResult
    func applyReviewCorrection(_ correction: FrameAssignment, at frameIndex: Int) -> Int? {
        correctAssignment(correction, at: frameIndex)
        return nextReviewFrame()
    }

    /// End the review flow.
    func finishReview() {
        isReviewingFlaggedFrames = false
        currentReviewIndex = 0
    }

    // MARK: - Helpers

    /// Total frames in the video.
    var totalFrames: Int {
        session.totalFrames
    }

    /// Frame rate of the video.
    var frameRate: Double {
        session.frameRate
    }

    /// All poses detected at a given frame (all people).
    func posesAtFrame(_ frameIndex: Int) -> [BodyPose] {
        guard frameIndex < allFramePoses.count else { return [] }
        return allFramePoses[frameIndex]
    }

    /// Number of people detected at a given frame.
    func personCount(at frameIndex: Int) -> Int {
        posesAtFrame(frameIndex).count
    }

    /// The phase at a given frame.
    func phase(at frameIndex: Int) -> JumpPhase? {
        guard frameIndex < phases.count else { return nil }
        return phases[frameIndex]
    }

    /// The tracking assignment at a given frame.
    func assignment(at frameIndex: Int) -> FrameAssignment? {
        assignments[frameIndex]
    }

    // MARK: - Pose Smoothing

    /// Apply a 3-frame moving average to the athlete's assigned poses.
    /// Smooths joint positions using adjacent frames to reduce jitter.
    func applySmoothingToAthletePoses() {
        guard allFramePoses.count >= 3 else { return }

        for frameIndex in 1..<(allFramePoses.count - 1) {
            guard let assignment = assignments[frameIndex],
                  let poseIndex = assignment.athletePoseIndex,
                  poseIndex < allFramePoses[frameIndex].count else { continue }

            // Get athlete poses from prev, current, next frames
            let prevPose = athletePose(at: frameIndex - 1)
            let currPose = allFramePoses[frameIndex][poseIndex]
            let nextPose = athletePose(at: frameIndex + 1)

            guard let prev = prevPose, let next = nextPose else { continue }

            // Average each joint's position
            var smoothedJoints: [BodyPose.JointName: BodyPose.JointPosition] = [:]
            for (jointName, currJoint) in currPose.joints {
                guard let prevJoint = prev.joints[jointName],
                      let nextJoint = next.joints[jointName] else {
                    smoothedJoints[jointName] = currJoint
                    continue
                }

                // Only smooth if all 3 frames have reasonable confidence
                guard prevJoint.confidence > 0.2,
                      currJoint.confidence > 0.2,
                      nextJoint.confidence > 0.2 else {
                    smoothedJoints[jointName] = currJoint
                    continue
                }

                let avgX = (prevJoint.point.x + currJoint.point.x + nextJoint.point.x) / 3.0
                let avgY = (prevJoint.point.y + currJoint.point.y + nextJoint.point.y) / 3.0
                let avgConf = (prevJoint.confidence + currJoint.confidence + nextJoint.confidence) / 3.0

                smoothedJoints[jointName] = BodyPose.JointPosition(
                    point: CGPoint(x: avgX, y: avgY),
                    confidence: avgConf
                )
            }

            let smoothedPose = BodyPose(
                frameIndex: currPose.frameIndex,
                timestamp: currPose.timestamp,
                joints: smoothedJoints
            )
            allFramePoses[frameIndex][poseIndex] = smoothedPose
        }
    }

    // MARK: - Vision Tracking Pass

    /// Run VNTrackObjectRequest bidirectionally from the selected athlete's anchor frame.
    ///
    /// Seeds the tracker with the athlete's bounding box at the anchor frame, then
    /// propagates forward and backward through the video. VNTrackObjectRequest tracks
    /// visual appearance (texture/color), NOT body shape — so it maintains a bounding box
    /// even through frames where both BlazePose and VNDetectHumanRectanglesRequest fail.
    func runVisionTrackingPass() async {
        guard let videoURL = session.videoURL,
              let anchorFrame = session.anchorFrameIndex,
              let anchorAssignment = assignments[anchorFrame],
              let anchorPoseIndex = anchorAssignment.athletePoseIndex,
              anchorFrame < allFramePoses.count,
              anchorPoseIndex < allFramePoses[anchorFrame].count else { return }

        let anchorPose = allFramePoses[anchorFrame][anchorPoseIndex]
        guard let seedBox = anchorPose.boundingBox else { return }

        isTrackingPoses = true
        defer { isTrackingPoses = false }

        // Expand seed box by 10% padding for better tracking
        let paddingX = seedBox.width * 0.1
        let paddingY = seedBox.height * 0.1
        let expandedSeed = CGRect(
            x: max(0, seedBox.origin.x - paddingX),
            y: max(0, seedBox.origin.y - paddingY),
            width: min(seedBox.width + paddingX * 2, 1.0 - max(0, seedBox.origin.x - paddingX)),
            height: min(seedBox.height + paddingY * 2, 1.0 - max(0, seedBox.origin.y - paddingY))
        )

        let trackingService = VisionTrackingService()
        trackingService.minTrackingConfidence = 0.15  // Low threshold — even weak tracking is useful

        do {
            let trackedBoxes = try await trackingService.runTrackingPass(
                url: videoURL,
                seedBox: expandedSeed,
                seedFrameIndex: anchorFrame,
                frameRate: session.frameRate,
                trimRange: session.trimRange,
                humanRects: allFrameHumanRects
            )

            // Store results
            var boxes = [CGRect?](repeating: nil, count: allFramePoses.count)
            for (frameIndex, box) in trackedBoxes {
                if frameIndex < boxes.count {
                    boxes[frameIndex] = box
                }
            }
            allFrameTrackedBoxes = boxes

            print("[Tracking] Visual tracking pass complete: \(trackedBoxes.count)/\(allFramePoses.count) frames tracked")
        } catch {
            print("[Tracking] Tracking pass failed: \(error)")
        }
    }

    // MARK: - Trajectory Validation

    /// Validate tracked bounding boxes against a physics-based parabolic trajectory.
    ///
    /// Builds anchor points from frames where both PersonTracker and VNTrackObjectRequest agree,
    /// fits a parabolic model (X linear, Y quadratic from gravity), and rejects tracked boxes
    /// that deviate from the expected trajectory — catching drift to spectators.
    func validateAndRefineTrackedBoxes() {
        guard !allFrameTrackedBoxes.isEmpty else { return }

        // Build anchor points ONLY from high-confidence assignments.
        // Filter out low-confidence auto-assignments to avoid polluting the trajectory
        // with spectator positions (e.g., frames where the athlete hasn't entered the scene yet).
        var anchors: [TrajectoryValidator.AnchorPoint] = []

        // Get the user-confirmed anchor frame as our reference point
        let userAnchorFrame = session.anchorFrameIndex ?? 0

        for frameIndex in 0..<allFramePoses.count {
            guard let assignment = assignments[frameIndex],
                  assignment.hasAthlete,
                  let poseIndex = assignment.athletePoseIndex,
                  poseIndex < allFramePoses[frameIndex].count else { continue }

            // Only use high-confidence frames for trajectory building:
            // - User-confirmed frames (always trusted)
            // - Auto-assigned frames with confidence >= 0.55
            //   (low-confidence auto-assignments are likely spectators)
            let isUserConfirmed = assignment.isUserConfirmed
            let isHighConfidence: Bool
            switch assignment {
            case .athleteAuto(_, let conf):
                isHighConfidence = conf >= 0.55
            case .athleteUncertain:
                isHighConfidence = false  // Never use uncertain frames
            default:
                isHighConfidence = true
            }

            guard isUserConfirmed || isHighConfidence else { continue }

            // Use the pose's center of mass (more reliable than tracked box center for anchoring)
            let pose = allFramePoses[frameIndex][poseIndex]
            if let com = pose.centerOfMass {
                anchors.append(TrajectoryValidator.AnchorPoint(
                    frameIndex: frameIndex,
                    center: com
                ))
            }
        }

        print("[Trajectory] Building from \(anchors.count) high-confidence anchors (user anchor frame: \(userAnchorFrame))")

        // Fit trajectory
        guard let model = TrajectoryValidator.fitTrajectory(anchors: anchors) else {
            print("[Trajectory] Could not fit trajectory (anchors: \(anchors.count))")
            return
        }

        trajectoryModel = model
        print("[Trajectory] Fitted trajectory from \(model.anchorCount) anchors, R²=\(String(format: "%.3f", model.rSquared))")

        // Build tracked boxes dict for validation
        var trackedBoxesDict: [Int: CGRect] = [:]
        for (frameIndex, box) in allFrameTrackedBoxes.enumerated() {
            if let box = box {
                trackedBoxesDict[frameIndex] = box
            }
        }

        // Validate and reject drifted boxes
        let (_, rejected) = TrajectoryValidator.validateTrackedBoxes(
            trackedBoxes: trackedBoxesDict,
            model: model
        )

        // Null out rejected boxes
        for frameIndex in rejected {
            if frameIndex < allFrameTrackedBoxes.count {
                allFrameTrackedBoxes[frameIndex] = nil
            }
        }

        print("[Trajectory] Rejected \(rejected.count)/\(trackedBoxesDict.count) tracked boxes as drifted")
    }

    // MARK: - Pose Recovery (Vision Crop-and-Redetect)

    /// Recover missing athlete poses using multiple fallback strategies.
    ///
    /// For each frame where the athlete is missing, tries recovery with priority:
    /// 1. **Validated tracked box** from VNTrackObjectRequest (drifted boxes already removed)
    /// 2. **Trajectory-predicted search region** (physics-based, from parabolic model)
    /// 3. **Apple VNDetectHumanBodyPoseRequest** on full frame (different model, may detect arch)
    /// 4. **Nearest human rect** from VNDetectHumanRectanglesRequest (0.35 threshold)
    /// 5. Skip (interpolation handles remaining gaps ≤15 frames)
    func recoverMissingPoses() async {
        guard let videoURL = session.videoURL else { return }

        isRecoveringPoses = true
        defer { isRecoveringPoses = false }

        // Compute typical athlete bounding box size from known poses (for trajectory prediction sizing)
        let typicalBoxSize = computeTypicalAthleteBoxSize()

        // Phase 1: Identify frames needing recovery and assign crop region source
        enum RecoverySource {
            case trackedBox(CGRect)
            case trajectoryPrediction(CGRect)
            case humanRect(CGRect)
        }

        var framesToRecover: [(frameIndex: Int, source: RecoverySource)] = []
        var framesNeedingApplePose: [Int] = []  // Frames with no crop region — try Apple pose later

        for frameIndex in 0..<allFramePoses.count {
            guard let assignment = assignments[frameIndex],
                  assignment == .noAthleteAuto || assignment == .unreviewedGap else { continue }

            // Priority 1: Validated tracked box (drifted ones already nulled by validateAndRefineTrackedBoxes)
            if frameIndex < allFrameTrackedBoxes.count,
               let trackedBox = allFrameTrackedBoxes[frameIndex] {
                framesToRecover.append((frameIndex, .trackedBox(trackedBox)))
                continue
            }

            // Priority 1.5: Trajectory-predicted search region
            if let model = trajectoryModel {
                let searchRegion = TrajectoryValidator.predictSearchRegion(
                    model: model,
                    at: frameIndex,
                    typicalBoxSize: typicalBoxSize
                )
                framesToRecover.append((frameIndex, .trajectoryPrediction(searchRegion)))
                continue
            }

            // Priority 3: Nearest human rect with relaxed threshold (0.35)
            if frameIndex < allFrameHumanRects.count,
               !allFrameHumanRects[frameIndex].isEmpty {
                let predicted = predictAthletePosition(at: frameIndex)
                if let predicted = predicted {
                    let rects = allFrameHumanRects[frameIndex]
                    var bestRect: CGRect?
                    var bestDistance: CGFloat = .infinity

                    for rect in rects {
                        let center = CGPoint(x: rect.midX, y: rect.midY)
                        let distance = hypot(center.x - predicted.x, center.y - predicted.y)
                        if distance < bestDistance {
                            bestDistance = distance
                            bestRect = rect
                        }
                    }

                    if let rect = bestRect, bestDistance < 0.35 {
                        framesToRecover.append((frameIndex, .humanRect(rect)))
                        continue
                    }
                }
            }

            // No crop region available — will try Apple body pose on full frame
            framesNeedingApplePose.append(frameIndex)
        }

        let totalAttempts = framesToRecover.count + framesNeedingApplePose.count
        guard totalAttempts > 0 else { return }

        print("[Recovery] Attempting to recover \(framesToRecover.count) frames via crop-and-redetect + \(framesNeedingApplePose.count) via Apple body pose")

        let frameRate = session.frameRate
        var recoveredCount = 0

        // Phase 2: Crop-and-redetect using BlazePose IMAGE mode
        for item in framesToRecover {
            do {
                let pixelBuffer = try await VideoFrameExtractor.extractPixelBuffer(
                    from: videoURL,
                    frameIndex: item.frameIndex,
                    frameRate: frameRate,
                    trimStartOffset: session.trimRange?.lowerBound ?? 0
                )

                let cropRegion: CGRect
                switch item.source {
                case .trackedBox(let box): cropRegion = box
                case .trajectoryPrediction(let region): cropRegion = region
                case .humanRect(let rect): cropRegion = rect
                }

                let timestamp = Double(item.frameIndex) / frameRate
                if let recoveredPose = try blazePoseService.redetectInRegion(
                    pixelBuffer: pixelBuffer,
                    region: cropRegion,
                    frameIndex: item.frameIndex,
                    timestamp: timestamp
                ) {
                    insertRecoveredPose(recoveredPose, at: item.frameIndex, confidence: 0.6)
                    recoveredCount += 1
                } else {
                    // BlazePose crop-redetect failed — escalate to Apple pose + human rect phases
                    framesNeedingApplePose.append(item.frameIndex)
                }
            } catch {
                print("[Recovery] Frame \(item.frameIndex) crop-redetect failed: \(error)")
            }
        }

        // Phase 3: Apple VNDetectHumanBodyPoseRequest + fresh VNDetectHumanRectanglesRequest fallback
        //
        // For remaining unrecovered frames, try:
        // (a) Apple body pose detection (different model from BlazePose, may detect different orientations)
        // (b) Fresh VNDetectHumanRectanglesRequest (detects person silhouettes, not joint configs)
        //     constrained by trajectory prediction — even without joints, knowing WHERE the athlete is
        //     lets us store a bounding box for the debug overlay and improves interpolation.
        if !framesNeedingApplePose.isEmpty {
            let visionService = VisionTrackingService()
            var applePoseRecovered = 0
            var humanRectRecovered = 0
            var framesStillMissing: [Int] = []

            for frameIndex in framesNeedingApplePose {
                // Skip if already recovered in phase 2
                if let assignment = assignments[frameIndex], assignment.hasAthlete { continue }

                do {
                    let pixelBuffer = try await VideoFrameExtractor.extractPixelBuffer(
                        from: videoURL,
                        frameIndex: frameIndex,
                        frameRate: frameRate,
                        trimStartOffset: session.trimRange?.lowerBound ?? 0
                    )

                    let timestamp = Double(frameIndex) / frameRate

                    // Try (a): Apple body pose
                    let applePoses = try visionService.detectBodyPoses(
                        in: pixelBuffer,
                        frameIndex: frameIndex,
                        timestamp: timestamp
                    )

                    if let bestPose = pickBestApplePose(applePoses, at: frameIndex) {
                        insertRecoveredPose(bestPose, at: frameIndex, confidence: 0.5)
                        applePoseRecovered += 1
                        recoveredCount += 1
                        continue
                    }

                    // Try (b): Fresh VNDetectHumanRectanglesRequest + trajectory constraint
                    // This is the KEY fallback for arch-phase frames: person detectors can still find
                    // the athlete's silhouette even when joint detectors fail. We use the trajectory
                    // prediction to select the correct person bounding box.
                    let freshHumanRects = try visionService.detectHumans(in: pixelBuffer)

                    if !freshHumanRects.isEmpty {
                        // Get predicted center from trajectory model (best) or velocity prediction (fallback)
                        let expectedCenter: CGPoint?
                        if let model = trajectoryModel {
                            expectedCenter = model.predictCenter(at: frameIndex)
                        } else {
                            expectedCenter = predictAthletePosition(at: frameIndex)
                        }

                        if let expected = expectedCenter {
                            var bestRect: CGRect?
                            var bestDistance: CGFloat = .infinity

                            for rect in freshHumanRects {
                                let center = CGPoint(x: rect.midX, y: rect.midY)
                                let distance = hypot(center.x - expected.x, center.y - expected.y)
                                if distance < bestDistance {
                                    bestDistance = distance
                                    bestRect = rect
                                }
                            }

                            // Use trajectory-constrained threshold: tighter when trajectory model exists
                            let maxDistance: CGFloat = trajectoryModel != nil ? 0.15 : 0.25

                            if let rect = bestRect, bestDistance < maxDistance {
                                // We found the person's bounding box but couldn't detect joints.
                                // Store the bounding box for debug overlay and create a minimal
                                // placeholder pose from the rect center (for interpolation bridging).
                                if frameIndex < allFrameTrackedBoxes.count {
                                    allFrameTrackedBoxes[frameIndex] = rect
                                }

                                // Create a minimal pose with just the center point
                                // This helps interpolation bridge across this frame
                                let centerPose = BodyPose(
                                    frameIndex: frameIndex,
                                    timestamp: timestamp,
                                    joints: [
                                        .root: BodyPose.JointPosition(
                                            point: CGPoint(x: rect.midX, y: rect.midY),
                                            confidence: 0.3
                                        )
                                    ]
                                )
                                insertRecoveredPose(centerPose, at: frameIndex, confidence: 0.35)
                                humanRectRecovered += 1
                                recoveredCount += 1
                                continue
                            }
                        }
                    }

                    framesStillMissing.append(frameIndex)
                } catch {
                    print("[Recovery] Frame \(frameIndex) Apple pose + human rect failed: \(error)")
                    framesStillMissing.append(frameIndex)
                }
            }

            if applePoseRecovered > 0 {
                print("[Recovery] Apple VNDetectHumanBodyPoseRequest recovered \(applePoseRecovered) frames")
            }
            if humanRectRecovered > 0 {
                print("[Recovery] Trajectory-constrained human rect recovered \(humanRectRecovered) frames (bounding box only, joints interpolated)")
            }
            if !framesStillMissing.isEmpty {
                print("[Recovery] \(framesStillMissing.count) frames still missing — will be handled by interpolation")
            }
        }

        print("[Recovery] Total recovered: \(recoveredCount)/\(totalAttempts) frames")
    }

    /// Insert a recovered pose into allFramePoses and update assignments.
    private func insertRecoveredPose(_ pose: BodyPose, at frameIndex: Int, confidence: Float) {
        if allFramePoses[frameIndex].isEmpty {
            allFramePoses[frameIndex] = [pose]
            assignments[frameIndex] = .athleteAuto(poseIndex: 0, confidence: confidence)
        } else {
            let newIndex = allFramePoses[frameIndex].count
            allFramePoses[frameIndex].append(pose)
            assignments[frameIndex] = .athleteAuto(poseIndex: newIndex, confidence: confidence)
        }
    }

    /// Pick the best Apple Vision body pose that matches the expected athlete position.
    ///
    /// Uses trajectory model prediction (preferred) or predictAthletePosition() as fallback.
    private func pickBestApplePose(_ poses: [BodyPose], at frameIndex: Int) -> BodyPose? {
        guard !poses.isEmpty else { return nil }
        if poses.count == 1 { return poses[0] }

        // Get expected position from trajectory model or velocity prediction
        let expectedCenter: CGPoint?
        if let model = trajectoryModel {
            expectedCenter = model.predictCenter(at: frameIndex)
        } else {
            expectedCenter = predictAthletePosition(at: frameIndex)
        }

        guard let expected = expectedCenter else { return poses.first }

        // Pick the pose with center of mass closest to expected position
        var bestPose: BodyPose?
        var bestDistance: CGFloat = .infinity
        let maxDistance: CGFloat = 0.20  // Apple pose must be within 0.20 of prediction

        for pose in poses {
            guard let com = pose.centerOfMass else { continue }
            let distance = hypot(com.x - expected.x, com.y - expected.y)
            if distance < bestDistance {
                bestDistance = distance
                bestPose = pose
            }
        }

        guard bestDistance < maxDistance else { return nil }
        return bestPose
    }

    /// Compute the typical bounding box size of the athlete from known poses.
    private func computeTypicalAthleteBoxSize() -> CGSize {
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []

        for frameIndex in 0..<allFramePoses.count {
            guard let assignment = assignments[frameIndex],
                  assignment.hasAthlete,
                  let poseIndex = assignment.athletePoseIndex,
                  poseIndex < allFramePoses[frameIndex].count else { continue }

            if let box = allFramePoses[frameIndex][poseIndex].boundingBox {
                widths.append(box.width)
                heights.append(box.height)
            }
        }

        guard !widths.isEmpty else {
            return CGSize(width: 0.15, height: 0.3)  // Reasonable default
        }

        // Use median for robustness
        widths.sort()
        heights.sort()
        let medianWidth = widths[widths.count / 2]
        let medianHeight = heights[heights.count / 2]
        return CGSize(width: medianWidth, height: medianHeight)
    }

    /// Predict where the athlete should be at a given frame based on nearest known poses.
    private func predictAthletePosition(at targetFrame: Int) -> CGPoint? {
        var beforePose: BodyPose?
        var beforeFrame: Int?
        var afterPose: BodyPose?
        var afterFrame: Int?

        // Search backward
        for f in stride(from: targetFrame - 1, through: max(0, targetFrame - 30), by: -1) {
            if let pose = athletePose(at: f), let _ = pose.centerOfMass {
                beforePose = pose
                beforeFrame = f
                break
            }
        }

        // Search forward
        for f in (targetFrame + 1)..<min(allFramePoses.count, targetFrame + 30) {
            if let pose = athletePose(at: f), let _ = pose.centerOfMass {
                afterPose = pose
                afterFrame = f
                break
            }
        }

        // Interpolate between before and after if both exist
        if let before = beforePose, let bf = beforeFrame,
           let after = afterPose, let af = afterFrame,
           let beforeCOM = before.centerOfMass, let afterCOM = after.centerOfMass {
            let t = CGFloat(targetFrame - bf) / CGFloat(af - bf)
            return CGPoint(
                x: beforeCOM.x + (afterCOM.x - beforeCOM.x) * t,
                y: beforeCOM.y + (afterCOM.y - beforeCOM.y) * t
            )
        }

        // Use velocity extrapolation from whichever side we have
        if let before = beforePose, let bf = beforeFrame, let beforeCOM = before.centerOfMass {
            for f in stride(from: bf - 1, through: max(0, bf - 10), by: -1) {
                if let earlierPose = athletePose(at: f), let earlierCOM = earlierPose.centerOfMass {
                    let vx = (beforeCOM.x - earlierCOM.x) / CGFloat(bf - f)
                    let vy = (beforeCOM.y - earlierCOM.y) / CGFloat(bf - f)
                    let dt = CGFloat(targetFrame - bf)
                    return CGPoint(x: beforeCOM.x + vx * dt, y: beforeCOM.y + vy * dt)
                }
            }
            return beforeCOM
        }

        if let after = afterPose, let afterCOM = after.centerOfMass {
            return afterCOM
        }

        return nil
    }

    // MARK: - Pose Interpolation

    /// Fill short gaps in the athlete's pose sequence using linear interpolation.
    /// Gaps of ≤15 frames are bridged; longer gaps remain nil.
    func interpolateMissingPoses() {
        guard !allFramePoses.isEmpty else { return }

        // Build the current athlete poses array
        let athletePoses: [BodyPose?] = (0..<allFramePoses.count).map { athletePose(at: $0) }

        // Run interpolation
        let interpolated = PoseInterpolator.interpolate(poses: athletePoses)

        // Write interpolated poses back into allFramePoses and update assignments
        for frameIndex in 0..<interpolated.count {
            guard let pose = interpolated[frameIndex], pose.isInterpolated else { continue }

            // Insert the interpolated pose into allFramePoses at this frame
            if allFramePoses[frameIndex].isEmpty {
                allFramePoses[frameIndex] = [pose]
                assignments[frameIndex] = .athleteAuto(poseIndex: 0, confidence: 0.5)
            } else {
                // Frame already has some poses but the athlete wasn't assigned —
                // append the interpolated pose
                let newIndex = allFramePoses[frameIndex].count
                allFramePoses[frameIndex].append(pose)
                assignments[frameIndex] = .athleteAuto(poseIndex: newIndex, confidence: 0.5)
            }
        }
    }

    // MARK: - Debug Video Export

    /// Export an annotated debug video with all tracking overlays burned in.
    ///
    /// Saves to a temporary file and presents the share sheet.
    func exportDebugVideo() async {
        guard !isExportingDebugVideo else { return }

        isExportingDebugVideo = true
        exportProgress = 0
        exportedVideoURL = nil

        do {
            // Recompute path if not cached yet
            if cachedAthletePath.isEmpty { refreshAthletePath() }

            let url = try await DebugVideoExporter.exportDebugVideo(
                session: session,
                allFramePoses: allFramePoses,
                assignments: assignments,
                allFrameTrackedBoxes: allFrameTrackedBoxes,
                trajectoryModel: trajectoryModel,
                athletePath: cachedAthletePath,
                takeoffFrame: cachedTakeoffFrame,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.exportProgress = progress.progress
                    }
                }
            )

            exportedVideoURL = url
            print("[Export] Debug video saved to: \(url.path)")
        } catch {
            errorMessage = "Debug video export failed: \(error.localizedDescription)"
            showError = true
            print("[Export] Failed: \(error)")
        }

        isExportingDebugVideo = false
    }

    /// Compute the athlete's path through the jump for debug overlay.
    ///
    /// Returns path points for every frame where the athlete is assigned,
    /// with takeoff detection based on vertical velocity (Y starts decreasing = going up).
    func computeAthletePath() -> (points: [AthletePathPoint], takeoffFrame: Int?) {
        var points: [AthletePathPoint] = []
        var takeoffFrame: Int?

        // Only include path points from frames near the user-confirmed anchor.
        // Before confirmation, the tracker may be on the wrong person (spectator).
        // We use the confirmed frame as the trust anchor and propagate outward,
        // discarding points that are spatially discontinuous (indicating a person switch).
        let anchorFrame = session.anchorFrameIndex ?? 0

        // First pass: collect ALL high-confidence athlete points
        var rawPoints: [(frameIndex: Int, pose: BodyPose)] = []
        for frameIndex in 0..<allFramePoses.count {
            guard let assignment = assignments[frameIndex],
                  assignment.hasAthlete,
                  let poseIndex = assignment.athletePoseIndex,
                  poseIndex < allFramePoses[frameIndex].count else { continue }

            rawPoints.append((frameIndex, allFramePoses[frameIndex][poseIndex]))
        }

        // Second pass: starting from the anchor frame, walk backward and forward,
        // stopping when there's a large spatial jump (indicates person switch)
        // or when frame gaps are too large (indicates tracking loss).
        let maxJumpDistance: CGFloat = 0.12  // Max normalized distance between consecutive assigned frames
        let maxFrameGap = 10                // Max frame gap between consecutive assigned points
        var validFrames: Set<Int> = []

        // Find anchor in raw points
        if let anchorIdx = rawPoints.firstIndex(where: { $0.frameIndex >= anchorFrame }) {
            validFrames.insert(rawPoints[anchorIdx].frameIndex)

            // Walk forward from anchor
            for i in (anchorIdx + 1)..<rawPoints.count {
                // Check frame gap — large gaps indicate tracking loss/recovery on wrong person
                let frameGap = rawPoints[i].frameIndex - rawPoints[i - 1].frameIndex
                if frameGap > maxFrameGap { break }

                let prevCOM = rawPoints[i - 1].pose.centerOfMass
                let currCOM = rawPoints[i].pose.centerOfMass
                if let prev = prevCOM, let curr = currCOM {
                    let dist = hypot(curr.x - prev.x, curr.y - prev.y)
                    if dist > maxJumpDistance { break }  // Spatial discontinuity — stop
                }
                validFrames.insert(rawPoints[i].frameIndex)
            }

            // Walk backward from anchor
            for i in stride(from: anchorIdx - 1, through: 0, by: -1) {
                // Check frame gap
                let frameGap = rawPoints[i + 1].frameIndex - rawPoints[i].frameIndex
                if frameGap > maxFrameGap { break }

                let nextCOM = rawPoints[i + 1].pose.centerOfMass
                let currCOM = rawPoints[i].pose.centerOfMass
                if let next = nextCOM, let curr = currCOM {
                    let dist = hypot(curr.x - next.x, curr.y - next.y)
                    if dist > maxJumpDistance { break }  // Spatial discontinuity — stop
                }
                validFrames.insert(rawPoints[i].frameIndex)
            }
        }

        // Third pass: build path points only from validated frames
        // Skip frames where the athlete is at the very edge of the frame (partial body = noisy joints)
        let edgeMargin: CGFloat = 0.04  // 4% from any edge
        for (frameIndex, pose) in rawPoints {
            guard validFrames.contains(frameIndex) else { continue }

            // Skip if center of mass is at the frame edge (partial body detection)
            if let com = pose.centerOfMass {
                if com.x < edgeMargin || com.x > (1.0 - edgeMargin) ||
                   com.y < edgeMargin || com.y > (1.0 - edgeMargin) {
                    continue
                }
            }

            // Foot contact: average of ankles (or whichever is available)
            // Require higher confidence to reduce noise from partial detections at frame edge
            let leftAnkle = pose.joints[.leftAnkle]
            let rightAnkle = pose.joints[.rightAnkle]
            var footContact: CGPoint?
            if let la = leftAnkle, la.confidence > 0.3,
               let ra = rightAnkle, ra.confidence > 0.3 {
                footContact = CGPoint(x: (la.point.x + ra.point.x) / 2,
                                      y: (la.point.y + ra.point.y) / 2)
            } else if let la = leftAnkle, la.confidence > 0.3 {
                footContact = la.point
            } else if let ra = rightAnkle, ra.confidence > 0.3 {
                footContact = ra.point
            }

            let com = pose.centerOfMass

            points.append(AthletePathPoint(
                frameIndex: frameIndex,
                footContact: footContact,
                centerOfMass: com,
                isAirborne: false  // Will be updated below
            ))
        }

        // Fourth pass: smooth foot contact positions with a 3-frame moving average
        // to remove zigzag from noisy ankle detections at frame edges
        if points.count >= 3 {
            var smoothed = points
            for i in 1..<(points.count - 1) {
                guard let prev = points[i - 1].footContact,
                      let curr = points[i].footContact,
                      let next = points[i + 1].footContact else { continue }
                let avgX = (prev.x + curr.x + next.x) / 3.0
                let avgY = (prev.y + curr.y + next.y) / 3.0
                smoothed[i] = AthletePathPoint(
                    frameIndex: points[i].frameIndex,
                    footContact: CGPoint(x: avgX, y: avgY),
                    centerOfMass: points[i].centerOfMass,
                    isAirborne: false
                )
            }
            points = smoothed
        }

        // Detect takeoff: find the last frame where feet are on the ground.
        //
        // Strategy: during the approach run, ankle Y stays at a consistent "ground level."
        // At takeoff, ankle Y rapidly decreases (moves up in top-left coords).
        // We compute the ground baseline from the first half of points, then find the
        // first frame where ankle Y rises significantly above that baseline.
        // The takeoff X is placed at the foot position of the LAST ground-contact frame.
        if points.count >= 5 {
            // Collect ankle Y values to establish ground baseline
            let ankleYValues: [CGFloat] = points.compactMap { $0.footContact?.y }

            if ankleYValues.count >= 3 {
                // Use the median of the first 60% of ankle positions as ground level
                let baselineCount = max(3, Int(Double(ankleYValues.count) * 0.6))
                let baselineValues = Array(ankleYValues.prefix(baselineCount)).sorted()
                let groundY = baselineValues[baselineValues.count / 2]  // median

                // Threshold: foot must rise at least 5% of frame height above ground
                // (in top-left coords, "above ground" means lower Y value)
                let liftThreshold: CGFloat = 0.05

                // Find first frame where ankle rises significantly above ground level
                for i in 0..<points.count {
                    guard let ankleY = points[i].footContact?.y else { continue }

                    // ankleY < groundY means foot is above ground (top-left coords)
                    if groundY - ankleY > liftThreshold {
                        // Takeoff frame = the frame BEFORE this one (last ground contact)
                        let takeoffIdx = max(0, i - 1)
                        takeoffFrame = points[takeoffIdx].frameIndex
                        break
                    }
                }
            }
        }

        // Mark airborne points
        if let tf = takeoffFrame {
            for i in 0..<points.count {
                if points[i].frameIndex >= tf {
                    points[i] = AthletePathPoint(
                        frameIndex: points[i].frameIndex,
                        footContact: points[i].footContact,
                        centerOfMass: points[i].centerOfMass,
                        isAirborne: true
                    )
                }
            }
        }

        print("[AthletePath] \(points.count) path points, takeoff at frame \(takeoffFrame?.description ?? "not detected")")
        return (points, takeoffFrame)
    }
}
