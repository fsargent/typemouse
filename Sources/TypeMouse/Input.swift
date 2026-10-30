import AppKit
import Carbon
import TypeMouseCore

/// One key press, as the modes see it.
struct KeyEvent {
    let keyCode: Int64
    /// Lowercased character, ignoring modifiers. Empty for non-character keys.
    let char: String
    let shift: Bool
    let command: Bool
    let option: Bool
    let control: Bool

    /// Hyper still held from the activation hotkey counts as no modifiers.
    var hyperHeld: Bool { shift && command && option && control }

    /// Main thread only. Reads the character with no modifiers, so Shift+; is still ";".
    /// Shift means right-click in click mode, so it must not change the character.
    init(keyCode: Int64, flags: CGEventFlags) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.keyCode = keyCode
        let c = KeyTranslator.unmodifiedCharacter(UInt16(truncatingIfNeeded: keyCode)).lowercased()
        char = c.count == 1 && c.unicodeScalars.first!.value >= 32 ? c : ""
        shift = flags.contains(.maskShift)
        command = flags.contains(.maskCommand)
        option = flags.contains(.maskAlternate)
        control = flags.contains(.maskControl)
    }

    enum Special { case escape, enter, backspace, tab, up, down, space, other }

    var special: Special {
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51: return .backspace
        case 48: return .tab
        case 126: return .up
        case 125: return .down
        case 49: return .space
        default: return .other
        }
    }
}

/// Turns a virtual key code into the character of the current keyboard layout.
enum KeyTranslator {
    static func unmodifiedCharacter(_ keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : ""
    }
}

/// Global hotkeys through Carbon. This is reliable and needs no permission.
final class HotkeyManager {
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    func register(_ spec: HotkeySpec, _ handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        var mods: UInt32 = 0
        if spec.modifiers.contains(.command) { mods |= UInt32(cmdKey) }
        if spec.modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
        if spec.modifiers.contains(.option) { mods |= UInt32(optionKey) }
        if spec.modifiers.contains(.control) { mods |= UInt32(controlKey) }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x544D_5345), id: id) // "TMSE"
        let status = RegisterEventHotKey(spec.keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.info("hotkey \(spec) failed to register: \(status)")
            return false
        }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            me.fire(hkID.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}

/// Swallows keyboard input while a mode is active, without taking focus from the target app.
///
/// The tap lives on its own thread with its own run loop. The main thread can block
/// on AX calls, and macOS disables taps whose callback is slow.
final class KeyCapture {
    var onKey: ((KeyEvent) -> Void)?
    private var tap: CFMachPort?
    private var thread: Thread?
    private let lock = NSLock()
    private var _active = false

    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return _active
    }

    var isStarted: Bool { tap != nil }

    /// Fails until the app has Accessibility permission.
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: keyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        t.name = "typemouse.keytap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        return true
    }

    func setActive(_ on: Bool) {
        lock.lock()
        _active = on
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if active, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard active else { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            // Only plain values cross threads. Text input source APIs must run on the main thread.
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            DispatchQueue.main.async { [weak self] in
                self?.onKey?(KeyEvent(keyCode: keyCode, flags: flags))
            }
        }
        return nil
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyCapture>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
