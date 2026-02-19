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

    // MARK: - Phase Colors

    static let phaseNoAthlete = Color(white: 0.35)
    static let phaseApproach = Color(red: 0.3, green: 0.7, blue: 1.0)
    static let phasePenultimate = Color(red: 0.9, green: 0.7, blue: 0.2)
    static let phaseTakeoff = Color(red: 1.0, green: 0.4, blue: 0.3)
    static let phaseFlight = Color(red: 0.6, green: 0.4, blue: 1.0)
    static let phaseLanding = Color(red: 0.3, green: 0.9, blue: 0.5)

    // MARK: - Tracking Confidence Colors

    static let trackingLocked = Color(red: 0.2, green: 0.8, blue: 0.3)
    static let trackingTracking = Color(red: 0.9, green: 0.8, blue: 0.2)
    static let trackingUncertain = Color(red: 1.0, green: 0.55, blue: 0.0)
    static let trackingLost = Color(red: 1.0, green: 0.25, blue: 0.25)

    // MARK: - Person Selection Colors

    /// Selected athlete skeleton color
    static let athleteCyan = Color(red: 0.0, green: 0.9, blue: 0.95)

    /// Unassigned person colors (used for multi-person overlay)
    static let personUnassigned1 = Color(red: 1.0, green: 0.85, blue: 0.2)   // Yellow
    static let personUnassigned2 = Color(red: 1.0, green: 0.4, blue: 0.6)    // Pink
    static let personUnassigned3 = Color(red: 1.0, green: 0.55, blue: 0.0)   // Orange
    static let personUnassigned4 = Color(red: 0.7, green: 0.4, blue: 1.0)    // Purple

    /// Unassigned person color by index
    static func personColor(at index: Int) -> Color {
        let colors: [Color] = [.personUnassigned1, .personUnassigned2, .personUnassigned3, .personUnassigned4]
        return colors[index % colors.count]
    }

    // MARK: - Bar & Calibration Colors

    /// Bar marking overlay line
    static let barLine = Color(red: 0.2, green: 1.0, blue: 0.4)

    /// Ground plane indicator
    static let groundPlane = Color(red: 0.5, green: 0.5, blue: 1.0)
}

// MARK: - ShapeStyle Conformance

extension ShapeStyle where Self == Color {
    static var jumpAccent: Color { Color.jumpAccent }
    static var jumpSecondary: Color { Color.jumpSecondary }
    static var jumpBackgroundTop: Color { Color.jumpBackgroundTop }
    static var jumpBackgroundBottom: Color { Color.jumpBackgroundBottom }
    static var jumpCard: Color { Color.jumpCard }
    static var jumpSubtle: Color { Color.jumpSubtle }
    static var skeletonLegs: Color { Color.skeletonLegs }
    static var skeletonArms: Color { Color.skeletonArms }
    static var skeletonTorso: Color { Color.skeletonTorso }
    static var skeletonHead: Color { Color.skeletonHead }
    static var skeletonJoint: Color { Color.skeletonJoint }
    static var severityMinor: Color { Color.severityMinor }
    static var severityModerate: Color { Color.severityModerate }
    static var severityMajor: Color { Color.severityMajor }
    static var phaseNoAthlete: Color { Color.phaseNoAthlete }
    static var phaseApproach: Color { Color.phaseApproach }
    static var phasePenultimate: Color { Color.phasePenultimate }
    static var phaseTakeoff: Color { Color.phaseTakeoff }
    static var phaseFlight: Color { Color.phaseFlight }
    static var phaseLanding: Color { Color.phaseLanding }
    static var trackingLocked: Color { Color.trackingLocked }
    static var trackingTracking: Color { Color.trackingTracking }
    static var trackingUncertain: Color { Color.trackingUncertain }
    static var trackingLost: Color { Color.trackingLost }
    static var athleteCyan: Color { Color.athleteCyan }
    static var barLine: Color { Color.barLine }
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
