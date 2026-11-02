import Foundation


/// Parses hotkey strings like "hyper+space" or "cmd+shift+k".
public struct HotkeySpec: Equatable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let hyper: Modifiers = [.command, .shift, .option, .control]
    }

    public let keyCode: UInt32
    public let modifiers: Modifiers
    public let description: String

    public init?(_ string: String) {
        let parts = string.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let code = HotkeySpec.keyCodes[keyName] else { return nil }
        var mods: Modifiers = []
        for p in parts.dropLast() {
            switch p {
            case "hyper": mods.formUnion(.hyper)
            case "meh": mods.formUnion([.shift, .option, .control])
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return nil
            }
        }
        keyCode = code
        modifiers = mods
        description = string
    }

    /// macOS virtual key codes (ANSI layout positions).
    public static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}

extension HotkeySpec {
    /// Names used when writing a hotkey to the config. Some keys have aliases ("enter", "delete"),
    /// so writing needs one fixed name per key code.
    static let canonicalNames: [UInt32: String] = {
        var out: [UInt32: String] = [:]
        let preferred = ["return", "backspace", "escape"]
        for (name, code) in keyCodes where out[code] == nil || preferred.contains(name) { out[code] = name }
        return out
    }()

    /// The config string for a key press, for example "hyper+j" or "ctrl+opt+k".
    /// Returns nil for keys TypeMouse cannot register.
    public static func configString(keyCode: UInt32, modifiers: Modifiers) -> String? {
        guard let key = canonicalNames[keyCode] else { return nil }
        if modifiers == .hyper { return "hyper+" + key }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// Short label for the UI, for example "Hyper J" or "⌃⌥K".
    public var displayString: String {
        let key = HotkeySpec.canonicalNames[keyCode].map(HotkeySpec.displayKey) ?? "?"
        if modifiers == .hyper { return "Hyper " + key }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    static func displayKey(_ name: String) -> String {
        switch name {
        case "space": return "Space"
        case "return": return "↩"
        case "tab": return "⇥"
        case "backspace": return "⌫"
        case "escape": return "⎋"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return name.uppercased()
        }
    }
}
