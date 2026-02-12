import SwiftUI

extension Color {
    // MARK: - App Theme Colors

    /// Primary accent color - vibrant blue
    static let jumpAccent = Color(red: 0.0, green: 0.65, blue: 1.0)

    /// Secondary accent - warm orange for highlights
    static let jumpSecondary = Color(red: 1.0, green: 0.55, blue: 0.0)

    /// Background gradient colors
    static let jumpBackgroundTop = Color(red: 0.08, green: 0.08, blue: 0.12)
    static let jumpBackgroundBottom = Color(red: 0.04, green: 0.04, blue: 0.08)

    /// Card background
    static let jumpCard = Color(white: 0.12)

    /// Subtle text
    static let jumpSubtle = Color(white: 0.5)

    // MARK: - Skeleton Colors

    /// Leg segments
    static let skeletonLegs = Color(red: 0.2, green: 0.6, blue: 1.0)

    /// Arm segments
    static let skeletonArms = Color(red: 0.3, green: 0.9, blue: 0.5)

    /// Torso segments
    static let skeletonTorso = Color.white

    /// Head/neck
    static let skeletonHead = Color.yellow

    /// Joint dots
    static let skeletonJoint = Color.white.opacity(0.9)

    // MARK: - Analysis Colors

    /// Severity colors
    static let severityMinor = Color.yellow
    static let severityModerate = Color.orange
    static let severityMajor = Color.red

    /// Phase colors
    static let phaseApproach = Color(red: 0.3, green: 0.7, blue: 1.0)
    static let phasePenultimate = Color(red: 0.9, green: 0.7, blue: 0.2)
    static let phaseTakeoff = Color(red: 1.0, green: 0.4, blue: 0.3)
    static let phaseFlight = Color(red: 0.6, green: 0.4, blue: 1.0)
    static let phaseLanding = Color(red: 0.3, green: 0.9, blue: 0.5)

    /// Bar detection line
    static let barLine = Color(red: 1.0, green: 0.2, blue: 0.4)
}

// MARK: - View Modifiers

struct JumpCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.jumpCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func jumpCard() -> some View {
        modifier(JumpCardStyle())
    }
}
