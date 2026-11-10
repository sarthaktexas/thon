import Foundation

// MARK: - Errors

enum DMError: LocalizedError {
    case io(String), parse(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .io(let s), .parse(let s), .unsupported(let s): return s
        }
    }
}

// MARK: - Memory-mapped file

final class MappedFile {
    let base: UnsafeRawPointer
    let size: Int

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw DMError.io("Cannot open \(url.lastPathComponent)") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 32 else { throw DMError.io("\(url.lastPathComponent) is too small to be a DM file") }
        let sz = Int(st.st_size)
        let p = mmap(nil, sz, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let p, p != MAP_FAILED else { throw DMError.io("Cannot map \(url.lastPathComponent)") }
        self.base = UnsafeRawPointer(p)
        self.size = sz
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }
}

// MARK: - Values and tag tree

struct DMArray {
    let elementType: Int
    let count: Int
    let offset: Int          // absolute file offset of the first element
    let preview: [DMValue]?  // only for short arrays
}

indirect enum DMValue {
    case int(Int64), uint(UInt64), double(Double), bool(Bool), string(String)
    case array(DMArray)
    case structure([DMValue])

    var asInt: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .uint(let v): return Int(truncatingIfNeeded: v)
        case .double(let v): return v.isFinite ? Int(v) : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var asDouble: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .uint(let v): return Double(v)
        case .double(let v): return v
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var display: String {
        switch self {
        case .int(let v): return String(v)
        case .uint(let v): return String(v)
        case .double(let v): return DMValue.format(v)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .structure(let f): return "(" + f.map { $0.display }.joined(separator: ", ") + ")"
        case .array(let a):
            if let p = a.preview { return "[" + p.map { $0.display }.joined(separator: ", ") + "]" }
            return "array<\(DMValue.typeName(a.elementType))> × \(a.count)"
        }
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e12 { return String(Int64(v)) }
        if !v.isFinite { return v.isNaN ? "nan" : (v > 0 ? "inf" : "-inf") }
        let a = abs(v)
        if a >= 1e6 || a < 1e-4 { return String(format: "%.6g", v) }
        return String(format: "%.6g", v)
    }

    static func typeName(_ t: Int) -> String {
        switch t {
        case 2: return "int16"; case 3: return "int32"; case 4: return "uint16"; case 5: return "uint32"
        case 6: return "float32"; case 7: return "float64"; case 8: return "bool"; case 9: return "char"
        case 10: return "uint8"; case 11: return "int64"; case 12: return "uint64"
        case 15: return "struct"; case 18: return "string"; default: return "type\(t)"
        }
    }
}

final class DMNode {
    let rawName: String
    let index: Int            // position within parent, 0-based
    var children: [DMNode] = []
    var value: DMValue?
    weak var parent: DMNode?

    init(name: String, index: Int) { self.rawName = name; self.index = index }

    var isGroup: Bool { value == nil }
    var name: String { rawName.isEmpty ? String(index + 1) : rawName }

    func child(_ name: String) -> DMNode? { children.first { $0.rawName == name } }

    /// Walk a path of labels; an all-digit component indexes (1-based) among children.
    func node(_ path: [String]) -> DMNode? {
        var cur: DMNode = self
        for comp in path {
            if let c = cur.child(comp) { cur = c; continue }
            if let i = Int(comp), i >= 1, i <= cur.children.count { cur = cur.children[i - 1]; continue }
            return nil
        }
        return cur
    }
    func node(_ path: String...) -> DMNode? { node(path) }
    func val(_ path: String...) -> DMValue? { node(path)?.value }
    func str(_ path: String...) -> String? { node(path)?.value?.asString }
    func num(_ path: String...) -> Double? { node(path)?.value?.asDouble }

    /// Flatten all leaves below this node: (path components, value).
    func leaves(prefix: [String] = []) -> [(path: [String], value: DMValue)] {
        var out: [(path: [String], value: DMValue)] = []
        for c in children {
            let p = prefix + [c.name]
            if let v = c.value { out.append((p, v)) } else { out.append(contentsOf: c.leaves(prefix: p)) }
        }
        return out
    }
}

// MARK: - Parser

struct Cursor {
    let base: UnsafeRawPointer
    let size: Int
    var pos: Int
    var little: Bool

