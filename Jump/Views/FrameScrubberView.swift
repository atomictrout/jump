import SwiftUI

/// Drag-to-scrub timeline for navigating video frames.
struct FrameScrubberView: View {
    @Binding var currentFrame: Int
    let totalFrames: Int
    let onSeek: (Int) -> Void

    @State private var isDragging = false
    @State private var dragDebounceTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.jumpCard)

                // Progress fill
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.jumpAccent.opacity(0.15))
                    .frame(width: progressWidth(in: geo.size.width))

                // Playhead indicator
                playhead(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let progress = max(0, min(1, value.location.x / geo.size.width))
                        let targetFrame = Int(progress * Double(max(totalFrames - 1, 1)))
                        currentFrame = targetFrame

                        // Debounce the actual frame extraction
                        dragDebounceTask?.cancel()
                        dragDebounceTask = Task {
                            try? await Task.sleep(for: .milliseconds(30))
                            guard !Task.isCancelled else { return }
                            onSeek(targetFrame)
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        let progress = max(0, min(1, value.location.x / geo.size.width))
                        let targetFrame = Int(progress * Double(max(totalFrames - 1, 1)))
                        dragDebounceTask?.cancel()
                        onSeek(targetFrame)
                    }
            )
        }
        .frame(height: 56)
    }

    // MARK: - Playhead

    @ViewBuilder
    private func playhead(in size: CGSize) -> some View {
        let offset = playheadOffset(in: size.width)

        ZStack {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.jumpAccent)
                .frame(width: 3, height: size.height + 12)
                .shadow(color: .jumpAccent.opacity(0.5), radius: 4)

            Circle()
                .fill(Color.jumpAccent)
                .frame(width: 12, height: 12)
                .offset(y: -(size.height / 2 + 2))
        }
        .offset(x: offset)
        .animation(isDragging ? nil : .easeOut(duration: 0.1), value: currentFrame)
    }

    private func playheadOffset(in width: CGFloat) -> CGFloat {
        guard totalFrames > 1 else { return 0 }
        return width * CGFloat(currentFrame) / CGFloat(totalFrames - 1)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard totalFrames > 1 else { return 0 }
        return totalWidth * CGFloat(currentFrame) / CGFloat(totalFrames - 1)
    }
}
