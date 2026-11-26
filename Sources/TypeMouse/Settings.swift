import AppKit
import SwiftUI
import TypeMouseCore
import UniformTypeIdentifiers

/// The settings window. It edits the same config file that TypeMouse watches,
/// so a change in the window and a change in the file have the same effect.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel

    /// - Parameters:
    ///   - save: writes a changed config.
    ///   - recording: true while a hotkey field records. TypeMouse releases its hotkeys then,
    ///     so the current hotkeys reach the window instead of opening a mode.
    init(config: Config, save: @escaping (Config) -> Void, recording: @escaping (Bool) -> Void) {
        model = SettingsModel(config: config, save: save, recording: recording)
        super.init()
    }

    func update(config: Config) {
        if model.config != config {
            model.config = config
        }
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let panel = NSWindow(contentViewController: hosting)
            panel.title = "TypeMouse Settings"
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .windowBackgroundColor
            panel.setContentSize(NSSize(width: 820, height: 620))
            panel.minSize = NSSize(width: 720, height: 500)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            window = panel
        }
        model.refreshSystemState()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshSystemState()
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
        case scroll = "Scroll mode"

        var id: String { rawValue }

        var feature: Config.Mode {
            switch self {
            case .click: return .click
            case .search: return .search
            case .window: return .windowList
            case .picker: return .windowPicker
            case .missionControl: return .missionControl
            case .grid: return .grid
            case .scroll: return .scroll
            }
        }

        var keyPath: WritableKeyPath<Config.Hotkeys, [String]> {
            switch self {
            case .click: return \.click
            case .search: return \.search
            case .window: return \.window
            case .picker: return \.picker
            case .missionControl: return \.missionControl
            case .grid: return \.grid
            case .scroll: return \.scroll
            }
        }
    }

    enum Slot: Equatable {
        case mode(Mode, Int)
        case command(WindowCommand)

        var feature: Config.Mode {
            switch self {
            case .mode(let mode, _): return mode.feature
            case .command: return .windowManagement
            }
        }

        var title: String {
            switch self {
            case .mode(let mode, _): return mode.rawValue
            case .command(let command): return command.title
            }
        }
    }

    static let slotsPerMode = 2

    @Published var config: Config
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published private(set) var recordingSlot: Slot?
    private let save: (Config) -> Void
    private let recording: (Bool) -> Void
    private var monitor: Any?

    init(config: Config, save: @escaping (Config) -> Void, recording: @escaping (Bool) -> Void) {
        self.config = config
        self.save = save
        self.recording = recording
    }

    func refreshSystemState() {
        launchAtLogin = LoginItem.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    func commit() {
        save(config)
    }

    func hotkeys(_ mode: Mode) -> [String] {
        config.hotkeys[keyPath: mode.keyPath]
    }

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

    func isDefault(_ mode: Mode) -> Bool {
        hotkeys(mode) == Config.Hotkeys()[keyPath: mode.keyPath]
    }

    /// Another slot (in any mode) with the same key combination, if any.
    func conflict(_ slot: Slot) -> Slot? {
        guard config.isModeEnabled(slot.feature),
              let string = hotkey(slot),
              let mine = HotkeySpec(string) else { return nil }
        let modes = Mode.allCases.filter { config.isModeEnabled($0.feature) }.flatMap { mode in
            hotkeys(mode).indices.map { Slot.mode(mode, $0) }
        }
        let commands = config.isModeEnabled(.windowManagement)
            ? WindowCommand.allCases.map { Slot.command($0) }
            : []
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
        if event.keyCode == 53 && mods.isEmpty {
            stopRecording()
            return
        }
        // A hotkey with no modifier would take that key away from every app.
        guard !mods.isEmpty,
              let string = HotkeySpec.configString(keyCode: UInt32(event.keyCode), modifiers: mods) else {
            NSSound.beep()
            return
        }
        switch slot {
        case .mode(let mode, let index):
            var list = hotkeys(mode)
            if list.indices.contains(index) {
                list[index] = string
            } else {
                list.append(string)
            }
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

// MARK: - Settings View

struct SettingsView: View {
    private enum Page: String, CaseIterable {
        case general = "General"
        case click = "Click"
        case grid = "Grid"
        case windowSelection = "Window selection"
        case windowManagement = "Window management"

        var mode: Config.Mode? {
            switch self {
            case .general: return nil
            case .click: return .click
            case .windowSelection: return .windowSelection
            case .grid: return .grid
            case .windowManagement: return .windowManagement
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .click: return "cursorarrow.click"
            case .grid: return "square.grid.3x3"
            case .windowSelection: return "macwindow"
            case .windowManagement: return "rectangle.split.2x2.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return Color(nsColor: .systemGray)
            case .click: return .orange
            case .grid: return .teal
            case .windowSelection: return .blue
            case .windowManagement: return .purple
            }
        }

        var introduction: String {
            switch self {
            case .general:
                return "Set up your Hyper key, startup options, and shared hint characters."
            case .click:
                return "Show a label on every clickable item and type it to click."
            case .grid:
                return "Refine a screen position through a 3×3 grid, or scroll continuously."
            case .windowSelection:
                return "Switch windows from a list, visible desktop labels, or Mission Control."
            case .windowManagement:
                return "Move and resize the focused window with keyboard layout shortcuts."
            }
        }
    }

    @ObservedObject var model: SettingsModel
    @State private var selection: Page? = .general
    @State private var hintCharacters = ""

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        let page = selection ?? .general
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
                List(Page.allCases, id: \.self, selection: $selection) { item in
                    sidebarRow(item)
                        .tag(item)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .padding(.top, 4)

                Divider()
                    .opacity(0.6)

                HStack {
                    Button {
                        NSWorkspace.shared.open(ConfigStore.url)
                    } label: {
                        Label("Config file", systemImage: "doc.text")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open ~/.config/typemouse/config.json")

                    Spacer()

                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 225, max: 250)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                detailHeader(page)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(page.introduction)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, -4)

                        pageContent(page)
                            .disabled(page.mode.map { !model.config.isModeEnabled($0) } ?? false)
                            .opacity(page.mode.map { model.config.isModeEnabled($0) ? 1 : 0.55 } ?? 1)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(page)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            hintCharacters = model.config.hintCharacters
            model.refreshSystemState()
        }
        .onChange(of: model.config.hintCharacters) { _, new in hintCharacters = new }
        .onChange(of: selection) { _, _ in model.stopRecording() }
    }

    private func sidebarRow(_ page: Page) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(page.tint.gradient)
                Image(systemName: page.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)

            Text(page.rawValue)
                .font(.system(size: 13))
        }
        .padding(.vertical, 3)
    }

    private func detailHeader(_ page: Page) -> some View {
        HStack(spacing: 12) {
            Text(page.rawValue)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Spacer()

            if let mode = page.mode {
                HStack(spacing: 8) {
                    Text(model.config.isModeEnabled(mode) ? "Enabled" : "Disabled")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    modeSwitch(mode)
                }
            }
        }
        .padding(.horizontal, 26)
        .frame(height: 52)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func pageContent(_ page: Page) -> some View {
        switch page {
        case .general:
            generalContent
        case .click:
            clickContent
        case .grid:
            gridContent
        case .windowSelection:
            windowSelectionContent
        case .windowManagement:
            windowManagementContent
        }
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("App") {
                SettingsToggleRow(
                    "Launch at login",
                    subtitle: "Start TypeMouse automatically when you sign in.",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
            }

            SettingsSection("Keyboard") {
                SettingsToggleRow(
                    "Use Caps Lock as Hyper",
                    subtitle: "Combine Command, Control, Option, and Shift on Caps Lock. Leave off if Karabiner or kanata already maps Hyper.",
                    isOn: setting(\.capsLockToHyper)
                )
            }

            SettingsSection(
                "Shared labels",
                footer: "Used by click mode, window pickers, window list, and scroll picker. Earlier characters get priority."
            ) {
                SettingsRow("Hint characters") {
                    HStack(spacing: 8) {
                        TextField("Hint characters", text: $hintCharacters)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 240)
                            .onSubmit(saveHintCharacters)
                        Button("Save", action: saveHintCharacters)
                            .disabled(!hintCharactersValid || hintCharacters == model.config.hintCharacters)
                    }
                }
            }

            SettingsSection(
                "Configuration",
                footer: "Edit per-app click strategies and browser accessibility overrides directly in JSON."
            ) {
                SettingsRow("Config file", subtitle: "~/.config/typemouse/config.json") {
                    Button("Open…") { NSWorkspace.shared.open(ConfigStore.url) }
                }
            }
        }
    }

    // MARK: - Click

    private var clickContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Shortcut", footer: shortcutHint(.click)) {
                hotkeyRow(.click)
            }

            SettingsSection("Labels") {
                SettingsToggleRow(
                    "Prioritize buttons, fields, and links",
                    subtitle: "Give controls the shortest labels before page links and browser chrome.",
                    isOn: setting(\.prioritizeLabels)
                )
                SettingsCardDivider()
                numberRow(
                    "Label size",
                    unit: "pt",
                    range: 8...48,
                    step: 1,
                    value: Binding(
                        get: { Int(model.config.labelFontSize) },
                        set: {
                            model.config.labelFontSize = Double($0)
                            model.commit()
                        }
                    )
                )
            }

            SettingsSection("Clicks") {
                SettingsToggleRow(
                    "Restore pointer position",
                    subtitle: "Put the pointer back after a synthetic click.",
                    isOn: setting(\.restoreMousePosition)
                )
                SettingsCardDivider()
                SettingsToggleRow(
                    "Start in chain mode",
                    subtitle: "Stay in click mode after every click. Press Space in click mode to toggle, or hold Shift for one chain click.",
                    isOn: setting(\.chainModeByDefault)
                )
                SettingsCardDivider()
                numberRow(
                    "Chain click delay",
                    subtitle: "Wait for menus or pages to update before showing new labels.",
                    unit: "ms",
                    range: 0...5000,
                    step: 50,
                    value: setting(\.chainDelayMs)
                )
            }

            SettingsSection(
                "Search",
                subtitle: "Find clickable items by text. Press / or Tab in click mode, or assign a direct shortcut."
            ) {
                SettingsToggleRow("Enable search", isOn: modeBinding(.search))
                Group {
                    SettingsCardDivider()
                    hotkeyRow(.search)
                }
                .disabled(!model.config.isModeEnabled(.search))
                .opacity(model.config.isModeEnabled(.search) ? 1 : 0.5)
            }
        }
    }

    // MARK: - Grid

    private var gridContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Shortcut", footer: shortcutHint(.grid)) {
                hotkeyRow(.grid)
            }

            SettingsSection(
                "Pointer grid",
                footer: "⌫ Undo · Esc Move pointer · Space Click · ↩ Scroll · Tab Switch displays"
            ) {
                SettingsRow(
                    "Preferred hand",
                    subtitle: "Used on a single display and for refinements. Two displays map left and right hands automatically."
                ) {
                    Picker("Preferred hand", selection: setting(\.gridHand)) {
                        ForEach(GridNavigation.Hand.allCases, id: \.self) { hand in
                            Text(hand.rawValue.capitalized).tag(hand)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                SettingsCardDivider()
                HStack(alignment: .top, spacing: 28) {
                    KeycapGridView(title: "Left hand", rows: [["W", "E", "R"], ["S", "D", "F"], ["X", "C", "V"]])
                    KeycapGridView(title: "Right hand", rows: [["U", "I", "O"], ["J", "K", "L"], ["M", ",", "."]])
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            SettingsSection(
                "Scroll mode",
                subtitle: "Label scrollable areas in the focused window, or press Enter from the grid to scroll there.",
                footer: "Arrow keys always scroll. Hold ⇧ for 3× speed, or ⌘⇧ for 6× speed."
            ) {
                SettingsToggleRow("Enable scroll mode", isOn: modeBinding(.scroll))
                Group {
                    SettingsCardDivider()
                    hotkeyRow(.scroll)
                    SettingsCardDivider()
                    SettingsRow("Direction keys") {
                        Picker("Direction keys", selection: setting(\.scrollKeys)) {
                            ForEach(ScrollKeys.allCases, id: \.self) { keys in
                                Text(keys.displayName).tag(keys)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    SettingsCardDivider()
                    numberRow(
                        "Scroll speed",
                        unit: "pt/s",
                        range: 50...5000,
                        step: 50,
                        value: setting(\.scrollSpeed)
                    )
                }
                .disabled(!model.config.isModeEnabled(.scroll))
                .opacity(model.config.isModeEnabled(.scroll) ? 1 : 0.5)
            }
        }
    }

    // MARK: - Window Selection

    private var windowSelectionContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Window list", subtitle: "Show a list of windows on every display with stable app letters.") {
                SettingsToggleRow("Enable window list", isOn: modeBinding(.windowList))
                Group {
                    SettingsCardDivider()
                    hotkeyRow(.window)
                }
                .disabled(!model.config.isModeEnabled(.windowList))
                .opacity(model.config.isModeEnabled(.windowList) ? 1 : 0.5)
            }

            SettingsSection("Window picker", subtitle: "Draw a large label directly on each visible window.") {
                SettingsToggleRow("Enable window picker", isOn: modeBinding(.windowPicker))
                Group {
                    SettingsCardDivider()
                    hotkeyRow(.picker)
                }
                .disabled(!model.config.isModeEnabled(.windowPicker))
                .opacity(model.config.isModeEnabled(.windowPicker) ? 1 : 0.5)
            }

            SettingsSection("Mission Control picker", subtitle: "Open Mission Control and label every window preview.") {
                SettingsToggleRow("Enable Mission Control picker", isOn: modeBinding(.missionControl))
                Group {
                    SettingsCardDivider()
                    hotkeyRow(.missionControl)
                }
                .disabled(!model.config.isModeEnabled(.missionControl))
                .opacity(model.config.isModeEnabled(.missionControl) ? 1 : 0.5)
            }

            SettingsSection("After selection") {
                SettingsToggleRow(
                    "Start click mode after focusing a window",
                    subtitle: "Applies to Window picker and Mission Control picker.",
                    isOn: setting(\.clickAfterPicker)
                )
                .disabled(!model.config.isModeEnabled(.click))
            }

            PinnedAppsSettings(model: model)
        }
    }

    // MARK: - Window Management

    private var windowManagementContent: some View {
        let rows: [[WindowCommand]] = [
            [.topLeft, .top, .topRight],
            [.left, .center, .right],
            [.bottomLeft, .bottom, .bottomRight],
        ]
        let footerText: String = {
            if case .command = model.recordingSlot {
                return "Press the new key combination. Press Escape to cancel."
            }
            return "Edge keys cycle half, two-thirds, and one-third. Center cycles full, half, and third."
        }()

        return VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Window layout", footer: footerText) {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row], id: \.self) { command in
                                windowShortcutCell(command)
                            }
                        }
                    }
                }
                .padding(12)
            }

            SettingsSection("Displays") {
                SettingsRow(
                    WindowCommand.nextDisplay.title,
                    subtitle: "Keep the window's relative size and position."
                ) {
                    slotView(.command(.nextDisplay))
                }
                if let other = model.conflict(.command(.nextDisplay)) {
                    conflictBanner(for: .command(.nextDisplay), other: other)
                }
            }

            HStack {
                Spacer()
                Button("Reset window management shortcuts") {
                    model.stopRecording()
                    model.config.hotkeys.windowManagement = [:]
                    model.commit()
                }
                .disabled(model.config.hotkeys.windowManagement.isEmpty)
            }
        }
    }

    private func windowShortcutCell(_ command: WindowCommand) -> some View {
        let slot = SettingsModel.Slot.command(command)
        return VStack(alignment: .leading, spacing: 6) {
            Text(command.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            slotView(slot)
            if let other = model.conflict(slot) {
                Text("Used by \(other.title)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    // MARK: - Shared Controls

    private func modeBinding(_ mode: Config.Mode) -> Binding<Bool> {
        Binding(
            get: { !model.config.disabledModes.contains(mode.rawValue) },
            set: { enabled in
                model.stopRecording()
                model.config.setModeEnabled(mode, enabled)
                model.commit()
            }
        )
    }

    private func modeSwitch(_ mode: Config.Mode) -> some View {
        Toggle("", isOn: modeBinding(mode))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private func setting<Value>(_ path: WritableKeyPath<Config, Value>) -> Binding<Value> {
        Binding(
            get: { model.config[keyPath: path] },
            set: {
                model.config[keyPath: path] = $0
                model.commit()
            }
        )
    }

    private func shortcutHint(_ mode: SettingsModel.Mode) -> String {
        if case .mode(let activeMode, _) = model.recordingSlot, activeMode == mode {
            return "Press the key combination. Press Escape to cancel."
        }
        return "Click a shortcut to record a new key combination, or add a second one."
    }

    @ViewBuilder
    private func hotkeyRow(_ mode: SettingsModel.Mode) -> some View {
        SettingsRow("Hotkeys") {
            HStack(spacing: 8) {
                ForEach(0..<SettingsModel.slotsPerMode, id: \.self) { index in
                    slotView(.mode(mode, index))
                }
                Button("Reset") { model.reset(mode) }
                    .disabled(model.isDefault(mode))
                    .help("Restore the default hotkeys")
            }
        }
        ForEach(0..<SettingsModel.slotsPerMode, id: \.self) { index in
            let slot = SettingsModel.Slot.mode(mode, index)
            if let other = model.conflict(slot) {
                conflictBanner(for: slot, other: other)
            }
        }
    }

    private func conflictBanner(for slot: SettingsModel.Slot, other: SettingsModel.Slot) -> some View {
        let label = model.hotkey(slot).map { HotkeySpec($0)?.displayString ?? $0 } ?? "This hotkey"
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text("\(label) is also used by \(other.title).")
                .font(.caption)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func numberRow(
        _ title: String,
        subtitle: String? = nil,
        unit: String,
        range: ClosedRange<Int>,
        step: Int,
        value: Binding<Int>
    ) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
        return SettingsRow(title, subtitle: subtitle) {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text(unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper(title, value: clamped, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func slotView(_ slot: SettingsModel.Slot) -> some View {
        let recording = model.recordingSlot == slot
        if let hotkey = model.hotkey(slot) {
            let display = HotkeySpec(hotkey)?.displayString ?? hotkey
            HotkeyPill(
                title: recording ? "Press keys…" : display,
                isRecording: recording,
                onRecord: { model.record(slot) },
                onClear: { model.remove(slot) },
                clearLabel: "Clear \(display)"
            )
        } else if case .mode(let mode, let index) = slot {
            if index == model.hotkeys(mode).count {
                HotkeyPill(
                    title: recording ? "Press keys…" : (index == 0 ? "Record shortcut" : "+ Add"),
                    isRecording: recording,
                    isEmpty: !recording,
                    onRecord: { model.record(slot) }
                )
            }
        } else {
            HotkeyPill(
                title: recording ? "Press keys…" : "Set shortcut",
                isRecording: recording,
                isEmpty: !recording,
                onRecord: { model.record(slot) }
            )
        }
    }

    private var hintCharactersValid: Bool {
        let cleaned = hintCharacters.lowercased().filter { !$0.isWhitespace && $0 != "/" }
        return Set(cleaned).count >= 2 && cleaned.count == hintCharacters.count
    }

    private func saveHintCharacters() {
        guard hintCharactersValid else {
            NSSound.beep()
            return
        }
        model.config.hintCharacters = hintCharacters.lowercased()
        model.commit()
    }
}

// MARK: - Reusable Settings Chrome

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}

private struct HotkeyPill: View {
    let title: String
    let isRecording: Bool
    var isEmpty: Bool = false
    let onRecord: () -> Void
    var onClear: (() -> Void)? = nil
    var clearLabel: String = "Clear shortcut"

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onRecord) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isRecording ? Color.accentColor : (isEmpty ? .secondary : .primary))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onClear, !isRecording {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5)
                .accessibilityLabel(clearLabel)
                .help("Clear this hotkey")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isRecording ? Color.accentColor : Color.primary.opacity(0.14),
                    lineWidth: isRecording ? 1.25 : 0.75
                )
        )
    }
}

private struct KeycapGridView: View {
    let title: String
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(rows[row], id: \.self) { key in
                            Text(key)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(width: 26, height: 24)
                                .background(
                                    Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                                )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pinned Apps

private struct PinnedAppsSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var pinMessage = ""
    @State private var showPinMessage = false

    var body: some View {
        let sortedPins = model.config.pins.sorted { $0.key < $1.key }
        SettingsSection(
            "Pinned apps",
            subtitle: "Give an app a fixed letter in the window list and pickers. The window list can also launch pinned apps.",
            footer: model.config.availableWindowPinLetters.isEmpty
                ? "All letters are in use. Remove a pin to free a letter."
                : nil
        ) {
            ForEach(Array(sortedPins.enumerated()), id: \.element.key) { index, entry in
                if index > 0 { SettingsCardDivider() }
                let (letter, bundleID) = entry
                let name = appName(bundleID)
                SettingsRow(name) {
                    HStack(spacing: 8) {
                        Picker("Pinned letter for \(name)", selection: Binding(
                            get: { letter },
                            set: { if model.config.setWindowPin($0, for: bundleID) { model.commit() } }
                        )) {
                            ForEach((model.config.availableWindowPinLetters + [letter]).sorted(), id: \.self) { choice in
                                Text(choice.uppercased()).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 56)

                        Button {
                            model.config.removeWindowPin(for: bundleID)
                            model.commit()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove pin for \(name)")
                        .help("Remove pin for \(name)")
                    }
                }
            }

            if !sortedPins.isEmpty { SettingsCardDivider() }

            HStack {
                Button("Pin an app…", action: chooseApp)
                    .disabled(model.config.availableWindowPinLetters.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
