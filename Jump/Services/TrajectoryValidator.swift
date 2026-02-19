import CoreGraphics
import Foundation

/// Physics-based trajectory validation for tracked athlete bounding boxes.
///
/// During a high jump, the athlete's center of mass follows a parabolic arc
/// (gravity is non-negotiable). This service fits a trajectory model to known-good
/// anchor points and validates tracked boxes against it, detecting drift when
/// VNTrackObjectRequest locks onto the wrong target.
struct TrajectoryValidator {

    // MARK: - Types

    /// A known-good position used to fit the trajectory model.
    /// Built from frames where PersonTracker pose matching AND VNTrackObjectRequest agree.
    struct AnchorPoint {
        let frameIndex: Int
        let center: CGPoint  // bounding box center, normalized top-left origin
    }

    /// Fitted trajectory model for the athlete's motion.
    ///
    /// - X(t) = ax * t + bx  (linear — roughly constant horizontal velocity)
    /// - Y(t) = ay * t² + by * t + cy  (parabolic — gravity)
    ///
    /// In top-left origin coordinates, Y decreases as the athlete goes higher
    /// (smaller Y = higher on screen), so `ay` is positive for a jump arc.
    struct TrajectoryModel {
        let ax: CGFloat
        let bx: CGFloat
        let ay: CGFloat
        let by: CGFloat
        let cy: CGFloat

        /// R-squared fit quality (0–1, higher is better).
        let rSquared: CGFloat
        let anchorCount: Int

        // Normalization parameters (frame indices are normalized before fitting)
        let frameMean: CGFloat
        let frameScale: CGFloat  // range, or 1.0 if all same frame

        /// Predict the expected center position at a given frame index.
        func predictCenter(at frameIndex: Int) -> CGPoint {
            let t = (CGFloat(frameIndex) - frameMean) / frameScale
            let x = ax * t + bx
            let y = ay * t * t + by * t + cy
            return CGPoint(x: x, y: y)
        }

        /// Distance from a point to the predicted trajectory position at a frame.
        func distanceFromTrajectory(center: CGPoint, at frameIndex: Int) -> CGFloat {
            let predicted = predictCenter(at: frameIndex)
            return hypot(center.x - predicted.x, center.y - predicted.y)
        }
    }

    // MARK: - Configuration

    static let minAnchorsForFit = 3
    static let minRSquared: CGFloat = 0.3
    static let defaultMaxDeviation: CGFloat = 0.12

    // MARK: - Trajectory Fitting

    /// Fit a trajectory model to known-good anchor points.
    ///
    /// Uses weighted least-squares:
    /// - Linear fit for X (horizontal velocity roughly constant)
    /// - Quadratic fit for Y (parabolic arc from gravity)
    ///
    /// Returns nil if fewer than 5 anchors or fit quality (R²) is below 0.5.
    static func fitTrajectory(anchors: [AnchorPoint]) -> TrajectoryModel? {
        guard anchors.count >= minAnchorsForFit else {
            print("[Trajectory] Too few anchors (\(anchors.count)) for trajectory fit, need \(minAnchorsForFit)")
            return nil
        }

        // Normalize frame indices for numerical stability
        let frames = anchors.map { CGFloat($0.frameIndex) }
        let frameMean = frames.reduce(0, +) / CGFloat(frames.count)
        let frameMin = frames.min()!
        let frameMax = frames.max()!
        let frameScale = max(frameMax - frameMin, 1.0)

        let normalizedFrames = frames.map { ($0 - frameMean) / frameScale }
        let xValues = anchors.map { $0.center.x }
        let yValues = anchors.map { $0.center.y }
        // --- Linear fit for X: X(t) = ax * t + bx ---
        let (ax, bx) = linearFit(t: normalizedFrames, values: xValues)

        // --- Quadratic fit for Y: Y(t) = ay * t² + by * t + cy ---
        let (ay, by_, cy) = quadraticFit(t: normalizedFrames, values: yValues)

        // --- Compute R-squared for the combined fit ---
        let rSquared = computeRSquared(
            anchors: anchors,
            ax: ax, bx: bx,
            ay: ay, by: by_, cy: cy,
            frameMean: frameMean, frameScale: frameScale
        )

        guard rSquared >= minRSquared else {
            print("[Trajectory] Poor fit quality (R²=\(String(format: "%.3f", rSquared))), skipping validation")
            return nil
        }

        return TrajectoryModel(
            ax: ax, bx: bx,
            ay: ay, by: by_, cy: cy,
            rSquared: rSquared,
            anchorCount: anchors.count,
            frameMean: frameMean,
            frameScale: frameScale
        )
    }

