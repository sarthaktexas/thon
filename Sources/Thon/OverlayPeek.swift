import AppKit

/// Hold Space over the image to hide every overlay (picks, rulers, header, scale bar, readout) and see the bare
/// micrograph; release to bring them back. Space is not a label hotkey, so it cannot clash with a scheme.
enum OverlayPeek {
    static let keyCode: UInt16 = 49

    /// True for a plain Space press (Shift is allowed; Command, Control and Option are not).
    static func isPeekKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == Self.keyCode && modifiers.intersection([.command, .control, .option]).isEmpty
    }
}
