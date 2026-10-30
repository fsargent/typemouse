import AppKit
import TypeMouseCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capture = KeyCapture()
    private let hotkeys = HotkeyManager()
    private var config = ConfigStore.load()
    private lazy var hints = HintMode(capture: capture, config: config)
    private lazy var windows = WindowMode(capture: capture, config: config)
    private var statusItem: NSStatusItem?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var permissionTimer: Timer?
    private var loginMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("TypeMouse starting, pid \(ProcessInfo.processInfo.processIdentifier)")
        AX.setGlobalTimeout(0.25)
        setUpStatusItem()
        registerHotkeys()
        capture.onKey = { [weak self] in self?.route($0) }

        if !startCapture(prompt: true) {
            // Poll until the user grants Accessibility permission in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.startCapture(prompt: false) == true { t.invalidate() }
            }
        }

        WindowProvider.shared.startTracking()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.hints.appDidActivate(app)
            // Wake Chromium/Electron trees early, so the first scan is not empty.
            AccessibilityActivator.activate(app, enhanced: self?.config.enhancedUserInterfaceApps.contains(app.bundleIdentifier ?? "") ?? false)
        }
        watchConfig()
        LoginItem.enableOnFirstLaunch()
    }

    private func startCapture(prompt: Bool) -> Bool {
        if capture.isStarted { return true }
        guard AX.isTrusted(prompt: prompt) else { return false }
        let ok = capture.start()
        Log.info("key capture \(ok ? "ready" : "failed")")
        updateStatusTitle(ok)
        return ok
    }

    // MARK: - Hotkeys and routing

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        let pairs: [(String, () -> Void)] = [
            (config.hotkeys.click, { [weak self] in self?.toggleHints(search: false) }),
            (config.hotkeys.search, { [weak self] in self?.toggleHints(search: true) }),
            (config.hotkeys.window, { [weak self] in self?.toggleWindows() }),
        ]
        for (string, action) in pairs {
            guard let spec = HotkeySpec(string) else { Log.info("bad hotkey \"\(string)\""); continue }
            _ = hotkeys.register(spec, action)
        }
    }

    private func toggleHints(search: Bool) {
        guard capture.active || startCapture(prompt: true) else { return }
        windows.exit()
        if hints.isActive { hints.exit() } else { hints.start(search: search) }
    }

    private func toggleWindows() {
        guard capture.active || startCapture(prompt: true) else { return }
        hints.exit()
        if windows.isActive { windows.hotkeyAgain() } else { windows.start() }
    }

    /// While a mode is active the tap swallows everything, including our own hotkeys,
    /// so we match them here too.
    private func route(_ key: KeyEvent) {
        if matches(key, config.hotkeys.click) { toggleHints(search: false); return }
        if matches(key, config.hotkeys.search) { toggleHints(search: true); return }
        if matches(key, config.hotkeys.window) { toggleWindows(); return }
        if hints.isActive { hints.handle(key) }
        else if windows.isActive { windows.handle(key) }
        else { capture.setActive(false) }
    }

    private func matches(_ key: KeyEvent, _ string: String) -> Bool {
        guard let spec = HotkeySpec(string), Int64(spec.keyCode) == key.keyCode else { return false }
        var mods: HotkeySpec.Modifiers = []
        if key.command { mods.insert(.command) }
        if key.shift { mods.insert(.shift) }
        if key.option { mods.insert(.option) }
        if key.control { mods.insert(.control) }
        return mods == spec.modifiers
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "TypeMouse")
        let menu = NSMenu()
        menu.addItem(withTitle: "Click mode  (\(config.hotkeys.click))", action: #selector(menuClick), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Window mode  (\(config.hotkeys.window))", action: #selector(menuWindows), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open config", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Accessibility settings…", action: #selector(openAXSettings), keyEquivalent: "").target = self
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        menu.delegate = self
        loginMenuItem = login
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TypeMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        updateStatusTitle(capture.active || AX.isTrusted(prompt: false))
    }

    private func updateStatusTitle(_ ready: Bool) {
        statusItem?.button?.appearsDisabled = !ready
        statusItem?.button?.toolTip = ready ? "TypeMouse" : "TypeMouse needs Accessibility permission"
    }

    @objc private func menuClick() {
        // Let the menu close and focus return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.toggleHints(search: false) }
    }

    @objc private func menuWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.toggleWindows() }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func openConfig() { NSWorkspace.shared.open(ConfigStore.url) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Config hot reload

    private func watchConfig() {
        let fd = open(ConfigStore.url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let next = ConfigStore.load()
            guard next != self.config else { return }
            Log.info("config reloaded")
            self.config = next
            self.hints.update(config: next)
            self.windows.update(config: next)
            self.registerHotkeys()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
    }
}

enum ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/typemouse/config.json")

    static func load() -> Config {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config().encoded().write(to: url)
        }
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try Config.decode(data)
        } catch {
            Log.info("config error, using defaults: \(error)")
            return Config()
        }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TypeMouse/typemouse.log")
    private static let queue = DispatchQueue(label: "typemouse.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static var echo = false

    /// Waits for pending writes. Call before exit().
    static func flush() { queue.sync {} }

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        queue.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginMenuItem?.state = LoginItem.isEnabled ? .on : .off
    }
}

/// Starts TypeMouse at login through SMAppService (macOS 13+).
enum LoginItem {
    private static let didSetUpKey = "loginItemSetUp"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("launch at login: \(on ? "on" : "off") (status \(SMAppService.mainApp.status.rawValue))")
        } catch {
            Log.info("launch at login change failed: \(error)")
        }
    }

    /// Turns the login item on once. After that, the menu toggle is the user's choice.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSetUpKey) else { return }
        defaults.set(true, forKey: didSetUpKey)
        if !isEnabled { set(true) }
    }
}
