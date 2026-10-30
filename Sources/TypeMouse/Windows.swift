import AppKit
import ApplicationServices
import TypeMouseCore

struct WindowInfo {
    let app: NSRunningApplication
    let window: AXUIElement?    // nil: pinned app that is not running, or running with no windows
    let id: CGWindowID?
    let title: String
    let minimized: Bool

    var appName: String { app.localizedName ?? app.bundleIdentifier ?? "?" }
    var appID: String { app.bundleIdentifier ?? appName }
}

/// Lists windows through AX (titles without Screen Recording permission) and tracks
/// most-recently-used order.
final class WindowProvider {
    static let shared = WindowProvider()

    private var mru: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]

    func startTracking() {
        seedFromZOrder()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(app)
            self?.noteFocusedWindow(of: app.processIdentifier)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observers[app.processIdentifier] = nil
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { observe(app) }
    }

    func noteFocusedWindow(of pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        if let id = appEl.element(kAXFocusedWindowAttribute)?.windowID { touch(id) }
    }

    func touch(_ id: CGWindowID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > 500 { mru.removeLast(mru.count - 500) }
    }

    /// Windows on the current Space, plus minimized windows and windows of hidden apps.
    /// Sorted most recently used first.
    func list(excluding ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [WindowInfo] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        var perApp = [[WindowInfo]](repeating: [], count: apps.count)
        perApp.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                buf[i] = Self.windows(of: apps[i])
            }
        }
        let rank = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let z = Self.zOrder()
        func key(_ w: WindowInfo) -> (Int, Int, Int) {
            guard let id = w.id else { return (2, Int.max, Int.max) }
            return (w.minimized ? 1 : 0, rank[id] ?? Int.max, z[id] ?? Int.max)
        }
        return perApp.flatMap { $0 }.sorted { key($0) < key($1) }
    }

    private static func windows(of app: NSRunningApplication) -> [WindowInfo] {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        return appEl.elements(kAXWindowsAttribute).compactMap { w in
            let v = w.values([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, kAXSizeAttribute])
            guard (v[kAXRoleAttribute] as? String) == kAXWindowRole else { return nil }
            let sub = v[kAXSubroleAttribute] as? String
            guard sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole else { return nil }
            return WindowInfo(app: app, window: w, id: w.windowID, title: (v[kAXTitleAttribute] as? String) ?? "",
                              minimized: (v[kAXMinimizedAttribute] as? NSNumber)?.boolValue ?? false)
        }
    }

    /// Front-to-back order of on-screen windows. Window IDs need no Screen Recording permission.
    private static func zOrder() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [CGWindowID: Int] = [:]
        for (i, d) in info.enumerated() {
            if let n = d[kCGWindowNumber as String] as? CGWindowID, (d[kCGWindowLayer as String] as? Int) == 0 { out[n] = i }
        }
        return out
    }

    private func seedFromZOrder() {
        mru = Self.zOrder().sorted { $0.value < $1.value }.map(\.key)
    }

    /// Focus changes inside an app (for example ⌘` between windows) do not activate a new app,
    /// so we also listen for AX focused-window changes.
    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowProvider>.fromOpaque(refcon).takeUnretainedValue()
            if let id = element.windowID { me.touch(id) }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, me)
        AXObserverAddNotification(obs, appEl, kAXMainWindowChangedNotification as CFString, me)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }
}

/// Window actions.
enum WindowActions {
    static func focus(_ w: WindowInfo) {
        if w.app.isHidden { w.app.unhide() }
        guard let win = w.window else {
            w.app.activate()
            return
        }
        if w.minimized { win.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        if let id = w.id, SkyLight.makeFront(pid: w.app.processIdentifier, windowID: id) {
            WindowProvider.shared.touch(id)
        } else {
            w.app.activate()
        }
        win.set(kAXMainAttribute, kCFBooleanTrue)
        win.perform(kAXRaiseAction)
    }

    static func close(_ w: WindowInfo) {
        w.window?.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
    }

    static func minimize(_ w: WindowInfo) {
        w.window?.set(kAXMinimizedAttribute, kCFBooleanTrue)
    }

    static func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Private SkyLight calls that focus one specific window, the way the Dock does.
/// `NSRunningApplication.activate` alone raises the app's key window, not the window we want,
/// and macOS 14+ may ignore it entirely. Same technique as yabai (MIT) and AltTab.
enum SkyLight {
    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFront: SetFrontFn? = dlsym(handle, "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFrontFn.self) }
    private static let postEvent: PostEventFn? = dlsym(handle, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: PostEventFn.self) }

    static func makeFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFront else { return false }
        var psn = ProcessSerialNumber()
        guard clk_GetProcessForPID(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFront(&psn, windowID, userGenerated) == .success else { return false }
        makeKey(&psn, windowID)
        return true
    }

    /// Sends the "make key window" event record. Byte layout from yabai.
    private static func makeKey(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        guard let postEvent else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { raw in
            for (i, b) in raw.enumerated() { bytes[0x3c + i] = b }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(&psn, $0.baseAddress!) }
    }
}

@_silgen_name("GetProcessForPID")
private func clk_GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
