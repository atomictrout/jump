import SwiftUI

@Observable
class PoseDetectionViewModel {
    var isProcessing = false
    var progress: Double = 0.0
    var poses: [BodyPose] = []
    var barDetection: BarDetectionResult?
    var analysisResult: AnalysisResult?
    var errorMessage: String?
    var showError = false
    var showPersonSelected = false
    var barHeightMeters: Double?

    // MARK: - Workflow State

    /// Whether pose detection has completed (observations collected)
    var hasDetected: Bool { !storedObservations.isEmpty }

    /// Whether person selection has been confirmed by the user
    var personConfirmed = false

    /// Multi-frame person annotations: [(frameIndex, visionPoint)]
    var personAnnotations: [(frame: Int, point: CGPoint)] = []

    /// Person tracker — keeps skeleton locked on the same athlete
    let personTracker = PersonTracker()

    /// Detected takeoff frame index (when the athlete leaves the ground).
    /// Computed from pose data after person is selected. nil if not enough data.
    var takeoffFrameIndex: Int?

    /// Frame indices where tracking confidence is low and user should review.
    /// Sorted by frame index. Empty when no uncertain frames or user has reviewed all.
    var uncertainFrameIndices: [Int] = []

    /// Index into uncertainFrameIndices for the current "review needed" frame.
    /// nil means no review is active.
    var currentUncertainReviewIndex: Int?

    /// Whether we should auto-navigate to the first uncertain frame after retrack
    var shouldNavigateToUncertain = false

    /// Stored raw observations from the initial detection pass.
    /// Used for instant re-tracking when the user selects a different person.
    private var storedObservations: [FrameObservations] = []
    
    /// Public accessor for stored observations (for multi-person selection UI)
    var allFrameObservations: [FrameObservations] {
        storedObservations
    }
    
    // MARK: - Tracking Status
    
    enum TrackingStatus {
        case noDetection           // No poses detected yet
        case noPerson             // Poses detected, but no athlete selected
        case personTracked        // Athlete successfully tracked
        case badDetection         // Athlete present but no pose detected for athlete
        
        var displayText: String {
            switch self {
            case .noDetection: return "No Detection"
            case .noPerson: return "No Athlete Selected"
            case .personTracked: return "Athlete Tracked"
            case .badDetection: return "Bad Detection"
            }
        }
        
        var color: Color {
            switch self {
            case .noDetection: return .red
            case .noPerson: return .orange
            case .personTracked: return .green
            case .badDetection: return .red
            }
        }
        
        var icon: String {
            switch self {
            case .noDetection: return "exclamationmark.triangle.fill"
            case .noPerson: return "person.crop.circle.badge.questionmark"
            case .personTracked: return "checkmark.circle.fill"
            case .badDetection: return "exclamationmark.circle.fill"
            }
        }
    }
    
    /// Current tracking status based on the state
    var trackingStatus: TrackingStatus {
        if !hasDetected {
            return .noDetection
        }
        
        if personAnnotations.isEmpty && !personConfirmed {
            return .noPerson
        }
        
        if personConfirmed || !personAnnotations.isEmpty {
            // Check if we have good tracking data
            let validPoseCount = poses.filter { $0.hasMinimumConfidence }.count
            let totalFrames = storedObservations.count
            
            // If we have annotations but very few valid poses, it's bad detection
            if totalFrames > 0 && Double(validPoseCount) / Double(totalFrames) < 0.3 {
                return .badDetection
            }
            
            return .personTracked
        }
        
        return .noPerson
    }
    
    // MARK: - Smart Tracking
    
    var autoTrackingResult: SmartTrackingEngine.TrackingResult?
    var currentDecisionPointIndex: Int = 0
    var correctionManager: TrackingCorrectionManager?

