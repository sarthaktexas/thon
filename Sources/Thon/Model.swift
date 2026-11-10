import SwiftUI
import Combine
import UniformTypeIdentifiers
import ImageIO

struct ExposureItem: Identifiable, Hashable {
    let url: URL
    let rel: String
    var id: URL { url }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name", time = "Acquired", mag = "Magnification"
    var id: String { rawValue }
}

/// Format-independent image description (what the views need).
struct ImageInfo {
    var width: Int, height: Int, depth: Int
    var pixelSizeA: Double?
    var dataTypeName: String
}

extension DMImageEntry {
    var info: ImageInfo { ImageInfo(width: width, height: height, depth: depth, pixelSizeA: pixelSizeA, dataTypeName: dataTypeName) }
}

final class LoadedExposure: @unchecked Sendable {
    let url: URL
    let file: DMFile?
    let mrc: MRCFile?
    let entry: ImageInfo
    let pixels: [Float]
    let stats: ImageStats
    let sections: [InfoSection]
    let tags: [TagRow]
    let frame: Int

    init(url: URL, frame: Int) throws {
        self.url = url
        if AppModel.isMRC(url) {
            let f = try MRCFile(url: url)
            let px = try f.readPixels(frame: frame)
            let st = ImageStats.compute(px)
            file = nil; mrc = f; pixels = px; stats = st; self.frame = frame
            entry = ImageInfo(width: f.width, height: f.height, depth: f.depth, pixelSizeA: f.header.pixelSizeA, dataTypeName: f.header.modeName)
            sections = f.buildSections(stats: st)
            tags = f.flatTags()
        } else {
            let f = try DMFile(url: url)
            guard let e = f.primaryImage else { throw DMError.unsupported("No image data found in \(url.lastPathComponent)") }
            let px = try f.readPixels(e, frame: frame)
            let st = ImageStats.compute(px)
            file = f; mrc = nil; entry = e.info; pixels = px; stats = st; self.frame = frame
            sections = f.buildSections(entry: e, stats: st)
            tags = f.flatTags()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var items: [ExposureItem] = []
    @Published var selection: URL? { didSet { if selection != oldValue { frame = 0; loadSelection() } } }
    @Published var thumbs: [URL: NSImage] = [:]
    @Published var metas: [URL: ExposureMeta] = [:]
    @Published var sortKey: SortKey = .name { didSet { resort() } }
    @Published var doc: LoadedExposure?
    @Published var fft: PowerSpectrum?
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var generation = 0
    @Published var frame = 0
    @Published var showInspector = true
    @Published var fftNormalize = true
    @Published var tagQuery = ""
    @Published var inspectorTab: InspectorTab = .overview
    @Published var showGallery = false
    @Published var showSwipe = false

    let view = ViewState()
    let cursor = CursorState()
    let picks = PickController()
    private var picksBag = Set<AnyCancellable>()

    init() {
        picks.gallery.loader = { root, key in AppModel.loadPixels(root: root, key: key) }
        picks.gallery.onGoTo = { [weak self] key, x, y in self?.goTo(key: key, x: x, y: y) }
        picks.$enabled.sink { [weak self] on in
            if on { self?.inspectorTab = .picks; self?.showInspector = true }
        }.store(in: &picksBag)
    }
    var renderer: MicrographRenderer?

    private var loadToken = 0
    private let indexQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2          // keep CPU load modest
        q.qualityOfService = .utility
        return q
    }()

    /// Raw pixels of a micrograph by project key (background use; no stats / tags).
    nonisolated static func loadPixels(root: URL?, key: String) -> (pixels: [Float], width: Int, height: Int)? {
        let url = key.hasPrefix("/") ? URL(fileURLWithPath: key) : (root ?? URL(fileURLWithPath: "/")).appendingPathComponent(key)
        if isMRC(url) {
            guard let f = try? MRCFile(url: url), let px = try? f.readPixels() else { return nil }
            return (px, f.width, f.height)
        }
        guard let f = try? DMFile(url: url), let e = f.primaryImage, let px = try? f.readPixels(e, frame: 0) else { return nil }
        return (px, e.width, e.height)
    }

    /// Opens micrograph `key` (if needed) and centres the view on the pick, zoomed so ~5 boxes fit across the view.
    func goTo(key: String, x: Double, y: Double) {
        showGallery = false
        let box = max(picks.boxPx, 8)
        let z = min(max(Double(min(view.viewPixels.width, view.viewPixels.height)) / (5 * box), 0.05), 32)
        let focus = CGPoint(x: x + 0.5, y: y + 0.5)
        guard let target = items.first(where: { picks.store.key(for: $0.url) == key })?.url else { loadError = "Micrograph \(key) is not in the open folder."; return }
        if target == selection { view.center = focus; view.zoom = z }
        else { view.pendingFocus = (focus, z); selection = target }
    }

    // MARK: library

    static let allowedExtensions: Set<String> = ["dm3", "dm4", "mrc", "mrcs"]
    nonisolated static func isMRC(_ u: URL) -> Bool { ["mrc", "mrcs"].contains(u.pathExtension.lowercased()) }

    var sortedItems: [ExposureItem] { items }

    func open(urls: [URL]) {
        var found: [ExposureItem] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let base = u.deletingLastPathComponent().path
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in en where Self.allowedExtensions.contains(f.pathExtension.lowercased()) {
                        found.append(ExposureItem(url: f, rel: String(f.path.dropFirst(base.count + 1))))
                    }
                }
            } else if Self.allowedExtensions.contains(u.pathExtension.lowercased()) {
                found.append(ExposureItem(url: u, rel: u.lastPathComponent))
            }
        }
        guard !found.isEmpty else { loadError = "No .dm3 / .dm4 / .mrc files found."; return }
        indexQueue.cancelAllOperations()
        // the project (picks_project.json, labels.json, backups/) lives in the opened folder,
        // or next to the first file when individual files were opened
        if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            picks.store.openProject(folder: urls[0])
        } else if let first = found.first {
            picks.store.openProject(folder: first.url.deletingLastPathComponent())
        }
        thumbs = [:]; metas = [:]
        items = found.sorted { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        selection = items.first?.url
        index(items)
    }

    private func index(_ list: [ExposureItem]) {
        for item in list {
            indexQueue.addOperation { [weak self] in
                var meta = ExposureMeta()
                var thumb: CGImage?
                if AppModel.isMRC(item.url) {
                    guard let f = try? MRCFile(url: item.url) else { return }
                    meta.width = f.width; meta.height = f.height; meta.pixelSizeA = f.header.pixelSizeA; meta.dataType = f.header.modeName
                    if let px = try? f.readPixels() { thumb = makeThumbnail(px, f.width, f.height) }
                } else {
                    guard let f = try? DMFile(url: item.url) else { return }
                    meta = f.quickMeta()
                    thumb = f.embeddedThumbnail()
                    if thumb == nil, let e = f.primaryImage, let px = try? f.readPixels(e) { thumb = makeThumbnail(px, e.width, e.height) }
                }
                let ns = thumb.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.metas[item.url] = meta
                    if let ns { self.thumbs[item.url] = ns }
                    if self.sortKey != .name { self.resort() }
                }
            }
        }
    }

    private func resort() {
        let sel = selection
        switch sortKey {
        case .name: items.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        case .time: items.sort { (metas[$0.url]?.acquired ?? .distantPast) < (metas[$1.url]?.acquired ?? .distantPast) }
        case .mag: items.sort { (metas[$0.url]?.indicatedMag ?? 0) < (metas[$1.url]?.indicatedMag ?? 0) }
        }
        if selection != sel { selection = sel }
    }

    var selectedIndex: Int? { items.firstIndex { $0.url == selection } }
    func step(_ d: Int) {
        guard let i = selectedIndex else { return }
        let j = min(max(i + d, 0), items.count - 1)
        selection = items[j].url
    }

    // MARK: loading

    func loadSelection() {
        guard let url = selection else { return }
        loadToken += 1
        let token = loadToken, fr = frame
        isLoading = true; loadError = nil
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try LoadedExposure(url: url, frame: fr) }.value
                guard token == loadToken else { return }
                doc = loaded
                fft = nil
                view.displayStats = loaded.stats
                view.applyAuto()
                cursor.pixels = loaded.pixels; cursor.width = loaded.entry.width; cursor.height = loaded.entry.height
                picks.pixels = loaded.pixels; picks.currentURL = url
                picks.setMicrograph(key: picks.store.key(for: url), width: loaded.entry.width, height: loaded.entry.height, pixelSizeA: loaded.entry.pixelSizeA)
                generation += 1
                isLoading = false
                let px = loaded.pixels, w = loaded.entry.width, h = loaded.entry.height
                let ps = await Task.detached(priority: .utility) { computePowerSpectrum(pixels: px, width: w, height: h) }.value
                if token == loadToken { fft = ps }
            } catch {
                guard token == loadToken else { return }
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }

    func reloadFrame() { loadSelection() }

    func applyProcessedStats(_ st: ImageStats?) {
        view.displayStats = st ?? doc?.stats
        view.applyAuto()
    }

    // MARK: interaction

    func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 123, 126: step(-1); return true
        case 124, 125: step(1); return true
        default: break
        }
        let chars = e.charactersIgnoringModifiers ?? ""
        let mods = e.modifierFlags
        if picks.handleKey(chars: chars, keyCode: e.keyCode, shift: mods.contains(.shift), command: mods.contains(.command)) { return true }
        switch chars.lowercased() {
        case "p": picks.enabled.toggle(); return true
        case "g": showGallery = true; return true
        case "s": if doc != nil { picks.enabled = true; showSwipe = true }; return true
        case "v": picks.showMarkers.toggle(); return true
        case "b": picks.showBoxes.toggle(); return true
        case "f": view.fit(); return true
        case "1": view.setZoom(1); return true
        case "i": view.invert.toggle(); return true
        case "=", "+": view.setZoom(view.zoom * 1.25); return true
        case "-": view.setZoom(view.zoom / 1.25); return true
        default: return false
        }
    }

    // MARK: open / export

    func presentOpenPanel(folders: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = !folders
        if !folders { p.allowedContentTypes = ["dm3", "dm4", "mrc", "mrcs"].compactMap { UTType(filenameExtension: $0) } }
        if p.runModal() == .OK { open(urls: p.urls) }
    }

    private func suggestedName(_ ext: String) -> String {
        (doc?.url.deletingPathExtension().lastPathComponent ?? "micrograph") + "." + ext
    }

    func exportPNG() {
        guard let doc, let px = renderer?.readProcessed() else { return }
        let sp = NSSavePanel(); sp.allowedContentTypes = [.png]; sp.nameFieldStringValue = suggestedName("png")
        guard sp.runModal() == .OK, let url = sp.url else { return }
        let w = doc.entry.width, h = doc.entry.height
        let lo = Float(view.lo), hi = Float(max(view.hi, view.lo + 1e-9)), g = Float(max(view.gamma, 0.05))
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            var t = min(max((px[i] - lo) / (hi - lo), 0), 1)
            t = powf(t, g)
            if view.invert { t = 1 - t }
            bytes[i] = UInt8(t * 255 + 0.5)
        }
        guard let prov = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        if !CGImageDestinationFinalize(dest) { loadError = "Could not write PNG." }
    }

    func exportMRC(processed: Bool) {
        guard let doc else { return }
        let px: [Float] = processed ? (renderer?.readProcessed() ?? doc.pixels) : doc.pixels
        let sp = NSSavePanel(); sp.nameFieldStringValue = suggestedName("mrc")
        guard sp.runModal() == .OK, let url = sp.url else { return }
        let w = doc.entry.width, h = doc.entry.height
        let st = ImageStats.compute(px)
        let pa = Float(doc.entry.pixelSizeA ?? 1)
        var hdr = [UInt8](repeating: 0, count: 1024)
        func putI(_ i: Int, _ v: Int32) { withUnsafeBytes(of: v.littleEndian) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
        func putF(_ i: Int, _ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
        putI(0, Int32(w)); putI(1, Int32(h)); putI(2, 1); putI(3, 2)
        putI(7, Int32(w)); putI(8, Int32(h)); putI(9, 1)
        putF(10, Float(w) * pa); putF(11, Float(h) * pa); putF(12, pa)
        putF(13, 90); putF(14, 90); putF(15, 90)
        putI(16, 1); putI(17, 2); putI(18, 3)
        putF(19, Float(st.min)); putF(20, Float(st.max)); putF(21, Float(st.mean))
        hdr[208] = 0x4D; hdr[209] = 0x41; hdr[210] = 0x50; hdr[211] = 0x20          // "MAP "
        hdr[212] = 0x44; hdr[213] = 0x44                                            // little-endian machine stamp
        putF(54, Float(st.std))
        var out = Data(hdr)
        var flipped = [Float](repeating: 0, count: w * h)       // MRC origin is bottom-left; DM data is top-down
        for y in 0..<h { flipped.replaceSubrange((h - 1 - y) * w ..< (h - y) * w, with: px[(y * w)..<((y + 1) * w)]) }
        flipped.withUnsafeBytes { out.append(contentsOf: $0) }
        do { try out.write(to: url) } catch { loadError = error.localizedDescription }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview", display = "Display", picks = "Picks", fft = "FFT", tags = "Tags"
    var id: String { rawValue }
}

/// 8-bit grayscale thumbnail with 1-99 percentile stretch (used when a file has no embedded thumbnail).
func makeThumbnail(_ px: [Float], _ w: Int, _ h: Int, maxSide: Int = 256) -> CGImage? {
    let f = max(1, max(w, h) / maxSide)
    let tw = w / f, th = h / f
    guard tw > 0, th > 0 else { return nil }
    var small = [Float](repeating: 0, count: tw * th)
    for y in 0..<th {
        for x in 0..<tw {
            var s: Float = 0
            for dy in 0..<f { for dx in 0..<f { s += px[(y * f + dy) * w + x * f + dx] } }
            small[y * tw + x] = s / Float(f * f)
        }
    }
    let sorted = small.sorted()
    let lo = sorted[Int(0.01 * Double(sorted.count - 1))], hi = max(sorted[Int(0.99 * Double(sorted.count - 1))], lo + 1e-9)
    let bytes = small.map { UInt8(max(0, min(255, ($0 - lo) / (hi - lo) * 255))) }
    guard let prov = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: tw, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}
