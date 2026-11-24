import Foundation

/// User configuration, read from ~/.config/typemouse/config.json.
/// Every key is optional. Missing keys keep their defaults.
public struct Config: Codable, Equatable {
    /// Each mode can have several hotkeys. In the file, a mode takes one string ("hyper+k"),
    /// a list (["hyper+k", "hyper+backspace"]), or [] / "" for no hotkey.
    /// A missing key keeps the default.
    public struct Hotkeys: Codable, Equatable {
        public var click = ["hyper+j"]
        /// No default: search is also one key away inside click mode (/ or Tab).
        public var search: [String] = []
        public var window = ["hyper+l"]
        public var picker = ["hyper+k"]
        public var missionControl = ["hyper+return"]
        public var grid = ["hyper+h"]
        /// Per-command overrides. An empty string clears the command's default hotkey.
        public var windowManagement: [String: String] = [:]

        enum CodingKeys: String, CodingKey { case click, search, window, picker, missionControl, grid, windowManagement }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Hotkeys()
            click = try Self.decode(c, .click) ?? d.click
            search = try Self.decode(c, .search) ?? d.search
            window = try Self.decode(c, .window) ?? d.window
            picker = try Self.decode(c, .picker) ?? d.picker
            missionControl = try Self.decode(c, .missionControl) ?? d.missionControl
            grid = try Self.decode(c, .grid) ?? d.grid
            windowManagement = try c.decodeIfPresent([String: String].self, forKey: .windowManagement) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try Self.encode(click, &c, .click)
            try Self.encode(search, &c, .search)
            try Self.encode(window, &c, .window)
            try Self.encode(picker, &c, .picker)
            try Self.encode(missionControl, &c, .missionControl)
            try Self.encode(grid, &c, .grid)
            if !windowManagement.isEmpty { try c.encode(windowManagement, forKey: .windowManagement) }
        }

        public func shortcut(for command: WindowCommand) -> String {
            windowManagement[command.rawValue] ?? command.defaultHotkey
        }

        private static func decode(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [String]? {
            if let list = try? c.decodeIfPresent([String].self, forKey: key) {
                return list.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            // "" means no hotkey.
            return try c.decodeIfPresent(String.self, forKey: key).map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [$0] }
        }

        /// One hotkey stays a plain string, so simple files stay simple.
        private static func encode(_ list: [String], _ c: inout KeyedEncodingContainer<CodingKeys>, _ key: CodingKeys) throws {
            if list.count == 1 { try c.encode(list[0], forKey: key) } else { try c.encode(list, forKey: key) }
        }
    }

    /// How to click a target in a given app.
    public enum ClickStrategy: String, Codable, Equatable {
        /// AXPress first, then a synthetic mouse click when AXPress fails. Web content always gets a mouse click.
        case auto
        /// Always AXPress (does not move the mouse).
        case press
        /// Always a synthetic mouse click.
        case mouse
    }

    /// Label characters, most preferred first: home row (index fingers out), then top row, then bottom row.
    /// Leaves out q, p, and z.
    public static let defaultHintCharacters = "fjdkslaghrueiwotyvmcxbn"
    public var hintCharacters = Config.defaultHintCharacters
    public var hotkeys = Hotkeys()
    /// Window mode: letter -> bundle identifier, for example {"s": "com.tinyspeck.slackmacgap"}.
    public var windowPins: [String: String] = [:]
    /// Bundle identifier -> click strategy. Apps not listed use `auto`.
    public var clickStrategy: [String: ClickStrategy] = [:]
    /// Put the mouse back where it was after a synthetic click.
    public var restoreMousePosition = true
    /// After the window picker focuses a window, start click mode in it.
    public var clickAfterPicker = true
    /// Click mode gives the shortest labels to buttons, then text fields, then links, then other
    /// elements, then the app's own UI (a browser's tabs and toolbar). Off: reading order.
    public var prioritizeLabels = true
    /// Caps Lock acts as Hyper (Command + Control + Option + Shift) while TypeMouse runs.
    /// Off by default because it changes a key everywhere. Not needed with Karabiner or kanata.
    public var capsLockToHyper = false
    /// Click mode starts with chain mode on. Space still turns it off for that session.
    public var chainModeByDefault = false
    /// Chain click: milliseconds to wait after a click before the new labels appear,
    /// so the app can react (open a menu, load a page).
    public var chainDelayMs = 250
    public var labelFontSize: Double = 12
    public var gridHand: GridNavigation.Hand = .right
    public var scrollKeys: ScrollKeys = .vim
    /// Scroll distance in points per second. Shift multiplies this by three.
    public var scrollSpeed = 600