    @MainActor
    func detectAllPeople(url: URL, session: JumpSession) async {
        guard !isProcessing else { return }

        // Check if pose detection is available (may fail on simulator)
        if !PoseDetectionService.isAvailable {
            errorMessage = "Pose detection is not available on this simulator. Please test on a physical iPhone (A12 chip or newer)."
            showError = true
            return
        }

        isProcessing = true
        progress = 0.0
        storedObservations = []

        do {
            // Collect all raw observations (all people per frame) on a background thread.
            let allObs = try await Task.detached(priority: .userInitiated) {
                try await PoseDetectionService.collectAllObservations(
                    url: url,
                    session: session
                ) { prog in
                    Task { @MainActor [weak self] in
                        self?.progress = prog
                    }
                }
            }.value
            storedObservations = allObs
            
            // DON'T run tracking - just keep all raw observations

        } catch {
            errorMessage = "Pose detection failed: \(error.localizedDescription)"
            showError = true
        }

        isProcessing = false
    }

    @MainActor
    func processVideo(url: URL, session: JumpSession) async {
        guard !isProcessing else { return }

        // Check if pose detection is available (may fail on simulator)
        if !PoseDetectionService.isAvailable {
            errorMessage = "Pose detection is not available on this simulator. Please test on a physical iPhone (A12 chip or newer)."
            showError = true
            return
        }

        isProcessing = true
        progress = 0.0
        poses = []
        analysisResult = nil
        storedObservations = []
        personConfirmed = false
        personAnnotations = []
        uncertainFrameIndices = []
        currentUncertainReviewIndex = nil
        shouldNavigateToUncertain = false
        takeoffFrameIndex = nil
        personTracker.reset()
        
        // Reset smart tracking state
        autoTrackingResult = nil
        currentDecisionPointIndex = 0
        correctionManager = nil

        do {
            // Collect all raw observations (all people per frame) on a background thread.
            let allObs = try await Task.detached(priority: .userInitiated) {
                try await PoseDetectionService.collectAllObservations(
                    url: url,
                    session: session
                ) { prog in
                    Task { @MainActor [weak self] in
                        self?.progress = prog
                    }
                }
            }.value
            storedObservations = allObs
            
            // Run smart auto-tracking algorithm
            let trackingResult = SmartTrackingEngine.autoTrack(
                allFrameObservations: allObs
            )
            autoTrackingResult = trackingResult
            
            // Initialize correction manager
            correctionManager = TrackingCorrectionManager()
            correctionManager?.initialize(from: trackingResult)
            
            // Store poses from auto-tracking
            poses = trackingResult.trackedPoses
            
            // Detect takeoff frame from tracked poses
            takeoffFrameIndex = Self.detectTakeoffFrame(from: poses)

        } catch {
            errorMessage = "Pose detection failed: \(error.localizedDescription)"
            showError = true
        }

        isProcessing = false
    }

    /// Add a person annotation at the given frame and re-track using all annotations.
    /// Multiple annotations improve tracking accuracy across the video.
    /// Queues the annotation if a retrack is already in progress.
    @MainActor
    func addPersonAnnotation(at visionPoint: CGPoint, frameIndex: Int) {
        guard !storedObservations.isEmpty else { 
            print("❌ No stored observations available")
            return 
        }

        print("➕ Adding annotation at frame \(frameIndex), point: \(visionPoint)")
        
        // Replace any existing annotation at same frame, otherwise add
        personAnnotations.removeAll { $0.frame == frameIndex }
        personAnnotations.append((frame: frameIndex, point: visionPoint))
        personAnnotations.sort { $0.frame < $1.frame }
        
        print("📝 Total annotations: \(personAnnotations.count)")

        // If already retracking, queue a new retrack after the current one finishes
        if isProcessing {
            print("⏳ Already processing, queuing retrack")
            pendingRetrack = true
        } else {
            print("🔄 Starting retrack from annotations")
            retrackFromAnnotations()
        }
    }

    /// Whether a retrack should be triggered after the current one finishes
    private var pendingRetrack = false

    /// Remove all person annotations and clear all skeletons.
    /// No skeleton is shown until the user selects a person again.
    @MainActor
    func clearPersonAnnotations() {
        personAnnotations = []
        personConfirmed = false
        poses = []
        analysisResult = nil
        uncertainFrameIndices = []
        currentUncertainReviewIndex = nil
        shouldNavigateToUncertain = false
        takeoffFrameIndex = nil
    }

    /// Remove the most recent person annotation and re-track
    @MainActor
    func undoLastAnnotation() {
        guard !personAnnotations.isEmpty else { return }
        personAnnotations.removeLast()

        if personAnnotations.isEmpty {
            clearPersonAnnotations()
        } else {
            retrackFromAnnotations()
        }
    }
    
