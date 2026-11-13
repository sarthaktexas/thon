import Foundation

/// Where a candidate list comes from. "Built-in" runs in-process (AutoPicker); Topaz and CryoSegNet run a script
/// that ships in the app (Resources/pickers) with the Python of an environment the user has installed, through
/// `ExternalPicker`. Nothing here is written into a project: only the resulting candidates are.
enum PickEngine: String, CaseIterable, Identifiable {
    case builtin = "Built-in", topaz = "Topaz", cryosegnet = "CryoSegNet"
    var id: String { rawValue }
}

/// Settings of the Python engines (per user, not per project).
struct EngineConfig: Codable, Equatable {
    var topazPython = ""
    var topazThreshold = -1.0        // log-likelihood-ratio cutoff passed to `topaz extract -t`
    var topazScale = 0               // 0 = automatic (particle radius about 4 px after downscaling)
    var csnPython = ""
    var csnRepo = ""                 // the CryoSegNet fork (holds mps_compat.py, models/, utils/)
    var csnWeights = ""              // folder with cryosegnet.pth and sam_vit_h_4b8939.pth
    var csnTile = 0                  // 0 = whole micrograph resized to 1024 px; N = native-pixel tiles
    var csnDevice = "auto"           // auto, mps or cpu
    var threads = 2                  // CPU threads for torch (kept low on purpose)

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = EngineConfig()
        topazPython = try c.decodeIfPresent(String.self, forKey: .topazPython) ?? z.topazPython
        topazThreshold = try c.decodeIfPresent(Double.self, forKey: .topazThreshold) ?? z.topazThreshold
        topazScale = try c.decodeIfPresent(Int.self, forKey: .topazScale) ?? z.topazScale
        csnPython = try c.decodeIfPresent(String.self, forKey: .csnPython) ?? z.csnPython
        csnRepo = try c.decodeIfPresent(String.self, forKey: .csnRepo) ?? z.csnRepo
        csnWeights = try c.decodeIfPresent(String.self, forKey: .csnWeights) ?? z.csnWeights
        csnTile = try c.decodeIfPresent(Int.self, forKey: .csnTile) ?? z.csnTile
        csnDevice = try c.decodeIfPresent(String.self, forKey: .csnDevice) ?? z.csnDevice
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? z.threads
    }
}

final class EngineSettings: ObservableObject {
    static let shared = EngineSettings()
    private static let key = "pickEngineConfig"
    static let enabledKey = "pickEnginesEnabled"
    private let defaults: UserDefaults
    @Published var config: EngineConfig { didSet { if config != oldValue { save(config) } } }
    /// Preferences ▸ Pickers: whether Topaz and CryoSegNet are offered in the Picks tab at all (off by default; the built-in picker is always there).
    @Published var enabled: Bool { didSet { if enabled != oldValue { defaults.set(enabled, forKey: Self.enabledKey) } } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let c = try? JSONDecoder().decode(EngineConfig.self, from: d) { config = c }
        else { config = EngineConfig() }
        enabled = defaults.bool(forKey: Self.enabledKey)
    }
    private func save(_ c: EngineConfig) {
        if let d = try? JSONEncoder().encode(c) { defaults.set(d, forKey: Self.key) }
    }

    /// Fills empty fields from what is found on disk; never overwrites something the user typed.
    func detect() {
        var c = config
        let found = EngineCommand.detect()
        if c.topazPython.isEmpty { c.topazPython = found.topazPython }
        if c.csnPython.isEmpty { c.csnPython = found.csnPython }
        if c.csnRepo.isEmpty { c.csnRepo = found.csnRepo }
        if c.csnWeights.isEmpty { c.csnWeights = found.csnWeights }
        config = c
    }
}

enum EngineCommand {
    static let scriptFolder = "pickers"

