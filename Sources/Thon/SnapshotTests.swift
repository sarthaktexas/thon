import Foundation
import CoreGraphics
import AppKit
import Metal

private func rgba(_ img: CGImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: img.width * img.height * 4)
    out.withUnsafeMutableBytes { p in
        if let c = CGContext(data: p.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }
    return out
}

/// Headless checks for "take a picture of the view" (`Thon --picktest`).
func testSnapshot(_ t: inout TestRun) {
    t.section("picture of the view")

    // output size and frame geometry
    let r = CGRect(x: 10, y: 20, width: 200, height: 150)
    let o1 = SnapshotGeometry.outputSize(rect: r, backingScale: 2, factor: 2)
    t.check(o1.w == 800 && o1.h == 600 && o1.pxPerScreenPx == 2, "2× of a 200×150 pt frame on a 2× display is 800×600", "\(o1)")
    let o2 = SnapshotGeometry.outputSize(rect: CGRect(x: 0, y: 0, width: 3000, height: 1000), backingScale: 2, factor: 4)
    t.check(max(o2.w, o2.h) == SnapshotState.maxSide && abs(Double(o2.w) / Double(o2.h) - 3) < 0.01 && o2.pxPerScreenPx < 4, "huge frames are scaled down to the size cap, aspect kept", "\(o2)")
    let c = SnapshotGeometry.clamp(CGRect(x: -30, y: 10, width: 500, height: 5), to: CGSize(width: 400, height: 300))
    t.check(c.minX == 0 && c.maxX == 400 && c.height >= SnapshotState.minSide && c.minY >= 0 && c.maxY <= 300, "frame is kept inside the pane and not thinner than the minimum", "\(c)")
    let fr = CGRect(x: 100, y: 100, width: 200, height: 100)
    let e1 = SnapshotGeometry.edges(at: CGPoint(x: 103, y: 150), in: fr), e2 = SnapshotGeometry.edges(at: CGPoint(x: 298, y: 103), in: fr)
    let e3 = SnapshotGeometry.edges(at: CGPoint(x: 200, y: 150), in: fr), e4 = SnapshotGeometry.edges(at: CGPoint(x: 50, y: 50), in: fr)
    t.check(e1.l && !e1.r && !e1.t && !e1.b, "a press near the left edge grabs the left edge")
    t.check(e2.r && e2.t && !e2.l && !e2.b, "a press near a corner grabs both edges")
    t.check(!(e3.l || e3.r || e3.t || e3.b) && !(e4.l || e4.r || e4.t || e4.b), "inside or far outside grabs no edge")

    // overlays on a rendered picture. The micrograph part is made on the CPU here, so these run without a GPU.
    MainActor.assumeIsolated {
        let W = 1024, H = 1024
        let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pc = PickController(); pc.store.saveDelay = 0; pc.store.openProject(folder: dir)
        pc.setMicrograph(key: "m.mrc", width: W, height: H, pixelSizeA: 5)
        var pr = pc.store.project.params; pr.diameterNm = 20; pc.store.setParams(pr)                // 20 nm at 5 Å/px = 40 px
        _ = pc.store.perform("m.mrc", "fixture") { $0.append(Pick(id: "p1", x: 300, y: 400, label: pc.activeLabel, source: .manual, status: .accepted)) }
        let ms = MeasureState(); ms.setImage(key: "m.mrc")

        // screen: 1 px per point, zoom 1, view 800×600 centred on (512,512). Frame (100,100,200,150) pt = image x 212…412, y 312…462,
        // so the frame centre is image (312,387). The picture is 2×: 400×300 px.
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150), centre = CGPoint(x: 312, y: 387)
        var flat = [UInt8](repeating: 0, count: 400 * 300 * 4)
        for y in 0..<300 { for x in 0..<400 { let v = UInt8(60 + x / 8); let i = (y * 400 + x) * 4; flat[i] = v; flat[i + 1] = v; flat[i + 2] = v; flat[i + 3] = 255 } }
        let base = CGDataProvider(data: Data(flat) as CFData).flatMap {
            CGImage(width: 400, height: 300, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }!
        var bare = SnapshotOptions(); bare.markers = false; bare.boxes = false; bare.scores = false
        bare.measurements = false; bare.scaleBar = false; bare.fileName = false; bare.factor = 2
        @MainActor func deco(_ o: SnapshotOptions, caption: String? = nil) -> CGImage? {
            SnapshotRenderer.decorate(base: base, rect: rect, centre: centre, zoom: 1, backingScale: 1, imageSize: CGSize(width: W, height: H),
                                      options: o, picks: pc, measure: ms, pixelSizeA: 5, caption: caption)
        }
        let a = rgba(base)
        func changed(_ img: CGImage) -> (n: Int, minX: Int, maxX: Int, minY: Int, maxY: Int) {
            let b = rgba(img); var r = (n: 0, minX: 9999, maxX: -1, minY: 9999, maxY: -1)
            guard img.width == 400, img.height == 300 else { return r }
            for y in 0..<300 { for x in 0..<400 {
                let i = (y * 400 + x) * 4
                if (0..<3).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 12 }) {
                    r.n += 1; r.minX = min(r.minX, x); r.maxX = max(r.maxX, x); r.minY = min(r.minY, y); r.maxY = max(r.maxY, y) }
            } }
            return r
        }

        if let img = deco(bare) { t.check(img.width == 400 && img.height == 300 && changed(img).n == 0, "nothing ticked: the micrograph comes back unchanged") }
        else { t.check(false, "picture without overlays") }

        var withPick = bare; withPick.markers = true
        if let img = deco(withPick) {
            let c = changed(img)
            // pick (300,400) -> viewer (300.5,400.5) -> frame (88.5,88.5) pt -> (177,177) px; a 40 px circle is 80 px across at 2×
            let cx = Double(c.minX + c.maxX) / 2, cy = Double(c.minY + c.maxY) / 2, d = Double(c.maxX - c.minX)
            t.check(img.width == 400 && img.height == 300, "overlay step keeps the picture size", "\(img.width)×\(img.height)")
            t.check(c.n > 100 && abs(cx - 177) < 4 && abs(cy - 177) < 4 && abs(d - 84) < 12, "the marker is drawn at the pick, with the right size", "n=\(c.n) c=(\(cx),\(cy)) d=\(d)")
        } else { t.check(false, "picture with markers") }

        var withBoxes = bare; withBoxes.boxes = true
        if let img = deco(withBoxes) { t.check(changed(img).n > 50, "extraction boxes can be drawn without the markers", "\(changed(img).n)") }
        else { t.check(false, "picture with boxes") }

        // outside the frame nothing is drawn
        _ = pc.store.perform("m.mrc", "far") { l in l = [Pick(id: "far", x: 900, y: 900, label: pc.activeLabel, source: .manual, status: .accepted)] }
        if let img = deco(withPick) { t.check(changed(img).n == 0, "a pick outside the frame leaves no trace") } else { t.check(false, "picture with a far pick") }
        _ = pc.store.perform("m.mrc", "restore") { l in l = [Pick(id: "p1", x: 300, y: 400, label: pc.activeLabel, source: .manual, status: .accepted)] }

        ms.mouseDown(at: CGPoint(x: 250, y: 400), radiusPx: 5); ms.mouseDragged(to: CGPoint(x: 350, y: 400), constrain: false); ms.mouseUp(at: CGPoint(x: 350, y: 400), radiusPx: 5)
        var withRuler = bare; withRuler.measurements = true
        if let img = deco(withRuler) {
            let c = changed(img)
            // line (250..350, 400) -> frame x 38…138 pt, y 88 pt -> px x 76…276, y 176; its label sits above it
            t.check(c.n > 200 && c.minX <= 78 && c.maxX >= 274 && c.minY < 176 && c.maxY >= 174, "the ruler line and its length label are drawn where they are on screen", "\(c)")
        } else { t.check(false, "picture with a ruler") }
        if let img = deco(bare) { t.check(changed(img).n == 0, "with measurements unticked the ruler line stays out") } else { t.check(false, "picture without ruler") }

        var bar = bare; bar.scaleBar = true
        if let img = deco(bar) {
            let c = changed(img)
            t.check(c.n > 100 && c.minX < 60 && c.maxY > 250, "the scale bar is drawn in the lower left corner", "\(c)")
        } else { t.check(false, "picture with a scale bar") }

        var cap = bare; cap.fileName = true
        if let img = deco(cap, caption: "m.mrc") { let c = changed(img); t.check(c.n > 100 && c.minY < 60 && c.minX < 40, "the file name goes in the upper left corner", "\(c)") }
        else { t.check(false, "picture with a caption") }

        if let dest = ProcessInfo.processInfo.environment["THON_SNAPSHOT_DEMO"] {
            var full = SnapshotOptions(); full.boxes = true; full.scores = true; full.fileName = true
            if let img = deco(full, caption: "m.mrc  ·  5 Å/px"), let png = SnapshotRenderer.pngData(img) { try? png.write(to: URL(fileURLWithPath: dest)) }
        }
    }

    // rendering of the micrograph part: needs Metal
    guard let dev = MTLCreateSystemDefaultDevice() else { print("  (no Metal device: skipping the Metal render checks)"); return }
    MainActor.assumeIsolated {
        do {
            let W = 1024, H = 1024
            var px = [Float](repeating: 0, count: W * H)
            for y in 0..<H { for x in 0..<W { px[y * W + x] = Float(x) / Float(W - 1) } }       // brightness grows to the right
            let screen = ViewState()
            let rend = try MicrographRenderer(device: dev, pixelFormat: .bgra8Unorm, state: screen)
            rend.setImage(width: W, height: H, pixels: px, mean: 0.5)
            screen.lo = 0; screen.hi = 1; screen.gamma = 1
            screen.zoom = 1; screen.center = CGPoint(x: 512, y: 512); screen.backingScale = 1
            screen.viewPixels = CGSize(width: 800, height: 600); screen.imageSize = CGSize(width: W, height: H)
            let pc = PickController(), ms = MeasureState()
            var bare = SnapshotOptions(); bare.markers = false; bare.boxes = false; bare.scores = false
            bare.measurements = false; bare.scaleBar = false; bare.fileName = false; bare.factor = 2
            let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
            guard let plain = SnapshotRenderer.compose(renderer: rend, screen: screen, rect: rect, options: bare, picks: pc, measure: ms, pixelSizeA: 5, caption: nil) else {
                t.check(false, "picture renders"); return
            }
            t.check(plain.width == 400 && plain.height == 300, "picture is 400×300 px at 2× of a 200×150 pt frame", "\(plain.width)×\(plain.height)")
            let a = rgba(plain)
            let left = Int(a[(150 * 400 + 2) * 4]), right = Int(a[(150 * 400 + 397) * 4])
            t.check(abs(left - Int(212.0 / 1023 * 255)) <= 6 && abs(right - Int(411.0 / 1023 * 255)) <= 6, "the crop shows the part of the image inside the frame (left edge ≈ x 212, right ≈ x 412)", "\(left) \(right)")
            t.check(screen.zoom == 1 && screen.center == CGPoint(x: 512, y: 512) && screen.viewPixels == CGSize(width: 800, height: 600), "taking a picture leaves the on-screen view as it was")
            var big = bare; big.factor = 4
            if let img = SnapshotRenderer.compose(renderer: rend, screen: screen, rect: rect, options: big, picks: pc, measure: ms, pixelSizeA: 5, caption: nil) {
                t.check(img.width == 800 && img.height == 600, "4× gives 800×600", "\(img.width)×\(img.height)")
            }
        } catch { t.check(false, "renderer set-up", error.localizedDescription) }
    }
}
