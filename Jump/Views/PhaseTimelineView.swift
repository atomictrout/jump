import SwiftUI

/// Color-coded horizontal bar showing jump phases.
/// Tappable sections navigate to phase boundaries.
struct PhaseTimelineView: View {
    let phases: [JumpPhase]
    let currentFrame: Int
    let totalFrames: Int
    let onSeekToFrame: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Phase segments
                HStack(spacing: 1) {
                    ForEach(phaseRuns, id: \.startFrame) { run in
                        let width = segmentWidth(for: run, in: geo.size.width)
                        Rectangle()
                            .fill(run.phase.color.opacity(0.6))
                            .frame(width: max(width, 2))
                            .onTapGesture {
                                onSeekToFrame(run.startFrame)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Playhead
                if totalFrames > 1 {
                    let x = geo.size.width * CGFloat(currentFrame) / CGFloat(totalFrames - 1)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: geo.size.height + 4)
                        .offset(x: x)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Phase Run Computation

    /// Consecutive frames with the same phase, collapsed into runs.
    private var phaseRuns: [PhaseRun] {
        guard !phases.isEmpty else { return [] }

        var runs: [PhaseRun] = []
        var currentPhase = phases[0]
        var startFrame = 0

        for (index, phase) in phases.enumerated() {
            if phase != currentPhase {
                runs.append(PhaseRun(phase: currentPhase, startFrame: startFrame, endFrame: index - 1))
                currentPhase = phase
                startFrame = index
            }
        }
        runs.append(PhaseRun(phase: currentPhase, startFrame: startFrame, endFrame: phases.count - 1))

        return runs
    }

    private func segmentWidth(for run: PhaseRun, in totalWidth: CGFloat) -> CGFloat {
        guard totalFrames > 0 else { return 0 }
        let frameCount = run.endFrame - run.startFrame + 1
        return totalWidth * CGFloat(frameCount) / CGFloat(totalFrames)
    }
}

// MARK: - Phase Run

private struct PhaseRun {
    let phase: JumpPhase
    let startFrame: Int
    let endFrame: Int
}
