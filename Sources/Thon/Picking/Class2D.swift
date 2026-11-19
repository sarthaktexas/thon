import Foundation
import Combine

// 2D classification with RELION from inside Thon.
//
// What happens when you press Run:
//   1. the accepted picks are written as RELION coordinate files, the micrographs are linked (or, for DM3/DM4, converted to MRC)
//      into a hidden work folder that has RELION's own layout (Micrographs/, Coords/, Extract/, Class2D/);
//   2. `relion_preprocess --extract` cuts the particles out (optionally scaled down, normalised, contrast inverted);
//   3. `relion_refine --grad` (VDAM) classifies them on the CPU, a few threads, low priority;
//   4. the last iteration's run_itNNN_data.star is mapped back onto the picks, exactly like "Load classification…".
// Nothing is written next to the project except the one hidden folder.

// MARK: RELION installation

struct RelionConfig: Codable, Equatable {
    var binFolder = ""               // folder that holds relion_refine, relion_preprocess, …
    var threads = 3                  // threads for relion_refine (--j); kept low on purpose
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = RelionConfig()
        binFolder = try c.decodeIfPresent(String.self, forKey: .binFolder) ?? z.binFolder
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? z.threads
    }
}

enum RelionLocator {
    static let requiredTools = ["relion_preprocess", "relion_refine"]

    static func tool(_ name: String, in folder: String) -> URL? {
        let u = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }
    /// What is missing from `folder` (empty = usable).
    static func problems(_ folder: String) -> [String] {
        if folder.trimmingCharacters(in: .whitespaces).isEmpty { return ["The RELION folder (the one that contains relion_refine) is not set."] }
        let missing = requiredTools.filter { tool($0, in: folder) == nil }
        return missing.isEmpty ? [] : ["Not found in \(folder): \(missing.joined(separator: ", "))."]
    }

    /// Looks for a RELION `bin` folder in the usual places and on PATH. A Finder-launched app has a short PATH, so the common install folders are listed too.
    static func detect(home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let fm = FileManager.default
        var dirs = [home + "/relion/bin", "/usr/local/relion/bin", "/opt/relion/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Applications/RELION/bin"]
        for parent in [home, home + "/Developer", home + "/software", "/opt", "/usr/local"] {
            for n in ((try? fm.contentsOfDirectory(atPath: parent)) ?? []).sorted() where n.lowercased().hasPrefix("relion") {
                dirs += [parent + "/" + n + "/bin", parent + "/" + n + "/build/bin"]
            }
        }
        dirs += path.split(separator: ":").map(String.init)
        for d in dirs where problems(d).isEmpty { return d }
        return nil
    }

