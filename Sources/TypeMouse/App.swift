import AppKit
import TypeMouseCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capture = KeyCapture()
    private let hotkeys = HotkeyManager()
    private let hyperKey = HyperKey()
    private let tiler = WindowTiler()
    private var recordingHotkey = false
    private var modeShortcuts: [(spec: HotkeySpec, action: () -> Void)] = []
    private var windowShortcuts: [(spec: HotkeySpec, command: WindowCommand)] = []
    private var config = ConfigStore.load()
    private lazy var hints = HintMode(capture: capture, config: config)
    private lazy var windows = WindowMode(capture: capture, config: config)
    private lazy var picker = WindowPicker(capture: capture, config: config)
    private lazy var grid = GridMode(capture: capture, config: config)
    private var statusItem: NSStatusItem?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var permissionTimer: Timer?
    private var flagTimer: Timer?
    private var loginMenuItem: NSMenuItem?
    private var modeMenuItems: [(NSMenuItem, String, Config.Mode, KeyPath<Config.Hotkeys, [String]>)] = []
    private lazy var settings = SettingsWindowController(
        config: config,
        save: { [weak self] next in
            if ConfigStore.save(next) { self?.applyConfig(next) }
        },
        recording: { [weak self] on in
            self?.recordingHotkey = on
            self?.registerHotkeys()
        })

    /// Puts Caps Lock back.
    func applicationWillTerminate(_ note: Notification) {
        grid.exit(movePointer: false)
        hyperKey.setEnabled(false)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("TypeMouse starting, pid \(ProcessInfo.processInfo.processIdentifier)")
        AX.setGlobalTimeout(0.25)
        setUpStatusItem()
        registerHotkeys()
        capture.onKey = { [weak self] in self?.route($0) }
        capture.onKeyUp = { [weak self] in self?.grid.keyUp($0) }
        capture.onFlagsChanged = { [weak self] in self?.grid.flagsChanged($0) }
        capture.onInterrupted = { [weak self] in self?.grid.releaseKeys() }
        picker.onPicked = { [weak self] info in
            guard let self, self.config.clickAfterPicker else { return }
            self.startClickModeWhenFocused(info)
        }

        if !startCapture(prompt: true) {
            // Poll until the user grants Accessibility permission in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.startCapture(prompt: false) == true { t.invalidate() }
            }
        }

        WindowProvider.shared.startTracking()
        AccessibilityActivator.activateAll(enhancedApps: config.enhancedUserInterfaceApps)
        // Other tools can turn AXEnhancedUserInterface off. Turn it back on early, so the browser
        // has rebuilt its page tree before the next hotkey press.
        flagTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, !self.hints.isActive, let front = NSWorkspace.shared.frontmostApplication,
                  self.config.enhancedUserInterfaceApps.contains(front.bundleIdentifier ?? "") else { return }
            AccessibilityActivator.activate(front, enhanced: true)
        }
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

    /// Opening the app again (Finder, Spotlight, Raycast) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    private func startCapture(prompt: Bool) -> Bool {
        if capture.isStarted { return true }
        guard AX.isTrusted(prompt: prompt) else { return false }
        let ok = capture.start()
        Log.info("key capture \(ok ? "ready" : "failed")")
        updateStatusTitle(ok)
        // After key capture: the newest tap sees keys first, so click mode also sees Hyper.
        if ok { hyperKey.setEnabled(config.capsLockToHyper) }
        return ok
    }

    // MARK: - Hotkeys and routing

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        modeShortcuts = []
        windowShortcuts = []
        // While a field records, let the keys reach the settings window.
        guard !recordingHotkey else { return }
        let pairs: [(Config.Mode, String, [String], () -> Void)] = [
            (.click, "click", config.hotkeys.click, { [weak self] in self?.toggleHints(search: false) }),
            (.search, "search", config.hotkeys.search, { [weak self] in self?.toggleHints(search: true) }),
            (.windowList, "window", config.hotkeys.window, { [weak self] in self?.toggleWindows() }),
            (.windowPicker, "picker", config.hotkeys.picker, { [weak self] in self?.togglePicker() }),
            (.missionControl, "mission control picker", config.hotkeys.missionControl, { [weak self] in self?.togglePicker(missionControl: true) }),
            (.grid, "grid", config.hotkeys.grid, { [weak self] in self?.toggleGrid() }),
            (.scroll, "scroll", config.hotkeys.scroll, { [weak self] in self?.toggleGrid(pickScrollArea: true) }),
        ]
        for (mode, name, strings, action) in pairs where config.isModeEnabled(mode) {
            for string in strings {
                guard let spec = HotkeySpec(string) else { Log.info("bad hotkey \"\(string)\""); continue }
                let registered = hotkeys.register(spec) { [weak self] in
                    // Logged, so a press that never arrives is visible: it leaves no line.
                    Log.info("hotkey \(name) (\(string)) in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    action()
                    if self?.capture.active == true { self?.capture.passNextKeyUp(Int64(spec.keyCode)) }
                }
                if registered { modeShortcuts.append((spec, action)) }
            }
        }
        guard config.isModeEnabled(.windowManagement) else { return }
        windowShortcuts = WindowCommand.allCases.compactMap { command in
            guard let spec = HotkeySpec(config.hotkeys.shortcut(for: command)),
                  hotkeys.register(spec, { [weak self] in self?.arrangeWindow(command) }) else { return nil }
            return (spec, command)
        }
    }

    private func arrangeWindow(_ command: WindowCommand) {
        guard config.isModeEnabled(.windowManagement), AX.isTrusted(prompt: true) else { return }
        hints.exit()
        windows.exit()
        picker.exit()
        grid.exit(movePointer: false)
        tiler.apply(command)
    }

    private func toggleHints(search: Bool) {
        guard config.isModeEnabled(search ? .search : .click),
              capture.active || startCapture(prompt: true) else { return }
        grid.exit()
        windows.exit()
        picker.exit()
        if hints.isActive { hints.exit("hotkey pressed again") } else { hints.start(search: search) }
    }

    private func toggleWindows() {
        guard config.isModeEnabled(.windowList),
              capture.active || startCapture(prompt: true) else { return }
        grid.exit()
        hints.exit()
        picker.exit()
        if windows.isActive { windows.hotkeyAgain() } else { windows.start() }
    }

    /// Click mode scans the front app's focused window, so wait until the picked window has focus.
    /// Checks every 30 ms for up to 0.8 s, then starts click mode anyway.
    private func startClickModeWhenFocused(_ info: WindowInfo, deadline: Date = Date().addingTimeInterval(0.8)) {
        guard config.isModeEnabled(.click) else { return }
        let pid = info.app.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let focused = info.id == nil
            || AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute)?.windowID == info.id
        if (front && focused) || Date() >= deadline {
            guard !hints.isActive, !windows.isActive, !picker.isActive, !grid.isActive else { return }
            hints.start(search: false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.startClickModeWhenFocused(info, deadline: deadline)
        }
    }

    private func togglePicker(missionControl: Bool = false) {
        guard config.isModeEnabled(missionControl ? .missionControl : .windowPicker),
              capture.active || startCapture(prompt: true) else { return }
        grid.exit()
        hints.exit()
        windows.exit()
        if picker.isActive {
            let switchToOverview = missionControl && !picker.isShowingOverview
            picker.exit()
            if switchToOverview { picker.start(missionControl: true) }
        } else {
            picker.start(missionControl: missionControl)
        }
    }

    private func toggleGrid(pickScrollArea: Bool = false) {
        guard config.isModeEnabled(pickScrollArea ? .scroll : .grid),
              capture.active || startCapture(prompt: true) else { return }
        hints.exit()
        windows.exit()
        picker.exit()
        let wasActive = grid.isActive
        let switchMode = pickScrollArea ? grid.isChoosingPoint : grid.isChoosingScrollArea
        grid.exit(movePointer: !pickScrollArea)
        guard !wasActive || switchMode else { return }
        if pickScrollArea { grid.startChoosingScrollArea() } else { grid.start() }
    }

    /// While a mode is active the tap swallows everything, including our own hotkeys,
    /// so we match them here too.
    private func route(_ key: KeyEvent) {
        if !key.isRepeat {
            if let shortcut = modeShortcuts.first(where: { matches(key, $0.spec) }) {
                shortcut.action()
                return
            }
            if let shortcut = windowShortcuts.first(where: { matches(key, $0.spec) }) {
                arrangeWindow(shortcut.command)
                return
            }
        }
        if hints.isActive { hints.handle(key) }
        else if windows.isActive { windows.handle(key) }
        else if picker.isActive { picker.handle(key) }
        else if grid.isActive { grid.handle(key) }
        else { capture.setActive(false) }
    }

    private func matches(_ key: KeyEvent, _ spec: HotkeySpec) -> Bool {
        var mods: HotkeySpec.Modifiers = []
        if key.command { mods.insert(.command) }
        if key.shift { mods.insert(.shift) }
        if key.option { mods.insert(.option) }
        if key.control { mods.insert(.control) }
        return Int64(spec.keyCode) == key.keyCode && mods == spec.modifiers
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "TypeMouse")
        let menu = NSMenu()
        for (title, action, mode, keyPath) in [("Click mode", #selector(menuClick), Config.Mode.click, \Config.Hotkeys.click),
                                         ("Window list", #selector(menuWindows), Config.Mode.windowList, \Config.Hotkeys.window),
                                         ("Window picker", #selector(menuPicker), Config.Mode.windowPicker, \Config.Hotkeys.picker),
                                         ("Mission Control picker", #selector(menuMissionControl), Config.Mode.missionControl, \Config.Hotkeys.missionControl),
                                         ("Grid mode", #selector(menuGrid), Config.Mode.grid, \Config.Hotkeys.grid),
                                         ("Choose scrollable area", #selector(menuScroll), Config.Mode.scroll, \Config.Hotkeys.scroll)] {
            let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            mi.target = self
            modeMenuItems.append((mi, title, mode, keyPath))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
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

    @objc private func menuPicker() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.togglePicker() }
    }

    @objc private func menuMissionControl() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.togglePicker(missionControl: true) }
    }

    @objc private func menuGrid() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.toggleGrid() }
    }

    @objc private func menuScroll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.toggleGrid(pickScrollArea: true) }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func openSettings() { settings.show() }

    @objc private func openConfig() { NSWorkspace.shared.open(ConfigStore.url) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Config hot reload

    private func applyConfig(_ next: Config) {
        guard next != config else { return }
        let accessibilityAppsChanged = next.enhancedUserInterfaceApps != config.enhancedUserInterfaceApps
        Log.info("config reloaded")
        config = next
        hints.update(config: next)
        windows.update(config: next)
        picker.update(config: next)
        grid.update(config: next)
        if capture.isStarted { hyperKey.setEnabled(next.capsLockToHyper) }
        settings.update(config: next)
        registerHotkeys()
        if accessibilityAppsChanged { AccessibilityActivator.activateAll(enhancedApps: next.enhancedUserInterfaceApps) }
    }

    private func watchConfig() {
        let fd = open(ConfigStore.url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.applyConfig(ConfigStore.load()) }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
    }
}

enum ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/typemouse/config.json")

    @discardableResult
    static func save(_ config: Config) -> Bool {
        do {
            try config.encoded().write(to: url, options: .atomic)
            return true
        } catch {
            Log.info("config save failed: \(error)")
            return false
        }
    }

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
        // Hotkeys can change in the settings window or the file, so label the items when the menu opens.
        for (item, title, mode, keyPath) in modeMenuItems {
            item.isHidden = !config.isModeEnabled(mode)
            let shown = config.hotkeys[keyPath: keyPath].map { HotkeySpec($0)?.displayString ?? $0 }
            item.title = shown.isEmpty ? "\(title)  (no hotkey)" : "\(title)  (\(shown.joined(separator: " or ")))"
        }
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
