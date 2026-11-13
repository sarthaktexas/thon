import Foundation
import Combine
import CoreGraphics

// Crop editor, built into the main viewer: the micrograph is cut into overlapping sections and the viewer is taken to one
// at a time (everything outside it is dimmed). The user moves, resizes, adds and removes circles and gives each one a type
// from the project's label scheme (a label hotkey, or the type list); the circle is drawn in the colour of its type. A double
// click or a right click on a circle removes it (= reject). Done confirms the section: circles left alone count as confirmed,
// so every circle in the section becomes a labelled example for the assistant (Reranker's logistic model and the Core ML
// classifier). A confirmed section is remembered in the project (`MicRecord.sections`) and tinted in the viewer. A region
// dragged over ground you already know is finished is confirmed the same way.

final class CropSession: ObservableObject {
    /// Derived from the type, never set on its own: the labels "maybe" and "uncertain" count as maybe (half weight when learning).
    enum Level: String { case sure, maybe }
    static func isMaybeLabel(_ id: String) -> Bool { id == "maybe" || id == "uncertain" }
    enum Order: String, CaseIterable, Identifiable { case uncertain = "Uncertain first", scan = "Left to right"; var id: String { rawValue } }

    struct Item: Identifiable, Equatable {
        var id: String
        var x: Double, y: Double
        var diameterNm: Double
        var level: Level
        var label: String
        var isNew: Bool
        var untouched: Bool                 // a suggestion nobody has edited yet (drawn dashed)
        var removed = false
        var orig: Pick?                     // the pick as found (nil for circles added here)
    }
    struct Tile: Equatable, Identifiable { var id: Int; var cx: Double; var cy: Double }

    private struct CommitRecord {
        var tile: Tile?; var key: String; var serial: Int?; var logged: Int
        var sampleIDs: [String]; var fileNames: [String]; var items: [Item]; var section: String
    }
    /// What the pointer is doing between mouse down and mouse up (see `pointerDown`).
    private enum Gesture {
        case none
        case item(id: String, origin: CGPoint, start: CGPoint, moved: Bool)
        case empty(start: CGPoint, moved: Bool)
        case region(start: CGPoint)
    }
    /// What the viewer should do with a mouse drag: pan the image, nothing yet, or the crop editor took it.
    enum DragResult { case pan, none, handled }

    unowned let pc: PickController
    var sw: SwipeSession { pc.swipe }
    var rr: Reranker { pc.swipe.reranker }
    let classifier = CropClassifier()

    @Published private(set) var queue: [Tile] = []
    @Published private(set) var tilesTotal = 0
    @Published private(set) var items: [Item] = []
    @Published var selected: String?
    /// View schemes only: resizing a circle also sets its type to the view whose typical size is closest (see `SizeTyper`).
    @Published var sizeTyping = UserDefaults.standard.bool(forKey: "crop.sizeTyping") { didSet { UserDefaults.standard.set(sizeTyping, forKey: "crop.sizeTyping") } }
    @Published private(set) var sizeTyper: SizeTyper?
    @Published var penNm: Double = 0                         // size of the next circle you add (0 until the project default is read)
    /// On while the crop editor owns the viewer: the viewer shows one section at a time and a click edits circles.
    @Published var active = false {
        didSet {
            guard active != oldValue else { return }
            if active {
                if !pc.enabled { pc.enabled = true }
                rebuild()
            } else {
                selected = nil; gesture = .none; regionRect = nil; regionTool = false
                view?.fit()
            }
        }
    }
    /// Plain drags mark a region done (instead of panning); Option-drag does the same for one drag.
    @Published var regionTool = false
    /// Rubber band of the region being dragged, pick coordinates.
    @Published private(set) var regionRect: CGRect?
    /// The viewer this session frames sections in (set by the app model).
    weak var view: ViewState? { didSet { view?.sectionFrame = { [weak self] in self?.frameTarget() } } }
    @Published var sideDiameters = 5.0 { didSet { if sideDiameters != oldValue { sideDiameters = min(max(sideDiameters, 2), 12); if sideDiameters != oldValue { rebuild() } } } }
    @Published var includeEmpty = false { didSet { if includeEmpty != oldValue { rebuild() } } }
    @Published var order = Order.uncertain { didSet { if order != oldValue { reorder() } } }
    @Published private(set) var revision = 0
    var reviewedCount: Int { max(0, tilesTotal - queue.count) }
    private(set) var shownAt = Date()
    /// A tile counts as finished when this much of it lies inside confirmed sections.
    static let doneCoverage = 0.9

