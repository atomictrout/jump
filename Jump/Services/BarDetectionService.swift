import Vision
import CoreImage
import CoreGraphics

struct BarDetectionService {

    /// Attempt to detect the high jump bar in a CGImage.
    /// Uses contour detection + filtering for horizontal lines.
    static func detectBar(in cgImage: CGImage) throws -> BarDetectionResult? {
        // Strategy 1: Try contour-based detection
        if let result = try detectBarViaContours(in: cgImage) {
            return result
        }

        // Strategy 2: Try rectangle detection (thin, wide rectangles)
        if let result = try detectBarViaRectangles(in: cgImage) {
            return result
        }

        return nil
    }

    // MARK: - Contour Detection

    private static func detectBarViaContours(in cgImage: CGImage) throws -> BarDetectionResult? {
        let ciImage = CIImage(cgImage: cgImage)

        // Apply edge detection to enhance lines
        let edgeImage = ciImage.applyingFilter("CIEdges", parameters: ["inputIntensity": 3.0])

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.maximumImageDimension = 512

        let handler = VNImageRequestHandler(ciImage: edgeImage, options: [:])
        try handler.perform([request])

        guard let contoursObservation = request.results?.first else { return nil }

        // Search through contours for horizontal bar-like segments
        var bestCandidate: BarDetectionResult?
        var bestScore: Double = 0

        let contourCount = contoursObservation.contourCount
        for i in 0..<contourCount {
            guard let contour = try? contoursObservation.contour(at: i) else { continue }

            let points = contour.normalizedPoints
            guard points.count >= 2 else { continue }

            // Analyze the contour: find the bounding box
            let xs = points.map { CGFloat($0.x) }
            let ys = points.map { CGFloat($0.y) }

            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }

            let width = maxX - minX
            let height = maxY - minY

            // Bar criteria:
            // 1. Wide: spans at least 25% of image width
            // 2. Thin: height/width ratio < 0.1
            // 3. Located in upper 70% of image (not on the ground)
            // 4. Approximately horizontal

            let isWideEnough = width > 0.25
            let isThinEnough = height < 0.08 && (width > 0 ? height / width < 0.1 : false)
            let isUpperRegion = minY > 0.2 // Vision coords: 0 = bottom, so upper region > 0.3
            let avgY = (minY + maxY) / 2

            if isWideEnough && isThinEnough && isUpperRegion {
                // Score: prefer wider, more horizontal, higher confidence
                let score = Double(width) * (1.0 - Double(height / max(width, 0.01)))

                if score > bestScore {
                    bestScore = score
                    bestCandidate = BarDetectionResult(
                        barLineStart: CGPoint(x: minX, y: avgY),
                        barLineEnd: CGPoint(x: maxX, y: avgY),
                        confidence: min(1.0, score * 2),
                        frameIndex: 0
                    )
                }
            }
        }

        // Only return if confidence is reasonable
        if let candidate = bestCandidate, candidate.confidence > 0.3 {
            return candidate
        }
        return nil
    }

    // MARK: - Rectangle Detection

    private static func detectBarViaRectangles(in cgImage: CGImage) throws -> BarDetectionResult? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.005
        request.maximumAspectRatio = 0.08
        request.minimumSize = 0.2
        request.maximumObservations = 10
        request.minimumConfidence = 0.3

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        guard let results = request.results, !results.isEmpty else { return nil }

        // Find the best rectangle that looks like a bar
        var bestResult: VNRectangleObservation?
        var bestScore: Double = 0

        for rect in results {
            let boundingBox = rect.boundingBox
            let width = boundingBox.width
            let height = boundingBox.height
            let aspectRatio = height / width

            // Bar should be wide and thin
            guard width > 0.2, aspectRatio < 0.1 else { continue }

            // Score: prefer wider and in upper region
            let positionScore = Double(boundingBox.midY) // Higher = upper in Vision coords
            let widthScore = Double(width)
            let score = widthScore * positionScore * Double(rect.confidence)

            if score > bestScore {
                bestScore = score
                bestResult = rect
            }
        }

        guard let best = bestResult else { return nil }

        let box = best.boundingBox
        return BarDetectionResult(
            barLineStart: CGPoint(x: box.minX, y: box.midY),
            barLineEnd: CGPoint(x: box.maxX, y: box.midY),
            confidence: Double(best.confidence),
            frameIndex: 0
        )
    }
}
