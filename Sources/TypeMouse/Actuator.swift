import AppKit
import ApplicationServices
import TypeMouseCore

enum ClickKind {
    case left, right, command, double, hover

    /// Modifiers on the final key choose the kind of click.
    init(_ key: KeyEvent) {
        if key.hyperHeld { self = .left }
        else if key.shift { self = .right }
        else if key.command { self = .command }
        else if key.control { self = .double }
        else if key.option { self = .hover }
        else { self = .left }
    }
}

/// Performs a click on a target, with AXPress or with a synthetic mouse event.
enum Actuator {
    static func perform(_ kind: ClickKind, on t: Target, strategy: Config.ClickStrategy, restoreMouse: Bool) {
        let point = CGPoint(x: t.frame.midX, y: t.frame.midY)
        Log.info("click \(kind) \(t.role) \"\(t.text.prefix(40))\" at \(Int(point.x)),\(Int(point.y)) strategy=\(strategy)")

        switch kind {
        case .hover:
            moveMouse(to: point)
            return
        case .right:
            if strategy != .mouse && !t.inWebArea && t.element.perform(kAXShowMenuAction) == .success { return }
            mouseClick(at: point, button: .right, restore: restoreMouse)
            return
        case .command:
            mouseClick(at: point, flags: .maskCommand, restore: restoreMouse)
            return
        case .double:
            mouseClick(at: point, count: 2, restore: restoreMouse)
            return
        case .left:
            break
        }

        if t.isTextInput {
            // Web text fields focus more reliably with a real click.
            if !t.inWebArea && strategy != .mouse && t.element.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { return }
            mouseClick(at: point, restore: false)
            return
        }

        switch strategy {
        case .mouse:
            mouseClick(at: point, restore: restoreMouse)
        case .press:
            press(t)
        case .auto:
            if t.inWebArea || !press(t) { mouseClick(at: point, restore: restoreMouse) }
        }
    }

    @discardableResult
    static func press(_ t: Target) -> Bool {
        // AXRow has no press action. Selecting it is what a click does.
        if t.role == "AXRow" { return t.element.set(kAXSelectedAttribute, kCFBooleanTrue) == .success }
        let err = t.element.perform(kAXPressAction)
        if err == .success { return true }
        return t.element.perform("AXOpen") == .success
    }

    static func moveMouse(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func mouseClick(at p: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = [], count: Int = 1, restore: Bool) {
        let original = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        let (downType, upType): (CGEventType, CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)

        moveMouse(to: p)
        for n in 1...max(1, count) {
            for type in [downType, upType] {
                guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { continue }
                e.flags = flags
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.post(tap: .cghidEventTap)
            }
        }
        if restore, let original {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                CGWarpMouseCursorPosition(original)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }
}
