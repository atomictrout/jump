import SwiftUI

// MARK: - Analysis Result (Top-Level)

struct AnalysisResult: Sendable {
    let phases: [DetectedPhase]
    let measurements: JumpMeasurements
    let errors: [DetectedError]
    let recommendations: [Recommendation]
    let coachingInsights: [CoachingInsight]
    let keyFrames: KeyFrames
    var clearanceProfile: ClearanceProfile?

    struct KeyFrames: Sendable {
        var firstAthleteFrame: Int?
        var penultimateContact: Int?
        var takeoffPlant: Int?
        var toeOff: Int?
        var peakHeight: Int?
        var barCrossing: Int?
        var landing: Int?
    }
}

// MARK: - Clearance Profile

/// Per-body-part clearance from the bar at the bar-crossing frame.
struct ClearanceProfile: Sendable {
    /// Clearance in meters for each body part (positive = above bar, negative = below/contact).
    let partClearances: [String: Double]

    /// The body part with the least clearance (the "limiter").
    var limiterBodyPart: String? {
        partClearances.min(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Detected Phase

struct DetectedPhase: Identifiable, Sendable {
    let id = UUID()
    let phase: JumpPhase
    let startFrame: Int
    let endFrame: Int
    let keyMetrics: [String: Double]

    var frameCount: Int {
        endFrame - startFrame + 1
    }
}

// MARK: - Metric Confidence Tiers (per spec Section 6)

enum MetricConfidence: Int, Sendable, Codable, Comparable {
    /// Robust — always shown, no correction needed (angles, timing, vertical measurements).
    case tier1 = 1
    /// Correctable — shown with correction applied when camera angle is known.
    case tier2 = 2
    /// Approximate — shown with warning when camera angle > 30deg.
    case tier3 = 3
    /// Unreliable — hidden or grayed out when camera angle > 45deg.
    case tier4 = 4

    static func < (lhs: MetricConfidence, rhs: MetricConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var badge: String? {
        switch self {
        case .tier1: return nil
        case .tier2, .tier3: return "~"
        case .tier4: return "?"
        }
    }
}

// MARK: - Measurements

struct JumpMeasurements: Sendable {
    // MARK: Approach
    var approachSpeed: Double?
    var approachSpeedProgression: [Double]?
    var approachAngleToBar: Double?
    var curveRadius: Double?
    var stepCount: Int?
    var stepLengths: [Double]?
    var stepContactTimes: [Double]?
    var flightToContactRatio: Double?
    var inwardBodyLean: Double?
    var footContactTypes: [FootContactType]?

    // MARK: Penultimate
    var penultimateCOMHeight: Double?
    var penultimateShinAngle: Double?
    var penultimateKneeAngle: Double?
    var penultimateStepDuration: Double?
    var penultimateStepLength: Double?

    // MARK: Takeoff
    var takeoffLegKneeAtPlant: Double?
    var takeoffLegKneeAtToeOff: Double?
    var driveKneeAngleAtTakeoff: Double?
    var ankleAngleAtPlant: Double?
    var anklePlantarflexionAtToeOff: Double?
    var trailLegKneeAtTouchdown: Double?
    var takeoffAngle: Double?
    var backwardLeanAtPlant: Double?
    var hipShoulderSeparationAtTD: Double?
    var hipShoulderSeparationAtTO: Double?
    var verticalVelocityAtToeOff: Double?
    var horizontalVelocityAtToeOff: Double?
    var groundContactTime: Double?
    var takeoffDistanceFromBar: Double?
    var cmToFootDistanceAtPlant: Double?
    var comHeightAtToeOff: Double?
    var trailLegThighPeakVelocity: Double?

    // MARK: Peak / Flight
    var peakCOMHeight: Double?
    var comRise: Double?
    var clearanceOverBar: Double?
    var peakCOMDistanceFromBar: Double?
    var backTiltAngleAtPeak: Double?
    var hipElevationOverBar: Double?
    var headDropTiming: HeadDropTiming?
    var handsPosition: HandsPosition?
    var kneeBendInFlight: Double?

    // MARK: Landing
    var landingZone: LandingZone?
    var flightTime: Double?
    var legClearance: Double?

    // MARK: Bar
    var barKnocked: Bool = false
    var barKnockFrame: Int?
    var barKnockBodyPart: String?
    var jumpSuccess: Bool?

    // MARK: H1 + H2 + H3 Decomposition
    var h1: Double?
    var h2: Double?
    var h3: Double?

    // MARK: Scale
    var barHeightMeters: Double?
    var estimatedAthleteHeight: Double?
    var pixelsPerMeter: Double?
    var cameraAngle: Double?

    // MARK: Takeoff leg
    var takeoffLeg: TakeoffLeg?

    enum TakeoffLeg: String, Sendable, Codable {
        case left, right
    }

    enum FootContactType: String, Sendable, Codable {
        case heelStrike = "Heel Strike"
        case forefoot = "Forefoot"
        case midfoot = "Midfoot"
        case unknown = "Unknown"
    }

    enum HeadDropTiming: String, Sendable {
        case beforeHipsCross = "Early (before hips pass bar)"
        case afterHipsCross = "Correct (after hips pass bar)"
        case noDropDetected = "No drop detected"
    }

    enum HandsPosition: String, Sendable {
        case atHips = "At hips (correct)"
        case extended = "Extended (should be tucked)"
        case overhead = "Overhead"
    }

    enum LandingZone: String, Sendable {
        case center = "Center of mat"
        case offCenter = "Off-center"
        case edge = "Near edge (safety concern)"
    }
}

// MARK: - Measurement Status

extension JumpMeasurements {
    static func status(_ value: Double, idealRange: ClosedRange<Double>) -> MeasurementStatus {
        if idealRange.contains(value) {
            return .good
        }
        let margin = (idealRange.upperBound - idealRange.lowerBound) * 0.3
        let extendedRange = (idealRange.lowerBound - margin)...(idealRange.upperBound + margin)
        if extendedRange.contains(value) {
            return .marginal
        }
        return .poor
    }

    enum MeasurementStatus: Sendable {
        case good, marginal, poor

        var color: Color {
            switch self {
            case .good: return .green
            case .marginal: return .yellow
            case .poor: return .red
            }
        }

        var icon: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .marginal: return "exclamationmark.triangle.fill"
            case .poor: return "xmark.circle.fill"
            }
        }
    }
}

// MARK: - Detected Error (21 types per spec Section 10)

struct DetectedError: Identifiable, Sendable {
    let id: UUID
    let type: ErrorType
    let frameRange: ClosedRange<Int>
    let severity: Severity
    let description: String
    let confidenceTier: MetricConfidence

    init(
        id: UUID = UUID(),
        type: ErrorType,
        frameRange: ClosedRange<Int>,
        severity: Severity,
        description: String,
        confidenceTier: MetricConfidence = .tier1
    ) {
        self.id = id
        self.type = type
        self.frameRange = frameRange
        self.severity = severity
        self.description = description
        self.confidenceTier = confidenceTier
    }

    enum ErrorType: String, Sendable, CaseIterable {
        // Approach errors
        case flatteningCurve = "Flattening the Curve"
        case cuttingCurve = "Cutting the Curve"
        case steppingOutOfCurve = "Stepping Out of Curve"
        case deceleratingOnApproach = "Decelerating on Approach"
        case inconsistentStepCount = "Inconsistent Step Count"
        case insufficientInwardLean = "Insufficient Inward Lean"

        // Penultimate/Takeoff errors
        case overReachingPenultimate = "Over-reaching Penultimate"
        case extendedBodyPosition = "Extended Body Position"
        case improperTakeoffAngle = "Improper Takeoff Angle"
        case takeoffFootMisalignment = "Takeoff Foot Misalignment"
        case incompleteKneeDrive = "Incomplete Knee Drive"
        case tooCloseToBar = "Too Close to Bar"
        case tooFarFromBar = "Too Far from Bar"
        case longGroundContact = "Long Ground Contact"

        // Flight/clearance errors
        case hammockPosition = "Hammock Position"
        case hipCollapse = "Hip Collapse"
        case insufficientRotation = "Insufficient Rotation"
        case earlyHeadDrop = "Early Head Drop"
        case lateLegLift = "Late Leg Lift"
        case armsNotTucked = "Arms Not Tucked"

        // General
        case barKnock = "Bar Knocked"

        var phase: JumpPhase {
            switch self {
            case .flatteningCurve, .cuttingCurve, .steppingOutOfCurve,
                 .deceleratingOnApproach, .inconsistentStepCount, .insufficientInwardLean:
                return .approach
            case .overReachingPenultimate:
                return .penultimate
            case .extendedBodyPosition, .improperTakeoffAngle, .takeoffFootMisalignment,
                 .incompleteKneeDrive, .tooCloseToBar, .tooFarFromBar, .longGroundContact:
                return .takeoff
            case .hammockPosition, .hipCollapse, .insufficientRotation,
                 .earlyHeadDrop, .lateLegLift, .armsNotTucked, .barKnock:
                return .flight
            }
        }
    }

    enum Severity: Int, Sendable, Comparable {
        case minor = 1
        case moderate = 2
        case major = 3

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .minor: return "Minor"
            case .moderate: return "Moderate"
            case .major: return "Major"
            }
        }

        var color: Color {
            switch self {
            case .minor: return .severityMinor
            case .moderate: return .severityModerate
            case .major: return .severityMajor
            }
        }

        var icon: String {
            switch self {
            case .minor: return "exclamationmark.triangle"
            case .moderate: return "exclamationmark.triangle.fill"
            case .major: return "xmark.octagon.fill"
            }
        }
    }
}

// MARK: - Recommendation

struct Recommendation: Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let relatedError: DetectedError.ErrorType?
    let priority: Int
    let phase: JumpPhase?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        relatedError: DetectedError.ErrorType? = nil,
        priority: Int,
        phase: JumpPhase? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.relatedError = relatedError
        self.priority = priority
        self.phase = phase
    }
}

// MARK: - Coaching Insight (per spec Section 11)

struct CoachingInsight: Identifiable, Sendable {
    let id = UUID()
    let question: String
    let answer: String
    let phase: JumpPhase
    let relatedFrameIndex: Int?
    let metric: String?
}

// MARK: - Scale Calibration

struct ScaleCalibration: Sendable {
    let barEndpoint1: CGPoint
    let barEndpoint2: CGPoint
    let barHeightMeters: Double
    let groundY: Double
    let pixelsPerMeter: Double
    let cameraAngle: Double?

    /// Convert a normalized vertical distance to meters.
    func normalizedToMeters(_ distance: CGFloat) -> Double {
        Double(distance) / pixelsPerMeter
    }
}
