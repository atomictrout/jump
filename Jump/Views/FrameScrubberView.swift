import SwiftUI

struct FrameScrubberView: View {
    @Bindable var viewModel: VideoPlayerViewModel

    @State private var isDragging = false
    @State private var dragDebounceTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Thumbnail strip background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.3))

                // Thumbnail images
                if !viewModel.thumbnails.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(viewModel.thumbnails.enumerated()), id: \.offset) { _, thumb in
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(
                                    width: geo.size.width / CGFloat(viewModel.thumbnails.count),
                                    height: geo.size.height - 4
                                )
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(2)
                }

                // Playhead indicator
                playhead(in: geo.size)

                // Phase markers could go here in future
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let progress = max(0, min(1, value.location.x / geo.size.width))
                        let targetFrame = Int(progress * Double(viewModel.totalFrames - 1))

                        // Update frame index immediately for responsiveness
                        viewModel.currentFrameIndex = targetFrame

                        // Debounce the actual frame extraction
                        dragDebounceTask?.cancel()
                        dragDebounceTask = Task {
                            try? await Task.sleep(for: .milliseconds(30))
                            guard !Task.isCancelled else { return }
                            await viewModel.seekToFrame(targetFrame)
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        let progress = max(0, min(1, value.location.x / geo.size.width))
                        let targetFrame = Int(progress * Double(viewModel.totalFrames - 1))

                        dragDebounceTask?.cancel()
                        Task {
                            await viewModel.seekToFrame(targetFrame)
                        }
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
            // Playhead line
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.jumpAccent)
                .frame(width: 3, height: size.height + 12)
                .shadow(color: .jumpAccent.opacity(0.5), radius: 4)

            // Top handle
            Circle()
                .fill(Color.jumpAccent)
                .frame(width: 12, height: 12)
                .offset(y: -(size.height / 2 + 2))
        }
        .offset(x: offset - size.width / 2)
        .animation(isDragging ? nil : .easeOut(duration: 0.1), value: viewModel.currentFrameIndex)
    }

    private func playheadOffset(in width: CGFloat) -> CGFloat {
        guard viewModel.totalFrames > 1 else { return 0 }
        return width * CGFloat(viewModel.currentFrameIndex) / CGFloat(viewModel.totalFrames - 1)
    }
}

#Preview {
    FrameScrubberView(viewModel: VideoPlayerViewModel())
        .padding()
        .background(Color.jumpBackgroundTop)
}
