import Foundation
import CoreGraphics

// MARK: - Image entry

struct DMImageEntry {
    let index: Int
    let node: DMNode
    let name: String
    let dims: [Int]
    let dataType: Int
    let data: DMArray
    let scale: [Double]
    let origin: [Double]
    let units: [String]
    let brightScale: Double
    let brightOrigin: Double
    let brightUnits: String

    var width: Int { dims[0] }
    var height: Int { dims.count > 1 ? dims[1] : 1 }
    var depth: Int { dims.count > 2 ? dims[2...].reduce(1, *) : 1 }
    var tags: DMNode? { node.child("ImageTags") }
    var isRGB: Bool { dataType == 23 || dataType == 8 }
    var dataTypeName: String { DMImageEntry.typeName(dataType) }

    static func typeName(_ t: Int) -> String {
        switch t {
        case 1: return "int16"; case 2: return "float32"; case 3: return "complex64"; case 6: return "uint8"
        case 7: return "int32"; case 8, 23: return "RGB(A) 8-bit"; case 9: return "int8"; case 10: return "uint16"
        case 11: return "uint32"; case 12: return "float64"; case 13: return "complex128"; case 14: return "bool"
        default: return "type \(t)"
        }
    }
    static func bytesPerPixel(_ t: Int) -> Int? {
        switch t {
        case 1, 10: return 2
        case 2, 7, 11, 8, 23: return 4
        case 3, 12: return 8
        case 13: return 16
        case 6, 9, 14: return 1
        default: return nil
        }
    }

    /// Pixel size in angstrom per pixel, if the calibration is a length.
    var pixelSizeA: Double? {
        guard let s = scale.first, s > 0, let u = units.first else { return nil }
        let unit = u.lowercased().trimmingCharacters(in: .whitespaces)
        switch unit {
        case "nm": return s * 10
        case "µm", "um", "μm", "micron", "microns": return s * 1e4
        case "å", "a", "angstrom": return s
        case "m": return s * 1e10
        case "mm": return s * 1e7
        default: return nil
        }
    }

    static func extract(from f: DMFile) -> [DMImageEntry] {
        guard let list = f.root.child("ImageList") else { return [] }
        var out: [DMImageEntry] = []
        for (i, item) in list.children.enumerated() {
            guard let imgData = item.child("ImageData"),
                  let dataNode = imgData.child("Data"),
                  case .array(let arr)? = dataNode.value else { continue }
            let dt = imgData.child("DataType")?.value?.asInt ?? 0
            var dims: [Int] = []
            if let d = imgData.child("Dimensions") {
                if d.isGroup { dims = d.children.compactMap { $0.value?.asInt } }
                else if case .array(let a)? = d.value, let p = a.preview { dims = p.compactMap { $0.asInt } }
            }
            guard dims.count >= 2, dims.allSatisfy({ $0 > 0 }) else { continue }
            var sc: [Double] = [], og: [Double] = [], un: [String] = []
            if let cal = imgData.child("Calibrations")?.child("Dimension") {
                for dim in cal.children {
                    sc.append(dim.num("Scale") ?? 1)
                    og.append(dim.num("Origin") ?? 0)
                    un.append(dim.str("Units") ?? "")
                }
            }
            let b = imgData.child("Calibrations")?.child("Brightness")
            out.append(DMImageEntry(index: i, node: item, name: item.str("Name") ?? "Image \(i + 1)",
                                    dims: dims, dataType: dt, data: arr, scale: sc, origin: og, units: un,
                                    brightScale: b?.num("Scale") ?? 1, brightOrigin: b?.num("Origin") ?? 0,
                                    brightUnits: b?.str("Units") ?? ""))
        }
        return out
    }
}

extension DMFile {
    /// The main image: the largest non-RGB entry (the RGB entry is the GMS thumbnail).
    var primaryImage: DMImageEntry? {
        let scalar = images.filter { !$0.isRGB && DMImageEntry.bytesPerPixel($0.dataType) != nil }
        let pool = scalar.isEmpty ? images : scalar
        return pool.max { $0.width * $0.height * $0.depth < $1.width * $1.height * $1.depth }
    }
    var thumbnailEntry: DMImageEntry? {
        images.filter { $0.isRGB && $0.dataType == 23 && $0.depth == 1 }.min { $0.width < $1.width }
    }

    // MARK: pixel reading

