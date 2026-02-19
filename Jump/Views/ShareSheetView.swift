import SwiftUI
import UIKit

/// UIActivityViewController wrapped for SwiftUI.
///
/// Presents the system share sheet for exporting files (videos, images, etc.)
struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]
    var activities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: activities
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
