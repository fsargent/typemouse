/// The key remap that lets Caps Lock act as Hyper: macOS sends F18 for Caps Lock, and
/// TypeMouse adds the Hyper modifiers while F18 is held. This is the same remap `hidutil` uses.
public enum CapsLockMapping {
    /// HID usage codes (usage page 7, keyboard).
    public static let capsLock: UInt64 = 0x7_0000_0039
    public static let f18: UInt64 = 0x7_0000_006D
    /// The macOS virtual key code of F18, as key events carry it.
    public static let f18KeyCode = Int64(KeyCode.f18)

    public static let sourceKey = "HIDKeyboardModifierMappingSrc"
    public static let destinationKey = "HIDKeyboardModifierMappingDst"

    /// Adds Caps Lock -> F18 to the current remaps. Other remaps stay.
    /// An older remap of Caps Lock is replaced, because a key can map to one key only.
    public static func adding(to existing: [[String: UInt64]]) -> [[String: UInt64]] {
        existing.filter { $0[sourceKey] != capsLock } + [[sourceKey: capsLock, destinationKey: f18]]
    }

    /// Removes only the Caps Lock -> F18 remap.
    public static func removing(from existing: [[String: UInt64]]) -> [[String: UInt64]] {
        existing.filter { !($0[sourceKey] == capsLock && $0[destinationKey] == f18) }
    }
}
