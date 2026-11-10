import Foundation
import Accelerate
import CoreGraphics

struct PowerSpectrum {
    let n: Int
    let logPower: [Float]      // n*n, fft-shifted, log10(power)
    let normPower: [Float]     // n*n, fft-shifted, log10(power / radial mean)
    let profile: [Float]       // radial mean of linear power, index = radius in FFT pixels (0...n/2)
    let imageLog: CGImage?
    let imageNorm: CGImage?

    /// Spatial frequency (1/Å) of radius index r for pixel size p (Å).
    func frequency(radius r: Double, pixelSizeA p: Double) -> Double { r / (Double(n) * p) }
}

func computePowerSpectrum(pixels: [Float], width: Int, height: Int, maxN: Int = 2048) -> PowerSpectrum? {
    var n = 1
    while n * 2 <= min(width, height) && n * 2 <= maxN { n *= 2 }
    guard n >= 64 else { return nil }
    let log2n = vDSP_Length(Int(log2(Double(n))))
    let x0 = (width - n) / 2, y0 = (height - n) / 2

    var mean = 0.0
    for y in 0..<n { pixels.withUnsafeBufferPointer { b in for x in 0..<n { mean += Double(b[(y0 + y) * width + x0 + x]) } } }
    mean /= Double(n * n)

    let win: [Float] = (0..<n).map { 0.5 - 0.5 * Float(cos(2 * Double.pi * (Double($0) + 0.5) / Double(n))) }
    var re = [Float](repeating: 0, count: n * n)
    var im = [Float](repeating: 0, count: n * n)
    pixels.withUnsafeBufferPointer { b in
        for y in 0..<n {
            let wy = win[y]
            for x in 0..<n { re[y * n + x] = (b[(y0 + y) * width + x0 + x] - Float(mean)) * wy * win[x] }
        }
    }
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
    defer { vDSP_destroy_fftsetup(setup) }
    var power = [Float](repeating: 0, count: n * n)
    re.withUnsafeMutableBufferPointer { rp in
        im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft2d_zip(setup, &split, 1, vDSP_Stride(n), log2n, log2n, FFTDirection(FFT_FORWARD))
            power.withUnsafeMutableBufferPointer { pp in
                vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(n * n))
            }
        }
    }
    re = []; im = []

    // fft-shift and radial average
    let h = n / 2
    var shifted = [Float](repeating: 0, count: n * n)
    var rsum = [Double](repeating: 0, count: h + 1)
    var rcnt = [Double](repeating: 0, count: h + 1)
    for y in 0..<n {
        let sy = (y + h) % n
        for x in 0..<n {
            let sx = (x + h) % n
            let v = power[y * n + x]
            shifted[sy * n + sx] = v
            let r = Int((Double((sx - h) * (sx - h) + (sy - h) * (sy - h))).squareRoot() + 0.5)
            if r <= h { rsum[r] += Double(v); rcnt[r] += 1 }
        }
    }
    let profile: [Float] = (0...h).map { rcnt[$0] > 0 ? Float(rsum[$0] / rcnt[$0]) : 0 }
    var logP = [Float](repeating: 0, count: n * n)
    var normP = [Float](repeating: 0, count: n * n)
    for y in 0..<n {
        for x in 0..<n {
            let v = shifted[y * n + x]
            logP[y * n + x] = log10f(v + 1e-12)
            let r = min(h, Int((Double((x - h) * (x - h) + (y - h) * (y - h))).squareRoot() + 0.5))
            normP[y * n + x] = log10f((v + 1e-12) / (profile[r] + 1e-12))
        }
    }
    return PowerSpectrum(n: n, logPower: logP, normPower: normP, profile: profile,
                         imageLog: grayImage(logP, n: n, lowPct: 1, highPct: 99.8, mask: 2),
                         imageNorm: grayImage(normP, n: n, lowPct: 2, highPct: 99.7, mask: 2))
}

/// 8-bit grayscale CGImage with percentile contrast (computed from a strided sample, excluding a central DC mask).
func grayImage(_ a: [Float], n: Int, lowPct: Double, highPct: Double, mask: Int) -> CGImage? {
    var sample: [Float] = []
    let stride = max(1, n * n / 200_000)
    var i = 0
    while i < a.count {
        let y = i / n, x = i % n
        if abs(x - n / 2) > mask || abs(y - n / 2) > mask { sample.append(a[i]) }
        i += stride
    }
    guard !sample.isEmpty else { return nil }
    sample.sort()
    func pct(_ p: Double) -> Float { sample[min(sample.count - 1, Int(p / 100 * Double(sample.count - 1)))] }
    let lo = pct(lowPct), hi = max(pct(highPct), lo + 1e-9)
    var bytes = [UInt8](repeating: 0, count: n * n)
    let s = 255 / (hi - lo)
    for k in 0..<(n * n) { bytes[k] = UInt8(max(0, min(255, (a[k] - lo) * s))) }
    guard let prov = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}
