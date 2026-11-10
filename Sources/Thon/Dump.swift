import Foundation

/// Headless inspection: `Thon --dump file.dm4 [--tags] [--fft]`
func runDump(_ args: [String]) {
    guard let path = args.drop(while: { $0 != "--dump" }).dropFirst().first(where: { !$0.hasPrefix("--") }) else {
        print("usage: Thon --dump FILE [--tags] [--fft]"); return
    }
    do {
        let f = try DMFile(url: URL(fileURLWithPath: path))
        print("version", f.version, "little", f.littleEndian, "images", f.images.count)
        for e in f.images {
            print("image[\(e.index)] \(e.name) dims=\(e.dims) type=\(e.dataType)(\(e.dataTypeName)) offset=\(e.data.offset) count=\(e.data.count) px=\(e.pixelSizeA.map { String($0) } ?? "nil") Å")
        }
        guard let e = f.primaryImage else { print("no primary image"); return }
        let t0 = Date()
        let px = try f.readPixels(e)
        let t1 = Date()
        let st = ImageStats.compute(px)
        let t2 = Date()
        print(String(format: "primary=%d  read %.3fs  stats %.3fs", e.index, t1.timeIntervalSince(t0), t2.timeIntervalSince(t1)))
        print("min", st.min, "max", st.max, "mean", st.mean, "std", st.std)
        print("p0.5", st.percentile(0.5), "p50", st.percentile(50), "p99.5", st.percentile(99.5))
        print("px[0..4]", px.prefix(5).map { $0 }, "center", px[(e.height / 2) * e.width + e.width / 2])
        for s in f.buildSections(entry: e, stats: st) {
            print("== \(s.title)")
            for r in s.rows { print("  \(r.label): \(r.value)") }
        }
        if args.contains("--tags") { for t in f.flatTags() { print(t.path, "=", t.value) } }
        if args.contains("--fft") {
            let t3 = Date()
            if let ps = computePowerSpectrum(pixels: px, width: e.width, height: e.height) {
                print(String(format: "fft n=%d  %.3fs", ps.n, Date().timeIntervalSince(t3)))
                print("profile[1,2,5,10,50,100] =", [1, 2, 5, 10, 50, 100].map { ps.profile[$0] })
            }
        }
        let m = f.quickMeta()
        print("meta", m)
    } catch { print("ERROR:", error.localizedDescription) }
}
