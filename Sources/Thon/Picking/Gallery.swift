import Foundation
import Combine
import CoreGraphics

/// Bilinear crop of a box around (cx, cy) (pick coordinates), resampled to out x out 8-bit gray.
/// Downsampling is anti-aliased by a Gaussian pre-blur; `smoothSigma` (source px) adds extra smoothing.
/// Positions outside the image are mid-gray.
func renderThumb(pixels: [Float], width: Int, height: Int, cx: Double, cy: Double, boxPx: Double, out: Int,
                 lo: Float, hi: Float, smoothSigma: Double = 0, invert: Bool = false) -> [UInt8] {
    let scale = boxPx / Double(out)
    let sigma = max(smoothSigma, scale > 1.5 ? 0.5 * scale : 0)
    let pad = sigma > 0.05 ? Int((3.5 * sigma).rounded(.up)) + 1 : 1
    let half = Int((boxPx / 2).rounded(.up)) + pad + 1
    let x0 = Int(cx.rounded(.down)) - half, y0 = Int(cy.rounded(.down)) - half, n = 2 * half + 1
    var region = [Float](repeating: 0, count: n * n)
    for j in 0..<n {
        let yy = min(max(y0 + j, 0), height - 1)
        for i in 0..<n { region[j * n + i] = pixels[yy * width + min(max(x0 + i, 0), width - 1)] }
    }
    if sigma > 0.05 { region = AutoPicker.gaussianBlur(region, n, n, sigma: sigma) }
    var o = [UInt8](repeating: 128, count: out * out)
    let span = max(hi - lo, 1e-12)
    for j in 0..<out {
        let sy = cy + ((Double(j) + 0.5) / Double(out) - 0.5) * boxPx
        if sy < -0.5 || sy > Double(height) - 0.5 { continue }
        let ry = sy - Double(y0), jy = min(max(Int(ry.rounded(.down)), 0), n - 2), fy = Float(ry - Double(jy))
        for i in 0..<out {
            let sx = cx + ((Double(i) + 0.5) / Double(out) - 0.5) * boxPx
            if sx < -0.5 || sx > Double(width) - 0.5 { continue }
            let rx = sx - Double(x0), ix = min(max(Int(rx.rounded(.down)), 0), n - 2), fx = Float(rx - Double(ix))
            let a = region[jy * n + ix], b = region[jy * n + ix + 1], c = region[(jy + 1) * n + ix], d = region[(jy + 1) * n + ix + 1]
            let v = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
            var t = min(max((v - lo) / span, 0), 1)
            if invert { t = 1 - t }
            o[j * out + i] = UInt8(t * 255 + 0.5)
        }
    }
    return o
}

/// Robust display window for a micrograph: median - 3 sigma ... median + 4 sigma (sigma from the MAD).
func robustWindow(_ pixels: [Float]) -> (lo: Float, hi: Float) {
    let s = AutoPicker.robustStats(pixels)
    return (s.median - 3 * s.sigma, s.median + 4 * s.sigma)
}

struct GalleryItem: Identifiable, Equatable {
    var id: String                    // pick id
    var key: String                   // micrograph key
    var label: String
    var status: PickStatus
    var score: Float?
    var x: Double, y: Double
    var boxPx: Double = 0             // extraction box of this pick (px)
    var thumb: [UInt8]?
    var cls: Int?
}

enum GalleryScope: String, CaseIterable, Identifiable { case current = "This micrograph", all = "All micrographs"; var id: String { rawValue } }
enum GallerySort: String, CaseIterable, Identifiable { case micrograph = "Micrograph", score = "Score", label = "Label", cls = "Class"; var id: String { rawValue } }

