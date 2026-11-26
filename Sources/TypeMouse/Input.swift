import AppKit
import Carbon
import TypeMouseCore

/// One key press, as the modes see it.
struct KeyEvent: Sendable {
    let keyCode: Int64
    /// Lowercased character, ignoring modifiers. Empty for non-character keys.
    let char: String
    let shift: Bool
    let command: Bool
    let option: Bool
    let control: Bool
    let isRepeat: Bool

    /// Hyper still held from the activation hotkey counts as no modifiers.
    var hyperHeld: Bool { shift && command && option && control }

    /// Main thread only. Reads the character with no modifiers, so Shift+; is still ";".
    /// Shift chains clicks in click mode, so it must not change the character.
    @MainActor
    init(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.keyCode = keyCode
        self.isRepeat = isRepeat
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
        case Int64(KeyCode.escape): return .escape
        case Int64(KeyCode.returnKey), Int64(KeyCode.numpadEnter): return .enter
        case Int64(KeyCode.backspace): return .backspace
        case Int64(KeyCode.tab): return .tab
        case Int64(KeyCode.upArrow): return .up
        case Int64(KeyCode.downArrow): return .down
        case Int64(KeyCode.space): return .space
        default: return .other
        }
    }
}

/// Turns a virtual key code into the character of the current keyboard layout.
enum KeyTranslator {
    static func unmodifiedCharacter(_ keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : ""
    }
}

/// Global hotkeys through Carbon. This is reliable and needs no permission.
@MainActor
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
        let hkID = EventHotKeyID(signature: OSType(0x544D_5345), id: id)  // "TMSE"
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
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        handlers = [:]
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { me.fire(hkID.id) }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}

/// Swallows keyboard input while a mode is active, without taking focus from the target app.
///
/// The tap lives on its own thread with its own run loop. The main thread can block
/// on AX calls, and macOS disables taps whose callback is slow.
final class KeyCapture: @unchecked Sendable {
    @MainActor var onKey: ((KeyEvent) -> Void)?
    @MainActor var onKeyUp: ((Int64) -> Void)?
    @MainActor var onFlagsChanged: ((CGEventFlags) -> Void)?
    @MainActor var onInterrupted: (() -> Void)?
    private var tap: CFMachPort?
    private var thread: Thread?
    private let lock = NSLock()
    private var _active = false
    private var passthroughKeyUps: Set<Int64> = []

    @MainActor init() {}

    var active: Bool {
        lock.withLock { _active }
    }

    var isStarted: Bool { tap != nil }

    /// Fails until the app has Accessibility permission.
    func start() -> Bool {
        if tap != nil { return true }
        let mask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: keyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
        let boxedSource = UnsafeSendable(value: CFMachPortCreateRunLoopSource(nil, tap, 0))
        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), boxedSource.value, .commonModes)
            CFRunLoopRun()
        }
        t.name = "typemouse.keytap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        return true
    }

    func setActive(_ on: Bool) {
        lock.withLock {
            _active = on
            if !on { passthroughKeyUps = [] }
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    /// Carbon must see the release of a hotkey that enabled capture.
    func passNextKeyUp(_ keyCode: Int64) {
        lock.withLock { _ = passthroughKeyUps.insert(keyCode) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onInterrupted?() }
            }
            if active, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard active else { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            // Only plain values cross threads. Text input source APIs must run on the main thread.
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onKey?(KeyEvent(keyCode: keyCode, flags: flags, isRepeat: isRepeat))
                }
            }
        } else if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onKeyUp?(keyCode) }
            }
            let pass = lock.withLock { passthroughKeyUps.remove(keyCode) != nil }
            if pass { return Unmanaged.passUnretained(event) }
        } else if type == .flagsChanged {
            let flags = event.flags
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onFlagsChanged?(flags) }
            }
            return Unmanaged.passUnretained(event)
        }
        return nil
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>?
{
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyCapture>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
