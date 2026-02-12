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

    @MainActor
    func processVideo(url: URL, session: JumpSession) async {
        guard !isProcessing else { return }

        isProcessing = true
        progress = 0.0
        poses = []
        analysisResult = nil

        do {
            let detectedPoses = try await PoseDetectionService.processVideo(
                url: url,
                session: session
            ) { prog in
                Task { @MainActor [weak self] in
                    self?.progress = prog
                }
            }
            poses = detectedPoses

            // Auto-detect bar after pose detection
            await autoDetectBar(url: url, session: session)

        } catch {
            errorMessage = "Pose detection failed: \(error.localizedDescription)"
            showError = true
        }

        isProcessing = false
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
    func runAnalysis(frameRate: Double) {
        guard !poses.isEmpty else {
            errorMessage = "No pose data available. Please detect poses first."
            showError = true
            return
        }

        analysisResult = AnalysisEngine.analyze(
            poses: poses,
            bar: barDetection,
            frameRate: frameRate
        )
    }

    // MARK: - Private

    @MainActor
    private func autoDetectBar(url: URL, session: JumpSession) async {
        // Try to detect bar in a frame from the middle of the video
        // (bar is most likely fully visible before the jump)
        let targetFrame = max(0, session.totalFrames / 3)

        do {
            let image = try await VideoFrameExtractor.extractFrame(
                from: url,
                frameIndex: targetFrame,
                frameRate: session.frameRate
            )

            if let result = try BarDetectionService.detectBar(in: image) {
                barDetection = result
            }
        } catch {
            // Bar detection is non-critical
            print("Auto bar detection failed: \(error)")
        }
    }
}
