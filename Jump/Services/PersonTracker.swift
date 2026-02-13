import Vision
import CoreGraphics

/// Tracks a single athlete across video frames by matching bounding boxes.
/// Thread-safe via NSLock for use from background processing threads.
final class PersonTracker: @unchecked Sendable {

    private let lock = NSLock()

    /// The bounding box of the currently tracked person (normalized Vision coords)
    private var _trackedBBox: CGRect?
    /// The centroid of the tracked person
    private var _trackedCentroid: CGPoint?
    /// Manual override point (user tapped to select a person)
    private var _manualOverridePoint: CGPoint?
    /// Whether a manual override has been set
    private var _hasManualOverride = false

    // MARK: - Configuration

    /// Maximum centroid distance (normalized) to consider a match between frames
    private let matchThreshold: CGFloat = 0.20

    /// Weight for centrality score in initial selection (0-1)
    private let centralityWeight: CGFloat = 0.4
    /// Weight for size score in initial selection (0-1)
    private let sizeWeight: CGFloat = 0.6

    // MARK: - Public Interface

    /// Reset tracking state for a new video
    func reset() {
        lock.withLock {
            _trackedBBox = nil
            _trackedCentroid = nil
            _manualOverridePoint = nil
            _hasManualOverride = false
            _isLocked = false
            _framesSinceEstablished = 0
            _consecutiveMisses = 0
        }
    }

    /// Set a manual override point — the person nearest this point will be selected.
    /// Point should be in Vision normalized coordinates (0-1, bottom-left origin).
    func setManualOverride(point: CGPoint) {
        lock.withLock {
            _manualOverridePoint = point
            _hasManualOverride = true
            // Reset tracking so next frame re-selects
            _trackedBBox = nil
            _trackedCentroid = nil
        }
    }

    /// Whether a person has been initially selected (after first few frames)
    private var _isLocked = false

    /// Number of frames since tracking was established
    private var _framesSinceEstablished = 0

    /// Frames needed before we "lock on" and reject non-matching people
    private let lockAfterFrames = 8

    /// Number of consecutive frames where no match was found
    private var _consecutiveMisses = 0

    /// After this many consecutive misses, assume the person has left and re-lock next appearance
    private let reacquireAfterMisses = 30

    /// Select the best observation from a set of detected people for the given frame.
    /// Returns nil if no observations match the tracked athlete (avoids annotating bystanders).
    ///
    /// - Parameters:
    ///   - observations: All VNHumanBodyPoseObservation results for this frame
    ///   - frameIndex: Current frame number
    /// - Returns: The selected observation, or nil
    func selectBest(
        from observations: [VNHumanBodyPoseObservation],
        frameIndex: Int
    ) -> VNHumanBodyPoseObservation? {
        guard !observations.isEmpty else {
            lock.withLock {
                _consecutiveMisses += 1
                if _consecutiveMisses >= reacquireAfterMisses {
                    // Person has been gone long enough — unlock to reacquire
                    _isLocked = false
                    _framesSinceEstablished = 0
                }
            }
            return nil
        }

        return lock.withLock {
            // If manual override is set, find the person nearest the override point
            if _hasManualOverride, let overridePoint = _manualOverridePoint {
                let selected = selectNearest(to: overridePoint, from: observations)
                if let selected {
                    updateTrackingUnlocked(for: selected)
                    _isLocked = true
                    _framesSinceEstablished = lockAfterFrames
                    _consecutiveMisses = 0
                }
                return selected
            }

            // If we have a tracked person, match by centroid proximity
            if let trackedCentroid = _trackedCentroid {
                let matched = matchByProximity(to: trackedCentroid, from: observations)
                if let matched {
                    updateTrackingUnlocked(for: matched)
                    _framesSinceEstablished += 1
                    if _framesSinceEstablished >= lockAfterFrames {
                        _isLocked = true
                    }
                    _consecutiveMisses = 0
                    return matched
                }

                // No match within threshold
                _consecutiveMisses += 1
                if _consecutiveMisses >= reacquireAfterMisses {
                    _isLocked = false
                    _framesSinceEstablished = 0
                }

                // If locked on, return nil rather than picking a bystander
                if _isLocked {
                    return nil
                }
                // Not yet locked — fall through to initial selection
            }

            // Initial selection: score by centrality + size
            let selected = initialSelection(from: observations)
            if let selected {
                updateTrackingUnlocked(for: selected)
                _framesSinceEstablished = 1
                _consecutiveMisses = 0
            }
            return selected
        }
    }

