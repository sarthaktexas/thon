import Foundation

// MARK: STAR parsing

struct StarTable {
    var name: String
    var columns: [String]
    var rows: [[String]]
    func index(_ column: String) -> Int? { columns.firstIndex { $0.caseInsensitiveCompare(column) == .orderedSame } }
}

enum StarFile {
    /// Minimal RELION STAR parser: data_ blocks, loop_ tables and key-value blocks. Comments (#) are ignored.
    static func parse(_ text: String) -> [StarTable] {
        var tables: [StarTable] = []
        var block = ""
        var cur: StarTable?
        var inLoopHeader = false, inLoopRows = false
        var kv = StarTable(name: "", columns: [], rows: [[]])
        func flushKV() { if !kv.columns.isEmpty { var t = kv; t.name = block; tables.append(t) }; kv = StarTable(name: "", columns: [], rows: [[]]) }
        func flushLoop() { if let c = cur { tables.append(c) }; cur = nil; inLoopHeader = false; inLoopRows = false }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if inLoopRows { flushLoop() }; continue }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("data_") { flushLoop(); flushKV(); block = String(line.dropFirst(5)); continue }
            if line == "loop_" { flushLoop(); flushKV(); cur = StarTable(name: block, columns: [], rows: []); inLoopHeader = true; continue }
            if line.hasPrefix("_") {
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if inLoopHeader { cur?.columns.append(toks[0]); continue }
                if cur != nil { flushLoop() }
                kv.columns.append(toks[0]); kv.rows[0].append(toks.count > 1 ? toks[1] : "")
                continue
            }
            if inLoopHeader || inLoopRows, cur != nil {
                inLoopHeader = false; inLoopRows = true
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if toks.count == cur!.columns.count { cur!.rows.append(toks) }
            }
        }
        flushLoop(); flushKV()
        return tables
    }
}

// MARK: import

struct ImportedPick { var mic: String?; var x: Double; var y: Double; var score: Float?; var label: String?; var status: PickStatus? = nil }

struct ImportPlan {
    var picks: [String: [Pick]] = [:]               // micrograph key -> new picks
    var unmatched: [String] = []                    // micrograph names that matched no known micrograph
    var unknownLabels = Set<String>()
    var notes: [String] = []
    var boxNm: Double?
    var total: Int { picks.values.reduce(0) { $0 + $1.count } }
}

