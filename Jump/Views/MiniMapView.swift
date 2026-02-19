import SwiftUI

/// Small thumbnail in the corner showing the full frame with a viewport rectangle
/// when the video is zoomed in.
struct MiniMapView: View {
    let frameImage: CGImage
    let zoomScale: CGFloat
    let panOffset: CGSize
    let containerSize: CGSize

    private let miniMapWidth: CGFloat = 80

    var body: some View {
        let imageAspect = CGFloat(frameImage.width) / CGFloat(frameImage.height)
        let miniMapHeight = miniMapWidth / imageAspect

        ZStack {
            // Downscaled thumbnail
            Image(decorative: frameImage, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: miniMapWidth, height: miniMapHeight)

            // Viewport rectangle
            Rectangle()
                .stroke(Color.jumpAccent, lineWidth: 1.5)
                .frame(
                    width: miniMapWidth / zoomScale,
                    height: miniMapHeight / zoomScale
                )
                .offset(
                    x: -panOffset.width / zoomScale * (miniMapWidth / containerSize.width),
                    y: -panOffset.height / zoomScale * (miniMapHeight / containerSize.height)
                )
        }
        .frame(width: miniMapWidth, height: miniMapHeight)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
        )
        .allowsHitTesting(false)
    }
}