/// Crop gallery of picks, grouped by label, with relabel / delete / accept and "go to" actions.
final class GalleryModel: ObservableObject {
    unowned let pc: PickController
    @Published var scope = GalleryScope.current { didSet { if scope != oldValue { selection = []; refresh() } } }
    @Published var sort = GallerySort.micrograph
    @Published var groupByLabel = true
    @Published var showCandidates = true
    @Published var thumbPx = 96.0
    @Published var smooth = 1.0 { didSet { if smooth != oldValue { invalidate() } } }
    @Published var invert = false { didSet { if invert != oldValue { invalidate() } } }
    @Published var selection = Set<String>()
    @Published var progress: String?
    @Published private(set) var revision = 0

    static let cap = 6000
    static let outPx = 96
    /// Loads raw pixels of a micrograph by key (set by the app; runs on a background queue).
    var loader: ((URL?, String) -> (pixels: [Float], width: Int, height: Int)?)?
    var onGoTo: ((String, Double, Double) -> Void)?
    private var cache: [String: (x: Double, y: Double, box: Double, bytes: [UInt8])] = [:]
    private var cacheSig = ""
    private var token = 0
    private var batches: [[String]] = []
    private let queue = DispatchQueue(label: "thon.gallery", qos: .userInitiated)
    private var bag = Set<AnyCancellable>()

    init(pc: PickController) {
        self.pc = pc
        pc.store.$revision.dropFirst().debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
    }

    private var signature: String {
        "\(pc.store.project.params.boxNm)|\(pc.effectiveAngpix)|\(smooth)|\(invert)"
    }
    func invalidate() { cache = [:]; refresh() }

    // MARK: items