enum PickImporter {
    static func stem(_ s: String) -> String {
        let name = (s as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    /// Maps a micrograph name or path (or a coordinate-file stem such as "F4a_000_core") to a known micrograph key.
    static func resolveKey(_ name: String, known: [String]) -> String? {
        if known.contains(name) { return name }
        let base = (name as NSString).lastPathComponent
        let byBase = known.filter { ($0 as NSString).lastPathComponent == base }
        if byBase.count == 1 { return byBase[0] }
        let st = stem(name)
        let byStem = known.filter { stem($0) == st }
        if byStem.count == 1 { return byStem[0] }
        if byBase.count > 1 || byStem.count > 1 {                 // ambiguous: prefer a key whose directory is a suffix of the path
            if let k = (byBase + byStem).first(where: { name.hasSuffix($0) }) { return k }
            return nil
        }
        // coordinate files are often named <micrograph>_<suffix>.star
        var best: String?
        for k in known {
            let ks = stem(k)
            guard ks.count >= 3, st.hasPrefix(ks) else { continue }
            let rest = st.dropFirst(ks.count)
            if rest.isEmpty || "_-.".contains(rest.first!), ks.count > (best.map { stem($0).count } ?? 0) { best = k }
        }
        return best
    }

    static func resolveLabel(_ s: String?, scheme: LabelScheme, fallback: String, plan: inout ImportPlan) -> String {
        guard let s, !s.isEmpty else { return fallback }
        if scheme.label(s) != nil { return s }
        if let l = scheme.labels.first(where: { $0.name.caseInsensitiveCompare(s) == .orderedSame }) { return l.id }
        plan.unknownLabels.insert(s); return fallback
    }

    static func add(_ ip: [ImportedPick], micKey: String?, known: [String], scheme: LabelScheme, label: String,
                    status: PickStatus, plan: inout ImportPlan) {
        for p in ip {
            var key = micKey
            if key == nil, let m = p.mic { key = resolveKey(m, known: known); if key == nil { plan.unmatched.append(m); continue } }
            guard let k = key else { plan.notes.append("picks without a micrograph were skipped (open the micrograph first)"); continue }
            let lab = resolveLabel(p.label, scheme: scheme, fallback: label, plan: &plan)
            let src: PickSource = p.score != nil ? .auto : .manual
            plan.picks[k, default: []].append(Pick(x: p.x, y: p.y, label: lab, score: p.score, source: src, status: p.status ?? status))
        }
    }

    // --- parsers ---

    static func coordinates(fromStar text: String) -> [ImportedPick] {
        for t in StarFile.parse(text) {
            guard let ix = t.index("_rlnCoordinateX"), let iy = t.index("_rlnCoordinateY") else { continue }
            let im = t.index("_rlnMicrographName"), isc = t.index("_rlnAutopickFigureOfMerit")
            return t.rows.compactMap { r in
                guard let x = Double(r[ix]), let y = Double(r[iy]) else { return nil }
                return ImportedPick(mic: im.map { r[$0] }, x: x, y: y, score: isc.flatMap { Float(r[$0]) }, label: nil)
            }
        }
        return []
    }

    /// `coords_list.star`: (micrograph name, coordinate file) pairs.
    static func coordinateList(fromStar text: String) -> [(mic: String, file: String)] {
        for t in StarFile.parse(text) {
            guard let a = t.index("_rlnMicrographName"), let b = t.index("_rlnMicrographCoordinates") else { continue }
            return t.rows.map { ($0[a], $0[b]) }
        }
        return []
    }

    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", inQ = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQ {
                if c == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQ = false } }
                else { field.append(c) }
            } else if c == "\"" { inQ = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// CSV with x/y columns (x_px,y_px | x,y | rlnCoordinateX,Y) and optional micrograph, label, score columns.
    static func coordinates(fromCSV text: String) -> [ImportedPick] {
        let rows = csvRows(text)
        guard let head = rows.first else { return [] }
        let h = head.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? { names.compactMap { h.firstIndex(of: $0) }.first }
        guard let ix = col(["x_px", "x", "_rlncoordinatex", "coordinatex"]), let iy = col(["y_px", "y", "_rlncoordinatey", "coordinatey"]) else { return [] }
        let im = col(["micrograph", "raw", "mic", "micrograph_name", "_rlnmicrographname"]), il = col(["label", "class_label"]), isc = col(["score", "figure_of_merit"])
        let ids = col(["dataset"])
        return rows.dropFirst().compactMap { r in
            guard r.count > max(ix, iy), let x = Double(r[ix]), let y = Double(r[iy]) else { return nil }
            var mic = im.flatMap { $0 < r.count ? r[$0] : nil }
            if let m = mic, let d = ids.flatMap({ $0 < r.count ? r[$0] : nil }), !m.contains("/"), !d.isEmpty { mic = m }   // dataset/mic names are matched by stem
            return ImportedPick(mic: mic, x: x, y: y, score: isc.flatMap { $0 < r.count ? Float(r[$0]) : nil },
                                label: il.flatMap { $0 < r.count ? r[$0] : nil })
        }
    }

    /// Web picker state (picks.json) or swipe state (swipe.json). Returns picks per "dataset/mic" name.
    static func webPicker(json data: Data) -> (picks: [ImportedPick], boxNm: Double?)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [ImportedPick] = []
        var box: Double? = nil
        if let mics = obj["mics"] as? [String: Any] {
            box = ((obj["params"] as? [String: Any])?["box_nm"] as? NSNumber)?.doubleValue
            for (key, v) in mics {
                guard let rec = v as? [String: Any], let list = rec["picks"] as? [[String: Any]] else { continue }
                for p in list {
                    guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue else { continue }
                    out.append(ImportedPick(mic: key, x: x, y: y, score: nil, label: p["label"] as? String))
                }
            }
            return (out, box)
        }
        if let dec = obj["dec"] as? [String: Any] {                      // swipe.json: card id "<dataset>/<mic>@<n>"
            box = (((obj["p"] as? [String: Any])?["box_nm"]) as? NSNumber)?.doubleValue
            for (cid, v) in dec {
                guard let d = v as? [String: Any], (d["dc"] as? NSNumber)?.boolValue != true,
                      let kind = d["d"] as? String, kind == "pick" || kind == "unsure",
                      let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue else { continue }
                let label = kind == "pick" ? ((d["l"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "oligomer") : "uncertain"
                out.append(ImportedPick(mic: String(cid.split(separator: "@", maxSplits: 1)[0]), x: x, y: y, score: nil, label: label))
            }
            return (out, box)
        }
        return nil
    }

    /// Builds an import plan from files. `currentKey` is used for coordinate files that carry no micrograph name.
    static func plan(files: [URL], known: [String], currentKey: String?, scheme: LabelScheme, defaultLabel: String,
                     asCandidates: Bool) -> ImportPlan {
        var plan = ImportPlan()
        let status: PickStatus = asCandidates ? .candidate : .accepted
        for u in files {
            let ext = u.pathExtension.lowercased()
            guard let data = try? Data(contentsOf: u) else { plan.notes.append("could not read \(u.lastPathComponent)"); continue }
            let text = String(decoding: data, as: UTF8.self)
            switch ext {
            case "json":
                guard let r = webPicker(json: data) else { plan.notes.append("\(u.lastPathComponent): not a picker state file"); continue }
                add(r.picks, micKey: nil, known: known, scheme: scheme, label: defaultLabel, status: status, plan: &plan)
                if let b = r.boxNm { plan.boxNm = b }
            case "csv":
                let ip = coordinates(fromCSV: text)
                if ip.isEmpty { plan.notes.append("\(u.lastPathComponent): no x/y columns found"); continue }
                add(ip, micKey: ip.allSatisfy({ $0.mic == nil }) ? currentKey : nil, known: known, scheme: scheme, label: defaultLabel, status: status, plan: &plan)
            case "star":
                let list = coordinateList(fromStar: text)
                if !list.isEmpty {                                       // coords_list.star -> read every coordinate file
                    for (mic, file) in list {
                        let cand = [u.deletingLastPathComponent().appendingPathComponent(file), URL(fileURLWithPath: file),
                                    u.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(file)]
                        guard let f = cand.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                              let t = try? String(contentsOf: f, encoding: .utf8) else { plan.notes.append("missing coordinate file \(file)"); continue }
                        var ip = coordinates(fromStar: t); for i in ip.indices { ip[i].mic = mic }
                        add(ip, micKey: nil, known: known, scheme: scheme, label: defaultLabel, status: status, plan: &plan)
                    }
                } else {
                    let ip = coordinates(fromStar: text)
                    if ip.isEmpty { plan.notes.append("\(u.lastPathComponent): no _rlnCoordinateX/Y columns"); continue }
                    var key = currentKey
                    if ip.contains(where: { $0.mic != nil }) { key = nil }
                    else if let k = resolveKey(u.lastPathComponent, known: known) { key = k }          // F4a_000_core.star -> F4a_000
                    add(ip, micKey: key, known: known, scheme: scheme, label: defaultLabel, status: status, plan: &plan)
                }
            default: plan.notes.append("\(u.lastPathComponent): unsupported file type")
            }
        }
        plan.unmatched = Array(Set(plan.unmatched)).sorted()
        return plan
    }
}

extension PickStore {
    /// Applies an import plan: one undoable edit per micrograph; picks within 1 px of an existing pick are skipped.
    @discardableResult
    func apply(_ plan: ImportPlan) -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        for (key, list) in plan.picks.sorted(by: { $0.key < $1.key }) {
            perform(key, "Import \(list.count) picks") { l in
                for p in list {
                    if l.contains(where: { $0.status != .dismissed && abs($0.x - p.x) < 1 && abs($0.y - p.y) < 1 }) { skipped += 1; continue }
                    l.append(p); added += 1
                }
            }
        }
        if let b = plan.boxNm { var pr = project.params; pr.boxNm = b; setParams(pr) }
        return (added, skipped)
    }
}