    private var key: String?
    private var keptTiles: [Tile] = []
    private var gesture = Gesture.none
    private var lastClick: (id: String, at: Date)?
    private var editHistory: [[Item]] = []
    private var commits: [CommitRecord] = []
    private var orderToken = 0
    private let work = DispatchQueue(label: "thon.crops.order", qos: .utility)
    private var bag = Set<AnyCancellable>()

    init(pc: PickController) {
        self.pc = pc
        classifier.onChange = { [weak self] in self?.reorder() }
        classifier.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    // MARK: geometry

    var defaultDiameterNm: Double { pc.store.project.params.diameterNm }
    var defaultDiameterPx: Double { defaultDiameterNm * 10 / pc.effectiveAngpix }
    var sidePx: Double {
        let cap = max(1, min(pc.imageSize.width, pc.imageSize.height))
        return min(max(64, sideDiameters * defaultDiameterPx), cap)
    }
    var windowPx: Double { sidePx }
    var current: Tile? { queue.first }
    var done: Bool { queue.isEmpty }
    var remaining: Int { queue.count }
    var canUndo: Bool { !editHistory.isEmpty || !commits.isEmpty }
    /// The section on screen, in pick coordinates.
    var currentRect: CGRect? { current.map { tileRect($0) } }
    func tileRect(_ t: Tile) -> CGRect { CGRect(x: t.cx - sidePx / 2, y: t.cy - sidePx / 2, width: sidePx, height: sidePx) }
    /// Sections already confirmed on the current micrograph.
    var sections: [DoneRegion] { key.map { pc.store.sections($0) } ?? [] }

    /// Share of `r` (0...1) that lies inside the regions, estimated on a 14 × 14 grid of sample points.
    static func coverage(of r: CGRect, in regions: [DoneRegion]) -> Double {
        guard !regions.isEmpty, r.width > 0, r.height > 0 else { return 0 }
        let n = 14
        var hit = 0
        for j in 0..<n { for i in 0..<n {
            let x = r.minX + (Double(i) + 0.5) / Double(n) * r.width, y = r.minY + (Double(j) + 0.5) / Double(n) * r.height
            if regions.contains(where: { $0.contains(x: x, y: y) }) { hit += 1 }
        } }
        return Double(hit) / Double(n * n)
    }

    /// Where the viewer should look for the current section (centre in viewer coordinates, drawable pixels per image pixel),
    /// or nil when the editor is off or nothing is queued.
    func frameTarget() -> (center: CGPoint, zoom: Double)? {
        guard active, let t = current, let v = view, v.viewPixels.width > 1 else { return nil }
        let z = 0.9 * Double(min(v.viewPixels.width, v.viewPixels.height)) / sidePx
        return (CGPoint(x: t.cx + 0.5, y: t.cy + 0.5), min(max(z, 0.01), 256))
    }
    /// Takes the viewer to the current section.
    func frame() { if let f = frameTarget(), let v = view { v.center = f.center; v.zoom = f.zoom } }

    /// Pick-coordinate position of a point at fractions (u, v) of the current crop (origin top-left).
    func point(u: Double, v: Double) -> CGPoint? {
        guard let t = current else { return nil }
        return CGPoint(x: t.cx + (u - 0.5) * windowPx, y: t.cy + (v - 0.5) * windowPx)
    }
    func px(_ nm: Double) -> Double { nm * 10 / pc.effectiveAngpix }

    // MARK: types and size typing

    /// Labels that name a kind of particle (top, side, …) rather than a confidence or a rejection.
    var viewLabelIDs: [String] {
        pc.store.scheme.labels.filter { $0.exported && !Self.isMaybeLabel($0.id) && $0.id != "good" && $0.id != "reject" }.map { $0.id }
    }
    var isViewScheme: Bool { viewLabelIDs.count >= 2 }
    /// Types you can give a circle. Reject is not one of them: deleting a circle is the only way to reject it
    /// (a circle the picker found counts as a "no" for the assistant; a circle you added just goes away).
    var typeLabels: [PickLabel] { pc.store.scheme.labels.filter { $0.exported } }
    func isAssignable(_ id: String) -> Bool { pc.store.scheme.label(id)?.exported != false }
    /// The type of the next circle you add: the active type, unless that one is not an exported type (then the first exported one).
    var penLabelID: String { isAssignable(pc.activeLabel) ? pc.activeLabel : (typeLabels.first?.id ?? pc.activeLabel) }
    /// Candidates carry whatever label was active when the picker ran, which may have been Reject; here they take the pen type.
    private func normalized(_ it: Item) -> Item {
        var i = it
        if !isAssignable(i.label) { i.label = penLabelID; i.level = Self.isMaybeLabel(i.label) ? .maybe : .sure }
        return i
    }

    /// Learns the typical size of each view from the circles you sized by hand (picks with their own diameter) across the project.
    func refreshSizeTyper() {
        guard isViewScheme else { sizeTyper = nil; return }
        let ids = Set(viewLabelIDs)
        var samples: [(String, Double)] = []
        for rec in pc.store.project.mics.values {
            for p in rec.picks where p.status == .accepted && !p.isMaybe && ids.contains(p.label) { if let d = p.diameterNm { samples.append((p.label, d)) } }
        }
        sizeTyper = SizeTyper.learn(samples)
    }
    /// The view for a circle of this size, or nil when size typing is off, not learned yet, or the circle is not of a view type.
    private func typeFromSize(_ nm: Double, current: String) -> String? {
        guard sizeTyping, isViewScheme, viewLabelIDs.contains(current), let t = sizeTyper else { return nil }
        return t.label(forNm: nm)
    }

    // MARK: tiles

    static func centres(length: Double, side: Double) -> [Double] {
        guard length > side else { return [length / 2] }
        let step = side * 0.75
        var out: [Double] = [], c = side / 2
        while c + side / 2 < length - 0.5 { out.append(c); c += step }
        out.append(length - side / 2)
        if out.count > 1, out[out.count - 1] - out[out.count - 2] < 0.3 * side { out.remove(at: out.count - 2) }
        return out
    }

    func relevant(_ p: Pick) -> Bool {
        (p.status == .accepted && isAssignable(p.label)) || (p.status == .candidate && (p.score ?? .infinity) >= pc.scoreCutoff)
    }

    func allTiles() -> [Tile] {
        let w = pc.imageSize.width, h = pc.imageSize.height
        guard w > 0, h > 0 else { return [] }
        let s = sidePx
        var out: [Tile] = []
        for cy in Self.centres(length: h, side: s) { for cx in Self.centres(length: w, side: s) { out.append(Tile(id: out.count, cx: cx, cy: cy)) } }
        return out
    }

    func picksIn(_ t: Tile, window: Double? = nil, key k: String) -> [Pick] {
        let half = (window ?? sidePx) / 2
        return pc.store.picks(k).filter { relevant($0) && abs($0.x - t.cx) <= half && abs($0.y - t.cy) <= half }
    }

    func rebuild() {
        guard let k = pc.currentKey, pc.imageSize.width > 0 else { queue = []; tilesTotal = 0; items = []; key = nil; return }
        key = k
        rr.use(store: pc.store); classifier.use(project: pc.store.projectURL)
        refreshSizeTyper()
        let all = allTiles()
        keptTiles = includeEmpty ? all : all.filter { !picksIn($0, key: k).isEmpty }
        tilesTotal = keptTiles.count
        let regions = pc.store.sections(k)
        queue = keptTiles.filter { Self.coverage(of: tileRect($0), in: regions) < Self.doneCoverage }
        editHistory = []; commits = []; lastClick = nil
        if penNm <= 0 { penNm = defaultDiameterNm }
        loadItems(); reorder(includeFirst: true)
    }

    /// Drops the tiles that confirmed sections now cover. `restoring` tiles (a take-back) go first; the crop on screen stays
    /// while it holds edits you have not confirmed. Everything else keeps its order.
    private func requeue(restoring: Tile? = nil) {
        guard let k = key else { return }
        let regions = pc.store.sections(k)
        let oldHead = queue.first
        let pos = Dictionary(uniqueKeysWithValues: queue.enumerated().map { ($1.id, $0) })
        var q = keptTiles.filter { t in
            if t == restoring { return true }
            if t == oldHead, hasEdits { return true }
            return Self.coverage(of: tileRect(t), in: regions) < Self.doneCoverage
        }
        q.sort { (t, u) in
            let a = t == restoring ? -2 : (pos[t.id] ?? -1), b = u == restoring ? -2 : (pos[u.id] ?? -1)
            return a != b ? a < b : t.id < u.id
        }
        queue = q
    }
    /// True once something on the crop on screen was changed and not yet confirmed.
    var hasEdits: Bool { items.contains { !$0.untouched || $0.removed || $0.isNew } }

    private func loadItems() {
        selected = nil; editHistory = []; items = []
        if let t = current, let k = key {
            items = picksIn(t, window: windowPx, key: k).map { p in var i = Self.item(from: p); i.diameterNm = pc.store.diameterNm(p); return normalized(i) }
        }
        shownAt = Date(); revision += 1; sw.viewChanged()
        if active { frame() }
    }

    static func item(from p: Pick) -> Item {
        Item(id: p.id, x: p.x, y: p.y, diameterNm: p.diameterNm ?? 0, level: (p.isMaybe || isMaybeLabel(p.label)) ? .maybe : .sure, label: p.label,
             isNew: false, untouched: p.status == .candidate, orig: p)
    }

    // MARK: ordering (uncertain first)

    /// Puts the remaining crops in order of how unsure the model is about their candidates (most unsure first). The crop on
    /// screen stays first unless `includeFirst` (a fresh start, nothing edited yet). Without a model the order is left to right.
    func reorder(includeFirst: Bool = false) {
        guard let k = key, queue.count > (includeFirst ? 1 : 2) else { objectWillChange.send(); return }
        if order == .scan || (rr.model == nil && !(classifier.ready && classifier.enabled)) {
            let head = includeFirst ? [] : [queue[0]], rest = includeFirst ? queue : Array(queue.dropFirst())
            let new = head + rest.sorted { $0.id < $1.id }
            if new != queue { let changedFirst = new.first != queue.first; queue = new; if includeFirst && changedFirst { loadItems() } }
            return
        }
        orderToken += 1
        let token = orderToken
        let side = sidePx
        let cands = pc.store.candidates(k).filter { relevant($0) }
        let pixels = pc.pixels, w = Int(pc.imageSize.width), h = Int(pc.imageSize.height)
        let dPx = defaultDiameterPx
        let model = rr.model, useE = rr.modelUsesEmbedding
        let win = sw.displayWindow()
        let cm = classifier
        let eh = min(96, max(16, Int((1.25 * dPx).rounded())))
        work.async { [weak self] in
            var u: [String: Float] = [:]
            for c in cands {
                var p: Float?
                if cm.ready, cm.enabled { p = cm.probability(gray: Self.gray(pixels, w, h, c.x, c.y, dPx, lo: win.lo, hi: win.hi)) }
                if p == nil, let m = model, let hand = CardFeatures.hand(pixels: pixels, width: w, height: h, cx: c.x, cy: c.y, diameterPx: dPx) {
                    if useE {
                        let bytes = renderCrop(pixels: pixels, width: w, height: h, cx: c.x, cy: c.y, half: eh, lo: Double(win.lo), hi: Double(win.hi))
                        if let e = CoreMLEmbedding.embed(gray: bytes, size: 2 * eh) { p = m.probability(hand + e) }
                    } else { p = m.probability(hand) }
                }
                if let p { u[c.id] = 1 - abs(2 * p - 1) }
            }
            DispatchQueue.main.async {
                guard let self, token == self.orderToken, self.queue.count > (includeFirst ? 1 : 2) else { return }
                let pinFirst = !includeFirst || !self.editHistory.isEmpty
                let oldFirst = self.queue.first
                let head = pinFirst ? [self.queue[0]] : [], rest = pinFirst ? Array(self.queue.dropFirst()) : self.queue
                func score(_ t: Tile) -> Float {
                    let half = side / 2
                    return cands.filter { abs($0.x - t.cx) <= half && abs($0.y - t.cy) <= half }.compactMap { u[$0.id] }.max() ?? -1
                }
                self.queue = head + rest.sorted { (score($0), -$0.id) > (score($1), -$1.id) }
                if !pinFirst, self.queue.first != oldFirst { self.loadItems() }
            }
        }
    }

    // MARK: image

    /// Crop 2.5 particle diameters wide around (x, y), resampled to the Core ML input size, for the Core ML classifier.
    static func gray(_ pixels: [Float], _ w: Int, _ h: Int, _ x: Double, _ y: Double, _ dPx: Double, lo: Float, hi: Float) -> [UInt8] {
        let n = CropClassifier.side, half = 1.25 * max(dPx, 4), step = 2 * half / Double(n)
        let span = max(hi - lo, 1e-12)
        var out = [UInt8](repeating: 0, count: n * n)
        for j in 0..<n { for i in 0..<n {
            let v = CardFeatures.bilinear(pixels, w, h, x - half + (Double(i) + 0.5) * step, y - half + (Double(j) + 0.5) * step)
            out[j * n + i] = UInt8(min(max((v - lo) / span, 0), 1) * 255 + 0.5)
        } }
        return out
    }

    // MARK: editing (every change can be undone with Z)

    func beginEdit() { editHistory.append(items); if editHistory.count > 200 { editHistory.removeFirst() } }

    func hit(x: Double, y: Double, tolerancePx: Double) -> Item? {
        guard let t = current else { return nil }
        let half = windowPx / 2
        var best: (Item, Double)?
        for it in items where !it.removed && abs(it.x - t.cx) <= half + 1 && abs(it.y - t.cy) <= half + 1 {
            let r = max(px(it.diameterNm) / 2, tolerancePx), d = hypot(it.x - x, it.y - y)
            guard d <= r else { continue }
            let norm = d / r
            if best == nil || norm < best!.1 { best = (it, norm) }
        }
        return best?.0
    }

    @discardableResult func add(x: Double, y: Double) -> String? {
        guard pc.inside(CGPoint(x: x, y: y)) else { return nil }
        beginEdit()
        let (cx, cy) = (min(max(x, 0), pc.imageSize.width - 1), min(max(y, 0), pc.imageSize.height - 1))
        let nm = penNm > 0 ? penNm : defaultDiameterNm
        let label = penNm > 0 ? (typeFromSize(nm, current: penLabelID) ?? penLabelID) : penLabelID
        let it = Item(id: Pick.newID(), x: cx, y: cy, diameterNm: nm, level: Self.isMaybeLabel(label) ? .maybe : .sure, label: label,
                      isNew: true, untouched: false, removed: false, orig: nil)
        items.append(it); selected = it.id; revision += 1
        return it.id
    }
    func move(_ id: String, to p: CGPoint) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].x = min(max(p.x, 0), pc.imageSize.width - 1); items[i].y = min(max(p.y, 0), pc.imageSize.height - 1); items[i].untouched = false
    }
    /// Resizing remembers the size for the next circle you add (handy for a run of large particles).
    func setDiameter(_ id: String, nm: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let v = min(max(nm, defaultDiameterNm * 0.2), defaultDiameterNm * 6)
        items[i].diameterNm = v; items[i].untouched = false; penNm = v
        if let l = typeFromSize(v, current: items[i].label), l != items[i].label {
            items[i].label = l; items[i].level = Self.isMaybeLabel(l) ? .maybe : .sure
            if pc.activeLabel != l { pc.activeLabel = l }                  // the next circle you add is of the same kind
        }
    }
    /// The one place a circle's type changes (right-click menu, hotkeys, the type list, Space). The level follows from it.
    func setLabel(_ id: String, _ label: String) {
        guard isAssignable(label), let i = items.firstIndex(where: { $0.id == id }), items[i].label != label || items[i].untouched else { return }
        beginEdit(); items[i].label = label; items[i].level = Self.isMaybeLabel(label) ? .maybe : .sure; items[i].untouched = false
    }
    /// Reject: a circle you added disappears; a suggestion is dismissed when the crop is confirmed.
    func remove(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        beginEdit()
        if items[i].isNew { items.remove(at: i) } else { items[i].removed = true }
        if selected == id { selected = nil }
        revision += 1
    }
    /// Space: the next type in the scheme (wraps around).
    func cycleLabel(_ id: String) {
        let ls = typeLabels
        guard !ls.isEmpty, let it = items.first(where: { $0.id == id }) else { return }
        let i = ls.firstIndex { $0.id == it.label } ?? -1
        let next = ls[(i + 1) % ls.count].id
        setLabel(id, next); pc.activeLabel = next
    }
    /// Z: take back the last edit; with none left on this crop, take back the last confirmed crop.
    func undo() {
        if let h = editHistory.popLast() { items = h; if let s = selected, !items.contains(where: { $0.id == s && !$0.removed }) { selected = nil }; revision += 1; return }
        undoCommit()
    }

    var visibleItems: [Item] {
        guard let t = current else { return [] }
        let half = windowPx / 2
        return items.filter { !$0.removed && abs($0.x - t.cx) <= half + 1 && abs($0.y - t.cy) <= half + 1 }
    }
    var counts: (sure: Int, maybe: Int, removed: Int) {
        let v = items
        return (v.filter { !$0.removed && $0.level == .sure }.count, v.filter { !$0.removed && $0.level == .maybe }.count, v.filter { $0.removed && !$0.isNew }.count)
    }

    // MARK: confirm

    /// Done: confirms the section on screen (see `confirm`).
    func commit() {
        guard let t = current else { return }
        confirm(items: items, area: tileRect(t), tile: t, name: "Crop \(reviewedCount + 1)")
    }

    /// Confirms a region you dragged over ground you know is finished. The circles in it (the ones on screen with your edits,
    /// and every other pick of the region) are confirmed like those of a section; circles outside it stay as they are.
    func markRegionDone(_ r: CGRect) {
        guard let k = key ?? pc.currentKey, r.width >= 8, r.height >= 8 else { return }
        let bounds = CGRect(x: -0.5, y: -0.5, width: pc.imageSize.width, height: pc.imageSize.height)
        let box = r.intersection(bounds)
        guard !box.isNull, box.width >= 8, box.height >= 8 else { return }
        func inside(_ x: Double, _ y: Double) -> Bool { x >= box.minX && x <= box.maxX && y >= box.minY && y <= box.maxY }
        var all = items.filter { inside($0.x, $0.y) }
        let have = Set(items.map { $0.id })
        for p in pc.store.picks(k) where relevant(p) && inside(p.x, p.y) && !have.contains(p.id) {
            var i = Self.item(from: p); i.diameterNm = pc.store.diameterNm(p); all.append(normalized(i))
        }
        confirm(items: all, area: box, tile: nil, name: "Mark region done")
    }

    /// Applies every circle to the picks (one undoable store edit), logs it, teaches the assistant and records `area` as a
    /// confirmed section of the micrograph.
    private func confirm(items all: [Item], area: CGRect, tile t: Tile?, name: String) {
        guard let k = key ?? pc.currentKey else { return }
        let defNm = defaultDiameterNm
        func sized(_ d: Double) -> Double? { abs(d - defNm) > 1e-6 ? d : nil }
        if all.contains(where: { !$0.removed && $0.level == .maybe }), !pc.store.project.params.maybeFlag {
            var p = pc.store.project.params; p.maybeFlag = true; pc.store.setParams(p)            // so the yellow ones show as ? and can be left out of an export
        }
        let changed = pc.store.perform(k, name) { l in
            for it in all {
                let maybe: Bool? = it.level == .maybe ? true : nil
                if it.isNew {
                    if it.removed { continue }
                    l.append(Pick(id: it.id, x: it.x, y: it.y, label: it.label, score: nil, source: .manual, status: .accepted, diameterNm: sized(it.diameterNm), maybe: maybe))
                } else if let i = l.firstIndex(where: { $0.id == it.id }) {
                    if it.removed { if l[i].source == .manual { l.remove(at: i) } else { l[i].status = .dismissed } }
                    else { l[i].status = .accepted; l[i].x = it.x; l[i].y = it.y; l[i].label = it.label; l[i].maybe = maybe; l[i].diameterNm = sized(it.diameterNm) }
                }
            }
        }
        let serial = changed ? pc.store.topSerial(k) : nil

        // log (marks the circles as sorted) and training examples
        let dwell = Int(Date().timeIntervalSince(shownAt) * 1000), now = Date().timeIntervalSince1970
        var log = pc.store.record(k).swipe ?? SwipeLog()
        var logged = 0
        var sampleIDs: [String] = [], files: [String] = []
        let win = sw.displayWindow()
        let useE = rr.useEmbedding
        func teach(_ id: String, x: Double, y: Double, dNm: Double, yes: Bool, weight: Float?, decoy: Bool = false, picture: Bool = true) {
            let dPx = px(dNm)
            guard let hand = CardFeatures.hand(pixels: pc.pixels, width: Int(pc.imageSize.width), height: Int(pc.imageSize.height), cx: x, cy: y, diameterPx: dPx) else { return }
            rr.observe(key: k, id: id, decision: yes ? "pick" : "reject", decoy: decoy, hand: hand, embedding: useE ? sw.assistEmbedding(x, y) : nil, weight: weight, fit: false)
            sampleIDs.append(id)
            if picture, weight == nil || weight! >= 1 || !yes {
                let fname = "\(stableHash(k))_\(id)"
                let g = Self.gray(pc.pixels, Int(pc.imageSize.width), Int(pc.imageSize.height), x, y, dPx, lo: win.lo, hi: win.hi)
                if classifier.save(gray: g, name: fname, yes: yes) { files.append(fname) }
            }
        }
        for it in all {
            if it.isNew && it.removed { continue }
            let moved = it.orig.map { hypot($0.x - it.x, $0.y - it.y) > 0.25 * px(pc.store.diameterNm($0)) } ?? false
            log.decisions.append(SwipeDecision(id: it.id, decision: it.removed ? "reject" : "pick", label: it.removed ? nil : it.label, x: it.x, y: it.y, decoy: false,
                                               recentered: moved, ms: dwell, t: now, view: sw.display.logTag, mode: "crop"))
            logged += 1
            if it.removed, let o = it.orig {
                teach(it.id, x: o.x, y: o.y, dNm: pc.store.diameterNm(o), yes: false, weight: nil)
            } else {
                teach(it.id, x: it.x, y: it.y, dNm: it.diameterNm, yes: true, weight: it.level == .maybe ? 0.5 : nil)
                if moved, let o = it.orig { teach("o_" + it.id, x: o.x, y: o.y, dNm: pc.store.diameterNm(o), yes: false, weight: 0.5, picture: false) }
            }
        }
        // blank spots of the area as easy negatives (so "no" also covers plain background): two per section, more for a big region
        let tag = t.map { "\($0.id)" } ?? "r" + String(stableHash(Pick.newID()) % 100000)
        var rng = LCG(s: stableHash(k) &+ UInt64(t?.id ?? Int(area.minX) &+ Int(area.minY)) &* 7919 | 1)
        let wanted = t != nil ? 2 : min(8, max(2, Int((area.width * area.height / (sidePx * sidePx) * 2).rounded())))
        let minD = 0.8 * defaultDiameterPx
        let near = pc.store.picks(k).filter { $0.status != .dismissed }.map { CGPoint(x: $0.x, y: $0.y) } + all.filter { !$0.removed }.map { CGPoint(x: $0.x, y: $0.y) }
        var made = 0, tries = 0
        while made < wanted, tries < 200 {
            tries += 1
            let x = area.minX + rng.next() * area.width, y = area.minY + rng.next() * area.height
            guard pc.inside(CGPoint(x: x, y: y)), !near.contains(where: { hypot($0.x - x, $0.y - y) < minD }) else { continue }
            teach("b\(tag)_\(made)", x: x, y: y, dNm: defNm, yes: false, weight: nil, decoy: true)
            made += 1
        }
        pc.store.setSwipe(k, log)
        rr.finishBatch()
        classifier.retrain()

        let region = DoneRegion(x0: area.minX, y0: area.minY, x1: area.maxX, y1: area.maxY)
        pc.store.addSection(k, region)
        commits.append(CommitRecord(tile: t, key: k, serial: serial, logged: logged, sampleIDs: sampleIDs, fileNames: files, items: all, section: region.id))
        let committed = Set(all.map { $0.id })
        let head = queue.first
        if t != nil { items = [] } else { items.removeAll { committed.contains($0.id) } }
        selected = nil
        requeue()
        refreshSizeTyper()
        if t != nil || queue.first != head { loadItems() } else { editHistory = []; revision += 1 }
        reorder()
    }

    /// Takes back the last confirmed section or region: picks, log, training examples, its mark and its place in the queue.
    private func undoCommit() {
        guard let c = commits.popLast() else { return }
        if c.serial != nil, pc.store.topSerial(c.key) == c.serial { pc.store.undo(c.key) }
        var log = pc.store.record(c.key).swipe ?? SwipeLog()
        log.decisions.removeLast(min(c.logged, log.decisions.count))
        pc.store.setSwipe(c.key, log)
        for id in c.sampleIDs { rr.forget(key: c.key, id: id) }
        rr.finishBatch()
        for f in c.fileNames { classifier.forget(name: f) }
        pc.store.removeSection(c.key, id: c.section)
        if let t = c.tile {
            requeue(restoring: t)
            items = c.items; selected = nil; editHistory = []; revision += 1; shownAt = Date()
            if active { frame() }
        } else {
            requeue()
            let ids = Set(c.items.map { $0.id })
            items.removeAll { ids.contains($0.id) }
            if let r = currentRect { items += c.items.filter { r.contains(CGPoint(x: $0.x, y: $0.y)) } }
            selected = nil; editHistory = []; revision += 1
        }
        refreshSizeTyper()
    }

    /// Moves the crop on screen to the end of the queue without deciding anything.
    func skip() {
        guard queue.count > 1, let t = queue.first else { return }
        queue.removeFirst(); queue.append(t); loadItems()
    }

    /// Forgets which sections of this micrograph are finished (the picks stay as they are).
    func clearSections() {
        guard let k = key ?? pc.currentKey else { return }
        pc.store.clearSections(k); commits.removeAll()
        rebuild()
    }

    // MARK: pointer (the main viewer calls these while the editor is active; pick coordinates throughout)

    /// A section's own rectangle: circles can only be added inside it.
    private func insideSection(_ p: CGPoint) -> Bool { currentRect?.contains(p) ?? false }

    func pointerDown(at p: CGPoint, tolerancePx: Double, region: Bool) {
        guard active else { return }
        if region || regionTool { gesture = .region(start: p); regionRect = CGRect(origin: p, size: .zero); return }
        if let it = hit(x: p.x, y: p.y, tolerancePx: tolerancePx) {
            gesture = .item(id: it.id, origin: CGPoint(x: it.x, y: it.y), start: p, moved: false); selected = it.id
        } else { gesture = .empty(start: p, moved: false) }
    }

    /// `movedPoints` = pointer travel since mouse down in view points (a click becomes a drag past 3).
    func pointerDragged(to p: CGPoint, movedPoints: Double) -> DragResult {
        switch gesture {
        case .none: return .pan
        case .empty(let start, _):
            guard movedPoints >= 3 else { return .none }
            gesture = .empty(start: start, moved: true)
            return .pan
        case .item(let id, let origin, let start, let moved):
            guard moved || movedPoints >= 3 else { return .none }
            if !moved { beginEdit(); gesture = .item(id: id, origin: origin, start: start, moved: true) }
            move(id, to: CGPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
            revision += 1
            return .handled
        case .region(let start):
            regionRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            return .handled
        }
    }

    /// `now` is injectable for tests. A second click on a circle within 0.45 s removes it.
    func pointerUp(at p: CGPoint, now: Date = Date()) {
        defer { gesture = .none }
        switch gesture {
        case .none: break
        case .region:
            let r = regionRect; regionRect = nil
            if let r { markRegionDone(r) }
        case .item(let id, _, _, let moved):
            if moved { lastClick = nil; break }
            if let l = lastClick, l.id == id, now.timeIntervalSince(l.at) < 0.45 { remove(id); lastClick = nil }
            else { lastClick = (id, now) }
        case .empty(_, let moved):
            if moved { break }
            if insideSection(p), let id = add(x: p.x, y: p.y) { lastClick = (id, now) } else { selected = nil }
        }
    }

    /// Right click: removes the circle under the pointer.
    func rightClick(at p: CGPoint, tolerancePx: Double) {
        guard active, let it = hit(x: p.x, y: p.y, tolerancePx: tolerancePx) else { return }
        remove(it.id)
    }

    /// Pinch over a circle (the selected one, else the one under the pointer): resizes it. False when there is none, so the
    /// viewer zooms instead.
    func pinch(at p: CGPoint, tolerancePx: Double, scale: Double, began: Bool) -> Bool {
        guard active, scale > 0 else { return false }
        guard let id = selected ?? hit(x: p.x, y: p.y, tolerancePx: tolerancePx)?.id, let it = items.first(where: { $0.id == id && !$0.removed }) else { return false }
        if began { beginEdit() }
        setDiameter(id, nm: it.diameterNm * scale)
        return true
    }
}

