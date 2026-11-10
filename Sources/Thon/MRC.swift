import Foundation

/// Minimal MRC2014 reader (.mrc / .mrcs). Foundation only, so it can be tested headlessly.
/// Rows are returned exactly as stored (row 0 first, no flip) – the same convention as numpy/mrcfile,
/// RELION coordinates and the web picker.
struct MRCHeader {
    var nx = 0, ny = 0, nz = 0
    var mode = 2
    var mx = 0, my = 0, mz = 0
    var cellX = 0.0, cellY = 0.0, cellZ = 0.0
    var dmin = 0.0, dmax = 0.0, dmean = 0.0, rms = 0.0
    var nsymbt = 0
    var littleEndian = true
    var labels: [String] = []

    /// Å per pixel, or nil if the header carries no calibration (cell == grid, i.e. 1.0 Å/px).
    var pixelSizeA: Double? {
        guard mx > 0, cellX > 0 else { return nil }
        let p = cellX / Double(mx)
        return (p.isFinite && p > 0 && abs(p - 1) > 1e-6) ? p : nil
    }
    var bytesPerPixel: Int {
        switch mode { case 0: return 1; case 1, 6, 12: return 2; case 2: return 4; default: return 0 }
    }
    var modeName: String {
        switch mode {
        case 0: return "int8"; case 1: return "int16"; case 2: return "float32"; case 6: return "uint16"; case 12: return "float16"
        default: return "mode \(mode)"
        }
    }
    static let supportedModes: Set<Int> = [0, 1, 2, 6, 12]
}

enum MRCError: LocalizedError {
    case tooShort, badHeader(String), unsupportedMode(Int), truncated
    var errorDescription: String? {
        switch self {
        case .tooShort: return "File is too short to be an MRC file."
        case .badHeader(let s): return "Invalid MRC header: \(s)"
        case .unsupportedMode(let m): return "Unsupported MRC mode \(m) (supported: 0, 1, 2, 6, 12)."
        case .truncated: return "MRC file is truncated."
        }
    }
}

final class MRCFile: @unchecked Sendable {
    let url: URL
    let header: MRCHeader
    private let data: Data

    var width: Int { header.nx }
    var height: Int { header.ny }
    var depth: Int { header.nz }
    var dataOffset: Int { 1024 + header.nsymbt }

    init(url: URL) throws {
        self.url = url
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        guard d.count >= 1024 else { throw MRCError.tooShort }
        data = d
        header = try MRCFile.parseHeader(d)
    }

