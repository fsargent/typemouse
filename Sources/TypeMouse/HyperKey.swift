import AppKit
import IOKit.hidsystem
import TypeMouseCore

/// Caps Lock as Hyper, the same way the Hyperkey app does it:
/// 1. A system key remap makes Caps Lock send F18.
/// 2. An event tap swallows F18 and, while it is held, adds Command + Control + Option + Shift
///    to every other key. So Caps Lock + J arrives everywhere as Hyper + J.
///
/// The tap runs only while the setting is on. The remap is removed when the setting turns off
/// and when TypeMouse quits.
final class HyperKey {
    private var tap: CFMachPort?
    private var thread: Thread?
    private let lock = NSLock()
    private var held = false
    private(set) var isEnabled = false

    static let hyperFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if on {
            guard startTap() else { Log.info("caps lock to hyper: event tap failed"); return }
            Self.updateRemap(add: true)
            isEnabled = true
            Log.info("caps lock to hyper: on")
        } else {
            Self.updateRemap(add: false)
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            isEnabled = false
            Log.info("caps lock to hyper: off")
        }
    }

    // MARK: - Remap

    private static func updateRemap(add: Bool) {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let key = "UserKeyMapping" as CFString
        let current = (IOHIDEventSystemClientCopyProperty(client, key) as? [[String: Any]] ?? []).map { entry in
            entry.compactMapValues { ($0 as? NSNumber)?.uint64Value }
        }
        let next = add ? CapsLockMapping.adding(to: current) : CapsLockMapping.removing(from: current)
        let value = next.map { $0.mapValues { NSNumber(value: $0) } } as CFArray
        if !IOHIDEventSystemClientSetProperty(client, key, value) {
            Log.info("caps lock to hyper: key remap failed")
        }
    }

    // MARK: - Tap

    private func startTap() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: hyperTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // Its own thread, like the key capture tap: a slow main thread must not delay typing.
        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        t.name = "typemouse.hyperkey"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isEnabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventKeycode) == CapsLockMapping.f18KeyCode {
            lock.lock()
            held = type == .keyDown
            lock.unlock()
            return nil
        }
        lock.lock()
        let isHeld = held
        lock.unlock()
        if isHeld { event.flags.formUnion(Self.hyperFlags) }
        return Unmanaged.passUnretained(event)
    }
}

private func hyperTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HyperKey>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
