import Foundation
import CoreGraphics
import ImageIO

/// Minimal HTTP/1.1 request parsing and response serialization for the phone server.
/// Pure value types and functions (no sockets), so they are covered by `--picktest`.

struct PhoneRequest {
    var method: String
    var path: String                       // without query
    var query: [String: String]
    var headers: [String: String]          // lowercased names
    var body: Data
    var cookies: [String: String]

    init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query
        self.headers = headers; self.body = body
        self.cookies = PhoneRequest.parseCookies(headers["cookie"] ?? "")
    }

    static func parseCookies(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

struct PhoneResponse {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]
    /// Work that must run off the main thread (JPEG rendering); the server calls it and sends its result instead.
    var deferred: (() -> PhoneResponse)?

    static func json(_ obj: Any, status: Int = 200) -> PhoneResponse {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return PhoneResponse(status: status, contentType: "application/json; charset=utf-8", body: d, headers: ["Cache-Control": "no-store"])
    }
    static func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> PhoneResponse {
        PhoneResponse(status: status, contentType: type, body: Data(s.utf8), headers: ["Cache-Control": "no-store"])
    }
    static func error(_ status: Int, _ msg: String) -> PhoneResponse { json(["error": msg], status: status) }
    static let unauthorized = PhoneResponse(status: 401, contentType: "text/plain; charset=utf-8", body: Data(), headers: [:])

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 204: return "No Content"; case 302: return "Found"; case 400: return "Bad Request"
        case 401: return "Unauthorized"; case 404: return "Not Found"; case 405: return "Method Not Allowed"
        case 409: return "Conflict"; case 413: return "Payload Too Large"; case 431: return "Request Header Fields Too Large"
        default: return "Status"
        }
    }

    func serialized() -> Data {
        var h = "HTTP/1.1 \(status) \(PhoneResponse.reason(status))\r\n"
        h += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        h += "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var d = Data(h.utf8); d.append(body); return d
    }
}

enum PhoneParse {
    case incomplete
    case request(PhoneRequest)
    case failure(Int)                      // HTTP status to answer with (400, 413, 431)
}

enum PhoneLimits {
    static let maxHeader = 16 * 1024
    static let maxBody = 64 * 1024
}

/// Parses `buffer` (everything received so far on one connection).
func parsePhoneRequest(_ buffer: Data) -> PhoneParse {
    let sep = Data("\r\n\r\n".utf8)
    guard let r = buffer.range(of: sep) else {
        return buffer.count > PhoneLimits.maxHeader ? .failure(431) : .incomplete
    }
    if r.lowerBound > PhoneLimits.maxHeader { return .failure(431) }
    guard let head = String(data: buffer[buffer.startIndex..<r.lowerBound], encoding: .utf8) else { return .failure(400) }
    let lines = head.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .failure(400) }
    var headers: [String: String] = [:]
    for l in lines.dropFirst() {
        guard let c = l.firstIndex(of: ":") else { return .failure(400) }
        headers[l[l.startIndex..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
    let len = Int(headers["content-length"] ?? "0") ?? -1
    if len < 0 { return .failure(400) }
    if len > PhoneLimits.maxBody { return .failure(413) }
    let bodyStart = r.upperBound
    if buffer.count - bodyStart < len { return .incomplete }
    let body = Data(buffer[bodyStart..<(bodyStart + len)])
    let target = String(parts[1])
    let (rawPath, rawQuery) = splitOnce(target, "?")
    var query: [String: String] = [:]
    for kv in rawQuery.split(separator: "&") {
        let (k, v) = splitOnce(String(kv), "=")
        query[k.removingPercentEncoding ?? k] = v.removingPercentEncoding ?? v
    }
    return .request(PhoneRequest(method: String(parts[0]).uppercased(), path: rawPath.removingPercentEncoding ?? rawPath,
                                 query: query, headers: headers, body: body))
}

private func splitOnce(_ s: String, _ ch: Character) -> (String, String) {
    guard let i = s.firstIndex(of: ch) else { return (s, "") }
    return (String(s[s.startIndex..<i]), String(s[s.index(after: i)...]))
}

/// Encodes an 8-bit gray image as JPEG (ImageIO).
func phoneJPEG(gray bytes: [UInt8], size: Int, quality: Double = 0.82) -> Data? {
    guard let img = grayCGImage(bytes, width: size, height: size) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

/// Constant-time string comparison (tokens).
func phoneTokenEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    for i in 0..<max(x.count, y.count) { diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
    return diff == 0
}
