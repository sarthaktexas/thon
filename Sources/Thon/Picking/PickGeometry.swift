import Foundation
import CoreGraphics

/// Image <-> view transform, mirroring ViewState / InteractiveMTKView.
/// "Viewer image coordinates" are continuous with pixel i spanning [i, i+1).
/// "Pick coordinates" are array indices (pixel center = integer), as used by numpy, mrcfile and RELION,
/// so pick = viewer - 0.5.
struct ViewGeometry {
    var zoom: Double                  // drawable px per image px
    var center: CGPoint               // viewer image coords at the center of the view
    var viewPixels: CGSize            // drawable size in px
    var backingScale: Double          // drawable px per point

    /// viewer image coords -> view points (origin top-left)
    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: ((p.x - center.x) * zoom + viewPixels.width / 2) / backingScale,
                y: ((p.y - center.y) * zoom + viewPixels.height / 2) / backingScale)
    }
    /// view points -> viewer image coords
    func toImage(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (pt.x * backingScale - viewPixels.width / 2) / zoom,
                y: center.y + (pt.y * backingScale - viewPixels.height / 2) / zoom)
    }
    func pickToView(x: Double, y: Double) -> CGPoint { toView(CGPoint(x: x + 0.5, y: y + 0.5)) }
    func viewToPick(_ pt: CGPoint) -> CGPoint { let p = toImage(pt); return CGPoint(x: p.x - 0.5, y: p.y - 0.5) }
    /// points per image pixel
    var pointsPerPixel: Double { zoom / backingScale }
}

/// Renders a (2*half)² crop centered on pick coordinates (cx, cy) as 8-bit gray with the viewer's contrast mapping.
/// Pixels outside the image are mid-gray. Row 0 = top.
func renderCrop(pixels: [Float], width: Int, height: Int, cx: Double, cy: Double, half: Int,
                lo: Double, hi: Double, gamma: Double = 1, invert: Bool = false) -> [UInt8] {
    let n = 2 * half
    var out = [UInt8](repeating: 128, count: n * n)
    let x0 = Int(cx.rounded()) - half, y0 = Int(cy.rounded()) - half
    let span = Float(max(hi - lo, 1e-12)), l = Float(lo), g = Float(max(gamma, 0.05))
    for j in 0..<n {
        let y = y0 + j
        guard y >= 0, y < height else { continue }
        for i in 0..<n {
            let x = x0 + i
            guard x >= 0, x < width else { continue }
            var v = min(max((pixels[y * width + x] - l) / span, 0), 1)
            if g != 1 { v = powf(v, g) }
            if invert { v = 1 - v }
            out[j * n + i] = UInt8(v * 255 + 0.5)
        }
    }
    return out
}

func grayCGImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard bytes.count == width * height, let prov = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}