    mutating func need(_ n: Int) throws {
        if n < 0 || pos < 0 || pos + n > size { throw DMError.parse("Unexpected end of file at byte \(pos)") }
    }
    mutating func u8() throws -> UInt8 {
        try need(1); defer { pos += 1 }
        return base.load(fromByteOffset: pos, as: UInt8.self)
    }
    mutating func beU16() throws -> Int {
        try need(2); defer { pos += 2 }
        return Int(UInt16(bigEndian: base.loadUnaligned(fromByteOffset: pos, as: UInt16.self)))
    }
    mutating func beU32() throws -> Int {
        try need(4); defer { pos += 4 }
        return Int(UInt32(bigEndian: base.loadUnaligned(fromByteOffset: pos, as: UInt32.self)))
    }
    mutating func beU64() throws -> Int {
        try need(8); defer { pos += 8 }
        let v = UInt64(bigEndian: base.loadUnaligned(fromByteOffset: pos, as: UInt64.self))
        guard v < UInt64(Int.max) else { throw DMError.parse("Implausible 64-bit length at byte \(pos - 8)") }
        return Int(v)
    }
    mutating func load<T: FixedWidthInteger>(_ t: T.Type) throws -> T {
        try need(MemoryLayout<T>.size); defer { pos += MemoryLayout<T>.size }
        let raw = base.loadUnaligned(fromByteOffset: pos, as: T.self)
        return little ? T(littleEndian: raw) : T(bigEndian: raw)
    }
}

enum DMTypes {
    static func elementSize(_ t: Int) -> Int? {
        switch t {
        case 2, 4: return 2
        case 3, 5, 6: return 4
        case 7, 11, 12: return 8
        case 8, 9, 10: return 1
        default: return nil
        }
    }
}

final class DMFile {
    let url: URL
    let map: MappedFile
    let version: Int
    let littleEndian: Bool
    let root: DMNode
    private(set) var images: [DMImageEntry] = []

    private var cur: Cursor
    private var v4: Bool { version == 4 }

    init(url: URL) throws {
        self.url = url
        let m = try MappedFile(url: url)
        self.map = m
        var c = Cursor(base: m.base, size: m.size, pos: 0, little: false)
        let ver = try c.beU32()
        guard ver == 3 || ver == 4 else { throw DMError.parse("Not a DM3/DM4 file (version field = \(ver))") }
        self.version = ver
        _ = ver == 4 ? try c.beU64() : try c.beU32()   // root length
        let order = try c.beU32()
        c.little = (order == 1)
        self.littleEndian = c.little
        self.root = DMNode(name: "", index: 0)
        self.cur = c
        try readGroup(into: root, depth: 0)
        self.images = DMImageEntry.extract(from: self)
    }

    // MARK: group / tag

    private func readGroup(into node: DMNode, depth: Int) throws {
        guard depth < 64 else { throw DMError.parse("Tag nesting too deep") }
        _ = try cur.u8()                // sorted
        _ = try cur.u8()                // open
        let n = v4 ? try cur.beU64() : try cur.beU32()
        guard n >= 0, n < 5_000_000 else { throw DMError.parse("Implausible tag count \(n)") }
        for i in 0..<n {
            let kind = try cur.u8()
            let labelLen = try cur.beU16()
            try cur.need(labelLen)
            let label = DMFile.decodeLabel(cur.base + cur.pos, labelLen)
            cur.pos += labelLen
            if v4 { _ = try cur.beU64() }          // tag byte size (unused)
            let child = DMNode(name: label, index: i)
            child.parent = node
            switch kind {
            case 20:
                try readGroup(into: child, depth: depth + 1)
            case 21:
                child.value = try readTagValue()
            default:
                throw DMError.parse("Unknown tag kind \(kind) at byte \(cur.pos)")
            }
            node.children.append(child)
        }
    }