    func readPixels(_ e: DMImageEntry, frame: Int = 0) throws -> [Float] {
        guard let bpp = DMImageEntry.bytesPerPixel(e.dataType) else { throw DMError.unsupported("Unsupported image data type \(e.dataType)") }
        let n = e.width * e.height
        let frameBytes = n * bpp
        let start = e.data.offset + min(max(frame, 0), e.depth - 1) * frameBytes
        guard start + frameBytes <= map.size else { throw DMError.parse("Image data runs past end of file") }
        let p = map.base + start
        let swap = !littleEndian

        func raw<T>(_: T.Type) -> [T] {
            var a = [T](unsafeUninitializedCapacity: n) { buf, c in
                memcpy(buf.baseAddress!, p, n * MemoryLayout<T>.size); c = n
            }
            if swap {
                let s = MemoryLayout<T>.stride
                a.withUnsafeMutableBytes { rb in
                    for i in 0..<n {
                        var lo = i * s, hi = lo + s - 1
                        while lo < hi { rb.swapAt(lo, hi); lo += 1; hi -= 1 }
                    }
                }
            }
            return a
        }
        switch e.dataType {
        case 1: return raw(Int16.self).map { Float($0) }
        case 2: return raw(Float.self)
        case 6, 14: return raw(UInt8.self).map { Float($0) }
        case 7: return raw(Int32.self).map { Float($0) }
        case 9: return raw(Int8.self).map { Float($0) }
        case 10: return raw(UInt16.self).map { Float($0) }
        case 11: return raw(UInt32.self).map { Float($0) }
        case 12: return raw(Double.self).map { Float($0) }
        case 3:
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let re = Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self)))
                let im = Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self)))
                out[i] = (re * re + im * im).squareRoot()
            }
            return out
        case 8, 23:
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let b = p.load(fromByteOffset: i * 4, as: UInt8.self)
                let g = p.load(fromByteOffset: i * 4 + 1, as: UInt8.self)
                let r = p.load(fromByteOffset: i * 4 + 2, as: UInt8.self)
                out[i] = (Float(r) + Float(g) + Float(b)) / 3
            }
            return out
        default: throw DMError.unsupported("Unsupported image data type \(e.dataType) (\(e.dataTypeName))")
        }
    }

    /// Embedded GMS thumbnail (8-bit RGB), if present.
    func embeddedThumbnail() -> CGImage? {
        guard let t = thumbnailEntry else { return nil }
        let w = t.width, h = t.height, nbytes = w * h * 4
        guard t.data.offset + nbytes <= map.size else { return nil }
        let d = Data(bytes: map.base + t.data.offset, count: nbytes)
        guard let prov = CGDataProvider(data: d as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: prov, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Statistics

struct ImageStats {
    var min: Double, max: Double, mean: Double, std: Double
    var count: Int
    /// Sorted strided sample (<= ~1M values) used for percentiles and histograms.
    var sample: [Float]

    func percentile(_ p: Double) -> Double {
        guard !sample.isEmpty else { return 0 }
        let q = Swift.min(Swift.max(p, 0), 100) / 100 * Double(sample.count - 1)
        let i = Int(q), f = q - Double(i)
        let a = Double(sample[i]), b = Double(sample[Swift.min(i + 1, sample.count - 1)])
        return a + (b - a) * f
    }

    func histogram(bins: Int = 256, lowPct: Double = 0.05, highPct: Double = 99.95) -> (lo: Double, hi: Double, counts: [Int]) {
        let lo = percentile(lowPct), hi = Swift.max(percentile(highPct), lo + 1e-9)
        var c = [Int](repeating: 0, count: bins)
        let s = Double(bins) / (hi - lo)
        for v in sample {
            let x = Double(v)
            if x < lo || x > hi { continue }
            c[Swift.min(bins - 1, Int((x - lo) * s))] += 1
        }
        return (lo, hi, c)
    }

    static func compute(_ px: [Float]) -> ImageStats {
        let n = px.count
        guard n > 0 else { return ImageStats(min: 0, max: 0, mean: 0, std: 0, count: 0, sample: []) }
        var mn = Float.infinity, mx = -Float.infinity
        var sum = 0.0
        px.withUnsafeBufferPointer { b in
            for v in b { if v < mn { mn = v }; if v > mx { mx = v }; sum += Double(v) }
        }
        let mean = sum / Double(n)
        var ss = 0.0
        px.withUnsafeBufferPointer { b in for v in b { let d = Double(v) - mean; ss += d * d } }
        let target = 1 << 20
        let stride = Swift.max(1, n / target)
        var s = [Float](); s.reserveCapacity(n / stride + 1)
        var i = 0
        while i < n { s.append(px[i]); i += stride }
        s.sort()
        return ImageStats(min: Double(mn), max: Double(mx), mean: mean, std: (ss / Double(n)).squareRoot(), count: n, sample: s)
    }
}
