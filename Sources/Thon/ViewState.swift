import SwiftUI
import Combine

enum AutoMode: String, CaseIterable, Identifiable {
    case percentile = "Percentile", sigma = "Mean ± nσ"
    var id: String { rawValue }
}

/// All user-adjustable display parameters. Zoom is in drawable (physical) pixels per image pixel.
final class ViewState: ObservableObject {
    @Published var zoom: Double = 1
    @Published var center = CGPoint.zero
    @Published var lo: Double = 0
    @Published var hi: Double = 1
    @Published var gamma: Double = 1
    @Published var invert = false

    @Published var lowpassSigma: Double = 0      // image pixels, 0 = off
    @Published var flattenSigma: Double = 0      // image pixels, 0 = off

    @Published var autoContrast = true
    @Published var autoMode: AutoMode = .percentile
    @Published var lowPct: Double = 0.5
    @Published var highPct: Double = 99.5
    @Published var sigmaN: Double = 3

    @Published var displayStats: ImageStats?
    @Published var imageSize = CGSize.zero

    // Non-published (set by the Metal view; avoids publishing during view updates)
    var viewPixels = CGSize(width: 800, height: 600)
    var backingScale: Double = 2
    var pendingFit = false
    var pendingFocus: (center: CGPoint, zoom: Double)?      // applied after the next fit (used by "go to pick")

    func applyAuto() {
        guard autoContrast, let s = displayStats else { return }
        switch autoMode {
        case .percentile:
            lo = s.percentile(lowPct); hi = s.percentile(highPct)
        case .sigma:
            lo = s.mean - sigmaN * s.std; hi = s.mean + sigmaN * s.std
        }
        if hi <= lo { hi = lo + 1e-6 }
    }

    func fitZoom() -> Double {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return 0.97 * min(viewPixels.width / imageSize.width, viewPixels.height / imageSize.height)
    }

    func fit() {
        zoom = fitZoom()
        center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        if let f = pendingFocus { pendingFocus = nil; center = f.center; zoom = f.zoom }
    }

    func setZoom(_ z: Double, about p: CGPoint? = nil) {
        let nz = min(max(z, 0.01), 256)
        if let p {   // p in drawable pixels relative to view origin (top-left)
            let dx = p.x - viewPixels.width / 2, dy = p.y - viewPixels.height / 2
            let imgX = center.x + dx / zoom, imgY = center.y + dy / zoom
            center = CGPoint(x: imgX - dx / nz, y: imgY - dy / nz)
        }
        zoom = nz
    }
}

/// High-frequency cursor readout, kept out of ViewState so the whole UI is not invalidated on mouse move.
final class CursorState: ObservableObject {
    @Published var x: Int?
    @Published var y: Int?
    @Published var value: Float?
    var pixels: [Float] = []
    var width = 0, height = 0

    func set(image px: CGPoint?) {
        guard let px, width > 0, px.x >= 0, px.y >= 0, Int(px.x) < width, Int(px.y) < height else {
            if x != nil { x = nil; y = nil; value = nil }
            return
        }
        let ix = Int(px.x), iy = Int(px.y)
        x = ix; y = iy
        value = pixels.isEmpty ? nil : pixels[iy * width + ix]
    }
}