    /// First line of `relion_refine --version` (nil when it cannot be run).
    static func version(_ folder: String) -> String? {
        guard let t = tool("relion_refine", in: folder) else { return nil }
        let p = Process(); p.executableURL = t; p.arguments = ["--version"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

final class RelionSettings: ObservableObject {
    static let shared = RelionSettings()
    private static let key = "relionConfig"
    private let defaults: UserDefaults
    @Published var config: RelionConfig { didSet { if config != oldValue, let d = try? JSONEncoder().encode(config) { defaults.set(d, forKey: Self.key) } } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let c = try? JSONDecoder().decode(RelionConfig.self, from: d) { config = c } else { config = RelionConfig() }
    }
    /// Fills an empty folder from what is found on disk; never replaces a folder the user chose.
    func detect() {
        if config.binFolder.isEmpty || !RelionLocator.problems(config.binFolder).isEmpty, let f = RelionLocator.detect() { config.binFolder = f }
    }
}

// MARK: parameters and geometry

struct Class2DParams: Codable, Equatable {
    var labels: [String] = []              // label ids whose picks are classified (empty = every exported label)
    var excludeMaybe = false
    var onlyDone = false
    var includeCandidates = false          // also classify unreviewed auto-pick candidates
    var minScore: Float = 0                // candidates below this score are left out (starts at the Picks tab's score cutoff)
    var angpix: Double?                    // pixel-size group to classify (nil = the group with most picks)
    var sizeNm: Double?                    // particle-size group to classify (median diameter; nil = the group with most picks)
    var sizeTolerance = 0.2                // picks whose diameters are within about ±20 % share a group; groups are never mixed
    var maskMargin = 1.0                   // mask diameter = this × the group's particle diameter
    var boxScale = 1.0                     // box = this × the group's box (from the picks, or the project's box : diameter ratio)
    var targetBoxPx = 64                   // box after scaling down (never larger than the extracted box)
    var invertContrast = false             // RELION wants bright particles; tick for dark particles on a lighter background
    var classes = 12
    var iterations = 100
    var threads = 3
    var psiStep = 12.0
    var tau2Fudge = 2.0
    var maxOffsetPx = 5
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = Class2DParams()
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? z.labels
        excludeMaybe = try c.decodeIfPresent(Bool.self, forKey: .excludeMaybe) ?? z.excludeMaybe
        onlyDone = try c.decodeIfPresent(Bool.self, forKey: .onlyDone) ?? z.onlyDone
        includeCandidates = try c.decodeIfPresent(Bool.self, forKey: .includeCandidates) ?? z.includeCandidates
        minScore = try c.decodeIfPresent(Float.self, forKey: .minScore) ?? z.minScore
        angpix = try c.decodeIfPresent(Double.self, forKey: .angpix)
        sizeNm = try c.decodeIfPresent(Double.self, forKey: .sizeNm)
        sizeTolerance = try c.decodeIfPresent(Double.self, forKey: .sizeTolerance) ?? z.sizeTolerance
        maskMargin = try c.decodeIfPresent(Double.self, forKey: .maskMargin) ?? z.maskMargin
        boxScale = try c.decodeIfPresent(Double.self, forKey: .boxScale) ?? z.boxScale
        targetBoxPx = try c.decodeIfPresent(Int.self, forKey: .targetBoxPx) ?? z.targetBoxPx
        invertContrast = try c.decodeIfPresent(Bool.self, forKey: .invertContrast) ?? z.invertContrast
        classes = try c.decodeIfPresent(Int.self, forKey: .classes) ?? z.classes
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? z.iterations
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? z.threads
        psiStep = try c.decodeIfPresent(Double.self, forKey: .psiStep) ?? z.psiStep
        tau2Fudge = try c.decodeIfPresent(Double.self, forKey: .tau2Fudge) ?? z.tau2Fudge
        maxOffsetPx = try c.decodeIfPresent(Int.self, forKey: .maxOffsetPx) ?? z.maxOffsetPx
    }
}

/// Sizes in pixels / Å that follow from the pixel size and the parameters.
struct Class2DGeometry: Equatable {
    var angpix: Double
    var extractPx: Int
    var scaledPx: Int
    var scaledAngpix: Double
    var diameterA: Double
    var bgRadiusPx: Int
    var warnings: [String] = []

    static func make(angpix: Double, boxNm: Double, diameterNm: Double, params p: Class2DParams, angstroms: Bool = UnitSettings.shared.angstroms) -> Class2DGeometry {
        func len(_ a: Double) -> String { LengthUnits.format(angstroms: a, useAngstroms: angstroms) }
        func evenUp(_ v: Double) -> Int { let n = Int(v.rounded()); return n % 2 == 0 ? n : n + 1 }      // nearest whole pixel, then up to even
        func evenDown(_ v: Int) -> Int { v % 2 == 0 ? v : v - 1 }
        var w: [String] = []
        let ext = max(16, evenUp(boxNm * p.boxScale * 10 / max(angpix, 1e-6)))
        var sc = min(max(16, evenDown(p.targetBoxPx)), ext)
        if sc < 16 { sc = 16 }
        let sAng = angpix * Double(ext) / Double(sc)
        var diam = diameterNm * p.maskMargin * 10
        let boxA = Double(ext) * angpix
        if diam > 0.9 * boxA { diam = 0.9 * boxA; w.append("The mask diameter does not fit the box; it was reduced to 90% of the box (\(len(diam))). Use a larger box.") }
        else if diam > 0.8 * boxA { w.append("The box is tight around the particle (box \(len(boxA)), particle \(len(diam))); a box of about 1.5 × the particle keeps class edges clean.") }
        if sAng > 12 { w.append("After scaling the pixel size is \(String(format: "%.1f", sAng)) Å; fine detail is lost. Raise the scaled box size.") }
        let bg = min(max(Int((0.5 * diam / sAng).rounded(.down)), 1), sc / 2 - 1)
        return Class2DGeometry(angpix: angpix, extractPx: ext, scaledPx: sc, scaledAngpix: sAng, diameterA: diam, bgRadiusPx: bg, warnings: w)
    }
}

// MARK: what can be classified

struct SourceInfo { var width: Int, height: Int, depth: Int, angpix: Double? }

enum Class2DSource {
    /// Size, number of frames and pixel size from the file header (nil when unreadable).
    static func info(_ url: URL) -> SourceInfo? {
        if AppModel.isMRC(url) {
            guard let f = try? MRCFile(url: url) else { return nil }
            return SourceInfo(width: f.width, height: f.height, depth: f.depth, angpix: f.header.pixelSizeA)
        }
        guard let f = try? DMFile(url: url), let e = f.primaryImage else { return nil }
        return SourceInfo(width: e.width, height: e.height, depth: e.depth, angpix: e.info.pixelSizeA)
    }
}

struct Class2DMic: Equatable {
    var key: String
    var url: URL
    var width: Int, height: Int
    var picks: [Pick]
}

/// Picks that may be classified together: one pixel size AND one particle size. Particles of different sizes are never mixed in a run.
struct ClassGroup: Identifiable, Equatable {
    var angpix: Double
    var sizeNm: Double                  // median particle diameter of the group
    var minNm: Double, maxNm: Double
    var boxNm: Double                   // median extraction box of the group's picks
    var mics: [Class2DMic]
    var id: String { String(format: "%.4f|%.2f", angpix, sizeNm) }
    var pickCount: Int { mics.reduce(0) { $0 + $1.picks.count } }
    var candidateCount: Int { mics.reduce(0) { $0 + $1.picks.filter { $0.status == .candidate }.count } }
    /// "20 nm", "10–12 nm (median 11)": in nm, or in Å when the display setting says so (stored sizes stay in nm).
    func sizeText(angstroms a: Bool) -> String {
        let f = { (v: Double) in LengthUnits.fromNm(v, angstroms: a) }, u = LengthUnits.name(a)
        return maxNm - minNm < 0.05 * sizeNm ? String(format: "%.3g %@", f(sizeNm), u) : String(format: "%.3g–%.3g %@ (median %.3g)", f(minNm), f(maxNm), u, f(sizeNm))
    }
    var sizeText: String { sizeText(angstroms: UnitSettings.shared.angstroms) }
}

struct Class2DInventory: Equatable {
    var groups: [ClassGroup] = []
    var skippedStackPicks = 0           // picks on multi-frame files (RELION cannot cut them from the average)
    var skippedFramePicks = 0           // picks on single frames of an unpacked stack
    var skippedNoPixelSize = 0          // micrograph has no pixel size in its header or in the project
    var skippedUnreadable = 0
    var totalPicks: Int { groups.reduce(0) { $0 + $1.pickCount } }
    var skippedPicks: Int { skippedStackPicks + skippedFramePicks + skippedNoPixelSize + skippedUnreadable }
    var pixelSizes: [Double] { Array(Set(groups.map { $0.angpix })).sorted() }

    /// The requested group (pixel size within 0.5 %, nearest particle size), else the group with most picks.
    func group(angpix: Double?, sizeNm: Double?) -> ClassGroup? {
        var pool = groups
        if let a = angpix, a > 0 { let m = groups.filter { abs($0.angpix - a) / a < 0.005 }; if !m.isEmpty { pool = m } }
        if let sz = sizeNm, sz > 0 { return pool.min { abs(log($0.sizeNm / sz)) < abs(log($1.sizeNm / sz)) } }
        return pool.max { $0.pickCount < $1.pickCount }
    }
    func group(for p: Class2DParams) -> ClassGroup? { group(angpix: p.angpix, sizeNm: p.sizeNm) }

    var skippedText: String? {
        var p: [String] = []
        if skippedStackPicks > 0 { p.append("\(skippedStackPicks) on multi-frame stacks") }
        if skippedFramePicks > 0 { p.append("\(skippedFramePicks) on single frames of unpacked stacks") }
        if skippedNoPixelSize > 0 { p.append("\(skippedNoPixelSize) without a pixel size") }
        if skippedUnreadable > 0 { p.append("\(skippedUnreadable) in unreadable files") }
        return p.isEmpty ? nil : "Left out: " + p.joined(separator: ", ") + "."
    }

    static func labels(_ p: Class2DParams, scheme: LabelScheme) -> Set<String> {
        p.labels.isEmpty ? Set(scheme.labels.filter { $0.exported }.map { $0.id }) : Set(p.labels)
    }

    static func median(_ v: [Double]) -> Double { SizeStats.quantile(v.sorted(), 0.5) }

    static func build(project: PickProject, keyMap: PickKeyMap, params p: Class2DParams, info: (URL) -> SourceInfo? = Class2DSource.info) -> Class2DInventory {
        struct Entry { var ap: Double; var d: Double; var box: Double; var mic: Class2DMic; var pick: Pick }
        var inv = Class2DInventory()
        let want = labels(p, scheme: project.scheme)
        let pp = project.params
        var ents: [Entry] = []
        for (key, rec) in project.mics.sorted(by: { $0.key < $1.key }) {
            let picks = rec.picks.filter { pk in
                (pk.status == .accepted || (p.includeCandidates && pk.status == .candidate && (pk.score ?? .infinity) >= p.minScore)) && want.contains(pk.label) && !(p.excludeMaybe && pk.isMaybe)
            }
            if picks.isEmpty || (p.onlyDone && !rec.done) { continue }
            if FrameKey.isFrame(key) || project.isHiddenAverage(key) { inv.skippedFramePicks += picks.count; continue }
            let url = keyMap.url(forKey: key)
            guard let si = info(url) else { inv.skippedUnreadable += picks.count; continue }
            if si.depth > 1 { inv.skippedStackPicks += picks.count; continue }
            guard let ap = rec.angpix ?? si.angpix, ap > 0 else { inv.skippedNoPixelSize += picks.count; continue }
            let mic = Class2DMic(key: key, url: url, width: si.width, height: si.height, picks: [])
            for pk in picks {
                let d = pk.diameterNm ?? pp.diameterNm
                // a pick's own box, else the project's box (fixed when typed in, otherwise it follows the diameter)
                let box = pk.boxNm ?? (pp.isBoxCustom ? pp.boxNm : pp.boxNm * d / max(pp.diameterNm, 1e-6))
                ents.append(Entry(ap: ap, d: d, box: box, mic: mic, pick: pk))
            }
        }
        // pixel sizes that agree within 0.5 % go together; inside them, diameters within the tolerance
        let ratio = (1 + p.sizeTolerance) / max(1 - p.sizeTolerance, 0.05)
        var byPixel: [[Entry]] = []
        for e in ents.sorted(by: { $0.ap < $1.ap }) {
            if let f = byPixel.last?.first, abs(e.ap - f.ap) / f.ap < 0.005 { byPixel[byPixel.count - 1].append(e) } else { byPixel.append([e]) }
        }
        for pg in byPixel {
            let ap = pg.reduce(0) { $0 + $1.ap } / Double(pg.count)
            var clusters: [[Entry]] = []
            for e in pg.sorted(by: { $0.d < $1.d }) {
                if let f = clusters.last?.first, e.d <= f.d * ratio { clusters[clusters.count - 1].append(e) } else { clusters.append([e]) }
            }
            for cl in clusters {
                var order: [String] = [], mics: [String: Class2DMic] = [:]
                for e in cl {
                    if mics[e.mic.key] == nil { mics[e.mic.key] = e.mic; order.append(e.mic.key) }
                    mics[e.mic.key]!.picks.append(e.pick)
                }
                let ds = cl.map { $0.d }
                inv.groups.append(ClassGroup(angpix: ap, sizeNm: median(ds), minNm: ds.min() ?? 0, maxNm: ds.max() ?? 0, boxNm: median(cl.map { $0.box }),
                                             mics: order.sorted().compactMap { mics[$0] }))
            }
        }
        inv.groups.sort { $0.angpix != $1.angpix ? $0.angpix < $1.angpix : $0.sizeNm < $1.sizeNm }
        return inv
    }
}

// MARK: the job on disk

struct Class2DJobFile: Codable, Equatable, Identifiable {
    var number: Int
    var created: Date
    var params: Class2DParams
    var angpix: Double
    var extractPx: Int
    var scaledPx: Int
    var scaledAngpix: Double
    var diameterA: Double
    var bgRadiusPx: Int
    var sizeNm: Double                   // particle size of the group this job classified (median diameter)
    var sizeRangeNm: [Double]            // smallest and largest diameter in it
    var boxNm: Double
    var micrographs: Int
    var picks: Int
    var names: [String: String]          // micrograph name used in the star files -> project key
    var particles: Int?                  // rows of the extracted particles.star
    var finalIteration: Int?
    var status: String                   // running, finished, failed, cancelled
    var id: Int { number }
    var folderName: String { String(format: "job%03d", number) }
}

enum Class2DJobs {
    static let fileName = "thon_job.json"

    static func jobDir(_ base: URL, _ n: Int) -> URL { base.appendingPathComponent("Class2D").appendingPathComponent(String(format: "job%03d", n)) }

    static func nextNumber(base: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Class2D").path)) ?? []
        return (names.compactMap { $0.hasPrefix("job") ? Int($0.dropFirst(3)) : nil }.max() ?? 0) + 1
    }

    static func write(_ j: Class2DJobFile, base: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(j) { try? d.write(to: jobDir(base, j.number).appendingPathComponent(fileName)) }
    }

    static func read(_ url: URL) -> Class2DJobFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Class2DJobFile.self, from: d)
    }