    // MARK: - Validation

    /// Validate tracked bounding boxes against the trajectory model.
    ///
    /// Boxes whose center deviates more than `maxDeviation` normalized units
    /// from the predicted position are rejected.
    ///
    /// - Returns: Tuple of valid boxes (kept) and rejected frame indices.
    static func validateTrackedBoxes(
        trackedBoxes: [Int: CGRect],
        model: TrajectoryModel,
        maxDeviation: CGFloat = defaultMaxDeviation
    ) -> (valid: [Int: CGRect], rejected: Set<Int>) {
        var valid: [Int: CGRect] = [:]
        var rejected: Set<Int> = []

        for (frameIndex, box) in trackedBoxes {
            let center = CGPoint(x: box.midX, y: box.midY)
            let deviation = model.distanceFromTrajectory(center: center, at: frameIndex)

            if deviation <= maxDeviation {
                valid[frameIndex] = box
            } else {
                rejected.insert(frameIndex)
            }
        }

        return (valid: valid, rejected: rejected)
    }

    // MARK: - Search Region Prediction

    /// Predict a search/crop region at a frame for recovery.
    ///
    /// Centers the region on the trajectory-predicted position and expands
    /// it to accommodate model error and body deformation.
    ///
    /// - Parameters:
    ///   - model: The fitted trajectory model.
    ///   - frameIndex: Frame to predict for.
    ///   - typicalBoxSize: Typical athlete bounding box size (normalized).
    ///   - expansionFactor: How much to expand beyond typical box size (default 2.0).
    /// - Returns: A search region clamped to [0, 1] in both dimensions.
    static func predictSearchRegion(
        model: TrajectoryModel,
        at frameIndex: Int,
        typicalBoxSize: CGSize = CGSize(width: 0.15, height: 0.3),
        expansionFactor: CGFloat = 2.0
    ) -> CGRect {
        let center = model.predictCenter(at: frameIndex)

        let width = typicalBoxSize.width * expansionFactor
        let height = typicalBoxSize.height * expansionFactor

        let x = max(0, center.x - width / 2)
        let y = max(0, center.y - height / 2)

        return CGRect(
            x: x,
            y: y,
            width: min(width, 1.0 - x),
            height: min(height, 1.0 - y)
        )
    }

    // MARK: - Private Fitting Helpers

    /// Linear least-squares fit: value = a * t + b
    private static func linearFit(t: [CGFloat], values: [CGFloat]) -> (a: CGFloat, b: CGFloat) {
        let n = CGFloat(t.count)
        var sumT: CGFloat = 0
        var sumV: CGFloat = 0
        var sumTV: CGFloat = 0
        var sumT2: CGFloat = 0

        for i in 0..<t.count {
            sumT += t[i]
            sumV += values[i]
            sumTV += t[i] * values[i]
            sumT2 += t[i] * t[i]
        }

        let denom = n * sumT2 - sumT * sumT
        guard abs(denom) > 1e-10 else {
            // Degenerate case: all same t value
            return (a: 0, b: sumV / n)
        }

        let a = (n * sumTV - sumT * sumV) / denom
        let b = (sumV - a * sumT) / n
        return (a: a, b: b)
    }

