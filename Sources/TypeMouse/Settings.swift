import AppKit
import SwiftUI
import TypeMouseCore
import UniformTypeIdentifiers

/// The settings window. It edits the same config file that TypeMouse watches,
/// so a change in the window and a change in the file have the same effect.
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    /// - Parameters:
    ///   - save: writes a changed config.
    ///   - recording: true while a hotkey field records. TypeMouse releases its hotkeys then,
    ///     so the current hotkeys reach the window instead of opening a mode.
    init(config: Config, save: @escaping (Config) -> Void, recording: @escaping (Bool) -> Void) {
        model = SettingsModel(config: config, save: save, recording: recording)
    }

    func update(config: Config) {
        if model.config != config { model.config = config }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "TypeMouse Settings"
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 590))
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.model.stopRecording()
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case click = "Click mode"
        case search = "Search mode"
        case window = "Window list"
        case picker = "Window picker"
        case missionControl = "Mission Control picker"
        case grid = "Grid mode"

        var id: String { rawValue }

        var keyPath: WritableKeyPath<Config.Hotkeys, [String]> {
            switch self {
            case .click: return \.click
            case .search: return \.search
            case .window: return \.window
            case .picker: return \.picker
            case .missionControl: return \.missionControl
            case .grid: return \.grid
            }
        }
    }

    enum Slot: Equatable {
        case mode(Mode, Int)
        case command(WindowCommand)

        var title: String {
            switch self {
            case .mode(let mode, _): return mode.rawValue
            case .command(let command): return command.title
            }
        }
    }

    static let slotsPerMode = 2

    @Published var config: Config
    @Published private(set) var recordingSlot: Slot?
    private let save: (Config) -> Void
    private let recording: (Bool) -> Void
    private var monitor: Any?

    init(config: Config, save: @escaping (Config) -> Void, recording: @escaping (Bool) -> Void) {
        self.config = config
        self.save = save
        self.recording = recording
    }

    func commit() { save(config) }

    func hotkeys(_ mode: Mode) -> [String] { config.hotkeys[keyPath: mode.keyPath] }

    func hotkey(_ slot: Slot) -> String? {
        switch slot {
        case .mode(let mode, let index):
            let list = hotkeys(mode)
            return list.indices.contains(index) ? list[index] : nil
        case .command(let command):
            let value = config.hotkeys.shortcut(for: command)
            return value.isEmpty ? nil : value
        }
    }

    func isDefault(_ mode: Mode) -> Bool { hotkeys(mode) == Config.Hotkeys()[keyPath: mode.keyPath] }

    /// Another slot (in any mode) with the same key combination, if any.
    func conflict(_ slot: Slot) -> Slot? {
        guard let string = hotkey(slot), let mine = HotkeySpec(string) else { return nil }
        let modes = Mode.allCases.flatMap { mode in
            hotkeys(mode).indices.map { Slot.mode(mode, $0) }
        }
        let commands = WindowCommand.allCases.map { Slot.command($0) }
        return (modes + commands).first { other in
            guard other != slot, let theirs = hotkey(other).flatMap(HotkeySpec.init) else { return false }
            return theirs.keyCode == mine.keyCode && theirs.modifiers == mine.modifiers
        }
    }

    func record(_ slot: Slot) {
        stopRecording()
        recordingSlot = slot
        recording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recorded(event)
            return nil
        }
    }

    func remove(_ slot: Slot) {
        guard hotkey(slot) != nil else { return }
        stopRecording()
        switch slot {
        case .mode(let mode, let index):
            config.hotkeys[keyPath: mode.keyPath].remove(at: index)
        case .command(let command):
            config.hotkeys.windowManagement[command.rawValue] = ""
        }
        commit()
    }

    func reset(_ mode: Mode) {
        stopRecording()
        config.hotkeys[keyPath: mode.keyPath] = Config.Hotkeys()[keyPath: mode.keyPath]
        commit()
    }

    private func recorded(_ event: NSEvent) {
        guard let slot = recordingSlot else { return }
        let flags = event.modifierFlags
        var mods: HotkeySpec.Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        // Escape with no modifiers cancels.
        if event.keyCode == 53 && mods.isEmpty { stopRecording(); return }
        // A hotkey with no modifier would take that key away from every app.
        guard !mods.isEmpty, let string = HotkeySpec.configString(keyCode: UInt32(event.keyCode), modifiers: mods) else {
            NSSound.beep()
            return
        }
        switch slot {
        case .mode(let mode, let index):
            var list = hotkeys(mode)
            if list.indices.contains(index) { list[index] = string } else { list.append(string) }
            config.hotkeys[keyPath: mode.keyPath] = list
        case .command(let command):
            config.hotkeys.windowManagement[command.rawValue] = string
        }
        stopRecording()
        commit()
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recordingSlot != nil {
            recordingSlot = nil
            recording(false)
        }
    }
}

