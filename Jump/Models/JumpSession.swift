import Foundation
import AVFoundation
import SwiftData

/// Persistent session model for a single high jump analysis.
///
/// Each JumpSession represents one video import → analysis cycle.
/// All state is auto-saved via SwiftData after each major step.
@Model
final class JumpSession {
    // MARK: - Identity & Metadata
    var createdAt: Date
    var videoURLString: String            // URL to original video (Photos library or app sandbox)
    var duration: Double                  // video duration in seconds
    var frameRate: Double                 // video frame rate (e.g. 120, 240)
    var totalFrames: Int                  // total frame count
    var videoWidth: Double                // natural video width
    var videoHeight: Double               // natural video height
    var videoCaption: String?             // raw caption from video metadata (may contain bar height)

    // MARK: - Workflow State
    var poseDetectionComplete: Bool = false
    var personSelectionComplete: Bool = false
    var barMarkingComplete: Bool = false
    var analysisComplete: Bool = false

    // MARK: - Bar & Calibration
    var barEndpoint1X: Double?
    var barEndpoint1Y: Double?
    var barEndpoint2X: Double?
    var barEndpoint2Y: Double?
    var barHeightMeters: Double?
    var groundY: Double?                  // normalized Y coordinate of ground plane

    // MARK: - Trim
    var trimStartSeconds: Double?         // start of trim range (seconds)
    var trimEndSeconds: Double?           // end of trim range (seconds)

    var trimRange: ClosedRange<Double>? {
        guard let start = trimStartSeconds, let end = trimEndSeconds else { return nil }
        return start...end
    }

    // MARK: - Person Selection
    var anchorFrameIndex: Int?            // frame where user first selected the athlete
    var takeoffLegRaw: String?            // "left" or "right"

    // MARK: - Results Summary (for session list display)
    var jumpCleared: Bool?                // nil = not analyzed, true = cleared, false = knocked
    var barKnockBodyPart: String?
    var estimatedAthleteHeight: Double?   // meters
    var takeoffAngle: Double?             // for quick display on session card
    var peakClearance: Double?            // meters, for quick display

    // MARK: - Computed URL
    var videoURL: URL? {
        URL(string: videoURLString)
    }

    var naturalSize: CGSize {
        CGSize(width: videoWidth, height: videoHeight)
    }

    var barEndpoint1: CGPoint? {
        guard let x = barEndpoint1X, let y = barEndpoint1Y else { return nil }
        return CGPoint(x: x, y: y)
    }

    var barEndpoint2: CGPoint? {
        guard let x = barEndpoint2X, let y = barEndpoint2Y else { return nil }
        return CGPoint(x: x, y: y)
    }

    var takeoffLeg: JumpMeasurements.TakeoffLeg? {
        get {
            guard let raw = takeoffLegRaw else { return nil }
            return JumpMeasurements.TakeoffLeg(rawValue: raw)
        }
        set {
            takeoffLegRaw = newValue?.rawValue
        }
    }

    /// Whether this session has reached the minimum state for analysis.
    var canAnalyze: Bool {
        poseDetectionComplete && personSelectionComplete && barMarkingComplete && barHeightMeters != nil
    }

    /// Human-readable summary for the session card.
    var summaryText: String {
        var parts: [String] = []
        if let height = barHeightMeters {
            parts.append(String(format: "%.2fm", height))
        }
        if let angle = takeoffAngle {
            parts.append(String(format: "Takeoff: %.0f\u{00B0}", angle))
        }
        if let clearance = peakClearance {
            let sign = clearance >= 0 ? "+" : ""
            parts.append(String(format: "Clearance: %@%.0fcm", sign, clearance * 100))
        }
        return parts.isEmpty ? "In progress" : parts.joined(separator: " | ")
    }

    // MARK: - Initialization

    init(
        videoURL: URL,
        duration: Double = 0,
        frameRate: Double = 30,
        totalFrames: Int = 0,
        naturalSize: CGSize = .zero,
        videoCaption: String? = nil
    ) {
        self.createdAt = Date()
        self.videoURLString = videoURL.absoluteString
        self.duration = duration
        self.frameRate = frameRate
        self.totalFrames = totalFrames
        self.videoWidth = Double(naturalSize.width)
        self.videoHeight = Double(naturalSize.height)
        self.videoCaption = videoCaption
    }

    /// Create a session from a video URL, loading metadata automatically.
    static func create(from url: URL) async throws -> JumpSession {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw JumpSessionError.noVideoTrack
        }

        let frameRate = try await Double(videoTrack.load(.nominalFrameRate))
        let naturalSize = try await videoTrack.load(.naturalSize)
        let totalFrames = Int(duration * frameRate)

        // Try to extract caption from video metadata
        var caption: String?
        let metadata = try? await asset.load(.commonMetadata)
        if let metadata {
            for item in metadata {
                let key = item.commonKey
                if key == .commonKeyTitle || key == .commonKeyDescription {
                    if let stringValue = try? await item.load(.stringValue), !stringValue.isEmpty {
                        caption = stringValue
                        break
                    }
                }
            }
        }

        return JumpSession(
            videoURL: url,
            duration: duration,
            frameRate: frameRate,
            totalFrames: totalFrames,
            naturalSize: naturalSize,
            videoCaption: caption
        )
    }

    // MARK: - Bar Endpoint Setters

    func setBarEndpoints(_ p1: CGPoint, _ p2: CGPoint) {
        barEndpoint1X = Double(p1.x)
        barEndpoint1Y = Double(p1.y)
        barEndpoint2X = Double(p2.x)
        barEndpoint2Y = Double(p2.y)
    }
}

// MARK: - Errors

enum JumpSessionError: LocalizedError {
    case noVideoTrack
    case frameExtractionFailed
    case poseDetectionFailed
    case analysisInsufficientData
    case videoTooShort
    case videoUnavailable

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in the selected file."
        case .frameExtractionFailed:
            return "Failed to extract frames from the video."
        case .poseDetectionFailed:
            return "Failed to detect body poses in the video."
        case .analysisInsufficientData:
            return "Not enough data to complete analysis. Ensure the athlete is tracked in takeoff and flight phases."
        case .videoTooShort:
            return "Video is too short for analysis. Record at least 3-5 seconds covering approach through landing."
        case .videoUnavailable:
            return "The original video is no longer available."
        }
    }
}