// MARK: export

enum ExportFormat: String, CaseIterable, Identifiable {
    case relion = "RELION .star", csv = "CSV", eman = "EMAN .box"
    var id: String { rawValue }
}

struct ExportOptions {
    var formats: Set<ExportFormat> = [.relion, .csv]
    var onlyDone = false
    var coordPrefix: String?                         // path written into coords_list_<label>.star (default: relative to the project)
}

struct ExportSummary {
    var outDir: URL
    var totals: [String: Int] = [:]                  // label id -> picks
    var micrographs = 0
    var files = 0
    var skippedLabels: [String] = []                 // labels not exported (e.g. reject)
    var total: Int { totals.values.reduce(0, +) }
}

enum PickExporter {
    static func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
    static func fmtAngpix(_ v: Double?) -> String {
        guard let v else { return "" }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s
    }
    static func csvField(_ s: String) -> String { s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }

    static func dataset(for key: String, rootName: String) -> String {
        let parent = (key as NSString).deletingLastPathComponent
        let d = parent.isEmpty || parent.hasPrefix("/") ? (parent.isEmpty ? rootName : (parent as NSString).lastPathComponent) : parent
        return d.replacingOccurrences(of: "/", with: "__")
    }

    static func starText(_ pts: [(Double, Double)]) -> String {
        "\ndata_\n\nloop_\n_rlnCoordinateX #1\n_rlnCoordinateY #2\n" + pts.map { "\(fmt1($0.0)) \(fmt1($0.1))\n" }.joined()
    }

