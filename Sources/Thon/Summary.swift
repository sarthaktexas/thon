import Foundation

struct InfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    /// Same row with lengths in Å, for rows that carry a length. nil = identical in both units.
    var angstromValue: String?
    init(label: String, value: String, angstromValue: String? = nil) {
        self.label = label; self.value = value; self.angstromValue = angstromValue
    }
    func text(angstroms: Bool) -> String { angstroms ? (angstromValue ?? value) : value }
}
struct InfoSection: Identifiable {
    let id = UUID()
    let title: String
    var rows: [InfoRow]
}

struct TagRow: Identifiable {
    let id: Int
    let path: String
    let value: String
}

struct ExposureMeta {
    var width = 0, height = 0
    var pixelSizeA: Double?
    var indicatedMag: Double?
    var voltageKV: Double?
    var exposureS: Double?
    var acquired: Date?
    var camera: String = ""
    var dataType: String = ""
}

extension DMFile {
    /// First tag found among candidate label paths below the image's ImageTags.
    private func tag(_ e: DMImageEntry, _ candidates: [[String]]) -> DMValue? {
        guard let t = e.tags else { return nil }
        for c in candidates { if let v = t.node(c)?.value { return v } }
        return nil
    }
    private func text(_ e: DMImageEntry, _ c: [[String]]) -> String? {
        guard let v = tag(e, c) else { return nil }
        let s = v.display
        return s.isEmpty ? nil : s
    }
    private func number(_ e: DMImageEntry, _ c: [[String]]) -> Double? { tag(e, c)?.asDouble }

    func acquisitionDate(_ e: DMImageEntry) -> Date? {
        if let ft = number(e, [["DataBar", "Acquisition Time (OS)"]]), ft > 1e16 {
            return Date(timeIntervalSince1970: ft / 1e7 - 11_644_473_600)
        }
        if let d = text(e, [["DataBar", "Acquisition Date"]]), let t = text(e, [["DataBar", "Acquisition Time"]]) {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            for fmt in ["M/d/yyyy h:mm:ss a", "d/M/yyyy HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "M/d/yyyy HH:mm:ss"] {
                f.dateFormat = fmt
                if let r = f.date(from: d + " " + t) { return r }
            }
        }
        return nil
    }

    func quickMeta() -> ExposureMeta {
        var m = ExposureMeta()
        guard let e = primaryImage else { return m }
        m.width = e.width; m.height = e.height; m.pixelSizeA = e.pixelSizeA; m.dataType = e.dataTypeName
        m.indicatedMag = number(e, [["Microscope Info", "Indicated Magnification"]])
        m.voltageKV = number(e, [["Microscope Info", "Voltage"]]).map { $0 / 1000 }
        m.exposureS = number(e, [["DataBar", "Exposure Time (s)"], ["Acquisition", "Parameters", "High Level", "Exposure (s)"]])
        m.acquired = acquisitionDate(e)
        m.camera = text(e, [["DataBar", "Device Name"], ["Acquisition", "Device", "Name"]]) ?? ""
        return m
    }

