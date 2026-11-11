import Foundation
import Combine
import CoreGraphics

// Crop editor: the micrograph is cut into overlapping crops, one is shown at a time with its candidate circles.
// The user moves, resizes, adds and removes circles and gives each one a type from the project's label scheme (right-click
// a circle, a label hotkey, or the type list); the circle is drawn in the colour of its type. A double click on a circle
// removes it (= reject). Next confirms the crop: circles left alone count as confirmed, so every circle in
// the crop becomes a labelled example for the assistant (Reranker's logistic model and the Core ML classifier).

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
        var tile: Tile; var key: String; var serial: Int?; var logged: Int
        var sampleIDs: [String]; var fileNames: [String]; var items: [Item]
    }

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
    @Published var zoomOut = false { didSet { if zoomOut != oldValue { revision += 1; addPicksOfWindow() } } }
    @Published var sideDiameters = 5.0 { didSet { if sideDiameters != oldValue { sideDiameters = min(max(sideDiameters, 2), 12); if sideDiameters != oldValue { rebuild() } } } }
    @Published var includeEmpty = false { didSet { if includeEmpty != oldValue { rebuild() } } }
    @Published var order = Order.uncertain { didSet { if order != oldValue { reorder() } } }
    @Published private(set) var revision = 0
    @Published private(set) var reviewedCount = 0
    private(set) var shownAt = Date()

    private var key: String?
    private var reviewed: [String: Set<Int>] = [:]            // per micrograph and crop size
    private var editHistory: [[Item]] = []
    private var commits: [CommitRecord] = []
    private var plate: CardPlate?, plateSig = ""
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
    var windowPx: Double { sidePx * (zoomOut ? 2 : 1) }
    var current: Tile? { queue.first }
    var done: Bool { queue.isEmpty }
    var remaining: Int { queue.count }
    var canUndo: Bool { !editHistory.isEmpty || !commits.isEmpty }
    private var reviewKey: String { "\(key ?? "")|\(Int(sidePx))" }

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
    func isRejectLabel(_ id: String) -> Bool { pc.store.scheme.label(id)?.exported == false }

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
        p.status == .accepted || (p.status == .candidate && (p.score ?? .infinity) >= pc.scoreCutoff)
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
        let kept = includeEmpty ? all : all.filter { !picksIn($0, key: k).isEmpty }
        tilesTotal = kept.count
        let seen = reviewed[reviewKey] ?? []
        queue = kept.filter { !seen.contains($0.id) }
        reviewedCount = kept.count - queue.count
        editHistory = []; commits = []; zoomOut = false
        if penNm <= 0 { penNm = defaultDiameterNm }
        loadItems(); reorder(includeFirst: true)
    }

    private func loadItems() {
        selected = nil; editHistory = []; items = []
        if let t = current, let k = key {
            items = picksIn(t, window: windowPx, key: k).map { p in var i = Self.item(from: p); i.diameterNm = pc.store.diameterNm(p); return i }
        }
        shownAt = Date(); revision += 1; sw.viewChanged()
    }

    static func item(from p: Pick) -> Item {
        Item(id: p.id, x: p.x, y: p.y, diameterNm: p.diameterNm ?? 0, level: (p.isMaybe || isMaybeLabel(p.label)) ? .maybe : .sure, label: p.label,
             isNew: false, untouched: p.status == .candidate, orig: p)
    }

    /// Zooming out brings picks of the wider window into the list; edits already made are kept.
    private func addPicksOfWindow() {
        guard let t = current, let k = key else { return }
        let have = Set(items.map { $0.id })
        for p in picksIn(t, window: windowPx, key: k) where !have.contains(p.id) {
            var i = Self.item(from: p); i.diameterNm = pc.store.diameterNm(p); items.append(i)
        }
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

    func cropImage(out: Int) -> [UInt8]? {
        guard let t = current, !pc.pixels.isEmpty else { return nil }
        let d = sw.display
        let sig = "\(pc.currentKey ?? "")|\(pc.pixels.count)|\(t.id)|\(windowPx)|\(out)|\(d.denoise.rawValue)|\(d.size)|\(d.h)"
        if sig != plateSig || plate == nil {
            plate = CardPlate.make(pixels: pc.pixels, width: Int(pc.imageSize.width), height: Int(pc.imageSize.height), cx: t.cx, cy: t.cy,
                                   boxPx: windowPx, out: out, denoise: d.denoise, size: d.size, h: d.h)
            plateSig = sig
        }
        guard let plate else { return nil }
        let win = d.window(base: d.tone == .micrograph ? sw.displayWindow() : plate.localWindow())
        return plate.render(out: out, lo: win.lo, hi: win.hi, gamma: Float(d.gamma), invert: d.invert, nearest: d.pixelated)
    }

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
        let label = penNm > 0 ? (typeFromSize(nm, current: pc.activeLabel) ?? pc.activeLabel) : pc.activeLabel
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
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].label != label || items[i].untouched else { return }
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
        let ls = pc.store.scheme.labels
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

    /// Confirms the crop: applies every circle to the picks (one undoable store edit), logs it and teaches the assistant.
    func commit() {
        guard let k = key ?? pc.currentKey, let t = current else { return }
        let all = items
        let defNm = defaultDiameterNm
        func sized(_ d: Double) -> Double? { abs(d - defNm) > 1e-6 ? d : nil }
        if all.contains(where: { !$0.removed && $0.level == .maybe }), !pc.store.project.params.maybeFlag {
            var p = pc.store.project.params; p.maybeFlag = true; pc.store.setParams(p)            // so the yellow ones show as ? and can be left out of an export
        }
        let n = reviewedCount + 1
        let changed = pc.store.perform(k, "Crop \(n)") { l in
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
                let name = "\(stableHash(k))_\(id)"
                let g = Self.gray(pc.pixels, Int(pc.imageSize.width), Int(pc.imageSize.height), x, y, dPx, lo: win.lo, hi: win.hi)
                if classifier.save(gray: g, name: name, yes: yes) { files.append(name) }
            }
        }
        for it in all {
            if it.isNew && it.removed { continue }
            let moved = it.orig.map { hypot($0.x - it.x, $0.y - it.y) > 0.25 * px(pc.store.diameterNm($0)) } ?? false
            log.decisions.append(SwipeDecision(id: it.id, decision: (it.removed || isRejectLabel(it.label)) ? "reject" : "pick", label: it.removed ? nil : it.label, x: it.x, y: it.y, decoy: false,
                                               recentered: moved, ms: dwell, t: now, view: sw.display.logTag, mode: "crop"))
            logged += 1
            if it.removed, let o = it.orig {
                teach(it.id, x: o.x, y: o.y, dNm: pc.store.diameterNm(o), yes: false, weight: nil)
            } else if isRejectLabel(it.label) {
                teach(it.id, x: it.x, y: it.y, dNm: it.diameterNm, yes: false, weight: nil)            // typed "reject": kept in the project, a no for the assistant
            } else {
                teach(it.id, x: it.x, y: it.y, dNm: it.diameterNm, yes: true, weight: it.level == .maybe ? 0.5 : nil)
                if moved, let o = it.orig { teach("o_" + it.id, x: o.x, y: o.y, dNm: pc.store.diameterNm(o), yes: false, weight: 0.5, picture: false) }
            }
        }
        // two blank spots of the crop as easy negatives (so "no" also covers plain background)
        var rng = LCG(s: stableHash(k) &+ UInt64(t.id) &* 7919 | 1)
        let half = sidePx / 2, minD = 0.8 * defaultDiameterPx
        let near = pc.store.picks(k).filter { $0.status != .dismissed }.map { CGPoint(x: $0.x, y: $0.y) } + all.filter { !$0.removed }.map { CGPoint(x: $0.x, y: $0.y) }
        var made = 0, tries = 0
        while made < 2, tries < 200 {
            tries += 1
            let x = t.cx + (rng.next() - 0.5) * 2 * half, y = t.cy + (rng.next() - 0.5) * 2 * half
            guard pc.inside(CGPoint(x: x, y: y)), !near.contains(where: { hypot($0.x - x, $0.y - y) < minD }) else { continue }
            teach("b\(t.id)_\(made)", x: x, y: y, dNm: defNm, yes: false, weight: nil, decoy: true)
            made += 1
        }
        pc.store.setSwipe(k, log)
        rr.finishBatch()
        classifier.retrain()

        commits.append(CommitRecord(tile: t, key: k, serial: serial, logged: logged, sampleIDs: sampleIDs, fileNames: files, items: all))
        reviewed[reviewKey, default: []].insert(t.id)
        queue.removeFirst(); reviewedCount += 1
        zoomOut = false
        refreshSizeTyper()
        loadItems(); reorder()
    }

    /// Takes back the last confirmed crop: picks, log, training examples and the crop's place in the queue.
    private func undoCommit() {
        guard let c = commits.popLast() else { return }
        if c.serial != nil, pc.store.topSerial(c.key) == c.serial { pc.store.undo(c.key) }
        var log = pc.store.record(c.key).swipe ?? SwipeLog()
        log.decisions.removeLast(min(c.logged, log.decisions.count))
        pc.store.setSwipe(c.key, log)
        for id in c.sampleIDs { rr.forget(key: c.key, id: id) }
        rr.finishBatch()
        for f in c.fileNames { classifier.forget(name: f) }
        reviewed[reviewKey]?.remove(c.tile.id)
        queue.insert(c.tile, at: 0); reviewedCount = max(0, reviewedCount - 1)
        zoomOut = false
        items = c.items; selected = nil; editHistory = []; revision += 1; shownAt = Date()
        refreshSizeTyper()
    }

    /// Moves the crop on screen to the end of the queue without deciding anything.
    func skip() {
        guard queue.count > 1, let t = queue.first else { return }
        queue.removeFirst(); queue.append(t); zoomOut = false; loadItems()
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
