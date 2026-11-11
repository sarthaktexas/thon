import Foundation
import Vision
import CoreGraphics

/// Generic image embedding from Apple's Vision framework (a Core ML model that the system may run on the Neural Engine).
/// Optional extra for the swipe assistant. Returns nil on any failure; the assistant then keeps using its hand-made features.
enum CoreMLEmbedding {
    static func embed(gray: [UInt8], size: Int) -> [Float]? {
        guard size >= 8, gray.count == size * size else { return nil }
        var bytes = gray
        let image: CGImage? = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return ctx.makeImage()            // copies the pixels
        }
        guard let image else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill       // keep the whole crop
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        guard let o = request.results?.first as? VNFeaturePrintObservation, o.elementType == .float, o.elementCount > 0 else { return nil }
        let n = o.elementCount
        return o.data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self).prefix(n)) }
    }
}