    /// Writes the picks of `project` under `outDir` in the same layout as the web picker's picks_export/.
    /// Files written by a previous export are tracked in `.export_manifest.json` and replaced; nothing else is deleted.
    @discardableResult
    static func export(project: PickProject, root: URL, outDir: URL, options: ExportOptions) throws -> ExportSummary {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        // remove only what a previous export wrote
        let manifestURL = outDir.appendingPathComponent(".export_manifest.json")
        if let d = try? Data(contentsOf: manifestURL), let old = try? JSONDecoder().decode([String].self, from: d) {
            for f in old { try? fm.removeItem(at: outDir.appendingPathComponent(f)) }
            var dirs = Set(old.map { ($0 as NSString).deletingLastPathComponent })
            while let d = dirs.sorted(by: { $0.count > $1.count }).first, !d.isEmpty {
                dirs.remove(d)
                let u = outDir.appendingPathComponent(d)
                if (try? fm.contentsOfDirectory(atPath: u.path))?.isEmpty == true { try? fm.removeItem(at: u); dirs.insert((d as NSString).deletingLastPathComponent) }
            }
        }
        var written: [String] = []
        func write(_ text: String, _ rel: String) throws {
            let u = outDir.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
            written.append(rel)
        }
        let scheme = project.scheme
        let exportedIDs = Set(scheme.labels.filter { $0.exported }.map { $0.id })
        var sum = ExportSummary(outDir: outDir)
        sum.skippedLabels = scheme.labels.filter { !$0.exported }.map { $0.id }
        let rootName = root.lastPathComponent
        let rootPath = root.standardizedFileURL.path, outPath = outDir.standardizedFileURL.path
        let prefix = options.coordPrefix ?? (outPath.hasPrefix(rootPath + "/") ? String(outPath.dropFirst(rootPath.count + 1)) : outPath)

        struct Row { var ds, mid, raw: String; var angpix: Double?; var n: Int; var p: Pick }
        var rows: [Row] = []
        var perFile: [String: [(Double, Double)]] = [:]           // "<ds>/<label>/<mid>" -> points
        var lists: [String: [(String, String)]] = [:]             // "<ds>/<label>" -> (mic key, mid)
        var order: [String] = []
        for (key, rec) in project.mics.sorted(by: { $0.key < $1.key }) {
            if options.onlyDone && !rec.done { continue }
            let picks = rec.picks.filter { $0.status == .accepted && exportedIDs.contains($0.label) }
            if picks.isEmpty { continue }
            sum.micrographs += 1
            let ds = dataset(for: key, rootName: rootName), mid = PickImporter.stem(key)
            for (i, p) in picks.enumerated() {
                rows.append(Row(ds: ds, mid: mid, raw: key, angpix: rec.angpix, n: i + 1, p: p))
                let k = "\(ds)/\(p.label)/\(mid)"
                if perFile[k] == nil { order.append(k); lists["\(ds)/\(p.label)", default: []].append((key, mid)) }
                perFile[k, default: []].append((p.x, p.y))
                sum.totals[p.label, default: 0] += 1
            }
        }
        if options.formats.contains(.csv) {
            var lines = ["dataset,micrograph,raw,angpix,pick,x_px,y_px,label,box_nm,box_px,score,source"]
            for r in rows {
                let boxPx = r.angpix.map { fmt1(project.params.boxNm * 10 / $0) } ?? ""
                lines.append([csvField(r.ds), csvField(r.mid), csvField(r.raw), fmtAngpix(r.angpix), String(r.n), fmt1(r.p.x), fmt1(r.p.y), csvField(r.p.label),
                              String(project.params.boxNm), boxPx, r.p.score.map { String(format: "%.3f", $0) } ?? "", r.p.source.rawValue].joined(separator: ","))
            }
            try write(lines.joined(separator: "\n") + "\n", "all_picks.csv")
        }
        if options.formats.contains(.relion) {
            for k in order { try write(starText(perFile[k]!), k + ".star") }
            for (dl, mics) in lists.sorted(by: { $0.key < $1.key }) {
                let parts = dl.split(separator: "/", maxSplits: 1).map(String.init), ds = parts[0], label = parts[1]
                var t = "\ndata_coordinate_files\n\nloop_\n_rlnMicrographName #1\n_rlnMicrographCoordinates #2\n"
                for (key, mid) in mics { t += "\(key) \(prefix)/\(ds)/\(label)/\(mid).star\n" }
                try write(t, "\(ds)/coords_list_\(label).star")
            }
        }
        if options.formats.contains(.eman) {
            // corner of the box in pick coordinates (origin top-left, y down); box size in px from the micrograph's pixel size
            for k in order {
                let parts = k.split(separator: "/").map(String.init)
                let key = lists["\(parts[0])/\(parts[1])"]!.first { $0.1 == parts[2] }!.0
                let bx = project.params.boxNm * 10 / (project.mics[key]?.angpix ?? 1)
                let body = perFile[k]!.map { String(format: "%.0f\t%.0f\t%.0f\t%.0f\n", $0.0 - bx / 2, $0.1 - bx / 2, bx, bx) }.joined()
                try write(body, "box/\(parts[0])/\(parts[1])/\(parts[2]).box")
            }
        }
        if options.formats.contains(.csv) { for f in swipeFiles(project: project) { try write(f.text, f.name) } }
        sum.files = written.count
        try Data(try JSONEncoder().encode(written)).write(to: manifestURL)
        return sum
    }
}

/// `Thon --export-picks <project folder> <out dir> [--eman] [--no-csv] [--done]`
func runExportCLI(_ args: [String]) -> Int32 {
    guard let i = args.firstIndex(of: "--export-picks"), args.count > i + 2 else { print("usage: --export-picks PROJECT_DIR OUT_DIR [--eman] [--no-csv] [--done]"); return 2 }
    let root = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
    do {
        let proj = try PickStore.decode(Data(contentsOf: root.appendingPathComponent(PickStore.fileName)))
        var o = ExportOptions()
        if args.contains("--eman") { o.formats.insert(.eman) }
        if args.contains("--no-csv") { o.formats.remove(.csv) }
        o.onlyDone = args.contains("--done")
        let s = try PickExporter.export(project: proj, root: root, outDir: out, options: o)
        print("exported \(s.total) picks from \(s.micrographs) micrographs, \(s.files) files -> \(out.path)")
        return 0
    } catch { print("ERROR:", error.localizedDescription); return 1 }
}