    func buildSections(entry e: DMImageEntry, stats: ImageStats?) -> [InfoSection] {
        var secs: [InfoSection] = []
        func fmt(_ v: Double, _ d: Int = 3) -> String { String(format: "%.\(d)g", v) }

        // File
        var f: [InfoRow] = [
            InfoRow(label: "File", value: url.lastPathComponent),
            InfoRow(label: "Folder", value: url.deletingLastPathComponent().path),
            InfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(map.size), countStyle: .file)),
            InfoRow(label: "Format", value: "DM\(version), \(littleEndian ? "little" : "big")-endian"),
            InfoRow(label: "Image name", value: e.name),
            InfoRow(label: "Images in file", value: images.map { "\($0.width)×\($0.height) \($0.dataTypeName)" }.joined(separator: "; ")),
        ]
        if let g = text(e, [["GMS Version", "Created"]]) { f.append(InfoRow(label: "GMS version", value: g)) }
        secs.append(InfoSection(title: "File", rows: f))

        // Image
        var im: [InfoRow] = [
            InfoRow(label: "Dimensions", value: "\(e.width) × \(e.height)" + (e.depth > 1 ? " × \(e.depth) frames" : "")),
            InfoRow(label: "Data type", value: e.dataTypeName),
        ]
        if let p = e.pixelSizeA {
            im.append(InfoRow(label: "Pixel size", value: String(format: "%.4f Å/px  (%.5f nm/px)", p, p / 10),
                              angstromValue: String(format: "%.4f Å/px", p)))
            im.append(InfoRow(label: "Field of view", value: String(format: "%.1f × %.1f nm", Double(e.width) * p / 10, Double(e.height) * p / 10),
                              angstromValue: String(format: "%.0f × %.0f Å", Double(e.width) * p, Double(e.height) * p)))
        } else {
            im.append(InfoRow(label: "Pixel size", value: "uncalibrated"))
        }
        if let s = stats {
            im.append(InfoRow(label: "Mean ± σ", value: "\(fmt(s.mean, 6)) ± \(fmt(s.std, 5))"))
            im.append(InfoRow(label: "Min / max", value: "\(fmt(s.min, 6)) / \(fmt(s.max, 6))"))
            if e.brightUnits.lowercased().hasPrefix("e"), let p = e.pixelSizeA, e.brightScale > 0 {
                let epx = (s.mean * e.brightScale + e.brightOrigin)
                im.append(InfoRow(label: "Mean signal", value: String(format: "%.4g e⁻/px  ≈ %.4g e⁻/Å²", epx, epx / (p * p))))
            }
        }
        if !e.brightUnits.isEmpty || e.brightScale != 1 {
            im.append(InfoRow(label: "Intensity calibration", value: "\(fmt(e.brightScale, 6)) \(e.brightUnits)/count"))
        }
        secs.append(InfoSection(title: "Image", rows: im))

        // Acquisition
        var aq: [InfoRow] = []
        func add(_ rows: inout [InfoRow], _ label: String, _ c: [[String]], unit: String = "", scale: Double? = nil,
                 angstromScale: Double? = nil, angstromUnit: String? = nil) {
            if let sc = scale, let v = number(e, c) {
                rows.append(InfoRow(label: label, value: fmt(v * sc, 6) + unit,
                                    angstromValue: angstromScale.map { fmt(v * sc * $0, 6) + (angstromUnit ?? unit) }))
            }
            else if let t = text(e, c) { rows.append(InfoRow(label: label, value: t + unit)) }
        }
        if let d = acquisitionDate(e) {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .medium
            aq.append(InfoRow(label: "Acquired", value: df.string(from: d)))
        } else {
            add(&aq, "Date", [["DataBar", "Acquisition Date"]]); add(&aq, "Time", [["DataBar", "Acquisition Time"]])
        }
        add(&aq, "Camera", [["DataBar", "Device Name"], ["Acquisition", "Device", "Name"]])
        add(&aq, "Camera serial", [["Acquisition", "Device", "Source ID"]])
        add(&aq, "Exposure", [["DataBar", "Exposure Time (s)"], ["Acquisition", "Parameters", "High Level", "Exposure (s)"]], unit: " s", scale: 1)
        add(&aq, "Frame rate", [["DataBar", "Frames per Second"]], unit: " fps", scale: 1)
        add(&aq, "Binning", [["Acquisition", "Parameters", "High Level", "Binning"], ["DataBar", "Binning"]])
        add(&aq, "Sensor", [["Acquisition", "Device", "Active Size (pixels)"]])
        add(&aq, "Physical pixel", [["Acquisition", "Device", "CCD", "Pixel Size (um)"]], unit: " µm")
        add(&aq, "Processing", [["Acquisition", "Parameters", "High Level", "Processing"]])
        add(&aq, "Sensor temperature", [["Acquisition", "Device", "Temperature (C)"]], unit: " °C", scale: 1)
        add(&aq, "Exposure #", [["DataBar", "Exposure Number"]])
        add(&aq, "Collection #", [["DataBar", "Collection Number"]])
        if let x = number(e, [["Acquisition", "Spatial drift", "Total drift x (nm)"]]), let y = number(e, [["Acquisition", "Spatial drift", "Total drift y (nm)"]]) {
            aq.append(InfoRow(label: "Total drift", value: String(format: "(%.2f, %.2f) nm", x, y),
                              angstromValue: String(format: "(%.1f, %.1f) Å", x * 10, y * 10)))
        }
        add(&aq, "Mean drift rate", [["Acquisition", "Spatial drift", "Mean rate (nm/s)"]], unit: " nm/s", scale: 1, angstromScale: 10, angstromUnit: " Å/s")
        if !aq.isEmpty { secs.append(InfoSection(title: "Acquisition", rows: aq)) }

        // Microscope
        var mi: [InfoRow] = []
        add(&mi, "Instrument", [["Microscope Info", "Type", "Model"]])
        add(&mi, "Vendor", [["Microscope Info", "Type", "Vendor"]])
        add(&mi, "Voltage", [["Microscope Info", "Voltage"]], unit: " kV", scale: 0.001)
        add(&mi, "Indicated magnification", [["Microscope Info", "Indicated Magnification"]], unit: " ×", scale: 1)
        add(&mi, "Actual magnification", [["Microscope Info", "Actual Magnification"]], unit: " ×", scale: 1)
        add(&mi, "Illumination mode", [["Microscope Info", "Illumination Mode"]])
        add(&mi, "Imaging mode", [["Microscope Info", "Imaging Mode"]])
        add(&mi, "Operation mode", [["Microscope Info", "Operation Mode"]])
        add(&mi, "Spot size", [["Microscope Info", "Illumination Sub-mode"]])
        add(&mi, "Cs", [["Microscope Info", "Cs(mm)"]], unit: " mm", scale: 1)
        add(&mi, "Defocus", [["Microscope Info", "Defocus"], ["Microscope Info", "Defocus (nm)"]])
        add(&mi, "Condenser aperture", [["Microscope Info", "Condenser Aperture"]])
        add(&mi, "Objective aperture", [["Microscope Info", "Objective Aperture"]])
        add(&mi, "SA aperture", [["Microscope Info", "Selected Area Aperture"]])
        add(&mi, "Emission current", [["Microscope Info", "Emission Current (µA)"]], unit: " µA", scale: 1)
        add(&mi, "Stage X", [["Microscope Info", "Stage Position", "Stage X"]], scale: 1)
        add(&mi, "Stage Y", [["Microscope Info", "Stage Position", "Stage Y"]], scale: 1)
        add(&mi, "Stage Z", [["Microscope Info", "Stage Position", "Stage Z"]], scale: 1)
        add(&mi, "Stage α", [["Microscope Info", "Stage Position", "Stage Alpha"]], unit: "°", scale: 1)
        add(&mi, "Stage β", [["Microscope Info", "Stage Position", "Stage Beta"]], unit: "°", scale: 1)
        if !mi.isEmpty { secs.append(InfoSection(title: "Microscope", rows: mi)) }

        // Session
        var se: [InfoRow] = []
        add(&se, "Specimen", [["Session Info", "Specimen"]])
        add(&se, "Operator", [["Session Info", "Operator"]])
        add(&se, "Microscope", [["Session Info", "Microscope"]])
        if !se.isEmpty { secs.append(InfoSection(title: "Session", rows: se)) }
        return secs
    }

    func flatTags() -> [TagRow] {
        var out: [TagRow] = []
        for (i, l) in allLeaves.enumerated() {
            out.append(TagRow(id: i, path: l.path.joined(separator: " › "), value: l.value.display))
        }
        return out
    }
}

