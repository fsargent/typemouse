import AppKit
import TypeMouseCore

/// Window picker: one label on each visible window of the current Space. Press it to focus that window.
/// No list, no zoom, no animation. The windows stay where they are.
final class WindowPicker {
    struct Entry {
        let info: WindowInfo
        let point: CGPoint // AX coordinates
        let area: CGRect   // the window's largest visible rectangle, AX coordinates
    }

    private(set) var isActive = false
    private var entries: [Entry] = []
    private var labels: [String] = []
    private var typed = ""

    private let overlay = Overlay()
    private let capture: KeyCapture
    private var config: Config

    init(capture: KeyCapture, config: Config) {
        self.capture = capture
        self.config = config
    }

    func update(config: Config) { self.config = config }

    func start() {
        capture.setActive(true)
        isActive = true
        typed = ""
        let start = Date()
        entries = Self.visibleWindows()
        Log.info(String(format: "picker: %d visible windows in %.0f ms", entries.count, Date().timeIntervalSince(start) * 1000))
        guard !entries.isEmpty else { exit(); return }
        labels = Hints.generate(count: entries.count, alphabet: config.hintAlphabet)
        render()
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        capture.setActive(false)
        overlay.hide()
        entries = []
    }

    func handle(_ key: KeyEvent) {
        guard isActive else { return }
        switch key.special {
        case .escape: exit(); return
        case .backspace:
            if !typed.isEmpty { typed.removeLast(); render() }
            return
        default: break
        }
        guard key.char.count == 1 else { return }
        let next = typed + key.char
        let hits = labels.indices.filter { labels[$0].hasPrefix(next) }
        guard !hits.isEmpty else { NSSound.beep(); return }
        if hits.count == 1, labels[hits[0]] == next {
            let info = entries[hits[0]].info
            exit()
            WindowActions.focus(info)
            return
        }
        typed = next
        render()
    }

    private func render() {
        let specs = labels.indices.compactMap { i -> LabelSpec? in
            guard labels[i].hasPrefix(typed) else { return nil }
            let p = entries[i].point
            return LabelSpec(text: labels[i], typedCount: typed.count,
                             rect: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2), style: .normal,
                             fontSize: Self.fontSize(for: labels[i], in: entries[i].area))
        }
        overlay.render(specs)
    }

    /// Sizes the label box to about half of the window's visible area.
    /// A bold monospaced glyph is about 0.6 em wide, and the box is about 1.2 em tall.
    static func fontSize(for label: String, in area: CGRect) -> CGFloat {
        let byHeight = area.height * 0.5 / 1.2
        let byWidth = area.width * 0.5 / (0.6 * CGFloat(max(1, label.count)) + 0.7)
        return min(max(min(byHeight, byWidth), 18), 600)
    }

    /// On-screen windows of the current Space, front to back, with the part that shows.
    static func visibleWindows() -> [Entry] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }

        var windows: [(id: CGWindowID, pid: pid_t, frame: CGRect)] = []
        for d in info {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 80, frame.height >= 60 else { continue }
            windows.append((id, pid, frame)) // CG window bounds use the same top-left origin as AX
        }

        let placements = Visibility.placements(windows.map { .init(id: $0.id, frame: $0.frame) })
        // Focusing needs the AX window, so match by window ID.
        let axWindows = Dictionary(WindowProvider.shared.list(only: Set(windows.map(\.pid))).compactMap { w in w.id.map { ($0, w) } },
                                   uniquingKeysWith: { a, _ in a })

        var entries: [Entry] = []
        for w in windows {
            guard let placement = placements[w.id] else { continue }
            if let info = axWindows[w.id] {
                entries.append(Entry(info: info, point: placement.point, area: placement.area))
            } else if let app = NSRunningApplication(processIdentifier: w.pid), app.activationPolicy == .regular {
                // No AX match (some apps hide windows from AX). Activating the app is the best we can do.
                entries.append(Entry(info: WindowInfo(app: app, window: nil, id: w.id, title: "", minimized: false),
                                     point: placement.point, area: placement.area))
            }
        }
        // Top to bottom, then left to right, so labels read in screen order.
        return entries.sorted {
            Geometry.readingOrder(CGRect(origin: $0.point, size: .zero), CGRect(origin: $1.point, size: .zero), rowHeight: 200)
        }
    }
}