    // MARK: - Multi-Person Selection Support
    
    /// Get all detected poses for a specific frame (all people in frame)
    func getAllPosesForFrame(_ frameIndex: Int) -> [BodyPose] {
        guard frameIndex >= 0 && frameIndex < storedObservations.count else { return [] }
        return storedObservations[frameIndex].observations
    }
    
    /// Check if current frame has multiple people detected
    func hasMultiplePeople(at frameIndex: Int) -> Bool {
        return getAllPosesForFrame(frameIndex).count > 1
    }
    
    /// Get currently tracked pose for a frame (if any)
    func getTrackedPose(at frameIndex: Int) -> BodyPose? {
        return poses.first { $0.frameIndex == frameIndex }
    }
    
    /// Get tracking confidence for current frame
    /// Calculate average joint confidence as a proxy
    func trackingConfidence(at frameIndex: Int) -> Double {
        guard let trackedPose = getTrackedPose(at: frameIndex) else { return 0.0 }
        
        // Calculate average confidence from all joints
        let jointConfidences = trackedPose.joints.values.map { Double($0.confidence) }
        guard !jointConfidences.isEmpty else { return 0.0 }
        
        return jointConfidences.reduce(0.0, +) / Double(jointConfidences.count)
    }
    
    /// Count of detected people at frame
    func detectedPeopleCount(at frameIndex: Int) -> Int {
        return getAllPosesForFrame(frameIndex).count
    }
    
    /// Select a specific pose from multiple detections
    /// This is called when user taps on a skeleton in multi-person view
    @MainActor
    func selectSpecificPose(_ selectedPose: BodyPose, at frameIndex: Int) {
        print("🎯 selectSpecificPose called at frame \(frameIndex)")
        
        // Find the centroid of the selected pose to use as annotation point
        guard let bbox = selectedPose.boundingBox else { 
            print("❌ No bounding box for selected pose")
            return 
        }
        let annotationPoint = CGPoint(x: bbox.midX, y: bbox.midY)
        
        print("📍 Annotation point: \(annotationPoint)")
        print("📦 Stored observations count: \(storedObservations.count)")
        
        // Add annotation at this frame with the selected person's position
        addPersonAnnotation(at: annotationPoint, frameIndex: frameIndex)
    }
    
    /// Mark a frame as having no athlete present
    /// This is used when the athlete is off-camera, occluded, or not yet in frame
    @MainActor
    func markFrameAsNoAthlete(_ frameIndex: Int) {
        // Add a special annotation point that's off-screen (negative coords)
        // This signals "no athlete in this frame" to the tracker
        let noAthleteMarker = CGPoint(x: -1.0, y: -1.0)
        addPersonAnnotation(at: noAthleteMarker, frameIndex: frameIndex)
    }
    
    /// Check if a frame is marked as "no athlete"
    func isFrameMarkedNoAthlete(_ frameIndex: Int) -> Bool {
        return personAnnotations.contains { annotation in
            annotation.frame == frameIndex && 
            annotation.point.x < 0 && annotation.point.y < 0
        }
    }
    
    // MARK: - Smart Tracking Decision Handling
    
    /// Get all poses detected at a specific frame (all people, not just tracked)
    func getAllPosesAtFrame(_ frameIndex: Int) -> [BodyPose] {
        guard frameIndex < storedObservations.count else { return [] }
        return storedObservations[frameIndex].observations
    }
    
    /// Get the index of the currently tracked person at a given frame
    /// Returns nil if no person is being tracked at this frame
    func currentlyTrackedPersonIndex(at frameIndex: Int) -> Int? {
        guard frameIndex < poses.count else { return nil }
        let trackedPose = poses[frameIndex]
        
        // If no pose tracked at this frame, return nil
        guard trackedPose.hasMinimumConfidence else { return nil }
        
        let allPoses = getAllPosesAtFrame(frameIndex)
        
        // Find which pose in allPoses matches the tracked pose
        // Match by comparing center of mass
        guard let trackedCenter = trackedPose.centerOfMass else { return nil }
        
        return allPoses.firstIndex { pose in
            guard let center = pose.centerOfMass else { return false }
            let distance = hypot(center.x - trackedCenter.x, center.y - trackedCenter.y)
            return distance < 0.05 // Within 5% of frame
        }
    }
    