// MARK: - MRC summaries

extension MRCFile {
    func buildSections(stats: ImageStats?) -> [InfoSection] {
        let h = header
        var f: [InfoRow] = [
            InfoRow(label: "Name", value: url.lastPathComponent),
            InfoRow(label: "Format", value: "MRC (\(h.littleEndian ? "little" : "big")-endian)"),
        ]
        if let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            f.append(InfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)))
        }
        var im: [InfoRow] = [
            InfoRow(label: "Dimensions", value: "\(h.nx) × \(h.ny)" + (h.nz > 1 ? " × \(h.nz) frames" : "")),
            InfoRow(label: "Data type", value: h.modeName),
            InfoRow(label: "Pixel size", value: h.pixelSizeA.map { String(format: "%.4g Å/px", $0) } ?? "uncalibrated"),
        ]
        if let s = stats {
            im.append(InfoRow(label: "Mean", value: String(format: "%.6g", s.mean)))
            im.append(InfoRow(label: "Std. dev.", value: String(format: "%.6g", s.std)))
            im.append(InfoRow(label: "Min / max", value: String(format: "%.6g / %.6g", s.min, s.max)))
        }
        var secs = [InfoSection(title: "File", rows: f), InfoSection(title: "Image", rows: im)]
        if !h.labels.isEmpty { secs.append(InfoSection(title: "Labels", rows: h.labels.enumerated().map { InfoRow(label: "\($0.offset + 1)", value: $0.element) })) }
        return secs
    }

    func flatTags() -> [TagRow] {
        let h = header
        let rows: [(String, String)] = [
            ("nx, ny, nz", "\(h.nx), \(h.ny), \(h.nz)"), ("mode", "\(h.mode) (\(h.modeName))"),
            ("mx, my, mz", "\(h.mx), \(h.my), \(h.mz)"),
            ("cell (Å)", String(format: "%.5g, %.5g, %.5g", h.cellX, h.cellY, h.cellZ)),
            ("dmin / dmax / dmean / rms (header)", String(format: "%.6g / %.6g / %.6g / %.6g", h.dmin, h.dmax, h.dmean, h.rms)),
            ("extended header bytes", "\(h.nsymbt)"),
        ] + (h.extType.isEmpty ? [] : [("extended header type", h.extType)]) + h.labels.enumerated().map { ("label \($0.offset + 1)", $0.element) }
        return rows.enumerated().map { TagRow(id: $0.offset, path: $0.element.0, value: $0.element.1) }
    }
}
