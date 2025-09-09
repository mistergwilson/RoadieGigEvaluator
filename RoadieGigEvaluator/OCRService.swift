import UIKit
import Vision

final class OCRService {
    struct Parsed {
        var payUSD: Double?
        var gigMiles: Double?
        var pickupQuery: String?
        var rawText: String
    }

    func parse(image: UIImage, completion: @escaping (Parsed) -> Void) {
        guard let cg = image.cgImage else {
            completion(.init(payUSD: nil, gigMiles: nil, pickupQuery: nil, rawText: ""))
            return
        }

        let request = VNRecognizeTextRequest { req, _ in
            let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let fullText = lines.joined(separator: "\n")

            // 1) Geometry-aware price (handles superscript cents like $15⁸⁰)
            let payGeo = Self.extractPriceWithGeometry(from: observations)

            // 2) Text-only fallback (handles $15.80, $15 80, $1580 -> 15.80, etc.)
            let payText = Self.extractPayAmount(from: fullText)

            let pay = payGeo ?? payText

            // Miles like "11 mi"
            let miles = Self.firstMatch(in: fullText, pattern: #"(\d+(?:\.\d+)?)\s*mi\b"#)
                .flatMap { Double($0) }

            // City, ST (best-effort)
            let city = Self.firstMatch(in: fullText, pattern: #"([A-Za-z .'-]+,\s?[A-Z]{2})"#)

            completion(.init(payUSD: pay, gigMiles: miles, pickupQuery: city, rawText: fullText))
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.015 // helps keep tiny cents as separate tokens
        // Optional: give Vision some hints for this domain
        request.customWords = ["mi", "Roadie", "Support", "Available", "Gig", "CA", "Oakland"]

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        DispatchQueue.global(qos: .userInitiated).async { try? handler.perform([request]) }
    }

    // MARK: - Geometry-aware price extraction
    /// Finds a '$' + dollars and a small two-digit token up/right (superscript cents).
    private static func extractPriceWithGeometry(from obs: [VNRecognizedTextObservation]) -> Double? {
        struct Token { let text: String; let box: CGRect }
        struct Dollars { let digits: String; let box: CGRect }

        var twoDigitTokens: [Token] = []
        var dollarCandidates: [Dollars] = []

        let digitsRegex = try! NSRegularExpression(pattern: #"(?<!\d)\d{1,4}(?!\d)"#)
        let twoDigitsRegex = try! NSRegularExpression(pattern: #"(?<!\d)\d{2}(?!\d)"#)
        let dollarRegex = try! NSRegularExpression(pattern: #"\$\s*([0-9]{1,4})"#)

        for o in obs {
            guard let t = o.topCandidates(1).first else { continue }
            let s = t.string

            // Two-digit tokens (possible cents)
            for m in twoDigitsRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 0), in: s),
                   let rectObs = try? t.boundingBox(for: r) {
                    let box = rectObs.boundingBox // VNRectangleObservation → CGRect
                    twoDigitTokens.append(.init(text: String(s[r]), box: box))
                }
            }

            // Dollars immediately after '$'
            for m in dollarRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s),
                   let rectObs = try? t.boundingBox(for: r) {
                    let box = rectObs.boundingBox
                    dollarCandidates.append(.init(digits: String(s[r]), box: box))
                }
            }

            // Bare dollars (short tokens w/o $)
            if s.trimmingCharacters(in: .whitespaces).count <= 4 && s.contains(where: \.isNumber) && !s.contains("$") {
                if let m = digitsRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let r = Range(m.range(at: 0), in: s),
                   let rectObs = try? t.boundingBox(for: r) {
                    let box = rectObs.boundingBox
                    dollarCandidates.append(.init(digits: String(s[r]), box: box))
                }
            }
        }

        // Heuristic: cents token is to the right, slightly above, and smaller
        func looksLikeSuperscriptCents(base: CGRect, small: CGRect) -> Bool {
            let dx = small.minX - base.maxX
            let dy = small.midY - base.midY   // normalized coordinates
            let sizeRatio = small.height / max(0.0001, base.height)

            let closeRight = dx >= -0.01 && dx <= 0.10
            let slightlyAbove = dy >= -0.05 && dy <= 0.25
            let smaller = sizeRatio <= 0.85

            return closeRight && slightlyAbove && smaller
        }

        for d in dollarCandidates {
            guard let dollars = Double(d.digits) else { continue }
            let candidate = twoDigitTokens
                .filter { looksLikeSuperscriptCents(base: d.box, small: $0.box) }
                .min(by: { lhs, rhs in
                    let dl = hypot(lhs.box.midX - d.box.midX, lhs.box.midY - d.box.midY)
                    let dr = hypot(rhs.box.midX - d.box.midX, rhs.box.midY - d.box.midY)
                    return dl < dr
                })

            if let centsText = candidate?.text, let cents = Double(centsText) {
                return dollars + cents / 100.0
            }
        }

        return nil
    }

    // MARK: - Text-only fallback
    /// Handles $15.80, $15 80, $15•80, $1,580.00, and "$1580" → 15.80.
    private static func extractPayAmount(from text: String) -> Double? {
        // $1,234.56
        if let s = firstMatch(in: text, pattern: #"\$([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)"#) {
            let cleaned = s.replacingOccurrences(of: ",", with: "")
            if let v = Double(cleaned) { return v }
        }

        // $15.80 / $15·80 / $15•80 / $15 80
        if let match = firstMatch2(in: text,
            pattern: #"\$([0-9]{1,6})[ \u00A0\u202F\u2009\.\u2024\u2027\u00B7•·]([0-9]{2})"#) {
            if let dollars = Double(match.0), let cents = Double(match.1) {
                return dollars + cents / 100.0
            }
        }

        // "$1580" → interpret last two digits as cents → 15.80
        if let s = firstMatch(in: text, pattern: #"\$([0-9]{3,})"#) {
            let digits = s.replacingOccurrences(of: ",", with: "")
            if digits.count >= 3 {
                let dollarsStr = String(digits.dropLast(2))
                let centsStr = String(digits.suffix(2))
                if let d = Double(dollarsStr), let c = Double(centsStr) {
                    return d + c / 100.0
                }
            }
        }

        // "$15"
        if let s = firstMatch(in: text, pattern: #"\$([0-9]{1,6})\b"#),
           let v = Double(s) { return v }

        return nil
    }

    // MARK: - Small regex helpers
    private static func firstMatch(in text: String, pattern: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch2(in text: String, pattern: String) -> (String, String)? {
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text) else { return nil }
        let a = String(text[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = String(text[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (a, b)
    }
}