    // MARK: - Private

    /// Compute bounding box from an observation's recognized points
    private func boundingBox(for observation: VNHumanBodyPoseObservation) -> CGRect? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }

        var minX: CGFloat = 1.0
        var maxX: CGFloat = 0.0
        var minY: CGFloat = 1.0
        var maxY: CGFloat = 0.0
        var count = 0

        for (_, point) in points {
            guard point.confidence > 0.1 else { continue }
            minX = min(minX, point.location.x)
            maxX = max(maxX, point.location.x)
            minY = min(minY, point.location.y)
            maxY = max(maxY, point.location.y)
            count += 1
        }

        guard count >= 3 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Centroid of a bounding box
    private func centroid(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Distance between two points
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Initial selection: pick the person with highest combined centrality + size score
    private func initialSelection(from observations: [VNHumanBodyPoseObservation]) -> VNHumanBodyPoseObservation? {
        var bestScore: CGFloat = -1
        var bestObs: VNHumanBodyPoseObservation?

        // Find max area for normalization
        var areas: [(VNHumanBodyPoseObservation, CGRect)] = []
        var maxArea: CGFloat = 0

        for obs in observations {
            guard let bbox = boundingBox(for: obs) else { continue }
            let area = bbox.width * bbox.height
            areas.append((obs, bbox))
            maxArea = max(maxArea, area)
        }

        guard maxArea > 0 else { return observations.first }

        let imageCenter = CGPoint(x: 0.5, y: 0.5)

        for (obs, bbox) in areas {
            let center = centroid(of: bbox)
            let area = bbox.width * bbox.height

            // Centrality: 1.0 at center, 0.0 at corner (max distance is ~0.707)
            let dist = distance(center, imageCenter)
            let centralityScore = max(0, 1.0 - dist / 0.707)

            // Size: normalized to largest person
            let sizeScore = area / maxArea

            let totalScore = centralityWeight * centralityScore + sizeWeight * sizeScore

            if totalScore > bestScore {
                bestScore = totalScore
                bestObs = obs
            }
        }

        return bestObs
    }

    /// Match by proximity: find the observation whose centroid is closest to the tracked centroid
    private func matchByProximity(
        to trackedCentroid: CGPoint,
        from observations: [VNHumanBodyPoseObservation]
    ) -> VNHumanBodyPoseObservation? {
        var bestDist: CGFloat = .greatestFiniteMagnitude
        var bestObs: VNHumanBodyPoseObservation?

        for obs in observations {
            guard let bbox = boundingBox(for: obs) else { continue }
            let center = centroid(of: bbox)
            let dist = distance(center, trackedCentroid)

            if dist < bestDist {
                bestDist = dist
                bestObs = obs
            }
        }

        // Only return if within threshold
        if bestDist <= matchThreshold {
            return bestObs
        }
        return nil
    }

    /// Find the observation nearest to a specific point (for manual override)
    private func selectNearest(
        to point: CGPoint,
        from observations: [VNHumanBodyPoseObservation]
    ) -> VNHumanBodyPoseObservation? {
        var bestDist: CGFloat = .greatestFiniteMagnitude
        var bestObs: VNHumanBodyPoseObservation?

        for obs in observations {
            guard let bbox = boundingBox(for: obs) else { continue }
            let center = centroid(of: bbox)
            let dist = distance(center, point)

            if dist < bestDist {
                bestDist = dist
                bestObs = obs
            }
        }

        return bestObs
    }

    /// Update tracking state (caller must hold lock)
    private func updateTrackingUnlocked(for observation: VNHumanBodyPoseObservation) {
        if let bbox = boundingBox(for: observation) {
            _trackedBBox = bbox
            _trackedCentroid = centroid(of: bbox)
        }
    }

    /// Update tracking state (acquires lock)
    private func updateTracking(for observation: VNHumanBodyPoseObservation) {
        lock.withLock {
            updateTrackingUnlocked(for: observation)
        }
    }
}
