import Foundation

/// Parses bar height from text (video captions, filenames, user input).
/// Returns height in meters. Validates against reasonable high jump range (0.5m–2.60m).
struct BarHeightParser {

    /// Attempt to extract a bar height from a free-text string.
    /// Looks for patterns like "1.85m", "185cm", "6'1\"", etc.
    static func parseHeight(from text: String) -> Double? {
        let text = text.lowercased()

        // Pattern 1: meters with decimal — "1.85m", "1.85 m", "1.85 meters"
        if let match = text.range(of: #"(\d+\.\d+)\s*(?:m(?:eters?)?)\b"#, options: .regularExpression) {
            let numStr = text[match].replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
            if let value = Double(numStr), isReasonable(value) {
                return value
            }
        }

        // Pattern 2: centimeters — "185cm", "185 cm"
        if let match = text.range(of: #"(\d{2,3})\s*cm\b"#, options: .regularExpression) {
            let numStr = text[match].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
            if let cmValue = Double(numStr) {
                let meters = cmValue / 100.0
                if isReasonable(meters) {
                    return meters
                }
            }
        }

        // Pattern 3: feet and inches — "6'1\"", "6'1", "6ft1in", "6 ft 1 in"
        if let match = text.range(of: #"(\d+)\s*['′ft]\s*(\d+)\s*[\"″in]*"#, options: .regularExpression) {
            let part = String(text[match])
            let digits = part.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if digits.count >= 2,
               let feet = Double(digits[0]),
               let inches = Double(digits[1]) {
                let meters = (feet * 12 + inches) * 0.0254
                if isReasonable(meters) {
                    return meters
                }
            }
        }

        // Pattern 3b: dash-separated feet-inches — "6-2", "5-10" (common in captions)
        if let match = text.range(of: #"\b(\d)\s*[-–]\s*(\d{1,2})\b"#, options: .regularExpression) {
            let part = String(text[match])
            let digits = part.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if digits.count >= 2,
               let feet = Double(digits[0]),
               let inches = Double(digits[1]),
               feet >= 3 && feet <= 8 && inches <= 11 {
                let meters = (feet * 12 + inches) * 0.0254
                if isReasonable(meters) {
                    return meters
                }
            }
        }

        // Pattern 4: plain number that looks like meters — "1.85", "2.00"
        if let match = text.range(of: #"\b(\d+\.\d{1,2})\b"#, options: .regularExpression) {
            if let value = Double(text[match]) {
                if isReasonable(value) {
                    return value
                }
            }
        }

        return nil
    }

    /// Parse a user-entered height string (simpler, more direct)
    /// Accepts: "1.85", "1.85m", "185cm", "185", "6'1", "6'1\""
    static func parseUserInput(_ input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // First try the full parser
        if let result = parseHeight(from: trimmed) {
            return result
        }

        // Try as plain number — if > 10 assume cm, if 0.5-2.6 assume meters
        if let value = Double(trimmed.replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)) {
            if value > 10 && value <= 260 {
                // Likely centimeters
                let meters = value / 100.0
                if isReasonable(meters) { return meters }
            } else if isReasonable(value) {
                return value
            }
        }

        return nil
    }

    /// Format a height in meters for display
    static func formatHeight(_ meters: Double) -> String {
        return String(format: "%.2fm", meters)
    }

    /// Format as both metric and imperial
    static func formatHeightFull(_ meters: Double) -> String {
        let totalInches = meters / 0.0254
        let feet = Int(totalInches / 12)
        let inches = Int(totalInches.truncatingRemainder(dividingBy: 12))
        return String(format: "%.2fm (%d'%d\")", meters, feet, inches)
    }

    /// Check if a height in meters is reasonable for a high jump bar
    private static func isReasonable(_ meters: Double) -> Bool {
        meters >= 0.50 && meters <= 2.60
    }
}
