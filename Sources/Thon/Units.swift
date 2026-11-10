import SwiftUI
import Combine

/// Display unit for every length the UI shows (scale bar, cursor readout, measure tool, size sliders, file summary).
/// Stored data are unchanged: project parameters stay in nm and pixel sizes in Å, only the presentation switches.
/// Toggle: View ▸ Show Lengths in Ångströms.
final class UnitSettings: ObservableObject {
    static let shared = UnitSettings()
    static let defaultsKey = "showLengthsInAngstroms"
    @Published var angstroms: Bool {
        didSet { UserDefaults.standard.set(angstroms, forKey: Self.defaultsKey) }
    }
    init() { angstroms = UserDefaults.standard.bool(forKey: Self.defaultsKey) }
}

enum LengthUnits {
    static func name(_ angstroms: Bool) -> String { angstroms ? "Å" : "nm" }
    /// Value of a length stored in nm, expressed in the display unit.
    static func fromNm(_ nm: Double, angstroms: Bool) -> Double { angstroms ? nm * 10 : nm }
    /// Inverse of `fromNm`.
    static func toNm(_ v: Double, angstroms: Bool) -> Double { angstroms ? v / 10 : v }

    /// A length given in Å, formatted in the display unit.
    /// nm mode: "0.42 nm", "12.3 nm", "250 nm", "1.20 µm". Å mode: "4.2 Å", "123 Å", "2500 Å".
    static func format(angstroms a: Double, useAngstroms: Bool) -> String {
        if useAngstroms {
            return a < 100 ? String(format: "%.1f Å", a) : String(format: "%.0f Å", a)
        }
        let nm = a / 10
        if nm >= 1000 { return String(format: "%.2f µm", nm / 1000) }
        if nm >= 100 { return String(format: "%.0f nm", nm) }
        if nm >= 10 { return String(format: "%.1f nm", nm) }
        return String(format: "%.2f nm", nm)
    }
    /// A length given in nm, formatted in the display unit.
    static func format(nm: Double, useAngstroms: Bool) -> String { format(angstroms: nm * 10, useAngstroms: useAngstroms) }

    /// Label for a scale bar of `a` Å: the same unit as everywhere else, without a trailing decimal.
    static func scaleBarLabel(angstroms a: Double, useAngstroms: Bool) -> String {
        if useAngstroms { return a >= 1 ? String(format: "%.0f Å", a) : String(format: "%g Å", a) }
        if a >= 1e4 { return String(format: "%g µm", a / 1e4) }
        if a >= 10 { return String(format: "%g nm", a / 10) }
        return String(format: "%g Å", a)      // below 1 nm a bar in nm would read "0.5 nm"; keep Å there as before
    }
}

/// View ▸ Show Lengths in Ångströms.
struct UnitMenuToggle: View {
    @ObservedObject var units = UnitSettings.shared
    var body: some View {
        Toggle("Show Lengths in Ångströms", isOn: $units.angstroms)
            .keyboardShortcut("u", modifiers: [.command, .option])
    }
}
