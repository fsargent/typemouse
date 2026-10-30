import AppKit
import ApplicationServices
import TypeMouseCore

/// Thin, typed wrappers over the AXUIElement C API.
extension AXUIElement {
    func value(_ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(self, attr as CFString, &v) == .success ? v : nil
    }

    func string(_ attr: String) -> String? { value(attr) as? String }

    func bool(_ attr: String) -> Bool? { (value(attr) as? NSNumber)?.boolValue }

    func element(_ attr: String) -> AXUIElement? {
        guard let v = value(attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attr: String) -> [AXUIElement] {
        (value(attr) as? [AXUIElement]) ?? []
    }

    /// Reads several attributes in one IPC round trip. Missing or failed attributes are left out.
    func values(_ attrs: [String]) -> [String: AnyObject] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let arr = out as? [AnyObject] else { return [:] }
        var dict: [String: AnyObject] = [:]
        for (i, v) in arr.enumerated() where i < attrs.count {
            if v is NSNull { continue }
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            dict[attrs[i]] = v
        }
        return dict
    }

    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func parameterizedAttributeNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(self, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func parameterized(_ attr: String, _ param: AnyObject) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyParameterizedAttributeValue(self, attr as CFString, param, &v) == .success ? v : nil
    }

    @discardableResult
    func set(_ attr: String, _ value: AnyObject) -> AXError {
        AXUIElementSetAttributeValue(self, attr as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    var frame: CGRect? {
        let v = values([kAXPositionAttribute, kAXSizeAttribute])
        return AX.frame(position: v[kAXPositionAttribute], size: v[kAXSizeAttribute])
    }

    /// CGWindowID of an AXWindow, through the private (but stable for 15+ years) HIServices call.
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
              AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Caps every AX call. Without this, one hung app blocks us for the default 6 seconds.
    static func setGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Union of all screens in AX coordinates.
    static func desktopBounds() -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.reduce(CGRect.null) {
            $0.union(Geometry.cocoaRectToAX($1.frame, primaryHeight: primaryHeight))
        }
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

extension Geometry {
    static func cocoaRectToAX(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        axRect(fromCocoa: r, primaryHeight: primaryHeight)
    }
}

/// Chromium and Electron build their accessibility tree only when asked.
/// http://dev.chromium.org/developers/design-documents/accessibility
/// https://www.electronjs.org/docs/latest/tutorial/accessibility
enum AccessibilityActivator {
    /// Turns the flags on when they are off. Other tools (window managers, for example) can
    /// turn AXEnhancedUserInterface off again, so callers check before every scan.
    /// Returns true when this call turned the enhanced flag on, so the app is still building its tree.
    @discardableResult
    static func activate(_ app: NSRunningApplication, enhanced: Bool) -> Bool {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        if el.bool("AXManualAccessibility") != true { el.set("AXManualAccessibility", kCFBooleanTrue) }
        guard enhanced, el.bool("AXEnhancedUserInterface") != true else { return false }
        el.set("AXEnhancedUserInterface", kCFBooleanTrue)
        Log.info("AXEnhancedUserInterface was off in \(app.localizedName ?? "?"), turned it on")
        return true
    }

    /// Wakes every running app now, so the first scan does not find an empty tree.
    static func activateAll(enhancedApps: [String]) {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            activate(app, enhanced: enhancedApps.contains(app.bundleIdentifier ?? ""))
        }
    }
}
