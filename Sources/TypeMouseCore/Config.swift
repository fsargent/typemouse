import Foundation

/// User configuration, read from ~/.config/typemouse/config.json.
/// Every key is optional. Missing keys keep their defaults.
public struct Config: Codable, Equatable {
    public struct Hotkeys: Codable, Equatable {
        public var click = "hyper+space"
        public var search = "hyper+backspace"
        public var window = "hyper+tab"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Hotkeys()
            click = try c.decodeIfPresent(String.self, forKey: .click) ?? d.click
            search = try c.decodeIfPresent(String.self, forKey: .search) ?? d.search
            window = try c.decodeIfPresent(String.self, forKey: .window) ?? d.window
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
