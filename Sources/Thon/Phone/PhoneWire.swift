import Foundation

/// Wire format for phone transports that are not HTTP (Multipeer direct link).
/// Foundation only, no Thon types: this file is compiled into both the Mac app and the iOS app (ios/ThonSwipe).
///
/// A message is `[4-byte big-endian header length][header JSON][body bytes]`. Over a datagram-like channel a message is cut into
/// frames `[4-byte message id][2-byte sequence][2-byte frame count][payload]`; `PhoneReassembler` puts them back together.

struct PhoneWireHead: Codable, Equatable {
    var kind: String                       // "req", "res" or "paired"
    var id: UInt32 = 0                     // request / response pairing
    var method: String? = nil
    var path: String? = nil
    var query: [String: String]? = nil
    var headers: [String: String]? = nil
    var status: Int? = nil
    var contentType: String? = nil
    var token: String? = nil               // "paired": the long-lived token the phone keeps
}

enum PhoneWire {
    static let frameSize = 16 * 1024
    static let frameHeader = 8
    static let maxMessage = 4 * 1024 * 1024

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }

    static func pack(_ head: PhoneWireHead, body: Data = Data()) -> Data {
        let h = (try? JSONEncoder().encode(head)) ?? Data("{}".utf8)
        var d = Data(be32(UInt32(h.count)))
        d.append(h); d.append(body)
        return d
    }

    static func unpack(_ message: Data) -> (head: PhoneWireHead, body: Data)? {
        let b = [UInt8](message.prefix(4))
        guard b.count == 4 else { return nil }
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n >= 2, message.count >= 4 + n else { return nil }
        let headData = Data(message.dropFirst(4).prefix(n))
        guard let head = try? JSONDecoder().decode(PhoneWireHead.self, from: headData) else { return nil }
        return (head, Data(message.dropFirst(4 + n)))
    }

    /// Cuts a packed message into frames (always at least one).
    static func frames(of message: Data, id: UInt32) -> [Data] {
        let size = frameSize
        let total = max(1, (message.count + size - 1) / size)
        precondition(total < 65536, "message too large for 16-bit frame count")
        return (0..<total).map { i in
            var f = Data(be32(id) + be16(UInt16(i)) + be16(UInt16(total)))
            f.append(message.dropFirst(i * size).prefix(size))
            return f
        }
    }
}

/// Collects frames into whole messages. Tolerates reordering and interleaved messages; bounded in memory.
final class PhoneReassembler {
    private struct Partial { var total: Int; var parts: [Int: Data]; var bytes: Int }
    private var open: [UInt32: Partial] = [:]
    private var order: [UInt32] = []
    static let maxOpen = 8

    /// Returns the complete message when `frame` finishes one, else nil. Malformed or oversized input is dropped.
    func feed(_ frame: Data) -> Data? {
        let b = [UInt8](frame.prefix(PhoneWire.frameHeader))
        guard b.count == PhoneWire.frameHeader else { return nil }
        let id = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let seq = Int(b[4]) << 8 | Int(b[5]), total = Int(b[6]) << 8 | Int(b[7])
        let payload = Data(frame.dropFirst(PhoneWire.frameHeader))
        guard total >= 1, seq < total, payload.count <= PhoneWire.frameSize,
              total <= PhoneWire.maxMessage / PhoneWire.frameSize + 1 else { return nil }
        var p = open[id] ?? Partial(total: total, parts: [:], bytes: 0)
        guard p.total == total else { drop(id); return nil }
        if p.parts[seq] == nil { p.parts[seq] = payload; p.bytes += payload.count }
        if p.bytes > PhoneWire.maxMessage { drop(id); return nil }
        if p.parts.count == total {
            drop(id)
            var out = Data()
            for i in 0..<total { out.append(p.parts[i] ?? Data()) }
            return out
        }
        if open[id] == nil {
            order.append(id)
            if order.count > Self.maxOpen { drop(order[0]) }
        }
        open[id] = p
        return nil
    }

    private func drop(_ id: UInt32) { open[id] = nil; order.removeAll { $0 == id } }
}