    static func all(base: URL) -> [Class2DJobFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Class2D").path)) ?? []
        return names.filter { $0.hasPrefix("job") }.compactMap { n in
            Int(n.dropFirst(3)).flatMap { read(jobDir(base, $0).appendingPathComponent(fileName)) }
        }.sorted { $0.number > $1.number }
    }

    /// Highest iteration that has a `run_itNNN_data.star` (and its star file).
    static func latestIteration(in dir: URL) -> (n: Int, star: URL)? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var best: Int?
        for f in names where f.hasPrefix("run_it") && f.hasSuffix("_data.star") {
            if let n = Int(f.dropFirst(6).prefix(3)), n > (best ?? -1) { best = n }
        }
        return best.map { ($0, dir.appendingPathComponent(String(format: "run_it%03d_data.star", $0))) }
    }

    /// The name -> key map of the job that wrote `star` (nil for a star file from elsewhere).
    static func nameMap(near star: URL) -> [String: String]? {
        read(star.deletingLastPathComponent().appendingPathComponent(fileName))?.names
    }

    /// Per-class share of the particles from `run_itNNN_model.star` (class number -> particles).
    static func classCounts(model: URL, particles: Int) -> [Int: Int] {
        guard let text = try? String(contentsOf: model, encoding: .utf8) else { return [:] }
        for t in StarFile.parse(text) {
            guard let ir = t.index("_rlnReferenceImage"), let id = t.index("_rlnClassDistribution") else { continue }
            var out: [Int: Int] = [:]
            for (i, r) in t.rows.enumerated() where ir < r.count && id < r.count {
                if let d = Double(r[id]) { out[i + 1] = Int((d * Double(particles)).rounded()) }
            }
            return out
        }
        return [:]
    }
}

