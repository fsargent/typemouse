import AppKit
import SwiftUI
import TypeMouseCore

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
            w.styleMask = [.titled, .closable]
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

        var id: String { rawValue }

        var keyPath: WritableKeyPath<Config.Hotkeys, [String]> {
            switch self {
            case .click: return \.click
            case .search: return \.search
            case .window: return \.window
            case .picker: return \.picker
            }
        }
    }

    /// One hotkey of a mode. Index 0 is the main hotkey, index 1 the second one.
    struct Slot: Equatable {
        let mode: Mode
        let index: Int
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
        let list = hotkeys(slot.mode)
        return list.indices.contains(slot.index) ? list[slot.index] : nil
    }

    func isDefault(_ mode: Mode) -> Bool { hotkeys(mode) == Config.Hotkeys()[keyPath: mode.keyPath] }

    /// Another slot (in any mode) with the same key combination, if any.
    func conflict(_ slot: Slot) -> Slot? {
        guard let string = hotkey(slot), let mine = HotkeySpec(string) else { return nil }
        for mode in Mode.allCases {
            for (i, other) in hotkeys(mode).enumerated() where Slot(mode: mode, index: i) != slot {
                if let theirs = HotkeySpec(other), theirs.keyCode == mine.keyCode, theirs.modifiers == mine.modifiers {
                    return Slot(mode: mode, index: i)
                }
            }
        }
        return nil
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

    /// Clears one hotkey. A mode with no hotkey is off until you add one.
    func remove(_ slot: Slot) {
        guard hotkey(slot) != nil else { return }
        config.hotkeys[keyPath: slot.mode.keyPath].remove(at: slot.index)
        commit()
    }

    func reset(_ mode: Mode) {
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
        var list = hotkeys(slot.mode)
        if list.indices.contains(slot.index) { list[slot.index] = string } else { list.append(string) }
        config.hotkeys[keyPath: slot.mode.keyPath] = list
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
    @ObservedObject var model: SettingsModel
    @State private var hintCharacters = ""
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Hotkeys") {
                ForEach(SettingsModel.Mode.allCases) { mode in
                    HStack {
                        Text(mode.rawValue)
                        Spacer()
                        ForEach(0..<SettingsModel.slotsPerMode, id: \.self) { index in
                            slotView(SettingsModel.Slot(mode: mode, index: index))
                        }
                        Button("Reset") { model.reset(mode) }
                            .disabled(model.isDefault(mode))
                    }
                    ForEach(0..<SettingsModel.slotsPerMode, id: \.self) { index in
                        if let other = model.conflict(SettingsModel.Slot(mode: mode, index: index)) {
                            Text("\(model.hotkey(SettingsModel.Slot(mode: mode, index: index)).flatMap { HotkeySpec($0)?.displayString } ?? "") is also used by \(other.mode.rawValue)")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Text("Click a hotkey, then press the new key combination. Press Esc to cancel. Each mode can have a second hotkey. Click × to clear a hotkey and turn that mode off. Another app can own a hotkey without a warning. If a hotkey does nothing, try another.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Labels") {
                HStack {
                    TextField("Hint characters", text: $hintCharacters)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(saveHintCharacters)
                    Button("Save", action: saveHintCharacters)
                        .disabled(!hintCharactersValid || hintCharacters == model.config.hintCharacters)
                }
                Text("Most preferred first. Short labels use the first characters.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Shortest labels for buttons, then fields, then links", isOn: Binding(
                    get: { model.config.prioritizeLabels },
                    set: { model.config.prioritizeLabels = $0; model.commit() }))
                Text("A browser's own tabs and toolbar get the longest labels. Off: labels follow reading order.")
                    .font(.caption).foregroundStyle(.secondary)
                numberRow("Label size", unit: "pt", range: 8...48, step: 1, value: Binding(
                    get: { Int(model.config.labelFontSize) },
                    set: { model.config.labelFontSize = Double($0); model.commit() }))
            }

            Section("Keyboard") {
                Toggle("Use Caps Lock as Hyper", isOn: Binding(
                    get: { model.config.capsLockToHyper },
                    set: { model.config.capsLockToHyper = $0; model.commit() }))
                Text("Hold Caps Lock for Command + Control + Option + Shift, the default TypeMouse hotkeys. Leave this off if Karabiner, kanata, or your keyboard already makes a Hyper key.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Behavior") {
                Toggle("Start click mode in chain mode", isOn: Binding(
                    get: { model.config.chainModeByDefault },
                    set: { model.config.chainModeByDefault = $0; model.commit() }))
                numberRow("Chain click delay", unit: "ms", range: 0...5000, step: 100, value: Binding(
                    get: { model.config.chainDelayMs },
                    set: { model.config.chainDelayMs = $0; model.commit() }))
                Text("Shift + label, or Space in click mode, chains clicks: click, wait this long, then show new labels.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Start click mode after the window picker", isOn: Binding(
                    get: { model.config.clickAfterPicker },
                    set: { model.config.clickAfterPicker = $0; model.commit() }))
                Toggle("Put the mouse back after a click", isOn: Binding(
                    get: { model.config.restoreMousePosition },
                    set: { model.config.restoreMousePosition = $0; model.commit() }))
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
            }

            Section {
                HStack {
                    Text("Other settings, such as window pins and click strategies, are in the config file.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open config file") { NSWorkspace.shared.open(ConfigStore.url) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hintCharacters = model.config.hintCharacters }
        .onChange(of: model.config.hintCharacters) { _, new in hintCharacters = new }
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
                    .frame(minWidth: 110)
                Button { model.remove(slot) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Clear this hotkey")
            }
        } else if slot.index == model.hotkeys(slot.mode).count {
            // Only the next free slot shows an "add" button.
            HStack(spacing: 2) {
                if slot.index == 0 && !recording {
                    Text("Not set").foregroundStyle(.secondary)
                }
                Button(recording ? "Press keys…" : "+ Add") { model.record(slot) }
                    .frame(minWidth: 110)
            }
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
