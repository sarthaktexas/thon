import AppKit

/// Hold a key to hide every overlay and see the bare micrograph; release to bring them back.
/// The main viewer accepts Space or the backtick key (`). The crop editor uses the backtick key only, because Space
/// steps to the next type there. Neither is a label hotkey (the backtick is in `LabelScheme.reservedKeys`).
enum OverlayPeek {
    static let spaceKeyCode: UInt16 = 49
    static let graveKeyCode: UInt16 = 50

    /// True for a plain Space or backtick press in the main viewer (Shift is allowed; Command, Control and Option are not).
    static func isPeekKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        isPeekKeyCode(keyCode) && modifiers.intersection([.command, .control, .option]).isEmpty
    }
    static func isPeekKeyCode(_ keyCode: UInt16) -> Bool { keyCode == spaceKeyCode || keyCode == graveKeyCode }

    /// The crop editor reads characters (SwiftUI key presses): only the backtick counts.
    static func isCropPeekCharacter(_ characters: String) -> Bool { characters == "`" }
}