struct SettingsView: View {
    private enum Page: Hashable {
        case general
        case mode(SettingsModel.Mode)
        case scroll
        case windowManagement

        var title: String {
            switch self {
            case .general: return "General"
            case .mode(let mode): return mode.rawValue
            case .scroll: return "Scroll mode"
            case .windowManagement: return "Window management"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .mode(.click): return "cursorarrow.click"
            case .mode(.search): return "magnifyingglass"
            case .mode(.window): return "list.bullet"
            case .mode(.picker): return "macwindow"
            case .mode(.missionControl): return "rectangle.3.group"
            case .mode(.grid): return "square.grid.3x3"
            case .scroll: return "arrow.up.and.down"
            case .windowManagement: return "rectangle.split.2x2"
            }
        }

        var introduction: String {
            switch self {
            case .general:
                return "Set up your Hyper key, launch options, and shared label characters."
            case .mode(.click):
                return "Show a label on each clickable item. Type its label to click it."
            case .mode(.search):
                return "Find clickable items by text. Press Enter to click the highlighted match."
            case .mode(.window):
                return "Show a list of windows on every display. Type a label or highlight a row and press Enter."
            case .mode(.picker):
                return "Show a label on each visible window. Type its label to focus that window."
            case .mode(.missionControl):
                return "Open Mission Control and label its window previews. Type a label to focus that window."
            case .mode(.grid):
                return "Select cells in a 3×3 grid to position the pointer. Each key narrows the target."
            case .scroll:
                return "Press Enter in grid mode to scroll at the selected point or the current pointer position."
            case .windowManagement:
                return "Move and resize the focused window with shortcuts that match positions on the display."
            }
        }
    }