// MARK: preparing the files

enum Class2DBuilder {
    static func safeName(_ s: String) -> String {
        let t = String(s.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return t.isEmpty ? "mic" : t
    }

    /// Writes everything RELION needs under `base` for job `number`. `readPixels` loads a non-MRC file (converted to MRC).
    static func prepare(base: URL, number: Int, group: ClassGroup, params: Class2DParams, geometry g: Class2DGeometry,
                        readPixels: (URL) -> (pixels: [Float], width: Int, height: Int)?) throws -> Class2DJobFile {
        let fm = FileManager.default
        let micDir = base.appendingPathComponent("Micrographs")
        let coordDir = base.appendingPathComponent("Coords").appendingPathComponent(String(format: "job%03d", number))
        for d in [micDir, coordDir, Class2DJobs.jobDir(base, number), base.appendingPathComponent("Extract").appendingPathComponent(String(format: "job%03d", number))] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        var used = Set<String>(), names: [String: String] = [:]
        var micStar = "\n# written by Thon\n\ndata_optics\n\nloop_\n_rlnOpticsGroupName #1\n_rlnOpticsGroup #2\n_rlnMicrographPixelSize #3\n_rlnMicrographOriginalPixelSize #4\n_rlnVoltage #5\n_rlnSphericalAberration #6\n_rlnAmplitudeContrast #7\n"
        micStar += "opticsGroup1 1 \(PickExporter.fmtAngpix(g.angpix)) \(PickExporter.fmtAngpix(g.angpix)) 120.0 2.7 0.1\n\ndata_micrographs\n\nloop_\n_rlnMicrographName #1\n_rlnOpticsGroup #2\n"
        var list = "\ndata_coordinate_files\n\nloop_\n_rlnMicrographName #1\n_rlnMicrographCoordinates #2\n"
        let cj = String(format: "job%03d", number)
        var picks = 0
        for m in group.mics {
            var stem = safeName(PickImporter.stem(m.key)), k = 2
            while !used.insert(stem).inserted { stem = safeName(PickImporter.stem(m.key)) + "_\(k)"; k += 1 }
            let name = "Micrographs/\(stem).mrc"
            let link = micDir.appendingPathComponent(stem + ".mrc")
            if AppModel.isMRC(m.url) {
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: m.url.path)
            } else {
                let srcDate = (try? fm.attributesOfItem(atPath: m.url.path)[.modificationDate] as? Date) ?? .distantFuture
                let have = (try? fm.attributesOfItem(atPath: link.path)).flatMap { a -> Bool in
                    (a[.type] as? FileAttributeType) == .typeRegular && ((a[.modificationDate] as? Date) ?? .distantPast) >= srcDate &&
                    (a[.size] as? Int) == 1024 + 4 * m.width * m.height } ?? false
                if !have {
                    try? fm.removeItem(at: link)
                    guard let r = readPixels(m.url) else { throw NSError(domain: "Class2D", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read \(m.url.lastPathComponent)."]) }
                    try writeMRC(url: link, pixels: r.pixels, width: r.width, height: r.height, pixelSizeA: g.angpix)
                }
            }
            try Data(PickExporter.starText(m.picks.map { ($0.x, $0.y) }).utf8).write(to: coordDir.appendingPathComponent(stem + ".star"))
            micStar += "\(name) 1\n"
            list += "\(name) Coords/\(cj)/\(stem).star\n"
            names[name] = m.key
            picks += m.picks.count
        }
        try Data(micStar.utf8).write(to: coordDir.appendingPathComponent("micrographs.star"))
        try Data(list.utf8).write(to: coordDir.appendingPathComponent("coords_list.star"))
        let job = Class2DJobFile(number: number, created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), params: params, angpix: g.angpix, extractPx: g.extractPx, scaledPx: g.scaledPx,
                                 scaledAngpix: g.scaledAngpix, diameterA: g.diameterA, bgRadiusPx: g.bgRadiusPx, sizeNm: group.sizeNm, sizeRangeNm: [group.minNm, group.maxNm], boxNm: group.boxNm, micrographs: group.mics.count, picks: picks, names: names,
                                 particles: nil, finalIteration: nil, status: "running")
        Class2DJobs.write(job, base: base)
        return job
    }

    // Command lines (relative to `base`, which is the working directory of both programs).

    static func preprocessArguments(_ j: Class2DJobFile) -> [String] {
        let c = String(format: "job%03d", j.number)
        var a = ["--i", "Coords/\(c)/micrographs.star", "--coord_list", "Coords/\(c)/coords_list.star",
                 "--part_star", "Extract/\(c)/particles.star", "--part_dir", "Extract/\(c)/",
                 "--extract", "--extract_size", String(j.extractPx), "--scale", String(j.scaledPx),
                 "--norm", "--bg_radius", String(j.bgRadiusPx)]
        if j.params.invertContrast { a.append("--invert_contrast") }
        return a
    }

    static func refineArguments(_ j: Class2DJobFile) -> [String] {
        let c = String(format: "job%03d", j.number)
        let p = j.params
        return ["--i", "Extract/\(c)/particles.star", "--o", "Class2D/\(c)/run",
                "--grad", "--iter", String(p.iterations), "--grad_write_iter", "10",
                "--K", String(p.classes), "--tau2_fudge", String(format: "%g", p.tau2Fudge),
                "--particle_diameter", String(format: "%.0f", j.diameterA),
                "--flatten_solvent", "--zero_mask", "--center_classes",
                "--psi_step", String(format: "%g", p.psiStep), "--offset_range", String(p.maxOffsetPx), "--offset_step", "2",
                "--norm", "--scale", "--pad", "2", "--pool", "30", "--dont_combine_weights_via_disc",
                "--j", String(max(1, p.threads))]
    }

    /// (iteration, total) from the last "iteration N of M" in RELION's log (the log is full of carriage-return progress bars).
    static func progress(in log: String) -> (Int, Int)? {
        var found: (Int, Int)?
        for line in log.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let r = line.range(of: "iteration ") else { continue }
            let rest = line[r.upperBound...].split(separator: " ")
            if rest.count >= 3, rest[1] == "of", let n = Int(rest[0]), let m = Int(rest[2].prefix { $0.isNumber }) { found = (n, m) }
        }
        return found
    }