    /// Chromium browsers build the web page tree only when AXEnhancedUserInterface is on.
    /// AXManualAccessibility (enough for Electron) does not work for them.
    public static let chromiumBrowsers = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Bundle identifiers that get AXEnhancedUserInterface. This flag can make window-manager moves
    /// of those apps slow or animated. Homerow sets the same flag.
    public var enhancedUserInterfaceApps: [String] = Config.chromiumBrowsers

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hintCharacters = try c.decodeIfPresent(String.self, forKey: .hintCharacters) ?? d.hintCharacters
        hotkeys = try c.decodeIfPresent(Hotkeys.self, forKey: .hotkeys) ?? d.hotkeys
        windowPins = try c.decodeIfPresent([String: String].self, forKey: .windowPins) ?? d.windowPins
        clickStrategy = try c.decodeIfPresent([String: ClickStrategy].self, forKey: .clickStrategy) ?? d.clickStrategy
        restoreMousePosition = try c.decodeIfPresent(Bool.self, forKey: .restoreMousePosition) ?? d.restoreMousePosition
        clickAfterPicker = try c.decodeIfPresent(Bool.self, forKey: .clickAfterPicker) ?? d.clickAfterPicker
        prioritizeLabels = try c.decodeIfPresent(Bool.self, forKey: .prioritizeLabels) ?? d.prioritizeLabels
        capsLockToHyper = try c.decodeIfPresent(Bool.self, forKey: .capsLockToHyper) ?? d.capsLockToHyper
        chainModeByDefault = try c.decodeIfPresent(Bool.self, forKey: .chainModeByDefault) ?? d.chainModeByDefault
        chainDelayMs = max(0, try c.decodeIfPresent(Int.self, forKey: .chainDelayMs) ?? d.chainDelayMs)
        labelFontSize = try c.decodeIfPresent(Double.self, forKey: .labelFontSize) ?? d.labelFontSize
        gridHand = try c.decodeIfPresent(GridNavigation.Hand.self, forKey: .gridHand) ?? d.gridHand
        scrollKeys = try c.decodeIfPresent(ScrollKeys.self, forKey: .scrollKeys) ?? d.scrollKeys
        scrollSpeed = min(5000, max(50, try c.decodeIfPresent(Int.self, forKey: .scrollSpeed) ?? d.scrollSpeed))
        enhancedUserInterfaceApps = try c.decodeIfPresent([String].self, forKey: .enhancedUserInterfaceApps) ?? d.enhancedUserInterfaceApps
    }

    public var hintAlphabet: [Character] { Hints.unique(Array(hintCharacters.lowercased())) }

    public var pins: [Character: String] {
        var out: [Character: String] = [:]
        for (k, v) in windowPins {
            if let ch = k.lowercased().first, k.count == 1 { out[ch] = v }
        }
        return out
    }

    public var availableWindowPinLetters: [Character] {
        let assigned = pins
        return Array("abcdefghijklmnopqrstuvwxyz".filter { assigned[$0] == nil })
    }

    @discardableResult
    public mutating func setWindowPin(_ letter: Character, for bundleID: String) -> Bool {
        let key = letter.lowercased()
        guard key.count == 1, "abcdefghijklmnopqrstuvwxyz".contains(key), !bundleID.isEmpty else { return false }
        guard !windowPins.contains(where: { $0.key.lowercased() == key && $0.value != bundleID }) else { return false }
        removeWindowPin(for: bundleID)
        windowPins[key] = bundleID
        return true
    }

    public mutating func removeWindowPin(for bundleID: String) {
        windowPins = windowPins.filter { $0.value != bundleID }
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
