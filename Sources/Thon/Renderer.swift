import Metal
import MetalKit
import Accelerate

struct Uniforms {
    var viewSize: SIMD2<Float>
    var center: SIMD2<Float>
    var imgSize: SIMD2<Float>
    var levelSize: SIMD2<Float>
    var zoom: Float
    var lo: Float
    var hi: Float
    var gamma: Float
    var invert: Int32
    var level: Int32
    var nearest: Int32
    var pad: Int32 = 0
}

final class MicrographRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let state: ViewState
    private let renderPSO: MTLRenderPipelineState
    private let downPSO, ghPSO, gvPSO, flatPSO: MTLComputePipelineState

    private(set) var width = 0, height = 0
    private var rawMean: Double = 0
    private var src: MTLTexture?
    private var srcPyramid: [MTLTexture] = []
    private var proc: MTLTexture?
    private var pyramid: [MTLTexture] = []
    private var token = 0

    /// Called on the main thread with statistics of the *processed* image (nil = processed == raw).
    var onProcessedStats: ((ImageStats?) -> Void)?

    init(device dev: MTLDevice, pixelFormat: MTLPixelFormat, state: ViewState) throws {
        guard let q = dev.makeCommandQueue() else { throw DMError.unsupported("Could not create a Metal command queue") }
        self.device = dev; self.queue = q; self.state = state
        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: metalSource, options: nil) }
        catch { throw DMError.unsupported("Metal shader compilation failed: \(error.localizedDescription)") }
        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = lib.makeFunction(name: "vs_main")
        rd.fragmentFunction = lib.makeFunction(name: "fs_main")
        rd.colorAttachments[0].pixelFormat = pixelFormat
        renderPSO = try dev.makeRenderPipelineState(descriptor: rd)
        func cp(_ n: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: n) else { throw DMError.unsupported("Missing Metal function \(n)") }
            return try dev.makeComputePipelineState(function: f)
        }
        downPSO = try cp("downsample2x"); ghPSO = try cp("gauss_h"); gvPSO = try cp("gauss_v"); flatPSO = try cp("flatten")
        super.init()
    }

    // MARK: textures

    private func makeTexture(_ w: Int, _ h: Int, shared: Bool) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = shared ? (device.hasUnifiedMemory ? .shared : .managed) : .private
        return device.makeTexture(descriptor: d)!
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
        enc.setComputePipelineState(pso)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    private func levelCount(_ w: Int, _ h: Int) -> Int {
        var l = 1
        while min(w, h) >> l >= 64 { l += 1 }
        return l
    }

    /// Extends `levels` (index 0 = base) with 2x box-downsampled textures up to `count` levels.
    private func extendPyramid(_ levels: inout [MTLTexture], to count: Int, cmd: MTLCommandBuffer) {
        guard levels.count < count, let enc = cmd.makeComputeCommandEncoder() else { return }
        for i in levels.count..<count {
            let prev = levels[i - 1]
            let t = makeTexture(max(1, width >> i), max(1, height >> i), shared: false)
            enc.setTexture(prev, index: 0); enc.setTexture(t, index: 1)
            dispatch(enc, downPSO, t.width, t.height)
            levels.append(t)
        }
        enc.endEncoding()
    }

    private func gaussWeights(_ sigma: Double) -> ([Float], Int) {
        let r = max(1, min(Int((3.5 * sigma).rounded(.up)), 300))
        var w = (0...r).map { Float(exp(-0.5 * Double($0 * $0) / (sigma * sigma))) }
        let sum = w[0] + 2 * w.dropFirst().reduce(0, +)
        w = w.map { $0 / sum }
        return (w, r)
    }

    private func blur(_ input: MTLTexture, sigma: Double, cmd: MTLCommandBuffer, outShared: Bool) -> MTLTexture {
        let (w, r) = gaussWeights(sigma)
        var radius = Int32(r)
        let tmp = makeTexture(input.width, input.height, shared: false)
        let out = makeTexture(input.width, input.height, shared: outShared)
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setBytes(w, length: w.count * 4, index: 0)
            enc.setBytes(&radius, length: 4, index: 1)
            enc.setTexture(input, index: 0); enc.setTexture(tmp, index: 1)
            dispatch(enc, ghPSO, input.width, input.height)
            enc.setTexture(tmp, index: 0); enc.setTexture(out, index: 1)
            dispatch(enc, gvPSO, input.width, input.height)
            enc.endEncoding()
        }
        return out
    }

    // MARK: public API

    func setImage(width w: Int, height h: Int, pixels: [Float], mean: Double) {
        width = w; height = h; rawMean = mean
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let t = device.makeTexture(descriptor: d)!
        pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        src = t
        srcPyramid = [t]
        state.imageSize = CGSize(width: w, height: h)
        state.pendingFit = true
        reprocess()
    }

    /// Re-run low-pass / flatten from the raw image and rebuild the display pyramid.
    func reprocess() {
        guard let src, let cmd = queue.makeCommandBuffer() else { return }
        token += 1
        let myToken = token
        let lp = state.lowpassSigma, fl = state.flattenSigma
        var cur = src
        let processed = lp > 0 || fl > 0
        if lp > 0 { cur = blur(cur, sigma: lp, cmd: cmd, outShared: fl <= 0) }
        if fl > 0 {
            let k = max(1, min(Int(log2(max(fl, 4) / 4).rounded()), levelCount(width, height) - 1))
            extendPyramid(&srcPyramid, to: k + 1, cmd: cmd)
            let bg = blur(srcPyramid[k], sigma: max(1.0, fl / Double(1 << k)), cmd: cmd, outShared: false)
            let out = makeTexture(width, height, shared: true)
            var inv = Float(1.0 / Double(1 << k)), off = Float(rawMean)
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setTexture(cur, index: 0); enc.setTexture(bg, index: 1); enc.setTexture(out, index: 2)
                enc.setBytes(&inv, length: 4, index: 0); enc.setBytes(&off, length: 4, index: 1)
                dispatch(enc, flatPSO, width, height)
                enc.endEncoding()
            }
            cur = out
        }
        proc = cur
        var levels = [cur]
        extendPyramid(&levels, to: levelCount(width, height), cmd: cmd)
        pyramid = levels

        if processed {
            if !device.hasUnifiedMemory, let blit = cmd.makeBlitCommandEncoder() { blit.synchronize(resource: cur); blit.endEncoding() }
            let w = width, h = height
            cmd.addCompletedHandler { [weak self] _ in
                var px = [Float](repeating: 0, count: w * h)
                px.withUnsafeMutableBytes { cur.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
                let st = ImageStats.compute(px)
                DispatchQueue.main.async {
                    guard let self, self.token == myToken else { return }
                    self.onProcessedStats?(st)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in if self?.token == myToken { self?.onProcessedStats?(nil) } }
        }
        cmd.commit()
    }

    /// Block until all queued GPU work has finished.
    func waitIdle() { if let c = queue.makeCommandBuffer() { c.commit(); c.waitUntilCompleted() } }

    /// Synchronous read-back of the processed image (for export).
    func readProcessed() -> [Float]? {
        guard let proc, let cmd = queue.makeCommandBuffer() else { return nil }
        if !device.hasUnifiedMemory, let blit = cmd.makeBlitCommandEncoder() { blit.synchronize(resource: proc); blit.endEncoding() }
        cmd.commit(); cmd.waitUntilCompleted()
        var px = [Float](repeating: 0, count: width * height)
        px.withUnsafeMutableBytes { proc.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return px
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        state.viewPixels = size
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        state.viewPixels = size
        if state.pendingFit, size.width > 1 {
            state.pendingFit = false
            DispatchQueue.main.async { [state] in state.fit() }
        }
        state.backingScale = Double(view.window?.backingScaleFactor ?? 2)
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encodeScene(enc, size: size)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    func encodeScene(_ enc: MTLRenderCommandEncoder, size: CGSize) {
        guard !pyramid.isEmpty, width > 0 else { return }
        let zoom = max(state.zoom, 1e-4)
        let lvl = zoom < 1 ? min(max(Int(floor(log2(1.0 / zoom))), 0), pyramid.count - 1) : 0
        let tex = pyramid[lvl]
        var u = Uniforms(viewSize: SIMD2(Float(size.width), Float(size.height)),
                         center: SIMD2(Float(state.center.x), Float(state.center.y)),
                         imgSize: SIMD2(Float(width), Float(height)),
                         levelSize: SIMD2(Float(tex.width), Float(tex.height)),
                         zoom: Float(zoom), lo: Float(state.lo), hi: Float(state.hi), gamma: Float(max(state.gamma, 0.05)),
                         invert: state.invert ? 1 : 0, level: Int32(lvl), nearest: zoom >= 2 ? 1 : 0)
        enc.setRenderPipelineState(renderPSO)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Render the current view into an offscreen BGRA8 buffer (used by --render and --selftest).
    func renderOffscreen(width w: Int, height h: Int) -> [UInt8]? {
        state.viewPixels = CGSize(width: w, height: h)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let t = device.makeTexture(descriptor: d), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = t
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.075, green: 0.078, blue: 0.086, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encodeScene(enc, size: CGSize(width: w, height: h))
        enc.endEncoding()
        if !device.hasUnifiedMemory, let blit = cmd.makeBlitCommandEncoder() { blit.synchronize(resource: t); blit.endEncoding() }
        cmd.commit(); cmd.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        return out
    }
}
