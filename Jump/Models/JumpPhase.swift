import SwiftUI

/// Jump phases for frame classification.
///
/// Every frame in the video is classified into one of these categories.
/// This enables phase-specific metric display, color-coded timeline,
/// and quick-jump navigation.
enum JumpPhase: String, CaseIterable, Sendable, Identifiable, Codable {
    case noAthlete = "No Athlete"
    case approach = "Approach"
    case penultimate = "Penultimate"
    case takeoff = "Takeoff"
    case flight = "Flight"
    case landing = "Landing"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .noAthlete: return .phaseNoAthlete
        case .approach: return .phaseApproach
        case .penultimate: return .phasePenultimate
        case .takeoff: return .phaseTakeoff
        case .flight: return .phaseFlight
        case .landing: return .phaseLanding
        }
    }

    var icon: String {
        switch self {
        case .noAthlete: return "person.slash"
        case .approach: return "figure.run"
        case .penultimate: return "arrow.down.right"
        case .takeoff: return "arrow.up.forward"
        case .flight: return "figure.gymnastics"
        case .landing: return "arrow.down"
        }
    }

    var description: String {
        switch self {
        case .noAthlete:
            return "Athlete not in frame"
        case .approach:
            return "J-curve run-up building speed toward the bar"
        case .penultimate:
            return "Second-to-last step, lowering center of mass"
        case .takeoff:
            return "Plant foot contact through launch from ground"
        case .flight:
            return "Airborne phase over the bar"
        case .landing:
            return "Contact with the landing mat"
        }
    }

    /// Whether this is an active phase where the athlete is performing.
    var isActive: Bool {
        self != .noAthlete
    }
}