    /// Quadratic least-squares fit: value = a * t² + b * t + c
    ///
    /// Solves the 3x3 normal equations using Cramer's rule.
    private static func quadraticFit(t: [CGFloat], values: [CGFloat]) -> (a: CGFloat, b: CGFloat, c: CGFloat) {
        // Accumulate sums for normal equations
        var s0: CGFloat = 0  // sum(1) = n
        var s1: CGFloat = 0  // sum(t)
        var s2: CGFloat = 0  // sum(t²)
        var s3: CGFloat = 0  // sum(t³)
        var s4: CGFloat = 0  // sum(t⁴)
        var sv: CGFloat = 0  // sum(v)
        var stv: CGFloat = 0 // sum(t*v)
        var st2v: CGFloat = 0 // sum(t²*v)

        for i in 0..<t.count {
            let ti = t[i]
            let vi = values[i]
            let t2 = ti * ti
            let t3 = t2 * ti
            let t4 = t3 * ti

            s0 += 1
            s1 += ti
            s2 += t2
            s3 += t3
            s4 += t4
            sv += vi
            stv += ti * vi
            st2v += t2 * vi
        }

        // Normal equations matrix:
        // | s4  s3  s2 | | a |   | st2v |
        // | s3  s2  s1 | | b | = | stv  |
        // | s2  s1  s0 | | c |   | sv   |

        // Solve via Cramer's rule
        let det = s4 * (s2 * s0 - s1 * s1)
                - s3 * (s3 * s0 - s1 * s2)
                + s2 * (s3 * s1 - s2 * s2)

        guard abs(det) > 1e-10 else {
            // Degenerate — fall back to linear fit for Y
            let (a, b) = linearFit(t: t, values: values)
            return (a: 0, b: a, c: b)
        }

        let detA = st2v * (s2 * s0 - s1 * s1)
                 - s3 * (stv * s0 - s1 * sv)
                 + s2 * (stv * s1 - s2 * sv)

        let detB = s4 * (stv * s0 - s1 * sv)
                 - st2v * (s3 * s0 - s1 * s2)
                 + s2 * (s3 * sv - stv * s2)

        let detC = s4 * (s2 * sv - stv * s1)
                 - s3 * (s3 * sv - stv * s2)
                 + st2v * (s3 * s1 - s2 * s2)

        return (a: detA / det, b: detB / det, c: detC / det)
    }

    /// Compute R-squared for the combined X+Y fit.
    private static func computeRSquared(
        anchors: [AnchorPoint],
        ax: CGFloat, bx: CGFloat,
        ay: CGFloat, by: CGFloat, cy: CGFloat,
        frameMean: CGFloat, frameScale: CGFloat
    ) -> CGFloat {
        var ssRes: CGFloat = 0  // residual sum of squares
        var ssTotX: CGFloat = 0 // total sum of squares for X
        var ssTotY: CGFloat = 0 // total sum of squares for Y

        let meanX = anchors.map(\.center.x).reduce(0, +) / CGFloat(anchors.count)
        let meanY = anchors.map(\.center.y).reduce(0, +) / CGFloat(anchors.count)

        for anchor in anchors {
            let t = (CGFloat(anchor.frameIndex) - frameMean) / frameScale

            let predictedX = ax * t + bx
            let predictedY = ay * t * t + by * t + cy

            let residualX = anchor.center.x - predictedX
            let residualY = anchor.center.y - predictedY
            ssRes += residualX * residualX + residualY * residualY

            let diffX = anchor.center.x - meanX
            let diffY = anchor.center.y - meanY
            ssTotX += diffX * diffX
            ssTotY += diffY * diffY
        }

        let ssTot = ssTotX + ssTotY
        guard ssTot > 1e-10 else { return 1.0 } // All points identical → perfect fit

        return max(0, 1.0 - ssRes / ssTot)
    }
}
