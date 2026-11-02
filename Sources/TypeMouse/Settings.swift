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

        var keyPath: WritableKeyPath<Config.Hotkeys, String> {
            switch self {
            case .click: return \.click
            case .search: return \.search
            case .window: return \.window
            case .picker: return \.picker
            }
        }
    }

    @Published var config: Config
    @Published private(set) var recordingMode: Mode?
    private let save: (Config) -> Void
    private let recording: (Bool) -> Void
    private var monitor: Any?

    init(config: Config, save: @escaping (Config) -> Void, recording: @escaping (Bool) -> Void) {
        self.config = config
        self.save = save
        self.recording = recording
    }

    func commit() { save(config) }

    func hotkey(_ mode: Mode) -> String { config.hotkeys[keyPath: mode.keyPath] }

    /// The other mode that uses the same hotkey, if any.
    func conflict(_ mode: Mode) -> Mode? {
        guard let mine = HotkeySpec(hotkey(mode)) else { return nil }
        return Mode.allCases.first { other in
            guard other != mode, let theirs = HotkeySpec(hotkey(other)) else { return false }
            return theirs.keyCode == mine.keyCode && theirs.modifiers == mine.modifiers
        }
    }

    func record(_ mode: Mode) {
        stopRecording()
        recordingMode = mode
        recording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recorded(event)
            return nil
        }
    }

    func reset(_ mode: Mode) {
        config.hotkeys[keyPath: mode.keyPath] = Config.Hotkeys()[keyPath: mode.keyPath]
        commit()
    }

    private func recorded(_ event: NSEvent) {
        guard let mode = recordingMode else { return }
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
        config.hotkeys[keyPath: mode.keyPath] = string
        stopRecording()
        commit()
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recordingMode != nil {
            recordingMode = nil
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
                        if let other = model.conflict(mode) {
                            Text("Same as \(other.rawValue)").font(.caption).foregroundStyle(.red)
                        }
                        Button(label(mode)) { model.record(mode) }
                            .frame(minWidth: 150)
                        Button("Reset") { model.reset(mode) }
                            .disabled(model.hotkey(mode) == Config.Hotkeys()[keyPath: mode.keyPath])
                    }
                }
                Text("Click a hotkey, then press the new key combination. Press Esc to cancel. Another app can own a hotkey without a warning. If a hotkey does nothing, try another.")
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
                Stepper(value: Binding(get: { model.config.labelFontSize },
                                       set: { model.config.labelFontSize = $0; model.commit() }),
                        in: 9...24, step: 1) {
                    Text("Label size: \(Int(model.config.labelFontSize)) pt")
                }
            }

            Section("Behavior") {
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

    private func label(_ mode: SettingsModel.Mode) -> String {
        if model.recordingMode == mode { return "Press keys…" }
        return HotkeySpec(model.hotkey(mode))?.displayString ?? model.hotkey(mode)
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
