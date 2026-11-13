import Foundation

/// Pick keys of a stack that is unpacked into frames: `<micrograph key>#f<n>` with n counted from 1.
/// The plain key (no suffix) is the whole file: for a stack it is the average of all frames, and it is also where
/// picks made before frames could be picked separately live. Single-image files never get a suffix.
enum FrameKey {
    static let marker = "#f"

    /// Splits a key into the micrograph key and the 0-based frame (nil when the key has no frame suffix).
    static func split(_ key: String) -> (base: String, frame: Int?) {
        guard let r = key.range(of: marker, options: .backwards) else { return (key, nil) }
        let digits = key[r.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 1 else { return (key, nil) }
        return (String(key[..<r.lowerBound]), n - 1)
    }
    static func base(_ key: String) -> String { split(key).base }
    static func isFrame(_ key: String) -> Bool { split(key).frame != nil }
    /// `frame` is 0-based; nil gives the plain key.
    static func make(_ base: String, frame: Int?) -> String { frame.map { base + marker + String($0 + 1) } ?? base }
}

/// A list of sizes typed by the user: "12, 16 20", or a range "10:30:5" (first:last:step, both ends included).
enum SweepSpec {
    /// nil when something does not parse or is not positive; [] for blank text.
    static func parse(_ text: String) -> [Double]? {
        var out: [Double] = []
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
        for t in tokens {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            if parts.contains(where: { $0 == nil }) { return nil }
            let v = parts.map { $0! }
            switch v.count {
            case 1: out.append(v[0])
            case 3:
                let (a, b, s) = (v[0], v[1], v[2])
                guard s > 0, b >= a, (b - a) / s < 200 else { return nil }
                var x = a
                while x <= b + 1e-9 { out.append((x * 1000).rounded() / 1000); x += s }
            default: return nil
            }
        }
        guard out.allSatisfy({ $0 > 0 && $0.isFinite }) else { return nil }
        var seen = Set<Double>()
        return out.filter { seen.insert($0).inserted }.sorted()
    }
    static func format(_ v: [Double]) -> String { v.map { String(format: "%g", $0) }.joined(separator: ", ") }
}
