import Foundation
import CoreGraphics

/// RELION 2D/3D classification result mapped back onto the picks (matched by micrograph and coordinates).
struct ClassMapping {
    var source: String                              // file name of the data star
    var tolerancePx: Double
    var pickClass: [String: Int] = [:]              // pick id -> class number
    var counts: [Int: Int] = [:]                    // class -> matched picks
    var rows = 0                                    // particles in the star file
    var matchedRows = 0
    var unmatchedMicrographs: [String] = []
    var averages: [Int: (bytes: [UInt8], size: Int)] = [:]
    var classes: [Int] { counts.keys.sorted() }
    var unclassifiedPicks = 0                       // picks with no row (e.g. removed by 2D selection / border)

    static let palette = ["#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231", "#911eb4", "#46f0f0", "#f032e6",
                          "#bcf60c", "#fabebe", "#008080", "#e6beff", "#9a6324", "#fffac8", "#800000", "#aaffc3",
                          "#808000", "#ffd8b1", "#000075", "#a9a9a9"]
    static func color(_ cls: Int) -> String { palette[(max(cls, 1) - 1) % palette.count] }

    struct Row { var mic: String; var x: Double; var y: Double; var cls: Int }

    /// Reads particle rows (_rlnMicrographName, _rlnCoordinateX/Y, _rlnClassNumber) from a RELION data star.
    static func rows(fromStar text: String) -> [Row] {
        for t in StarFile.parse(text) {
            guard let im = t.index("_rlnMicrographName"), let ix = t.index("_rlnCoordinateX"), let iy = t.index("_rlnCoordinateY"),
                  let ic = t.index("_rlnClassNumber") else { continue }
            return t.rows.compactMap { r in
                guard let x = Double(r[ix]), let y = Double(r[iy]), let c = Int(r[ic]) else { return nil }
                return Row(mic: r[im], x: x, y: y, cls: c)
            }
        }
        return []
    }

    /// Matches every star row to the nearest pick of its micrograph within `tolerancePx`.
    static func build(rows: [Row], picks: [String: [Pick]], source: String, tolerancePx: Double) -> ClassMapping {
        var m = ClassMapping(source: source, tolerancePx: tolerancePx)
        m.rows = rows.count
        let known = Array(picks.keys)
        var grids: [String: PickGrid] = [:]
        for (k, l) in picks { grids[k] = PickGrid(picks: l.filter { $0.status != .dismissed }, cell: max(16, tolerancePx * 2)) }
        var unmatchedMic = Set<String>()
        var keyCache: [String: String?] = [:]
        for r in rows {
            let key: String?
            if let c = keyCache[r.mic] { key = c } else { key = PickImporter.resolveKey(r.mic, known: known); keyCache[r.mic] = .some(key) }
            guard let k = key, let g = grids[k] else { unmatchedMic.insert(r.mic); continue }
            if let p = g.nearest(x: r.x, y: r.y, radius: tolerancePx), m.pickClass[p.id] == nil {
                m.pickClass[p.id] = r.cls; m.counts[r.cls, default: 0] += 1; m.matchedRows += 1
            }
        }
        m.unmatchedMicrographs = unmatchedMic.sorted()
        m.unclassifiedPicks = picks.values.reduce(0) { $0 + $1.filter { $0.status == .accepted && m.pickClass[$0.id] == nil }.count }
        return m
    }

    /// Class average images (8-bit) from a RELION `*_classes.mrcs` stack; class n = frame n-1.
    static func loadAverages(_ url: URL) -> [Int: (bytes: [UInt8], size: Int)] {
        guard let f = try? MRCFile(url: url) else { return [:] }
        var out: [Int: (bytes: [UInt8], size: Int)] = [:]
        for fr in 0..<f.depth {
            guard let px = try? f.readPixels(frame: fr) else { continue }
            let s = px.sorted { $0 < $1 }
            let lo = s[Int(0.01 * Double(s.count - 1))], hi = max(s[Int(0.99 * Double(s.count - 1))], lo + 1e-9)
            out[fr + 1] = (px.map { UInt8(min(max(($0 - lo) / (hi - lo), 0), 1) * 255 + 0.5) }, f.width)
        }
        return out
    }
    static func averagesURL(forData star: URL) -> URL? {
        let n = star.lastPathComponent
        guard n.hasSuffix("_data.star") else { return nil }
        let u = star.deletingLastPathComponent().appendingPathComponent(String(n.dropLast("_data.star".count)) + "_classes.mrcs")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