    private static func parseHeader(_ d: Data) throws -> MRCHeader {
        func i32(_ w: Int, _ le: Bool) -> Int {
            let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: w * 4, as: UInt32.self) }
            return Int(Int32(bitPattern: le ? UInt32(littleEndian: v) : UInt32(bigEndian: v)))
        }
        func f32(_ w: Int, _ le: Bool) -> Double {
            let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: w * 4, as: UInt32.self) }
            return Double(Float(bitPattern: le ? UInt32(littleEndian: v) : UInt32(bigEndian: v)))
        }
        // Machine stamp (bytes 212..): 0x44 = little endian, 0x11 = big endian. Fall back to a mode sanity check.
        var le = true
        if d[212] == 0x11 && d[213] == 0x11 { le = false }
        else if d[212] != 0x44 { le = MRCHeader.supportedModes.contains(i32(3, true)) || !MRCHeader.supportedModes.contains(i32(3, false)) }
        var h = MRCHeader()
        h.littleEndian = le
        h.nx = i32(0, le); h.ny = i32(1, le); h.nz = i32(2, le); h.mode = i32(3, le)
        h.mx = i32(7, le); h.my = i32(8, le); h.mz = i32(9, le)
        h.cellX = f32(10, le); h.cellY = f32(11, le); h.cellZ = f32(12, le)
        h.dmin = f32(19, le); h.dmax = f32(20, le); h.dmean = f32(21, le); h.rms = f32(54, le)
        h.nsymbt = i32(23, le)
        guard h.nx > 0, h.ny > 0, h.nz > 0, h.nx < 1 << 20, h.ny < 1 << 20 else { throw MRCError.badHeader("dimensions \(h.nx)×\(h.ny)×\(h.nz)") }
        guard h.nsymbt >= 0, h.nsymbt < 1 << 24 else { throw MRCError.badHeader("extended header size \(h.nsymbt)") }
        guard MRCHeader.supportedModes.contains(h.mode) else { throw MRCError.unsupportedMode(h.mode) }
        let nl = max(0, min(10, i32(55, le)))
        for k in 0..<nl {
            let bytes = d.subdata(in: (224 + 80 * k)..<(224 + 80 * (k + 1)))
            let s = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { h.labels.append(s) }
        }
        return h
    }

    /// Pixels of one section as float32, row 0 first.
    func readPixels(frame: Int = 0) throws -> [Float] {
        let n = header.nx * header.ny
        guard frame >= 0, frame < header.nz else { throw MRCError.truncated }
        let bpp = header.bytesPerPixel
        let start = dataOffset + frame * n * bpp
        guard start + n * bpp <= data.count else { throw MRCError.truncated }
        let le = header.littleEndian
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: start)
            switch header.mode {
            case 2:
                out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: p, count: n * 4)) }
                if !le { for i in 0..<n { out[i] = Float(bitPattern: UInt32(bigEndian: out[i].bitPattern)) } }
                else if Self.hostIsBigEndian { for i in 0..<n { out[i] = Float(bitPattern: UInt32(littleEndian: out[i].bitPattern)) } }
            case 1:
                for i in 0..<n {
                    let v = p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)
                    out[i] = Float(Int16(bitPattern: le ? UInt16(littleEndian: v) : UInt16(bigEndian: v)))
                }
            case 6:
                for i in 0..<n {
                    let v = p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)
                    out[i] = Float(le ? UInt16(littleEndian: v) : UInt16(bigEndian: v))
                }
            case 0:
                for i in 0..<n { out[i] = Float(p.load(fromByteOffset: i, as: Int8.self)) }
            case 12:
                for i in 0..<n {
                    let v = p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)
                    out[i] = halfToFloat(le ? UInt16(littleEndian: v) : UInt16(bigEndian: v))
                }
            default: break
            }
        }
        return out
    }

    private static var hostIsBigEndian: Bool { UInt32(1).bigEndian == 1 }
}

/// Writes a float32 MRC (mode 2) with row 0 first (no flip). Used by tests and optional export.
func writeMRC(url: URL, pixels: [Float], width: Int, height: Int, pixelSizeA: Double?) throws {
    var hdr = [UInt8](repeating: 0, count: 1024)
    func putI(_ i: Int, _ v: Int32) { withUnsafeBytes(of: v.littleEndian) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
    func putF(_ i: Int, _ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
    let pa = Float(pixelSizeA ?? 1)
    var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude, sum = 0.0
    for v in pixels { mn = min(mn, v); mx = max(mx, v); sum += Double(v) }
    let mean = sum / Double(max(pixels.count, 1))
    var ss = 0.0
    for v in pixels { ss += (Double(v) - mean) * (Double(v) - mean) }
    putI(0, Int32(width)); putI(1, Int32(height)); putI(2, 1); putI(3, 2)
    putI(7, Int32(width)); putI(8, Int32(height)); putI(9, 1)
    putF(10, Float(width) * pa); putF(11, Float(height) * pa); putF(12, pa)
    putF(13, 90); putF(14, 90); putF(15, 90)
    putI(16, 1); putI(17, 2); putI(18, 3)
    putF(19, mn); putF(20, mx); putF(21, Float(mean))
    hdr[208] = 0x4D; hdr[209] = 0x41; hdr[210] = 0x50; hdr[211] = 0x20
    hdr[212] = 0x44; hdr[213] = 0x44
    putF(54, Float((ss / Double(max(pixels.count, 1))).squareRoot()))
    var out = Data(hdr)
    pixels.withUnsafeBytes { out.append(contentsOf: $0) }
    try out.write(to: url)
}

/// IEEE half -> float (avoids Float16, which is unavailable on Intel Macs).
func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h >> 15) << 31
    let exp = UInt32((h >> 10) & 0x1F), man = UInt32(h & 0x3FF)
    if exp == 0 {
        if man == 0 { return Float(bitPattern: sign) }
        let v = Float(man) * Float(sign == 0 ? 1 : -1) * 5.9604645e-8   // subnormal: man * 2^-24
        return v
    }
    if exp == 31 { return Float(bitPattern: sign | 0x7F800000 | (man << 13)) }
    return Float(bitPattern: sign | ((exp + 112) << 23) | (man << 13))
}