    /// Lines of a RELION log that say what went wrong.
    static func errorLines(in log: String) -> [String] {
        let lines = log.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }
        let bad = lines.filter { $0.contains("ERROR") || $0.lowercased().contains("error:") || $0.hasPrefix("in:") || $0.contains("terminate") }
        return Array((bad.isEmpty ? lines.filter { !$0.contains("~~(") && !$0.isEmpty } : bad).suffix(4))
    }

    /// Mean of the middle of the extracted particles minus the mean of their outer ring, in units of the pixel spread: positive = bright particles
    /// (what RELION expects), negative = dark particles. nil when the stack cannot be read.
    static func polarity(stack: URL, maxFrames: Int = 60) -> Double? {
        guard let f = try? MRCFile(url: stack), f.width == f.height, f.width >= 16 else { return nil }
        let n = f.width
        var core = 0.0, nc = 0, ring = 0.0, nr = 0, sq = 0.0
        for fr in 0..<min(f.depth, maxFrames) {
            guard let px = try? f.readPixels(frame: fr) else { continue }
            for y in 0..<n { for x in 0..<n {
                let r = hypot(Double(x) - Double(n) / 2 + 0.5, Double(y) - Double(n) / 2 + 0.5) / Double(n)
                let v = Double(px[y * n + x])
                sq += v * v
                if r < 0.2 { core += v; nc += 1 } else if r > 0.38 && r < 0.5 { ring += v; nr += 1 }
            } }
        }
        guard nc > 0, nr > 0 else { return nil }
        let sd = (sq / Double(nc + nr + 1)).squareRoot()
        return sd > 0 ? (core / Double(nc) - ring / Double(nr)) / sd : nil
    }
}