    /// `thon_topaz.py` etc.: inside the app bundle, or Resources/pickers of the source tree when run from .build.
    static func scriptURL(_ name: String, bundle: Bundle = .main, executable: String = CommandLine.arguments.first ?? "") -> URL? {
        let fm = FileManager.default
        if let u = bundle.resourceURL?.appendingPathComponent(scriptFolder).appendingPathComponent(name), fm.fileExists(atPath: u.path) { return u }
        var dir = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let u = dir.appendingPathComponent("Resources").appendingPathComponent(scriptFolder).appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func isExecutable(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.isExecutableFile(atPath: (path as NSString).expandingTildeInPath)
    }

    /// Human-readable problems that stop an engine from running (empty = ready).
    static func problems(_ e: PickEngine, _ c: EngineConfig) -> [String] {
        let fm = FileManager.default
        var p: [String] = []
        switch e {
        case .builtin: break
        case .topaz:
            if !isExecutable(c.topazPython) { p.append("Python of a Topaz environment not set (needs topaz-em and mrcfile).") }
            if scriptURL("thon_topaz.py") == nil { p.append("thon_topaz.py is missing from the app resources.") }
        case .cryosegnet:
            if !isExecutable(c.csnPython) { p.append("Python of a CryoSegNet environment not set (needs torch, segment-anything, opencv-python, mrcfile).") }
            if !fm.fileExists(atPath: ((c.csnRepo as NSString).expandingTildeInPath as NSString).appendingPathComponent("mps_compat.py")) {
                p.append("CryoSegNet folder not set (the fork that contains mps_compat.py).") }
            for w in ["cryosegnet.pth", "sam_vit_h_4b8939.pth"]
            where !fm.fileExists(atPath: ((c.csnWeights as NSString).expandingTildeInPath as NSString).appendingPathComponent(w)) {
                p.append("Weights folder does not contain \(w).") }
            if scriptURL("thon_cryosegnet.py") == nil { p.append("thon_cryosegnet.py is missing from the app resources.") }
        }
        return p
    }

    /// Shell command for one micrograph (`{mic}` is filled and quoted by ExternalPicker.run).
    static func command(_ e: PickEngine, _ c: EngineConfig, diameterPx: Double, brightParticles: Bool) -> String? {
        let q = ExternalPicker.shellQuote
        let d = String(format: "%.1f", max(diameterPx, 1))
        switch e {
        case .builtin: return nil
        case .topaz:
            guard let s = scriptURL("thon_topaz.py") else { return nil }
            // Topaz's pretrained models expect dark particles (cryo contrast): bright (stain) particles are inverted first
            var cmd = "\(q((c.topazPython as NSString).expandingTildeInPath)) \(q(s.path)) {mic} --diameter-px \(d) --threshold \(c.topazThreshold) --threads \(max(1, c.threads))"
            if c.topazScale > 0 { cmd += " --scale \(c.topazScale)" }
            if brightParticles { cmd += " --invert" }
            return cmd
        case .cryosegnet:
            guard let s = scriptURL("thon_cryosegnet.py") else { return nil }
            var cmd = "\(q((c.csnPython as NSString).expandingTildeInPath)) \(q(s.path)) {mic} --repo \(q((c.csnRepo as NSString).expandingTildeInPath)) --weights \(q((c.csnWeights as NSString).expandingTildeInPath)) --diameter-px \(d) --device \(c.csnDevice) --threads \(max(1, c.threads))"
            if c.csnTile > 0 { cmd += " --tile \(c.csnTile)" }
            return cmd
        }
    }

    /// Looks for conda/mamba environments and a CryoSegNet checkout in the usual places.
    static func detect(home: String = NSHomeDirectory()) -> EngineConfig {
        let fm = FileManager.default
        var c = EngineConfig()
        let roots = ["miniconda3", "miniforge3", "anaconda3", "mambaforge", "micromamba", ".conda"].map { home + "/" + $0 }
            + ["/opt/homebrew/Caskroom/miniforge/base", "/opt/homebrew/Caskroom/miniconda/base", "/opt/miniconda3", "/opt/anaconda3", "/usr/local/Caskroom/miniforge/base"]
        for r in roots {
            let t = r + "/envs/topaz/bin/python", s = r + "/envs/cryosegnet/bin/python"
            if c.topazPython.isEmpty, fm.isExecutableFile(atPath: t) { c.topazPython = t }
            if c.csnPython.isEmpty, fm.isExecutableFile(atPath: s) { c.csnPython = s }
        }
        var dirs = [home + "/cryosegnet-macos", home + "/CryoSegNet", home + "/Developer/cryosegnet-macos", home + "/Developer/CryoSegNet"]
        if let sub = try? fm.contentsOfDirectory(atPath: home + "/Developer") {
            for s in sub { dirs += [home + "/Developer/" + s + "/cryosegnet-macos", home + "/Developer/" + s + "/CryoSegNet"] }
        }
        for d in dirs where fm.fileExists(atPath: d + "/mps_compat.py") {
            c.csnRepo = d
            if fm.fileExists(atPath: d + "/pretrained_models/cryosegnet.pth") { c.csnWeights = d + "/pretrained_models" }
            break
        }
        return c
    }
}
