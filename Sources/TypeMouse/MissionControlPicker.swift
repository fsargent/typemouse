import AppKit
import TypeMouseCore

/// Reads the buttons that macOS draws for Mission Control. Their frames describe the
/// thumbnails, including windows that were covered on the desktop or raised by hover.
final class MissionControlPicker {
    struct Thumbnail {
        let button: AXUIElement
        let windowID: CGWindowID?
        let appID: String
        let name: String
        let frame: CGRect

        var identity: UInt32 { windowID ?? UInt32(truncatingIfNeeded: CFHash(button)) }
    }

    private static let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app", isDirectory: true)
    private let overlay = Overlay(windowLevel: .screenSaver)
    private let capture: KeyCapture
    private var config: Config
    private var timer: Timer?
    private var thumbnails: [Thumbnail] = []
    private var labels: [String] = []
    private var typed = ""
    private var launchedAt: TimeInterval = 0
    private var opensOverview = false
    private var rendered = false
    private var previousFrames: [UInt32: CGRect] = [:]
    private(set) var isActive = false
    var onPicked: ((WindowInfo) -> Void)?

    init(capture: KeyCapture, config: Config) {
        self.capture = capture
        self.config = config
    }

    func update(config: Config) { self.config = config }

    func start(openOverview: Bool, snapshot: [Thumbnail]?) {
        opensOverview = openOverview
        launchedAt = ProcessInfo.processInfo.systemUptime
        isActive = true
        capture.setActive(true)
        if snapshot == nil && !NSWorkspace.shared.open(Self.appURL) {
            exit(closeOverview: false)
            return
        }
        if let snapshot { refresh(snapshot) }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.refresh(Self.snapshot())
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func exit(closeOverview: Bool = true) {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        thumbnails = []
        labels = []
        typed = ""
        rendered = false
        previousFrames = [:]
        overlay.hide()
        capture.setActive(false)
        if closeOverview && opensOverview && Self.snapshot() != nil { NSWorkspace.shared.open(Self.appURL) }
    }

    func handle(_ key: KeyEvent) {
        if key.special == .escape { exit(); return }
        guard rendered, !key.isRepeat else { return }
        if key.special == .backspace {
            if !typed.isEmpty { typed.removeLast(); render() }
            return
        }
        guard key.char.count == 1 else { return }
        let next = typed + key.char
        let hits = labels.indices.filter { labels[$0].hasPrefix(next) }
        guard !hits.isEmpty else { NSSound.beep(); return }
        if hits.count == 1, labels[hits[0]] == next {
            let thumbnail = thumbnails[hits[0]]
            if thumbnail.button.perform(kAXPressAction) == .success {
                exit(closeOverview: false)
                if config.clickAfterPicker { notifyWhenFocused(thumbnail) }
            } else {
                NSSound.beep()
                refresh(Self.snapshot())
            }
            return
        }
        typed = next
        render()
    }

    private func refresh(_ snapshot: [Thumbnail]?) {
        guard isActive else { return }
        let age = ProcessInfo.processInfo.systemUptime - launchedAt
        guard let snapshot, !snapshot.isEmpty else {
            if (rendered && snapshot == nil) || age > 1.5 { exit(closeOverview: !rendered) }
            return
        }

        let frames = Dictionary(snapshot.map { ($0.identity, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let sameFrames = frames == previousFrames
        previousFrames = frames
        // Wait for the first two matching samples so labels do not follow the opening animation.
        guard rendered || sameFrames || age > 0.8 else { return }
        let sorted = snapshot.sorted { $0.identity < $1.identity }
        if thumbnails.map(\.identity) != sorted.map(\.identity) {
            Log.info("mission control picker: \(sorted.count) thumbnails")
            let items = sorted.map { PickerLabels.Item(windowID: $0.identity, appID: $0.appID, appName: $0.name) }
            let assigned = PickerLabels.assign(items, pins: config.pins, windowKeys: config.hintAlphabet)
            labels = sorted.map { assigned[$0.identity] ?? "" }
            typed = ""
        }
        thumbnails = sorted
        if !rendered || !sameFrames { render() }
        rendered = true
    }

    private func render() {
        let hints = zip(thumbnails, labels).compactMap { thumbnail, label -> LabelSpec? in
            guard !label.isEmpty, label.hasPrefix(typed) else { return nil }
            let point = CGPoint(x: thumbnail.frame.midX, y: thumbnail.frame.midY)
            return LabelSpec(text: label, typedCount: typed.count,
                             rect: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), style: .normal,
                             fontSize: WindowPicker.fontSize(for: label, in: thumbnail.frame))
        }
        overlay.render(hints)
    }

    private func notifyWhenFocused(_ target: Thumbnail, attempts: Int = 12) {
        guard attempts > 0, !isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self, !self.isActive else { return }
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == target.appID,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               let window = AXUIElementCreateApplication(app.processIdentifier).element(kAXFocusedWindowAttribute),
               target.windowID == nil || target.windowID == window.windowID,
               Self.snapshot() == nil {
                self.onPicked?(WindowInfo(app: app, window: window, id: window.windowID, title: "", minimized: false))
            } else {
                self.notifyWhenFocused(target, attempts: attempts - 1)
            }
        }
    }

    /// WindowManager hosts Mission Control on newer macOS versions. Older versions use Dock.
    static func snapshot() -> [Thumbnail]? {
        for host in ["com.apple.WindowManager", "com.apple.dock"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: host).first else { continue }
            let children = AXUIElementCreateApplication(app.processIdentifier).elements(kAXChildrenAttribute)
            let root = children.first { $0.string("AXIdentifier") == "mc" }
            let displays = (root?.elements(kAXChildrenAttribute) ?? children).filter { $0.string("AXIdentifier") == "mc.display" }
            guard !displays.isEmpty else { continue }
            let windows = host == "com.apple.dock"
                ? CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                : []
            return displays.flatMap { display in
                let children = display.elements(kAXChildrenAttribute)
                let group = children.first { $0.string("AXIdentifier") == "mc.windows" }
                return (group?.elements(kAXChildrenAttribute) ?? children).compactMap { button -> Thumbnail? in
                    let values = button.values([kAXRoleAttribute, "AXIdentifier", "wid", kAXTitleAttribute,
                                                kAXPositionAttribute, kAXSizeAttribute])
                    guard values[kAXRoleAttribute] as? String == kAXButtonRole,
                          let frame = AX.frame(position: values[kAXPositionAttribute], size: values[kAXSizeAttribute]),
                          frame.width > 0, frame.height > 0 else { return nil }
                    let identifier = values["AXIdentifier"] as? String ?? ""
                    guard !identifier.hasPrefix("mc.") else { return nil }
                    let windowID = (values["wid"] as? NSNumber)?.uint32Value
                    let owner = windowID.flatMap { id in
                        windows.first { $0[kCGWindowNumber as String] as? CGWindowID == id }?[kCGWindowOwnerPID as String] as? pid_t
                    }.flatMap { NSRunningApplication(processIdentifier: $0) }
                    let bundle = identifier.range(of: ".space.", options: .backwards).map { String(identifier[..<$0.lowerBound]) }
                    let appID = bundle ?? owner?.bundleIdentifier ?? identifier
                    let name = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first?.localizedName
                        ?? owner?.localizedName ?? (values[kAXTitleAttribute] as? String) ?? "Window"
                    return Thumbnail(button: button, windowID: windowID, appID: appID.isEmpty ? name : appID, name: name, frame: frame)
                }
            }
        }
        return nil
    }
}