// MARK: running RELION

/// One external program with its output in a log file; `run` returns when it ends.
final class RelionProcess {
    private(set) var process: Process?
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; let p = process; lock.unlock(); if p?.isRunning == true { p?.terminate() } }

    /// Runs `tool args` in `cwd` at low priority, stdout and stderr appended to `log`. `tick` is called about once a second.
    func run(tool: URL, args: [String], cwd: URL, log: URL, environment: [String: String] = [:], tick: () -> Void = {}) throws -> Int32 {
        let fm = FileManager.default
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: log)
        let h = try FileHandle(forWritingTo: log)
        defer { try? h.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", "19", tool.path] + args
        p.currentDirectoryURL = cwd
        p.standardOutput = h; p.standardError = h
        if !environment.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, n in n } }
        lock.lock(); if cancelled { lock.unlock(); return -1 }; process = p; lock.unlock()
        try p.run()
        var last = Date.distantPast, killed = false
        while p.isRunning {
            // a Stop that arrived before the program had started is honoured here (cancel() found nothing to terminate)
            if !killed && wasCancelled { killed = true; p.terminate() }
            Thread.sleep(forTimeInterval: 0.1)
            if Date().timeIntervalSince(last) >= 1 { last = Date(); tick() }
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

extension PickStore {
    /// The hidden folder holding the RELION work of this project (Micrographs/, Coords/, Extract/, Class2D/).
    func relionDirectory(root: URL) -> URL {
        isProjectFile ? root.appendingPathComponent("." + (projectURL!.deletingPathExtension().lastPathComponent) + "_relion") : root.appendingPathComponent(".thon-relion")
    }
}

enum Class2DPhase: Equatable { case idle, preparing, extracting, classifying, finished, failed, cancelled }

final class Class2DSession: ObservableObject {
    unowned let pc: PickController
    @Published var params = Class2DParams() {
        didSet { if params.classes != oldValue.classes && !suggesting { suggestedK = true } }       // a number typed by the user is never replaced by the suggestion
    }
    private var suggesting = false
    @Published private(set) var inventory: Class2DInventory?
    @Published private(set) var scanning = false
    @Published private(set) var phase = Class2DPhase.idle
    @Published private(set) var iteration = 0
    @Published private(set) var totalIterations = 0
    @Published private(set) var message: String?
    @Published private(set) var warning: String?
    @Published private(set) var averages: [Int: (bytes: [UInt8], size: Int)] = [:]
    @Published private(set) var counts: [Int: Int] = [:]
    @Published private(set) var jobs: [Class2DJobFile] = []
    @Published private(set) var currentJob: Class2DJobFile?
    var settings = RelionSettings.shared
    /// Loads raw pixels of a DM3/DM4 file so it can be written as MRC (set by the app).
    var pixelReader: (URL) -> (pixels: [Float], width: Int, height: Int)? = { AppModel.loadPixels(root: nil, key: $0.path) }
    private var proc: RelionProcess?
    private var suggestedK = false
    private let queue = DispatchQueue(label: "thon.class2d", qos: .utility)
    private var scanToken = 0

    init(pc: PickController) { self.pc = pc }

    var running: Bool { phase == .preparing || phase == .extracting || phase == .classifying }
    var base: URL? { pc.store.root.map { pc.store.relionDirectory(root: $0) } }
    var relionProblems: [String] { RelionLocator.problems(settings.config.binFolder) }
    /// The group the sheet has selected (pixel size and particle size).
    var selectedGroup: ClassGroup? { inventory?.group(for: params) }
    var geometry: Class2DGeometry? { selectedGroup.map { Class2DGeometry.make(angpix: $0.angpix, boxNm: $0.boxNm, diameterNm: $0.sizeNm, params: params) } }
    /// Groups with enough picks to classify at all.
    var runnableGroups: [ClassGroup] { (inventory?.groups ?? []).filter { $0.pickCount >= Class2DSession.minPicks } }
    static let minPicks = 10
    private var ready: Bool { !running && !scanning && relionProblems.isEmpty && base != nil }
    var canStart: Bool { ready && (selectedGroup?.pickCount ?? 0) >= Class2DSession.minPicks }
    var canStartAll: Bool { ready && runnableGroups.count > 1 }
    /// Groups still waiting in a "run every group" sequence.
    @Published private(set) var waiting: [ClassGroup] = []
    @Published private(set) var sequenceTotal = 0
    private var queueRunning: Bool { sequenceTotal > 0 }
    /// Classes for a group: the requested number, but at most one per 15 particles.
    static func classes(requested: Int, picks: Int) -> Int { max(2, min(requested, picks / 15)) }

    /// Fills the parameters from the project the first time (box and diameter of the project, label set, thread count).
    func seedParameters() {
        var p = params
        p.invertContrast = !pc.autoParams.bright
        p.minScore = pc.scoreCutoff
        p.threads = min(max(1, settings.config.threads), max(1, ProcessInfo.processInfo.activeProcessorCount))
        if let b = base, let d = try? Data(contentsOf: b.appendingPathComponent("last_params.json")), let last = try? JSONDecoder().decode(Class2DParams.self, from: d) {
            p.targetBoxPx = last.targetBoxPx; p.classes = last.classes; p.iterations = last.iterations; p.psiStep = last.psiStep
            p.tau2Fudge = last.tau2Fudge; p.maxOffsetPx = last.maxOffsetPx; p.includeCandidates = last.includeCandidates; p.sizeTolerance = last.sizeTolerance; p.maskMargin = last.maskMargin; p.boxScale = last.boxScale; p.excludeMaybe = last.excludeMaybe; p.invertContrast = last.invertContrast
            suggestedK = true
        }
        params = p
        refreshJobs()
    }

    func refreshJobs() { jobs = base.map { Class2DJobs.all(base: $0) } ?? [] }

    /// Counts what can be classified (reads the header of every micrograph that has picks; off the main thread).
    func scan() {
        guard !scanning else { return }
        scanning = true
        scanToken += 1
        let tk = scanToken
        let project = pc.store.project, km = pc.store.keyResolver(), p = params
        queue.async { [weak self] in
            let inv = Class2DInventory.build(project: project, keyMap: km, params: p)
            DispatchQueue.main.async {
                guard let self, tk == self.scanToken else { return }
                self.inventory = inv; self.scanning = false
                if !self.suggestedK, let g = inv.group(for: self.params) {
                    self.suggesting = true; self.params.classes = min(20, max(4, g.pickCount / 50)); self.suggesting = false; self.suggestedK = true
                }
            }
        }
    }

    /// Classifies the selected group.
    func start() {
        guard canStart, let group = selectedGroup else { return }
        waiting = []; sequenceTotal = 0
        launch(group)
    }

    /// Classifies every group in turn, each as its own job (sizes are never mixed). Stops at the first failure or when stopped.
    func startAll() {
        guard canStartAll else { return }
        var list = runnableGroups
        let first = list.removeFirst()
        waiting = list; sequenceTotal = list.count + 1
        launch(first)
    }

    private func advance() {
        guard queueRunning else { return }
        if waiting.isEmpty { sequenceTotal = 0; return }
        let next = waiting.removeFirst()
        launch(next)
    }

    private func launch(_ group: ClassGroup) {
        guard let base else { return }
        guard let refine = RelionLocator.tool("relion_refine", in: settings.config.binFolder), let pre = RelionLocator.tool("relion_preprocess", in: settings.config.binFolder) else { return }
        var p = params
        p.angpix = group.angpix; p.sizeNm = group.sizeNm
        p.classes = Class2DSession.classes(requested: params.classes, picks: group.pickCount)
        let g = Class2DGeometry.make(angpix: group.angpix, boxNm: group.boxNm, diameterNm: group.sizeNm, params: p)
        let reader = pixelReader
        let number = Class2DJobs.nextNumber(base: base)
        phase = .preparing; message = (queueRunning ? "Group \(sequenceTotal - waiting.count) of \(sequenceTotal), \(group.sizeText): " : "") + "writing coordinates and micrographs…"; warning = nil
        iteration = 0; totalIterations = p.iterations; averages = [:]; counts = [:]; currentJob = nil
        let proc = RelionProcess(); self.proc = proc
        if let d = try? JSONEncoder().encode(p) { try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true); try? d.write(to: base.appendingPathComponent("last_params.json")) }
        queue.async { [weak self] in
            func post(_ f: @escaping (Class2DSession) -> Void) { DispatchQueue.main.async { if let s = self { f(s) } } }
            var job: Class2DJobFile
            do { job = try Class2DBuilder.prepare(base: base, number: number, group: group, params: p, geometry: g, readPixels: reader) }
            catch { post { $0.phase = .failed; $0.message = "Could not prepare the files: \(error.localizedDescription)" }; return }
            func finish(_ status: String, _ msg: String, _ phase: Class2DPhase) {
                job.status = status
                Class2DJobs.write(job, base: base)
                let snapshot = job
                post { $0.phase = phase; $0.message = msg; $0.currentJob = snapshot; $0.refreshJobs(); $0.waiting = []; $0.sequenceTotal = 0 }
            }
            post { $0.currentJob = job; $0.phase = .extracting; $0.message = "Cutting out particles (relion_preprocess)…" + ($0.queueRunning ? " group \($0.sequenceTotal - $0.waiting.count) of \($0.sequenceTotal), \(group.sizeText)" : "") }
            let c = String(format: "job%03d", number)
            // 1. extraction
            let extLog = base.appendingPathComponent("Extract/\(c)/run.log")
            do {
                let st = try proc.run(tool: pre, args: Class2DBuilder.preprocessArguments(job), cwd: base, log: extLog)
                if proc.wasCancelled { finish("cancelled", "Stopped.", .cancelled); return }
                let star = base.appendingPathComponent("Extract/\(c)/particles.star")
                guard st == 0, FileManager.default.fileExists(atPath: star.path) else {
                    let log = (try? String(contentsOf: extLog, encoding: .utf8)) ?? ""
                    finish("failed", "Extraction failed: " + Class2DBuilder.errorLines(in: log).joined(separator: " | "), .failed); return
                }
                var rows = 0
                var hint: String?
                if let text = try? String(contentsOf: star, encoding: .utf8), let t = StarFile.parse(text).first(where: { $0.index("_rlnImageName") != nil }), let ii = t.index("_rlnImageName") {
                    rows = t.rows.count
                    if let first = t.rows.first, ii < first.count {
                        let stack = String(first[ii].split(separator: "@").last ?? "")
                        if let pol = Class2DBuilder.polarity(stack: base.appendingPathComponent(stack)), pol < -0.05 {
                            hint = "The extracted particles are darker than their surroundings; RELION expects bright particles. Tick \"Particles are dark\" and run again if the class averages look inverted."
                        }
                    }
                }
                job.particles = rows
                Class2DJobs.write(job, base: base)
                let jobNow = job
                guard rows >= 2 else { finish("failed", "relion_preprocess extracted \(rows) particles (picks too near the micrograph edge?).", .failed); return }
                let lost = job.picks - rows
                post { $0.warning = hint; $0.totalIterations = p.iterations
                       $0.phase = .classifying; $0.currentJob = jobNow
                       $0.message = "Classifying \(rows) particles of \(group.sizeText) into \(p.classes) classes…" + (lost > 0 ? " (\(lost) picks too near the edge were left out)" : "") }
            } catch { finish("failed", "Could not start relion_preprocess: \(error.localizedDescription)", .failed); return }
            // 2. classification
            let dir = Class2DJobs.jobDir(base, number), log = dir.appendingPathComponent("run.log")
            var shownIt = -1
            do {
                let st = try proc.run(tool: refine, args: Class2DBuilder.refineArguments(job), cwd: base, log: log, environment: ["OMP_NUM_THREADS": String(max(1, p.threads))]) {
                    let text = Class2DSession.tail(of: log)
                    let pr = Class2DBuilder.progress(in: text)
                    var avg: [Int: (bytes: [UInt8], size: Int)]?, cnt: [Int: Int]?, itNow = shownIt
                    if let latest = Class2DJobs.latestIteration(in: dir), latest.n != shownIt, latest.n > 0 {
                        let mrcs = dir.appendingPathComponent(String(format: "run_it%03d_classes.mrcs", latest.n))
                        if FileManager.default.fileExists(atPath: mrcs.path) {
                            avg = ClassMapping.loadAverages(mrcs)
                            cnt = Class2DJobs.classCounts(model: dir.appendingPathComponent(String(format: "run_it%03d_model.star", latest.n)), particles: job.particles ?? 0)
                            itNow = latest.n
                        }
                    }
                    shownIt = itNow
                    post { s in if let pr { s.iteration = pr.0; s.totalIterations = pr.1 }; if let a = avg, !a.isEmpty { s.averages = a }; if let c = cnt, !c.isEmpty { s.counts = c } }
                }
                if proc.wasCancelled { finish("cancelled", "Stopped. Iterations written so far stay in \(dir.lastPathComponent).", .cancelled); return }
                guard st == 0, let last = Class2DJobs.latestIteration(in: dir) else {
                    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    finish("failed", "Classification failed (exit \(st)): " + Class2DBuilder.errorLines(in: text).joined(separator: " | "), .failed); return
                }
                job.finalIteration = last.n
                job.status = "finished"
                Class2DJobs.write(job, base: base)
                let done = job
                post { s in
                    s.iteration = last.n; s.phase = .finished; s.currentJob = done; s.refreshJobs()
                    s.loadResult(job: done, base: base)
                    s.advance()
                }
            } catch { finish("failed", "Could not start relion_refine: \(error.localizedDescription)", .failed) }
        }
    }

    func cancel() { proc?.cancel() }

    /// Maps the last iteration of `job` onto the picks (colours, class averages, gallery sort by class).
    func loadResult(job: Class2DJobFile, base: URL) {
        let dir = Class2DJobs.jobDir(base, job.number)
        guard let last = Class2DJobs.latestIteration(in: dir) else { message = "No results in \(job.folderName)."; return }
        pc.loadClasses(star: last.star, tolerancePx: 2, nameToKey: job.names)
        if let m = pc.classes { averages = m.averages; counts = m.counts }
        message = (pc.ioMessage ?? "") + " (job \(job.number), iteration \(last.n))"
    }

    func loadJob(_ n: Int) {
        guard let base, let j = jobs.first(where: { $0.number == n }) else { return }
        currentJob = j
        loadResult(job: j, base: base)
    }

    /// Last ~8 kB of a log file as text.
    static func tail(of url: URL, bytes: Int = 8192) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