    /// Current items (without forcing thumbnail generation).
    var items: [GalleryItem] {
        let keys: [String]
        switch scope {
        case .current: keys = pc.currentKey.map { [$0] } ?? []
        case .all: keys = pc.store.project.mics.keys.sorted()
        }
        var out: [GalleryItem] = []
        for k in keys {
            for p in pc.store.picks(k) where p.status == .accepted || (showCandidates && p.status == .candidate) {
                if pc.hiddenLabels.contains(p.label) { continue }
                var it = GalleryItem(id: p.id, key: k, label: p.label, status: p.status, score: p.score, x: p.x, y: p.y, boxPx: pc.boxPx(p), thumb: nil, cls: pc.classes?.pickClass[p.id])
                if let c = cache[p.id], c.x == p.x, c.y == p.y, c.box == it.boxPx { it.thumb = c.bytes }
                out.append(it)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: pc.store.scheme.labels.enumerated().map { ($1.id, $0) })
        func lab(_ i: GalleryItem) -> Int { order[i.label] ?? 999 }
        out.sort { a, b in
            if groupByLabel, lab(a) != lab(b) { return lab(a) < lab(b) }
            switch sort {
            case .micrograph: return a.key != b.key ? a.key < b.key : (a.y != b.y ? a.y < b.y : a.x < b.x)
            case .score: return (a.score ?? .infinity) != (b.score ?? .infinity) ? (a.score ?? .infinity) > (b.score ?? .infinity) : a.id < b.id
            case .label: return lab(a) != lab(b) ? lab(a) < lab(b) : a.id < b.id
            case .cls: return (a.cls ?? 9999) != (b.cls ?? 9999) ? (a.cls ?? 9999) < (b.cls ?? 9999) : a.id < b.id
            }
        }
        return Array(out.prefix(Self.cap))
    }

    // MARK: thumbnails

    var autoRender = true                 // tests render synchronously instead

    func refresh() {
        if cacheSig != signature { cache = [:]; cacheSig = signature }
        objectWillChange.send()
        guard autoRender else { return }
        let missing = items.filter { $0.thumb == nil }
        guard !missing.isEmpty else { progress = nil; revision += 1; return }
        token += 1
        let tk = token
        let smooth = self.smooth, invert = self.invert
        let byKey = Dictionary(grouping: missing, by: { $0.key })
        let curKey = pc.currentKey, curPixels = pc.pixels, curW = Int(pc.imageSize.width), curH = Int(pc.imageSize.height)
        let loader = self.loader, root = pc.store.root, km = pc.store.keyResolver()
        let total = missing.count
        progress = "Rendering \(total) crops…"
        queue.async { [weak self] in
            var done = 0
            for (key, list) in byKey.sorted(by: { $0.key < $1.key }) {
                if self?.token != tk { return }
                var src: (pixels: [Float], width: Int, height: Int)?
                if key == curKey, !curPixels.isEmpty { src = (curPixels, curW, curH) } else { src = loader?(root, km.loaderKey(key)) }
                guard let s = src else { done += list.count; continue }
                let win = robustWindow(s.pixels)
                var res: [(String, Double, Double, Double, [UInt8])] = []
                for it in list {
                    res.append((it.id, it.x, it.y, it.boxPx, renderThumb(pixels: s.pixels, width: s.width, height: s.height, cx: it.x, cy: it.y, boxPx: it.boxPx,
                                                              out: GalleryModel.outPx, lo: win.lo, hi: win.hi, smoothSigma: smooth, invert: invert)))
                }
                done += list.count
                DispatchQueue.main.async {
                    guard let self, self.token == tk else { return }
                    for r in res { self.cache[r.0] = (r.1, r.2, r.3, r.4) }
                    self.progress = done < total ? "Rendering crops… \(done) / \(total)" : nil
                    self.revision += 1
                }
            }
        }
    }

    /// Synchronous variant for tests: renders every missing crop using the loader.
    func renderAllSync() {
        for (key, list) in Dictionary(grouping: items.filter { $0.thumb == nil }, by: { $0.key }) {
            let src: (pixels: [Float], width: Int, height: Int)? = (key == pc.currentKey && !pc.pixels.isEmpty) ? (pc.pixels, Int(pc.imageSize.width), Int(pc.imageSize.height)) : loader?(pc.store.root, pc.store.keyResolver().loaderKey(key))
            guard let s = src else { continue }
            let win = robustWindow(s.pixels)
            for it in list {
                cache[it.id] = (it.x, it.y, it.boxPx, renderThumb(pixels: s.pixels, width: s.width, height: s.height, cx: it.x, cy: it.y, boxPx: it.boxPx,
                                                       out: GalleryModel.outPx, lo: win.lo, hi: win.hi, smoothSigma: smooth, invert: invert))
            }
        }
    }

    // MARK: actions (grouped by micrograph; one gallery undo step = all micrographs touched)

    private func byKey(_ ids: Set<String>) -> [String: Set<String>] {
        var m: [String: Set<String>] = [:]
        for it in items where ids.contains(it.id) { m[it.key, default: []].insert(it.id) }
        return m
    }
    func relabelSelected(_ label: String) {
        let g = byKey(selection); guard !g.isEmpty else { return }
        for (k, ids) in g { pc.store.relabel(ids, to: label, in: k) }
        batches.append(Array(g.keys))
    }
    func deleteSelected() {
        let g = byKey(selection); guard !g.isEmpty else { return }
        for (k, ids) in g { pc.store.remove(ids, from: k) }
        batches.append(Array(g.keys)); selection = []
        pc.pruneSelection()
    }
    func acceptSelected() {
        let g = byKey(selection); guard !g.isEmpty else { return }
        for (k, ids) in g { pc.store.setStatus(ids, .accepted, in: k) }
        batches.append(Array(g.keys))
    }
    func undo() {
        guard let b = batches.popLast() else { return }
        for k in b { pc.store.undo(k) }
        pc.pruneSelection()
    }
    var canUndo: Bool { !batches.isEmpty }
    func selectAll(label: String? = nil) { selection = Set(items.filter { label == nil || $0.label == label }.map { $0.id }) }
    func goTo(_ id: String) { if let it = items.first(where: { $0.id == id }) { onGoTo?(it.key, it.x, it.y) } }
}