    private static func decodeLabel(_ p: UnsafeRawPointer, _ n: Int) -> String {
        let d = Data(bytes: p, count: n)
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .macOSRoman) ?? String(data: d, encoding: .isoLatin1) ?? ""
    }

    private func readInfoInt() throws -> Int { v4 ? try cur.beU64() : try cur.beU32() }

    private func readTagValue() throws -> DMValue {
        try cur.need(4)
        guard memcmp(cur.base + cur.pos, "%%%%", 4) == 0 else { throw DMError.parse("Missing %%%% delimiter at byte \(cur.pos)") }
        cur.pos += 4
        let nInfo = try readInfoInt()
        guard nInfo > 0, nInfo < 4096 else { throw DMError.parse("Implausible info array length \(nInfo)") }
        var info: [Int] = []
        info.reserveCapacity(nInfo)
        for _ in 0..<nInfo { info.append(try readInfoInt()) }

        switch info[0] {
        case 15:   // struct: [15, nameLen, nFields, (fieldNameLen, type)*]
            guard info.count >= 3 else { throw DMError.parse("Bad struct info") }
            let nf = info[2]
            var fields: [DMValue] = []
            for i in 0..<nf {
                guard 4 + 2 * i < info.count else { break }
                fields.append(try readScalar(info[4 + 2 * i]))
            }
            return .structure(fields)
        case 18:   // string: [18, nChars]
            guard info.count >= 2 else { throw DMError.parse("Bad string info") }
            return .string(try readUTF16(info[1]))
        case 20:   // array
            guard info.count >= 3 else { throw DMError.parse("Bad array info") }
            if info[1] == 15 {   // array of structs: [20, 15, nameLen, nFields, (len,type)*, count]
                let nf = info[3]
                var types: [Int] = []
                for i in 0..<nf where 5 + 2 * i < info.count { types.append(info[5 + 2 * i]) }
                let count = info.last!
                let stride = types.reduce(0) { $0 + (DMTypes.elementSize($1) ?? 0) }
                let off = cur.pos
                try cur.need(stride * count)
                cur.pos += stride * count
                return .array(DMArray(elementType: 15, count: count, offset: off, preview: nil))
            }
            if info[1] == 20 { throw DMError.unsupported("Nested arrays are not supported") }
            return try readArray(type: info[1], count: info[2])
        default:
            return try readScalar(info[0])
        }
    }

    private func readScalar(_ t: Int) throws -> DMValue {
        switch t {
        case 2: return .int(Int64(try cur.load(Int16.self)))
        case 3: return .int(Int64(try cur.load(Int32.self)))
        case 4: return .uint(UInt64(try cur.load(UInt16.self)))
        case 5: return .uint(UInt64(try cur.load(UInt32.self)))
        case 6: return .double(Double(Float(bitPattern: try cur.load(UInt32.self))))
        case 7: return .double(Double(bitPattern: try cur.load(UInt64.self)))
        case 8: return .bool(try cur.u8() != 0)
        case 9: return .uint(UInt64(try cur.u8()))
        case 10: return .uint(UInt64(try cur.u8()))
        case 11: return .int(try cur.load(Int64.self))
        case 12: return .uint(try cur.load(UInt64.self))
        default: throw DMError.unsupported("Unsupported tag data type \(t) at byte \(cur.pos)")
        }
    }

    private func readUTF16(_ n: Int) throws -> String {
        try cur.need(2 * n)
        var units = [UInt16](repeating: 0, count: n)
        for i in 0..<n { units[i] = try cur.load(UInt16.self) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private func readArray(type: Int, count: Int) throws -> DMValue {
        guard let es = DMTypes.elementSize(type) else { throw DMError.unsupported("Unsupported array element type \(type)") }
        let start = cur.pos
        try cur.need(es * count)
        // Short uint16 arrays holding printable characters are UTF-16 strings in DM files
        if type == 4, count == 0 { return .string("") }
        if type == 4, count > 0, count <= 4096 {
            var ok = true
            var units = [UInt16](repeating: 0, count: count)
            for i in 0..<count {
                let u = cur.little ? UInt16(littleEndian: cur.base.loadUnaligned(fromByteOffset: start + 2 * i, as: UInt16.self))
                                   : UInt16(bigEndian: cur.base.loadUnaligned(fromByteOffset: start + 2 * i, as: UInt16.self))
                units[i] = u
                if !(u >= 32 && u < 256) && !(u == 0 && i == count - 1) && u != 10 && u != 13 && u != 9 { ok = false; break }
            }
            if ok {
                cur.pos = start + es * count
                while units.last == 0 { units.removeLast() }
                return .string(String(decoding: units, as: UTF16.self))
            }
        }
        var preview: [DMValue]? = nil
        if count <= 32 {
            var p: [DMValue] = []
            for _ in 0..<count { p.append(try readScalar(type)) }
            preview = p
        }
        cur.pos = start + es * count
        return .array(DMArray(elementType: type, count: count, offset: start, preview: preview))
    }

    // MARK: convenience

    var allLeaves: [(path: [String], value: DMValue)] { root.leaves() }
}