    /// Re-detect poses at a specific frame with fresh processing
    @MainActor
    func redetectFrame(_ frameIndex: Int, videoURL: URL) async {
        // For now, just return all stored observations
        // In future, could re-run detection with different parameters
        // This is a placeholder for potential enhancement
    }
    
    /// Handle user selection at a decision point
    @MainActor
    func handleDecisionSelection(_ selectedPerson: PersonThumbnailGenerator.DetectedPerson?, at frameIndex: Int) {
        guard var result = autoTrackingResult else { return }
        
        if let person = selectedPerson {
            // User selected a person - update tracking from this point
            var newPoses = result.trackedPoses
            newPoses[frameIndex] = person.pose
            
            // Re-track forward from this decision with the selected identity
            let identity = SmartTrackingEngine.PersonIdentity(from: person.pose)
            retrackFromFrame(frameIndex, identity: identity, in: &newPoses)
            
            // Update result
            autoTrackingResult = SmartTrackingEngine.TrackingResult(
                trackedPoses: newPoses,
                decisionPoints: result.decisionPoints,
                autoTrackedFrames: result.autoTrackedFrames
            )
            poses = newPoses
            
            // Mark as confirmed
            correctionManager?.markFrameCorrect(frameIndex)
        } else {
            // User marked as "no athlete"
            markFrameAsNoAthlete(frameIndex)
        }
        
        // Update takeoff detection
        takeoffFrameIndex = Self.detectTakeoffFrame(from: poses)
    }
    
    /// Re-track from a specific frame forward with a known identity
    private func retrackFromFrame(_ startFrame: Int, identity: SmartTrackingEngine.PersonIdentity, in poses: inout [BodyPose]) {
        guard startFrame < storedObservations.count - 1 else { return }
        
        var lastPose = poses[startFrame]
        
        for i in (startFrame + 1)..<storedObservations.count {
            let frame = storedObservations[i]
            let observations = frame.observations
            
            if observations.isEmpty {
                poses[i] = .empty(frameIndex: i, timestamp: frame.timestamp)
                continue
            }
            
            if observations.count == 1 {
                // Single person - check if it matches identity
                let pose = observations[0]
                if SmartTrackingEngine.matchesPerson(pose, identity: identity, lastPose: lastPose) {
                    poses[i] = pose
                    lastPose = pose
                } else {
                    poses[i] = .empty(frameIndex: i, timestamp: frame.timestamp)
                }
                continue
            }
            
            // Multiple people - find best match
            let (bestMatch, confidence) = SmartTrackingEngine.findBestMatch(
                among: observations,
                identity: identity,
                lastPose: lastPose
            )
            
            if confidence > 0.75 {
                poses[i] = bestMatch
                lastPose = bestMatch
            } else {
                poses[i] = .empty(frameIndex: i, timestamp: frame.timestamp)
            }
        }
    }
    
    /// Get next decision point that needs user input
    func getNextDecisionPoint() -> SmartTrackingEngine.DecisionPoint? {
        guard let result = autoTrackingResult else { return nil }
        
        if currentDecisionPointIndex < result.decisionPoints.count {
            return result.decisionPoints[currentDecisionPointIndex]
        }
        return nil
    }
    
    /// Move to next decision point
    func advanceToNextDecision() {
        currentDecisionPointIndex += 1
    }
    
    /// Check if there are more decision points to handle
    func hasMoreDecisionPoints() -> Bool {
        guard let result = autoTrackingResult else { return false }
        return currentDecisionPointIndex < result.decisionPoints.count
    }

    /// Confirm person selection — enables bar marking step
    @MainActor
    func confirmPerson() {
        personConfirmed = true
    }

