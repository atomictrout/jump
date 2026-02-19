import SwiftUI

/// A circular magnifier showing a zoomed-in view of the area under the user's finger.
/// Used during bar endpoint placement for pixel-level precision.
struct LoupeView: View {
    let image: CGImage
    let touchPoint: CGPoint       // in video-space (untransformed) coords
    let videoSize: CGSize         // fitted video size within the container
    let videoOffset: CGPoint      // fitted video offset within the container

    private let loupeSize: CGFloat = 120
    private let magnification: CGFloat = 3.0
    private let offsetAboveFinger: CGFloat = 80

    var body: some View {
        if let croppedImage = croppedRegion {
            ZStack {
                // Magnified image
                Image(decorative: croppedImage, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: loupeSize, height: loupeSize)
                    .clipShape(Circle())

                // Crosshair
                crosshair

                // Border
                Circle()
                    .stroke(Color.barLine, lineWidth: 2.5)
                    .frame(width: loupeSize, height: loupeSize)

                // Outer shadow ring
                Circle()
                    .stroke(Color.black.opacity(0.4), lineWidth: 1)
                    .frame(width: loupeSize + 2, height: loupeSize + 2)
            }
            .position(loupePosition)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Positioning

    /// Position the loupe above the finger, clamped to stay on screen.
    private var loupePosition: CGPoint {
        let x = touchPoint.x
        var y = touchPoint.y - loupeSize / 2 - offsetAboveFinger

        // If too close to top, show below finger instead
        if y - loupeSize / 2 < 0 {
            y = touchPoint.y + loupeSize / 2 + 30
        }

        return CGPoint(x: x, y: y)
    }

    // MARK: - Crosshair

    private var crosshair: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let armLength: CGFloat = 15
            let gap: CGFloat = 4

            // Horizontal line
            var hLine = Path()
            hLine.move(to: CGPoint(x: center.x - armLength, y: center.y))
            hLine.addLine(to: CGPoint(x: center.x - gap, y: center.y))
            hLine.move(to: CGPoint(x: center.x + gap, y: center.y))
            hLine.addLine(to: CGPoint(x: center.x + armLength, y: center.y))

            // Vertical line
            var vLine = Path()
            vLine.move(to: CGPoint(x: center.x, y: center.y - armLength))
            vLine.addLine(to: CGPoint(x: center.x, y: center.y - gap))
            vLine.move(to: CGPoint(x: center.x, y: center.y + gap))
            vLine.addLine(to: CGPoint(x: center.x, y: center.y + armLength))

            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
            context.stroke(hLine, with: .color(.white), style: style)
            context.stroke(vLine, with: .color(.white), style: style)

            // Center dot
            let dotRect = CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)
            context.fill(Path(ellipseIn: dotRect), with: .color(.barLine))
        }
        .frame(width: loupeSize, height: loupeSize)
        .allowsHitTesting(false)
    }

    // MARK: - Image Cropping

    /// Crop a region from the full CGImage centered on the touch point.
    private var croppedRegion: CGImage? {
        // Convert touchPoint from video-space to CGImage pixel coords
        let normalizedX = (touchPoint.x - videoOffset.x) / videoSize.width
        let normalizedY = (touchPoint.y - videoOffset.y) / videoSize.height

        // Clamp to valid range
        guard normalizedX >= 0, normalizedX <= 1,
              normalizedY >= 0, normalizedY <= 1 else { return nil }

        let pixelX = normalizedX * CGFloat(image.width)
        let pixelY = normalizedY * CGFloat(image.height)

        // How many view-points the loupe shows = loupeSize / magnification
        // Map that to image pixels
        let viewPointsShown = loupeSize / magnification
        let pixelsPerViewPoint = CGFloat(image.width) / videoSize.width
        let regionSize = viewPointsShown * pixelsPerViewPoint

        let cropRect = CGRect(
            x: pixelX - regionSize / 2,
            y: pixelY - regionSize / 2,
            width: regionSize,
            height: regionSize
        )

        // Intersect with image bounds
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clampedRect = cropRect.intersection(imageBounds)

        guard !clampedRect.isEmpty, clampedRect.width > 0, clampedRect.height > 0 else { return nil }

        return image.cropping(to: clampedRect)
    }
}
