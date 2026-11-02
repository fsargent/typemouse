import Foundation

/// User configuration, read from ~/.config/typemouse/config.json.
/// Every key is optional. Missing keys keep their defaults.
public struct Config: Codable, Equatable {
    /// Each mode can have several hotkeys. In the file, a mode takes one string ("hyper+k")
    /// or a list (["hyper+k", "hyper+backspace"]).
    public struct Hotkeys: Codable, Equatable {
        public var click = ["hyper+space"]
        public var search = ["hyper+k"]
        public var window = ["hyper+l"]
        public var picker = ["hyper+j"]

        enum CodingKeys: String, CodingKey { case click, search, window, picker }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Hotkeys()
            click = try Self.decode(c, .click) ?? d.click
            search = try Self.decode(c, .search) ?? d.search
            window = try Self.decode(c, .window) ?? d.window
            picker = try Self.decode(c, .picker) ?? d.picker
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try Self.encode(click, &c, .click)
            try Self.encode(search, &c, .search)
            try Self.encode(window, &c, .window)
            try Self.encode(picker, &c, .picker)
        }

        private static func decode(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [String]? {
            if let list = try? c.decodeIfPresent([String].self, forKey: key) { return list }
            return try c.decodeIfPresent(String.self, forKey: key).map { [$0] }
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
    public var labelFontSize: Double = 12

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
        labelFontSize = try c.decodeIfPresent(Double.self, forKey: .labelFontSize) ?? d.labelFontSize
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

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