    @ObservedObject var model: SettingsModel
    @State private var selection: Page? = .general
    @State private var hintCharacters = ""
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        let page = selection ?? .general
        NavigationSplitView {
            List(selection: $selection) {
                sidebarRow(.general)
                Section("Modes") {
                    ForEach(SettingsModel.Mode.allCases) { mode in sidebarRow(.mode(mode)) }
                    sidebarRow(.scroll)
                    sidebarRow(.windowManagement)
                }
                .collapsible(false)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.title)
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(page.introduction)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                pageSections(page)
            }
            .formStyle(.grouped)
            .id(page)
        }
        .frame(minWidth: 680, minHeight: 490)
        .onAppear { hintCharacters = model.config.hintCharacters }
        .onChange(of: model.config.hintCharacters) { _, new in hintCharacters = new }
        .onChange(of: selection) { _, _ in model.stopRecording() }
    }

    private func sidebarRow(_ page: Page) -> some View {
        Label(page.title, systemImage: page.icon).tag(page)
    }

    @ViewBuilder
    private func pageSections(_ page: Page) -> some View {
        switch page {
        case .general:
            generalSections
        case .mode(let mode):
            shortcutSection(mode)
            switch mode {
            case .click:
                clickSections
            case .search:
                Section("From click mode") {
                    note("Press Slash (/) or Tab in click mode to start a search. Press Backspace on an empty search to return to labels.")
                }
            case .window:
                Section("Choose a window") {
                    note("Press Tab or the hotkey again to highlight the next window. Press Slash (/) to search by app or window title.")
                }
                PinnedAppsSettings(model: model)
            case .picker:
                Section("After selection") {
                    Toggle("Start click mode after focusing the window", isOn: setting(\.clickAfterPicker))
                }
            case .missionControl:
                Section("Choose a window") {
                    note("Labels stay on the previews as you move the pointer. Press Escape to close the picker and Mission Control.")
                    Toggle("Start click mode after focusing the window", isOn: setting(\.clickAfterPicker))
                    note("This setting also applies to the regular window picker.")
                }
            case .grid:
                Section("Choose a point") {
                    Picker("Preferred hand", selection: setting(\.gridHand)) {
                        ForEach(GridNavigation.Hand.allCases, id: \.self) { hand in
                            Text(hand.rawValue.capitalized).tag(hand)
                        }
                    }
                    note("Use your preferred hand on one display and to refine a selection. With two displays, the first grid keys match each display.")
                    HStack(alignment: .top, spacing: 32) {
                        gridKeys("Left hand", keys: "W E R\nS D F\nX C V")
                        gridKeys("Right hand", keys: "U I O\nJ K L\nM , .")
                    }
                    note("Press Backspace to undo a selection. Press Escape to move to the selected point and exit. Press Space to click.")
                    note("Without a selection, Space clicks at the current pointer position and Escape leaves the pointer in place.")
                    Button("Scroll mode settings") { selection = .scroll }
                }
            }
        case .windowManagement:
            windowManagementSections
        case .scroll:
            Section("Controls") {
                Picker("Scroll keys", selection: setting(\.scrollKeys)) {
                    ForEach(ScrollKeys.allCases, id: \.self) { keys in
                        Text(keys.displayName).tag(keys)
                    }
                }
                numberRow("Scroll speed", unit: "pt/s", range: 50...5000, step: 50, value: setting(\.scrollSpeed))
                note("Hold a direction key to scroll. Arrow keys work with every layout. Hold Shift for three times the speed. Press Escape to exit.")
            }
        }
    }

    private var windowManagementSections: some View {
        Group {
            Section("Default Hyper shortcuts") {
                Text("W E R\nS D F\nX C V")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Top row W E R. Middle row S D F. Bottom row X C V.")
                note("The edge keys cycle through half, two-thirds, and one-third. The corner keys resize to a quarter.")
                note("Center switches between a centered half and the full usable display area.")
                note("Move to next display keeps the window's relative size and position.")
            }
            Section("Hotkeys") {
                ForEach(WindowCommand.allCases, id: \.self) { command in
                    let slot = SettingsModel.Slot.command(command)
                    LabeledContent(command.title) { slotView(slot) }
                    if let other = model.conflict(slot) {
                        Text("This hotkey is also used by \(other.title).")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                if case .command = model.recordingSlot {
                    note("Press the key combination. Press Escape to cancel.")
                } else {
                    note("If another app uses the same hotkey, clear it there or choose a different hotkey here.")
                }
                Button("Reset window management hotkeys") {
                    model.stopRecording()
                    model.config.hotkeys.windowManagement = [:]
                    model.commit()
                }
                .disabled(model.config.hotkeys.windowManagement.isEmpty)
            }
        }
    }

    private var generalSections: some View {
        Group {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
            }
            Section("Keyboard") {
                Toggle("Use Caps Lock as Hyper", isOn: setting(\.capsLockToHyper))
                note("Hyper combines Command, Control, Option, and Shift. Leave this off if your keyboard or remapper already provides Hyper.")
            }
            Section("Shared labels") {
                LabeledContent("Hint characters") {
                    HStack {
                        TextField("Hint characters", text: $hintCharacters)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(saveHintCharacters)
                        Button("Save", action: saveHintCharacters)
                            .disabled(!hintCharactersValid || hintCharacters == model.config.hintCharacters)
                    }
                }
                note("Click mode, the window picker, and the window list use these characters. The first characters have priority.")
            }
            Section("Config file") {
                Button("Open config file") { NSWorkspace.shared.open(ConfigStore.url) }
                note("Use the file to edit per-app click strategies and other advanced settings.")
            }
        }
    }

    private var clickSections: some View {
        Group {
            Section("Labels") {
                Toggle("Give buttons, fields, and links the shortest labels", isOn: setting(\.prioritizeLabels))
                numberRow("Label size", unit: "pt", range: 8...48, step: 1, value: Binding(
                    get: { Int(model.config.labelFontSize) },
                    set: { model.config.labelFontSize = Double($0); model.commit() }))
            }
            Section("Clicks") {
                Toggle("Put the pointer back after a click", isOn: setting(\.restoreMousePosition))
            }
            Section("Chain clicks") {
                Toggle("Start click mode with chain clicks on", isOn: setting(\.chainModeByDefault))
                numberRow("Delay before new labels", unit: "ms", range: 0...5000, step: 50,
                          value: setting(\.chainDelayMs))
                note("Press Space in click mode to turn chain clicks on or off. Hold Shift while you type a label to chain one click.")
            }
        }
    }

    private func shortcutSection(_ mode: SettingsModel.Mode) -> some View {
        Section("Shortcut") {
            LabeledContent("Hotkeys") {
                HStack {
                    ForEach(0..<SettingsModel.slotsPerMode, id: \.self) { index in
                        slotView(SettingsModel.Slot.mode(mode, index))
                    }
                    Button("Reset") { model.reset(mode) }
                        .disabled(model.isDefault(mode))
                        .help("Restore the default hotkeys")
                }
            }
            ForEach(0..<SettingsModel.slotsPerMode, id: \.self) { index in
                let slot = SettingsModel.Slot.mode(mode, index)
                if let other = model.conflict(slot), let hotkey = model.hotkey(slot) {
                    Text("\(HotkeySpec(hotkey)?.displayString ?? hotkey) is also used by \(other.title).")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if case .mode(let activeMode, _) = model.recordingSlot, activeMode == mode {
                note("Press the key combination. Press Escape to cancel.")
            } else {
                note("Click a hotkey to change it, or add a second one.")
            }
        }
    }

    private func setting<Value>(_ path: WritableKeyPath<Config, Value>) -> Binding<Value> {
        Binding(get: { model.config[keyPath: path] },
                set: { model.config[keyPath: path] = $0; model.commit() })
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gridKeys(_ title: String, keys: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(keys).font(.system(.body, design: .monospaced))
        }
    }

    /// A number setting: the title on the left, the field (with its unit and a stepper) on the right.
    private func numberRow(_ title: String, unit: String, range: ClosedRange<Int>, step: Int, value: Binding<Int>) -> some View {
        let clamped = Binding(get: { value.wrappedValue },
                              set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) })
        return LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text(unit).foregroundStyle(.secondary)
                Stepper(title, value: clamped, in: range, step: step).labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func slotView(_ slot: SettingsModel.Slot) -> some View {
        let recording = model.recordingSlot == slot
        if let hotkey = model.hotkey(slot) {
            HStack(spacing: 2) {
                Button(recording ? "Press keys…" : (HotkeySpec(hotkey)?.displayString ?? hotkey)) { model.record(slot) }
                    .frame(minWidth: 76)
                Button { model.remove(slot) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(HotkeySpec(hotkey)?.displayString ?? hotkey)")
                    .help("Clear this hotkey")
            }
        } else if case .mode(let mode, let index) = slot {
            if index == model.hotkeys(mode).count {
                HStack(spacing: 2) {
                    if index == 0 && !recording { Text("Not set").foregroundStyle(.secondary) }
                    Button(recording ? "Press keys…" : "+ Add") { model.record(slot) }
                        .frame(minWidth: 76)
                }
            }
        } else {
            Button(recording ? "Press keys…" : "Add hotkey") { model.record(slot) }
        }
    }

    private var hintCharactersValid: Bool {
        Set(hintCharacters.lowercased()).count >= 2
    }

    private func saveHintCharacters() {
        guard hintCharactersValid else { NSSound.beep(); return }
        model.config.hintCharacters = hintCharacters.lowercased()
        model.commit()
    }
}

private struct PinnedAppsSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var pinMessage = ""
    @State private var showPinMessage = false

    var body: some View {
        Section("Pinned apps") {
            Text("Give an app a fixed letter in the window list and window picker. The window list can also launch pinned apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.config.pins.sorted(by: { $0.key < $1.key }), id: \.key) { letter, bundleID in
                let name = appName(bundleID)
                LabeledContent(name) {
                    Picker("Pinned letter for \(name)", selection: Binding(
                        get: { letter },
                        set: { if model.config.setWindowPin($0, for: bundleID) { model.commit() } })) {
                        ForEach((model.config.availableWindowPinLetters + [letter]).sorted(), id: \.self) { choice in
                            Text(choice.uppercased()).tag(choice)
                        }
                    }
                    .labelsHidden()
                    Button {
                        model.config.removeWindowPin(for: bundleID)
                        model.commit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove pin for \(name)")
                    .help("Remove pin for \(name)")
                }
            }

            HStack {
                Button("Pin an app…", action: chooseApp)
                    .disabled(model.config.availableWindowPinLetters.isEmpty)
                Button("Open config file") { NSWorkspace.shared.open(ConfigStore.url) }
            }
            if model.config.availableWindowPinLetters.isEmpty {
                Text("All letters are in use. Remove a pin to free a letter.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .alert("Pin an app", isPresented: $showPinMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pinMessage)
        }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func chooseApp() {
        guard let window = NSApp.keyWindow else { return }
        model.stopRecording()
        let panel = NSOpenPanel()
        panel.title = "Pin an app"
        panel.prompt = "Pin"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                showMessage("This app has no bundle identifier. Choose another app.")
                return
            }
            guard !model.config.pins.values.contains(bundleID) else {
                showMessage("This app already has a pin. Use the letter menu to change it.")
                return
            }
            let available = model.config.availableWindowPinLetters
            let name = FileManager.default.displayName(atPath: url.path)
            let letter = name.lowercased().first.flatMap { available.contains($0) ? $0 : nil } ?? available.first
            if let letter, model.config.setWindowPin(letter, for: bundleID) {
                model.commit()
            } else {
                showMessage("All letters are in use. Remove a pin to free a letter.")
            }
        }
    }

    private func showMessage(_ message: String) {
        pinMessage = message
        showPinMessage = true
    }
}