    /// Re-track using all current annotations.
    /// Segments the video at annotation points and tracks bidirectionally from each.
    /// After retracking, flags uncertain frames for user review.
    @MainActor
    private func retrackFromAnnotations() {
        guard !isProcessing, !personAnnotations.isEmpty else { return }

        isProcessing = true
        pendingRetrack = false
        analysisResult = nil

        let allObs = storedObservations
        let annotations = personAnnotations

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = PoseDetectionService.retrackWithMultipleAnnotations(
                allFrameObservations: allObs,
                annotations: annotations
            )
            let interpolated = PoseDetectionViewModel.interpolateMissingPoses(result.poses)

            await MainActor.run {
                guard let self else { return }
                self.poses = interpolated
                self.uncertainFrameIndices = result.uncertainFrameIndices
                self.currentUncertainReviewIndex = nil
                self.takeoffFrameIndex = Self.detectTakeoffFrame(from: interpolated)
                self.isProcessing = false
                self.showPersonSelected = true

                // If uncertain frames were found, signal to navigate to first one
                if !result.uncertainFrameIndices.isEmpty {
                    self.shouldNavigateToUncertain = true
                } else {
                    self.shouldNavigateToUncertain = false
                }

                // If a new annotation came in while we were retracking, do it now
                if self.pendingRetrack {
                    self.retrackFromAnnotations()
                }

                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.showPersonSelected = false
                }
            }
        }
    }

    /// Re-process person selection without clearing bar (for adding more annotations after bar step)
    @MainActor
    func selectPerson(at visionPoint: CGPoint, frameIndex: Int) {
        addPersonAnnotation(at: visionPoint, frameIndex: frameIndex)
    }

    /// Navigate to the next uncertain frame (returns the frame index to seek to, or nil)
    @MainActor
    func nextUncertainFrame() -> Int? {
        guard !uncertainFrameIndices.isEmpty else { return nil }

        if let current = currentUncertainReviewIndex {
            let next = current + 1
            if next < uncertainFrameIndices.count {
                currentUncertainReviewIndex = next
                return uncertainFrameIndices[next]
            }
            return nil  // No more uncertain frames
        } else {
            currentUncertainReviewIndex = 0
            return uncertainFrameIndices[0]
        }
    }

    /// Navigate to the previous uncertain frame
    @MainActor
    func previousUncertainFrame() -> Int? {
        guard !uncertainFrameIndices.isEmpty,
              let current = currentUncertainReviewIndex, current > 0 else { return nil }
        currentUncertainReviewIndex = current - 1
        return uncertainFrameIndices[current - 1]
    }

    /// Dismiss uncertain frame navigation (user is done reviewing)
    @MainActor
    func dismissUncertainReview() {
        shouldNavigateToUncertain = false
        currentUncertainReviewIndex = nil
    }

    /// Number of remaining uncertain frames the user hasn't reviewed
    var uncertainFrameCount: Int {
        uncertainFrameIndices.count
    }

    /// Current uncertain review position description (e.g. "2 of 5")
    var uncertainReviewProgress: String? {
        guard let idx = currentUncertainReviewIndex else { return nil }
        return "\(idx + 1) of \(uncertainFrameIndices.count)"
    }

    @MainActor
    func setBarManually(start: CGPoint, end: CGPoint, frameIndex: Int) {
        barDetection = BarDetectionResult(
            barLineStart: start,
            barLineEnd: end,
            confidence: 1.0,
            frameIndex: frameIndex
        )
    }

    @MainActor
    func setBarHeight(_ meters: Double) {
        barHeightMeters = meters
    }

    @MainActor
    func clearBar() {
        barDetection = nil
        barHeightMeters = nil
    }

    @MainActor
    func runAnalysis(frameRate: Double) {
        guard !poses.isEmpty else {
            errorMessage = "No pose data available. Please detect poses first."
            showError = true
            return
        }

        analysisResult = AnalysisEngine.analyze(
            poses: poses,
            bar: barDetection,
            barHeightMeters: barHeightMeters,
            frameRate: frameRate
        )
    }

    // MARK: - Pose Interpolation

    /// Fill in empty/low-confidence poses by interpolating from neighboring frames.
    /// Handles gaps up to `maxGap` frames by linearly interpolating joint positions.
    static func interpolateMissingPoses(_ poses: [BodyPose], maxGap: Int = 5) -> [BodyPose] {
        guard poses.count >= 3 else { return poses }

        var result = poses

        // Find runs of empty (low-confidence) frames and interpolate from boundaries
        var i = 0
        while i < result.count {
            if !result[i].hasMinimumConfidence {
                // Start of a gap — find the end
                let gapStart = i
                while i < result.count && !result[i].hasMinimumConfidence {
                    i += 1
                }
                let gapEnd = i  // first valid frame after gap (or end)

                let gapLength = gapEnd - gapStart

                // Only interpolate if gap is within maxGap and we have boundaries
                if gapLength <= maxGap && gapStart > 0 && gapEnd < result.count {
                    let before = result[gapStart - 1]
                    let after = result[gapEnd]

                    for g in gapStart..<gapEnd {
                        let t = CGFloat(g - gapStart + 1) / CGFloat(gapLength + 1)
                        result[g] = interpolatePose(from: before, to: after, t: t,
                                                     frameIndex: result[g].frameIndex,
                                                     timestamp: result[g].timestamp)
                    }
                }
            } else {
                i += 1
            }
        }

        return result
    }

    /// Linearly interpolate joint positions between two poses.
    private static func interpolatePose(
        from a: BodyPose, to b: BodyPose, t: CGFloat,
        frameIndex: Int, timestamp: Double
    ) -> BodyPose {
        var joints: [BodyPose.JointName: BodyPose.JointPosition] = [:]

        for jointName in BodyPose.JointName.allCases {
            guard let jointA = a.joints[jointName],
                  let jointB = b.joints[jointName],
                  jointA.confidence > 0.1 && jointB.confidence > 0.1 else { continue }

            let interpX = jointA.point.x + (jointB.point.x - jointA.point.x) * t
            let interpY = jointA.point.y + (jointB.point.y - jointA.point.y) * t
            let interpConf = jointA.confidence + (jointB.confidence - jointA.confidence) * Float(t)

            joints[jointName] = BodyPose.JointPosition(
                point: CGPoint(x: interpX, y: interpY),
                confidence: interpConf
            )
        }

        return BodyPose(frameIndex: frameIndex, timestamp: timestamp, joints: joints)
    }

    // MARK: - Takeoff Detection

    /// Detect the takeoff frame from pose data: last frame before sustained upward root movement.
    /// Returns nil if there isn't enough pose data or no clear takeoff is detected.
    static func detectTakeoffFrame(from poses: [BodyPose]) -> Int? {
        let rootYValues = poses.map { $0.joints[.root]?.point.y ?? 0 }
        guard rootYValues.count >= 15 else { return nil }

        // Compute velocity (change in Y between frames)
        var velocities: [Double] = [0]
        for i in 1..<rootYValues.count {
            velocities.append(Double(rootYValues[i] - rootYValues[i - 1]))
        }

        // Smooth velocities with 5-frame window
        var smooth = velocities
        for i in 2..<(velocities.count - 2) {
            smooth[i] = (velocities[i-2] + velocities[i-1] + velocities[i] +
                         velocities[i+1] + velocities[i+2]) / 5.0
        }

        // Find strongest velocity transition from low/negative to positive (takeoff moment)
        var bestFrame: Int?
        var bestScore: Double = 0

        for i in 5..<(smooth.count - 5) {
            let prevAvg = (smooth[i-3] + smooth[i-2] + smooth[i-1]) / 3.0
            let nextAvg = (smooth[i+1] + smooth[i+2] + smooth[i+3]) / 3.0

            if prevAvg < 0.005 && nextAvg > 0.005 {
                let score = nextAvg - prevAvg
                if score > bestScore {
                    bestScore = score
                    bestFrame = i
                }
            }
        }

        // Only return if the score is meaningful (indicates a real jump)
        return bestScore > 0.003 ? bestFrame : nil
    }

    // MARK: - Private

    @MainActor
    private func autoDetectBar(url: URL, session: JumpSession) async {
        // Try to detect bar in a frame from the middle of the video
        // (bar is most likely fully visible before the jump)
        let targetFrame = max(0, session.totalFrames / 3)

        do {
            // Run bar detection on background thread
            let result = try await Task.detached(priority: .userInitiated) {
                let image = try await VideoFrameExtractor.extractFrame(
                    from: url,
                    frameIndex: targetFrame,
                    frameRate: session.frameRate
                )
                return try BarDetectionService.detectBar(in: image)
            }.value

            if let result {
                barDetection = result
            }
        } catch {
            // Bar detection is non-critical
            print("Auto bar detection failed: \(error)")
        }
    }
}
