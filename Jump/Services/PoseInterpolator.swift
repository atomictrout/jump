import CoreGraphics

/// Fills short gaps in a pose sequence using linear interpolation.
///
/// When BlazePose fails to detect the athlete for a few frames (common during
/// fast motion / flight phase), this service synthesizes intermediate poses
/// by linearly interpolating joint positions between the last valid pose
/// before the gap and the first valid pose after.
///
/// Gaps longer than `maxGapFrames` or at the edges of the sequence are left as nil.
enum PoseInterpolator {

    /// Maximum gap length (in frames) that will be filled by interpolation.
    /// At 120fps, 30 frames = 250ms (typical bar clearance time for Fosbury Flop).
    /// At 240fps, 30 frames = 125ms.
    /// Gaps longer than this are left as nil to avoid hallucinating poses
    /// over extended periods of missing data.
    static let maxGapFrames = 30

    /// Minimum number of confident joints for a pose to serve as an interpolation boundary.
    /// Sparse recovery poses (e.g., only `.root`) produce poor interpolation because they
    /// share only 1-2 joints with the other endpoint. We treat them as part of the gap
    /// so the interpolator finds a richer boundary pose.
    static let minJointsForBoundary = 5

    /// Interpolate nil gaps in a pose sequence.
    ///
    /// - Parameter poses: Array of optional poses indexed by frame.
    /// - Returns: A new array with short gaps filled by interpolated poses.
    static func interpolate(poses: [BodyPose?]) -> [BodyPose?] {
        guard poses.count >= 3 else { return poses }

        var result = poses
        var i = 0

        while i < result.count {
            // Skip frames that are valid interpolation boundaries (non-nil with enough joints)
            guard !isValidBoundary(result[i]) else {
                i += 1
                continue
            }

            // Found start of a gap (nil or sparse pose) — find its extent
            let gapStart = i
            while i < result.count && !isValidBoundary(result[i]) {
                i += 1
            }
            let gapEnd = i // first valid-boundary frame after gap (or end of array)

            // Search backward from gapStart for a rich boundary pose
            var beforeIdx: Int?
            for idx in stride(from: gapStart - 1, through: max(0, gapStart - maxGapFrames), by: -1) {
                if isValidBoundary(result[idx]) {
                    beforeIdx = idx
                    break
                }
            }

            // Need a valid pose on both sides to interpolate
            guard let bIdx = beforeIdx,
                  gapEnd < result.count,
                  let beforePose = result[bIdx],
                  let afterPose = result[gapEnd] else {
                continue
            }

            let gapLength = gapEnd - bIdx - 1
            guard gapLength > 0, gapLength <= maxGapFrames else { continue }

            // Interpolate each frame in the gap (from bIdx+1 through gapEnd-1)
            for j in (bIdx + 1)..<gapEnd {
                let t = CGFloat(j - bIdx) / CGFloat(gapEnd - bIdx)
                result[j] = interpolatePose(
                    from: beforePose,
                    to: afterPose,
                    t: t,
                    frameIndex: j,
                    timestamp: beforePose.timestamp + (afterPose.timestamp - beforePose.timestamp) * Double(t)
                )
            }
        }

        return result
    }

    /// A valid interpolation boundary has enough confident joints to produce useful results.
    private static func isValidBoundary(_ pose: BodyPose?) -> Bool {
        guard let pose else { return false }
        let confidentJoints = pose.joints.values.filter { $0.confidence > 0.1 }.count
        return confidentJoints >= minJointsForBoundary
    }

    /// Create an interpolated pose between two reference poses.
    ///
    /// - Parameters:
    ///   - from: The pose before the gap.
    ///   - to: The pose after the gap.
    ///   - t: Interpolation factor (0 = `from`, 1 = `to`).
    ///   - frameIndex: The frame index for the new pose.
    ///   - timestamp: The timestamp for the new pose.
    /// - Returns: A new `BodyPose` with `isInterpolated = true`.
    private static func interpolatePose(
        from: BodyPose,
        to: BodyPose,
        t: CGFloat,
        frameIndex: Int,
        timestamp: Double
    ) -> BodyPose {
        var joints: [BodyPose.JointName: BodyPose.JointPosition] = [:]

        // Only interpolate joints present in BOTH bounding poses
        for (jointName, fromJoint) in from.joints {
            guard let toJoint = to.joints[jointName] else { continue }

            // Both joints need reasonable confidence to interpolate
            guard fromJoint.confidence > 0.1 && toJoint.confidence > 0.1 else { continue }

            let x = fromJoint.point.x + (toJoint.point.x - fromJoint.point.x) * t
            let y = fromJoint.point.y + (toJoint.point.y - fromJoint.point.y) * t
            let confidence = min(fromJoint.confidence, toJoint.confidence) * 0.8

            joints[jointName] = BodyPose.JointPosition(
                point: CGPoint(x: x, y: y),
                confidence: confidence
            )
        }

        return BodyPose(
            frameIndex: frameIndex,
            timestamp: timestamp,
            joints: joints,
            isInterpolated: true
        )
    }
}
