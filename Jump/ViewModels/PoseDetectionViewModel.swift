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

    /// Stored raw observations from the initial detection pass.
    /// Used for instant re-tracking when the user selects a different person.
    private var storedObservations: [FrameObservations] = []

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
        personTracker.reset()

        do {
            // Collect all raw observations (all people per frame) on a background thread
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

            // Initial tracking pass (forward from frame 0) using default auto-selection
            let tracker = personTracker
            let detectedPoses = await Task.detached(priority: .userInitiated) {
                PoseDetectionService.retrackForward(
                    allFrameObservations: allObs,
                    tracker: tracker
                )
            }.value
            poses = Self.interpolateMissingPoses(detectedPoses)

        } catch {
            errorMessage = "Pose detection failed: \(error.localizedDescription)"
            showError = true
        }

        isProcessing = false
    }

    /// Add a person annotation at the given frame and re-track using all annotations.
    /// Multiple annotations improve tracking accuracy across the video.
    @MainActor
    func addPersonAnnotation(at visionPoint: CGPoint, frameIndex: Int) {
        guard !isProcessing, !storedObservations.isEmpty else { return }

        // Replace any existing annotation at same frame, otherwise add
        personAnnotations.removeAll { $0.frame == frameIndex }
        personAnnotations.append((frame: frameIndex, point: visionPoint))
        personAnnotations.sort { $0.frame < $1.frame }

        retrackFromAnnotations()
    }

    /// Remove all person annotations and reset to auto-tracking
    @MainActor
    func clearPersonAnnotations() {
        personAnnotations = []
        personConfirmed = false

        guard !storedObservations.isEmpty else { return }

        // Re-run auto-tracking
        isProcessing = true
        let allObs = storedObservations
        let tracker = PersonTracker()

        Task.detached(priority: .userInitiated) { [weak self] in
            let detectedPoses = PoseDetectionService.retrackForward(
                allFrameObservations: allObs,
                tracker: tracker
            )
            let interpolated = PoseDetectionViewModel.interpolateMissingPoses(detectedPoses)

            await MainActor.run {
                guard let self else { return }
                self.poses = interpolated
                self.isProcessing = false
            }
        }
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

    /// Confirm person selection — enables bar marking step
    @MainActor
    func confirmPerson() {
        personConfirmed = true
    }

    /// Re-track using all current annotations.
    /// Segments the video at annotation points and tracks bidirectionally from each.
    @MainActor
    private func retrackFromAnnotations() {
        guard !isProcessing, !personAnnotations.isEmpty else { return }

        isProcessing = true
        analysisResult = nil

        let allObs = storedObservations
        let annotations = personAnnotations

        Task.detached(priority: .userInitiated) { [weak self] in
            let detectedPoses = PoseDetectionService.retrackWithMultipleAnnotations(
                allFrameObservations: allObs,
                annotations: annotations
            )
            let interpolated = PoseDetectionViewModel.interpolateMissingPoses(detectedPoses)

            await MainActor.run {
                guard let self else { return }
                self.poses = interpolated
                self.isProcessing = false
                self.showPersonSelected = true

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
