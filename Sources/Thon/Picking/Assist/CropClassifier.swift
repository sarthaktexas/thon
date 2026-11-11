import Foundation
import CoreML
import CreateML
import Vision
import CoreGraphics
import ImageIO

/// A Core ML image classifier trained on the crops you review in the crop editor (Apple's CreateML, on this Mac).
///
/// Every reviewed pick is saved as a small grayscale picture (2.5 particle diameters wide, resampled to `side` x `side`)
/// in the hidden folder `.<project>.assist/crops/yes` or `.../no`. Training uses CreateML's image classifier (transfer learning on Apple's
/// scene-print features) in the background after a crop is finished; the finished model is compiled, kept next to the
/// pictures and used only to ORDER the remaining crops (uncertain first). It never decides anything.
/// If CreateML or Vision fails (no model, too few pictures, an error), `ready` stays false and the hand-feature
/// logistic model of `Reranker` keeps doing the ordering. Not exercised in the agent sandbox (no Core ML runtime there).
final class CropClassifier: ObservableObject {
    static let side = 96
    static let minEach = 10

    @Published private(set) var training = false
    @Published private(set) var ready = false
    @Published private(set) var validationAccuracy: Double?
    @Published private(set) var trainedOn = 0
    @Published private(set) var message = "No Core ML model yet"
    @Published var enabled = true { didSet { if enabled != oldValue { enabledChanged() } } }
    /// Called on the main thread when a new model is ready, so the owner can re-order the remaining crops.
    var onChange: (() -> Void)?

    private(set) var folder: URL?
    private var vn: VNCoreMLModel?
    private var again = false
    private let queue = DispatchQueue(label: "thon.coreml", qos: .utility)

    // MARK: location

    /// Hidden (dot-prefixed) so the project folder stays tidy: `.<name>.assist` next to the project file.
    static func folder(forProject url: URL?) -> URL? {
        guard let url else { return nil }
        let base = url.deletingPathExtension()
        return base.deletingLastPathComponent().appendingPathComponent("." + base.lastPathComponent).appendingPathExtension("assist")
    }
    private var cropsDir: URL? { folder?.appendingPathComponent("crops") }
    private var modelURL: URL? { folder?.appendingPathComponent("crop.mlmodelc") }

    /// Switches to the model folder of another project and loads a model trained earlier, if there is one.
    func use(project url: URL?) {
        let f = Self.folder(forProject: url)
        guard f != folder else { return }
        folder = f; vn = nil; ready = false; validationAccuracy = nil; trainedOn = 0; message = "No Core ML model yet"
        if let m = modelURL, FileManager.default.fileExists(atPath: m.path) { load(m) }
        counts()
    }

    // MARK: sample pictures

    private func file(_ name: String, yes: Bool) -> URL? {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return cropsDir?.appendingPathComponent(yes ? "yes" : "no").appendingPathComponent(safe + ".png")
    }

    /// Stores (or replaces) the picture of one decision. A name is unique per micrograph and pick.
    @discardableResult func save(gray: [UInt8], name: String, yes: Bool) -> Bool {
        guard gray.count == Self.side * Self.side, let u = file(name, yes: yes), let other = file(name, yes: !yes) else { return false }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: other)
        guard let img = Self.cgImage(gray: gray, size: Self.side), let dest = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    func forget(name: String) {
        for yes in [true, false] { if let u = file(name, yes: yes) { try? FileManager.default.removeItem(at: u) } }
    }

    func pictureCounts() -> (yes: Int, no: Int) {
        func n(_ d: String) -> Int {
            guard let u = cropsDir?.appendingPathComponent(d) else { return 0 }
            return ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0.hasSuffix(".png") }.count
        }
        return (n("yes"), n("no"))
    }
    private func counts() {
        let c = pictureCounts()
        if !ready && !training { message = c.yes >= Self.minEach && c.no >= Self.minEach ? "Ready to train (\(c.yes) yes, \(c.no) no pictures)" : "Core ML model: \(c.yes) yes, \(c.no) no pictures so far (needs \(Self.minEach) of each)" }
    }

    static func cgImage(gray: [UInt8], size: Int) -> CGImage? {
        guard gray.count == size * size else { return nil }
        var bytes = gray
        return bytes.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: training

    private func enabledChanged() { if enabled { retrain() } else { counts() } }

    /// Trains in the background when enough pictures of both kinds exist; a request during training runs once more afterwards.
    func retrain() {
        guard enabled, let crops = cropsDir, let modelURL, let folder else { return }
        let c = pictureCounts()
        guard c.yes >= Self.minEach, c.no >= Self.minEach else { counts(); return }
        if training { again = true; return }
        training = true; message = "Training Core ML model on \(c.yes + c.no) crops…"
        queue.async { [weak self] in
            var result: (VNCoreMLModel, Double?, Int)?
            var err: String?
            do {
                let src = MLImageClassifier.DataSource.labeledDirectories(at: crops)
                let params = MLImageClassifier.ModelParameters(validation: .split(strategy: .automatic), maxIterations: 25, augmentation: [.flip, .rotation])
                let clf = try MLImageClassifier(trainingData: src, parameters: params)
                let ve = 1 - clf.validationMetrics.classificationError
                let tmp = folder.appendingPathComponent("crop.mlmodel")
                try clf.write(to: tmp)
                let compiled = try MLModel.compileModel(at: tmp)
                try? FileManager.default.removeItem(at: modelURL)
                try FileManager.default.copyItem(at: compiled, to: modelURL)
                try? FileManager.default.removeItem(at: tmp)
                let ml = try MLModel(contentsOf: modelURL)
                result = (try VNCoreMLModel(for: ml), ve.isFinite ? ve : nil, c.yes + c.no)
            } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.training = false
                if let r = result {
                    self.vn = r.0; self.ready = true; self.validationAccuracy = r.1; self.trainedOn = r.2
                    self.message = "Core ML model trained on \(r.2) crops" + (r.1.map { String(format: ", held-out accuracy %.0f %%", $0 * 100) } ?? "")
                    self.onChange?()
                } else { self.message = "Core ML training failed (\(err ?? "unknown")); the hand-feature model keeps ordering the crops" }
                if self.again { self.again = false; self.retrain() }
            }
        }
    }

    private func load(_ url: URL) {
        guard let ml = try? MLModel(contentsOf: url), let v = try? VNCoreMLModel(for: ml) else { return }
        vn = v; ready = true; message = "Core ML model loaded from an earlier session"
    }

    // MARK: prediction

    /// Probability that the crop shows a particle (nil without a model or when Vision fails).
    func probability(gray: [UInt8]) -> Float? {
        guard enabled, ready, let vn, let img = Self.cgImage(gray: gray, size: Self.side) else { return nil }
        let req = VNCoreMLRequest(model: vn)
        req.imageCropAndScaleOption = .scaleFill
        do { try VNImageRequestHandler(cgImage: img, options: [:]).perform([req]) } catch { return nil }
        guard let obs = req.results as? [VNClassificationObservation] else { return nil }
        return obs.first { $0.identifier == "yes" }?.confidence ?? obs.first { $0.identifier == "no" }.map { 1 - $0.confidence }
    }
}
