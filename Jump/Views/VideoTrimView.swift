import SwiftUI
import AVFoundation

/// Video trim interface with draggable start/end handles on a frame strip.
/// Allows users to narrow the analysis window before pose detection.
struct VideoTrimView: View {
    let session: JumpSession
    let onTrim: (ClosedRange<Double>?) -> Void // nil = use full video

    @Environment(\.dismiss) private var dismiss

    @State private var thumbnails: [CGImage] = []
    @State private var isLoadingThumbnails = true
    @State private var trimStart: Double = 0 // seconds
    @State private var trimEnd: Double = 0   // seconds
    @State private var startFrameImage: CGImage?
    @State private var endFrameImage: CGImage?

    private let thumbnailCount = 20
    private var duration: Double { session.duration }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.jumpBackgroundTop.ignoresSafeArea()

                VStack(spacing: 20) {
                    // Preview frames
                    previewFrames
                        .padding(.horizontal)

                    // Trim timeline
                    trimTimeline
                        .padding(.horizontal)

                    // Duration info
                    durationInfo

                    Spacer()

                    // Action buttons
                    actionButtons
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
                .padding(.top, 16)
            }
            .navigationTitle("Trim Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.jumpAccent)
                }
            }
            .task { await loadThumbnails() }
        }
    }

    // MARK: - Preview Frames

    private var previewFrames: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                if let image = startFrameImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.jumpCard)
                        .aspectRatio(16/9, contentMode: .fit)
                }
                Text(formatTime(trimStart))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.jumpSubtle)
            }

            Image(systemName: "arrow.right")
                .foregroundStyle(.jumpSubtle)

            VStack(spacing: 4) {
                if let image = endFrameImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.jumpCard)
                        .aspectRatio(16/9, contentMode: .fit)
                }
                Text(formatTime(trimEnd))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.jumpSubtle)
            }
        }
    }

    // MARK: - Trim Timeline

    private var trimTimeline: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                // Thumbnail strip background
                HStack(spacing: 1) {
                    ForEach(0..<thumbnails.count, id: \.self) { index in
                        Image(decorative: thumbnails[index], scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: (width - CGFloat(thumbnailCount - 1)) / CGFloat(thumbnailCount), height: 44)
                            .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Dimmed regions outside trim
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: startX(in: width))

                    Spacer()

                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: width - endX(in: width))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)

                // Trim selection border
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.jumpAccent, lineWidth: 2)
                    .frame(width: endX(in: width) - startX(in: width))
                    .offset(x: startX(in: width))
                    .allowsHitTesting(false)

                // Start handle
                trimHandle(color: .jumpAccent)
                    .position(x: startX(in: width), y: 22)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let fraction = max(0, min(value.location.x / width, endFraction - 0.05))
                                trimStart = fraction * duration
                            }
                            .onEnded { _ in
                                Task { await updatePreviewFrames() }
                            }
                    )

                // End handle
                trimHandle(color: .jumpAccent)
                    .position(x: endX(in: width), y: 22)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let fraction = min(1, max(value.location.x / width, startFraction + 0.05))
                                trimEnd = fraction * duration
                            }
                            .onEnded { _ in
                                Task { await updatePreviewFrames() }
                            }
                    )
            }
        }
        .frame(height: 44)
    }

    private func trimHandle(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 8, height: 50)
            .shadow(color: .black.opacity(0.3), radius: 2)
    }

    // MARK: - Duration Info

    private var durationInfo: some View {
        HStack(spacing: 16) {
            VStack(spacing: 2) {
                Text("Original")
                    .font(.caption2)
                    .foregroundStyle(.jumpSubtle)
                Text(formatTime(duration))
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.white)
            }

            Image(systemName: "arrow.right")
                .foregroundStyle(.jumpSubtle)

            VStack(spacing: 2) {
                Text("Trimmed")
                    .font(.caption2)
                    .foregroundStyle(.jumpSubtle)
                Text(formatTime(trimEnd - trimStart))
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.jumpAccent)
            }

            VStack(spacing: 2) {
                Text("Frames")
                    .font(.caption2)
                    .foregroundStyle(.jumpSubtle)
                Text("\(Int((trimEnd - trimStart) * session.frameRate))")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                let range = trimStart...trimEnd
                onTrim(range)
                dismiss()
            } label: {
                Text("Trim & Analyze")
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.jumpAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Button {
                onTrim(nil)
                dismiss()
            } label: {
                Text("Use Full Video")
                    .font(.subheadline.bold())
                    .foregroundStyle(.jumpSubtle)
            }
        }
    }

    // MARK: - Helpers

    private var startFraction: Double { duration > 0 ? trimStart / duration : 0 }
    private var endFraction: Double { duration > 0 ? trimEnd / duration : 1 }

    private func startX(in width: CGFloat) -> CGFloat {
        CGFloat(startFraction) * width
    }

    private func endX(in width: CGFloat) -> CGFloat {
        CGFloat(endFraction) * width
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        if mins > 0 {
            return String(format: "%d:%05.2f", mins, secs)
        }
        return String(format: "%.2fs", secs)
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnails() async {
        guard let url = session.videoURL else { return }

        trimEnd = duration

        // Load thumbnails
        var images: [CGImage] = []
        for i in 0..<thumbnailCount {
            let time = duration * Double(i) / Double(thumbnailCount)
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let image = try? await VideoFrameExtractor.extractImage(from: url, at: cmTime) {
                images.append(image)
            }
        }
        thumbnails = images
        isLoadingThumbnails = false

        await updatePreviewFrames()
    }

    private func updatePreviewFrames() async {
        guard let url = session.videoURL else { return }

        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        startFrameImage = try? await VideoFrameExtractor.extractImage(from: url, at: startTime)

        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        endFrameImage = try? await VideoFrameExtractor.extractImage(from: url, at: endTime)
    }
}
