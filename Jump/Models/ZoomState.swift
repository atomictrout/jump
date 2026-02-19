import SwiftUI

/// Holds zoom/pan transform state for the video frame viewer.
/// Applied as `.scaleEffect` + `.offset` to the entire image+overlay ZStack.
@Observable
final class ZoomState {
    var scale: CGFloat = 1.0
    var offset: CGSize = .zero

    // Gesture anchors — saved at gesture start
    var anchorScale: CGFloat = 1.0
    var anchorOffset: CGSize = .zero

    static let maxScale: CGFloat = 4.0
    static let minScale: CGFloat = 1.0

    var isZoomed: Bool { scale > 1.01 }

    func reset() {
        withAnimation(.easeOut(duration: 0.25)) {
            scale = 1.0
            offset = .zero
        }
        anchorScale = 1.0
        anchorOffset = .zero
    }

    /// Toggle between 1x and 2x zoom, centered on tap point.
    func toggleZoom(at tapPoint: CGPoint, in containerSize: CGSize) {
        if isZoomed {
            reset()
        } else {
            let targetScale: CGFloat = 2.0
            let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
            let dx = (center.x - tapPoint.x) * (targetScale - 1)
            let dy = (center.y - tapPoint.y) * (targetScale - 1)

            withAnimation(.easeOut(duration: 0.25)) {
                scale = targetScale
                offset = CGSize(width: dx, height: dy)
            }
            anchorScale = targetScale
            anchorOffset = CGSize(width: dx, height: dy)
            clampOffset(containerSize: containerSize)
        }
    }

    /// Clamp offset so the video cannot be panned beyond its edges.
    func clampOffset(containerSize: CGSize) {
        guard scale > 1.0 else {
            offset = .zero
            anchorOffset = .zero
            return
        }

        let maxOffsetX = containerSize.width * (scale - 1) / 2
        let maxOffsetY = containerSize.height * (scale - 1) / 2

        offset.width = min(maxOffsetX, max(-maxOffsetX, offset.width))
        offset.height = min(maxOffsetY, max(-maxOffsetY, offset.height))
        anchorOffset = offset
    }
}
