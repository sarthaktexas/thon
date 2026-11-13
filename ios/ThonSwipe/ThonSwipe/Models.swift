import Foundation

/// Mirror of the JSON the Mac sends. Fields the Mac may omit are optional so a newer or older Thon still decodes.

struct SchemeLabel: Codable, Identifiable, Equatable {
    var id: String, name: String, key: String, color: String
    var shape: String?
    var exported: Bool
}

struct Scheme: Codable, Equatable {
    var rev: String
    var labels: [SchemeLabel]
}

struct LevelInfo: Codable, Equatable {
    var key: String?, name: String?
    var index: Int?, count: Int?, total: Int?, reviewed: Int?, candidates: Int?
    var done: Bool?, empty: Bool?, loading: Bool?, autoBusy: Bool?
}

struct CardInfo: Codable, Equatable {
    var ref: String
    var diameterFrac: Double, boxFrac: Double
    var cross: [Double]
    var windowNm: Double?
    var view: String?
}

struct CountStats: Codable, Equatable {
    var cards: Int?, pick: Int?, reject: Int?, unsure: Int?
    var pickRateReal: Double?, pickRateDecoy: Double?
    var decoySeen: Int?
}

struct StatsPair: Codable, Equatable {
    var level: CountStats
    var all: CountStats
}

struct PhoneState: Codable, Equatable {
    struct Project: Codable, Equatable { var name: String? }
    var v: Int?, rev: Int?
    var project: Project?
    var scheme: Scheme
    var activeLabel: String
    var unsureLabel: String?
    var level: LevelInfo
    var card: CardInfo?
    var upcoming: [String]
    var canUndo: Bool
    var stats: StatsPair

    var exportedLabels: [SchemeLabel] { scheme.labels.filter { $0.exported } }
}

enum Decision: String, Codable, CaseIterable { case pick, reject, unsure, later }

struct DecisionBody: Codable, Equatable {
    var ref: String
    var decision: Decision
    var label: String?
    var u: Double?, v: Double?
    var ms: Int
    var cid: String
}

struct DecisionReply: Codable {
    var applied: Bool?
    var reason: String?
    var state: PhoneState?
}

struct StateReply: Codable { var state: PhoneState? }

struct DroppedDecision: Codable, Equatable {
    var ref: String
    var decision: Decision
    var reason: String
    var at: Date
}
