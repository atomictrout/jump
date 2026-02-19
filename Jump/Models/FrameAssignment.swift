import Foundation

/// Per-frame athlete assignment state.
///
/// Each frame in the video has exactly one FrameAssignment that describes
/// whether the athlete is present and which detected skeleton (if any) is theirs.
///
/// The poseIndex refers to the index within that frame's detected poses array
/// (from BlazePoseService).
enum FrameAssignment: Codable, Sendable, Equatable {
    /// User explicitly confirmed this skeleton is the athlete.
    case athleteConfirmed(poseIndex: Int)

    /// Propagation automatically matched this skeleton with high confidence.
    case athleteAuto(poseIndex: Int, confidence: Float)

    /// Propagation matched a skeleton but with low confidence — needs review.
    case athleteUncertain(poseIndex: Int, confidence: Float)

    /// User explicitly confirmed the athlete is NOT in this frame.
    case noAthleteConfirmed

    /// Propagation determined no skeleton matches the athlete.
    case noAthleteAuto

    /// User marked that the athlete IS visible but no skeleton was detected
    /// (occlusion, detection failure). These frames are excluded from
    /// biomechanical analysis but included in phase timeline (interpolated).
    case athleteNoPose

    /// No assignment yet — pose detection found skeletons but matching
    /// hasn't reached this frame, or detection gap.
    case unreviewedGap

    // MARK: - Convenience

    /// Whether the athlete is assigned (any skeleton matched) in this frame.
    var hasAthlete: Bool {
        switch self {
        case .athleteConfirmed, .athleteAuto, .athleteUncertain:
            return true
        default:
            return false
        }
    }

    /// The pose index of the assigned athlete, if any.
    var athletePoseIndex: Int? {
        switch self {
        case .athleteConfirmed(let idx):
            return idx
        case .athleteAuto(let idx, _):
            return idx
        case .athleteUncertain(let idx, _):
            return idx
        default:
            return nil
        }
    }

    /// Whether this assignment was confirmed by the user (hard anchor).
    var isUserConfirmed: Bool {
        switch self {
        case .athleteConfirmed, .noAthleteConfirmed, .athleteNoPose:
            return true
        default:
            return false
        }
    }

    /// Whether this frame needs review (uncertain or gap).
    var needsReview: Bool {
        switch self {
        case .athleteUncertain, .unreviewedGap:
            return true
        default:
            return false
        }
    }

    /// Confidence of the match (1.0 for user-confirmed, 0.0 for no match).
    var confidence: Float {
        switch self {
        case .athleteConfirmed:
            return 1.0
        case .athleteAuto(_, let conf):
            return conf
        case .athleteUncertain(_, let conf):
            return conf
        case .noAthleteConfirmed:
            return 1.0
        case .noAthleteAuto:
            return 0.8
        case .athleteNoPose:
            return 1.0
        case .unreviewedGap:
            return 0.0
        }
    }

    // MARK: - Timeline Color Category

    /// Color category for timeline display.
    var timelineCategory: TimelineCategory {
        switch self {
        case .athleteConfirmed:
            return .athleteConfirmed
        case .athleteAuto:
            return .athleteAuto
        case .athleteUncertain:
            return .athleteUncertain
        case .noAthleteConfirmed, .noAthleteAuto:
            return .noAthlete
        case .athleteNoPose, .unreviewedGap:
            return .gap
        }
    }

    enum TimelineCategory: Sendable {
        case athleteConfirmed   // Cyan + checkmark
        case athleteAuto        // Cyan
        case athleteUncertain   // Cyan + orange outline
        case noAthlete          // Gray
        case gap                // Red
    }
}
