import Foundation
import CoreGraphics

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
    var boxNm: Double?               // extraction box (nm); overrides the project default when set (size sweeps give each pick its own)
    var maybe: Bool?                 // optional "not sure" flag, independent of the label (nil = not flagged)
    var isMaybe: Bool { maybe == true }

    init(id: String = Pick.newID(), x: Double, y: Double, label: String, score: Float? = nil,
         source: PickSource = .manual, status: PickStatus = .accepted, diameterNm: Double? = nil, maybe: Bool? = nil, boxNm: Double? = nil) {
        self.id = id; self.x = x; self.y = y; self.label = label; self.score = score
        self.source = source; self.status = status; self.diameterNm = diameterNm; self.maybe = maybe; self.boxNm = boxNm
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
        boxNm = try c.decodeIfPresent(Double.self, forKey: .boxNm)
        maybe = (try c.decodeIfPresent(Bool.self, forKey: .maybe)) == true ? true : nil
    }

    static func newID() -> String {
        let a = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<8).map { _ in a[Int.random(in: 0..<a.count)] })
    }
}

/// A rectangle of a micrograph you have finished going through (pick coordinates, x0 < x1, y0 < y1).
/// The crop editor marks one for every confirmed section, or for a region you drag over; the viewer tints them.
struct DoneRegion: Codable, Equatable, Identifiable {
    var id: String
    var x0: Double, y0: Double, x1: Double, y1: Double
    init(id: String = Pick.newID(), x0: Double, y0: Double, x1: Double, y1: Double) {
        self.id = id; self.x0 = min(x0, x1); self.y0 = min(y0, y1); self.x1 = max(x0, x1); self.y1 = max(y0, y1)
    }
    var rect: CGRect { CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
    func contains(x: Double, y: Double) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 }
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
    var session: String?             // .thon projects: session this micrograph is listed / exported under (nil = the session whose folder holds the file)
    var sections: [DoneRegion]?      // crop editor: parts of the micrograph already gone through (nil = none)
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
        session = try c.decodeIfPresent(String.self, forKey: .session)
        sections = try c.decodeIfPresent([DoneRegion].self, forKey: .sections)
    }
}

struct ProjectParams: Codable, Equatable {
    var boxNm = 29.0                 // extraction box (nm), as in the web picker
    var diameterNm = 20.0            // default marker / particle diameter (nm)
    var maybeFlag = false            // opt-in: enables the per-pick "maybe" flag (key ?)
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        boxNm = try c.decodeIfPresent(Double.self, forKey: .boxNm) ?? 29
        diameterNm = try c.decodeIfPresent(Double.self, forKey: .diameterNm) ?? 20
        maybeFlag = try c.decodeIfPresent(Bool.self, forKey: .maybeFlag) ?? false
    }
}

struct PickProject: Codable, Equatable {
    var version = 1
    /// Scheme given to a brand-new project (tests override it).
    static var newProjectScheme = LabelScheme.default
    var scheme = PickProject.newProjectScheme
    var params = ProjectParams()
    var name: String?                          // project title (.thon projects)
    var sessions: [PickSession] = []           // imaging sessions; empty for a plain folder project
    var mics: [String: MicRecord] = [:]
    /// Swipe-assistant training samples (compact JSON, written by `Reranker`). Kept as one opaque blob so the project file
    /// stays small and readable; nil until the assistant has seen a decision.
    var assist: Data?
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scheme = try c.decodeIfPresent(LabelScheme.self, forKey: .scheme) ?? .views   // files written before schemes were stored used the six view labels
        params = try c.decodeIfPresent(ProjectParams.self, forKey: .params) ?? ProjectParams()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        sessions = try c.decodeIfPresent([PickSession].self, forKey: .sessions) ?? []
        mics = try c.decodeIfPresent([String: MicRecord].self, forKey: .mics) ?? [:]
        assist = try c.decodeIfPresent(Data.self, forKey: .assist)
    }
}