/// Typical size of each particle view, learned from the circles you sized by hand. A circle's type is then the view whose
/// typical size (median diameter, compared on a log scale) is closest. Needs at least `minEach` sized circles for each of at
/// least two views; with fewer it says nothing, so it never guesses from one example.
struct SizeTyper: Equatable {
    var centres: [(id: String, nm: Double)]
    static let minEach = 3

    static func == (a: SizeTyper, b: SizeTyper) -> Bool { a.centres.count == b.centres.count && zip(a.centres, b.centres).allSatisfy { $0.id == $1.id && $0.nm == $1.nm } }

    static func learn(_ samples: [(String, Double)], minEach: Int = SizeTyper.minEach) -> SizeTyper? {
        var by: [String: [Double]] = [:]
        for (l, d) in samples where d > 0 { by[l, default: []].append(d) }
        let cs: [(id: String, nm: Double)] = by.filter { $0.value.count >= minEach }.map { (id: $0.key, nm: median($0.value)) }.sorted { $0.nm < $1.nm }
        return cs.count >= 2 ? SizeTyper(centres: cs) : nil
    }

    func label(forNm nm: Double) -> String? {
        guard nm > 0 else { return nil }
        return centres.min { abs(log(nm / $0.nm)) < abs(log(nm / $1.nm)) }?.id
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
