import Foundation

enum PickSource: String, Codable { case manual, auto }

/// candidate = ghost from the auto-picker (undecided); accepted = a real pick; dismissed = candidate the user removed
/// (kept so re-running the auto-picker does not bring it back; never exported as a pick).
enum PickStatus: String, Codable { case candidate, accepted, dismissed }

/// One particle. (x, y) are native pixels of the micrograph array, origin top-left (row = y, column = x).
struct Pick: Codable, Identifiable, Equatable {
    var id: String
    var x: Double
    var y: Double
    var label: String
    var score: Float?
    var source: PickSource
    var status: PickStatus
    var diameterNm: Double?          // overrides the project default when set

    init(id: String = Pick.newID(), x: Double, y: Double, label: String, score: Float? = nil,
         source: PickSource = .manual, status: PickStatus = .accepted, diameterNm: Double? = nil) {
        self.id = id; self.x = x; self.y = y; self.label = label; self.score = score
        self.source = source; self.status = status; self.diameterNm = diameterNm
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Pick.newID()
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "particle"
        score = try c.decodeIfPresent(Float.self, forKey: .score)
        source = try c.decodeIfPresent(PickSource.self, forKey: .source) ?? .manual
        status = try c.decodeIfPresent(PickStatus.self, forKey: .status) ?? .accepted
        diameterNm = try c.decodeIfPresent(Double.self, forKey: .diameterNm)
    }

    static func newID() -> String {
        let a = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<8).map { _ in a[Int.random(in: 0..<a.count)] })
    }
}

/// Per-micrograph record in the project file.
struct MicRecord: Codable, Equatable {
    var done = false
    var note = ""
    var picks: [Pick] = []
    var auto: AutoParams?            // parameters of the last auto-pick run
    var width: Int?                  // micrograph size and pixel size, recorded when the micrograph is opened
    var height: Int?
    var angpix: Double?
    var swipe: SwipeLog?             // card-deck review decisions (statistics / audit)
    init() {}
    init(from d: Decoder) throws {   // tolerant: hand-edited / older files may omit fields
        let c = try d.container(keyedBy: CodingKeys.self)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        picks = try c.decodeIfPresent([Pick].self, forKey: .picks) ?? []
        auto = try c.decodeIfPresent(AutoParams.self, forKey: .auto)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        angpix = try c.decodeIfPresent(Double.self, forKey: .angpix)
        swipe = try c.decodeIfPresent(SwipeLog.self, forKey: .swipe)
    }
}

struct ProjectParams: Codable, Equatable {
    var boxNm = 29.0                 // extraction box (nm), as in the web picker
    var diameterNm = 20.0            // default marker / particle diameter (nm)
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        boxNm = try c.decodeIfPresent(Double.self, forKey: .boxNm) ?? 29
        diameterNm = try c.decodeIfPresent(Double.self, forKey: .diameterNm) ?? 20
    }
}

struct PickProject: Codable, Equatable {
    var version = 1
    var scheme = LabelScheme.default
    var params = ProjectParams()
    var mics: [String: MicRecord] = [:]
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scheme = try c.decodeIfPresent(LabelScheme.self, forKey: .scheme) ?? .default
        params = try c.decodeIfPresent(ProjectParams.self, forKey: .params) ?? ProjectParams()
        mics = try c.decodeIfPresent([String: MicRecord].self, forKey: .mics) ?? [:]
    }
}
