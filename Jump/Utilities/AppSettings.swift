import SwiftUI

// MARK: - App Settings Keys & Types

/// Centralized @AppStorage key constants and settings types.
enum AppSettingsKey {
    static let measurementUnit = "measurementUnit"
    static let athleteSex = "athleteSex"
    static let showSkeletonOverlay = "showSkeletonOverlay"
    static let showAngleBadges = "showAngleBadges"
    static let hasSeenOnboarding = "hasSeenOnboarding"
}

// MARK: - Measurement Unit

enum MeasurementUnit: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .metric: return "Metric (m, cm)"
        case .imperial: return "Imperial (ft, in)"
        }
    }
}

// MARK: - Athlete Sex (for COM calculation)

enum AthleteSex: String, CaseIterable, Identifiable {
    case male
    case female
    case notSpecified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .notSpecified: return "Not Specified"
        }
    }

    var comSex: COMCalculator.Sex {
        switch self {
        case .male, .notSpecified: return .male
        case .female: return .female
        }
    }
}
