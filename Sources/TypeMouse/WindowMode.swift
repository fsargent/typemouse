import AppKit
import TypeMouseCore

/// Window switcher: a list of windows, each with a stable label.
///
/// - Type a label to focus that window. One key for apps with one window, two keys otherwise.
/// - A typed key that matches no label starts a fuzzy filter on app name and title.
/// - Enter focuses the highlighted row. The default row is the previous window, so
///   hotkey + Enter toggles between the two most recent windows.
/// - ⌘W closes, ⌘M minimizes, ⌘H hides, ⌘Q quits the highlighted row's window or app.
final class WindowMode {
    struct Row {
        let info: WindowInfo?
        let launchBundleID: String?   // pinned app that is not running
        let appName: String
        let icon: NSImage?
        let title: String
        var label: String
    }

    private(set) var isActive = false
    private var rows: [Row] = []
    private var visible: [Int] = []
    private var typed = ""
    private var filter: String?
    private var highlight = 0

    private let panel = WindowPanel()
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
        filter = nil
        let start = Date()
        if let front = NSWorkspace.shared.frontmostApplication {
            WindowProvider.shared.noteFocusedWindow(of: front.processIdentifier)
        }
        rows = buildRows(WindowProvider.shared.list())
        Log.info(String(format: "windows: %d rows in %.0f ms", rows.count, Date().timeIntervalSince(start) * 1000))
        visible = Array(rows.indices)
        highlight = min(1, max(0, visible.count - 1))
        render()
    }

    /// Pressing the hotkey again while open moves down, like ⌘Tab.
    func hotkeyAgain() {
        moveHighlight(1)
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        capture.setActive(false)
        panel.hide()
    }

    func handle(_ key: KeyEvent) {
        guard isActive else { return }
        switch key.special {
        case .escape: exit(); return
        case .enter: choose(highlightedRow()); return
        case .down: moveHighlight(1); return
        case .up: moveHighlight(-1); return
        case .tab: moveHighlight(key.shift && !key.hyperHeld ? -1 : 1); return
        case .backspace: backspace(); return
        default: break
        }
        if key.command && !key.hyperHeld {
            commandKey(key.char)
            return
        }
        if key.control && key.char == "n" { moveHighlight(1); return }
        if key.control && key.char == "p" { moveHighlight(-1); return }
        if key.special == .space && filter != nil { appendFilter(" "); return }
        guard !key.char.isEmpty else { return }
        if key.char == "/" && filter == nil { filter = ""; typed = ""; refresh(); return }

        if filter != nil { appendFilter(key.char); return }

        let next = typed + key.char
        let hits = rows.indices.filter { rows[$0].label.hasPrefix(next) && !rows[$0].label.isEmpty }
        if hits.count == 1, rows[hits[0]].label == next {
            choose(hits[0])
        } else if !hits.isEmpty {
            typed = next
            refresh()
        } else {
            // Not a label. Treat everything typed so far as a search.
            filter = next
            typed = ""
            refresh()
        }
    }

    // MARK: - Rows

    private func buildRows(_ windows: [WindowInfo]) -> [Row] {
        var rows: [Row] = windows.map { w in
            Row(info: w, launchBundleID: nil, appName: w.appName, icon: w.app.icon,
                title: w.title.isEmpty ? (w.minimized ? "(minimized)" : "—") : w.title + (w.minimized ? "  (minimized)" : ""),
                label: "")
        }
        // Pinned apps with no window: a row that activates (or launches) the app.
        let present = Set(windows.map(\.appID))
        for (_, bundleID) in config.pins.sorted(by: { $0.key < $1.key }) where !present.contains(bundleID) {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            guard running != nil || url != nil else { continue }
            let name = running?.localizedName ?? url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
            let icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            if let running {
                let info = WindowInfo(app: running, window: nil, id: nil, title: "", minimized: false)
                rows.append(Row(info: info, launchBundleID: nil, appName: name, icon: icon, title: "(no windows)", label: ""))
            } else {
                rows.append(Row(info: nil, launchBundleID: bundleID, appName: name, icon: icon, title: "launch", label: ""))
            }
        }

        // Labels: group rows by app, keeping MRU order inside each app.
        var order: [String] = []
        var count: [String: Int] = [:]
        var names: [String: String] = [:]
        for r in rows {
            let id = Self.appID(r)
            if count[id] == nil { order.append(id) }
            count[id, default: 0] += 1
            names[id] = r.appName
        }
        let apps = order.map { WindowLabeler.App(id: $0, name: names[$0] ?? $0, windowCount: count[$0] ?? 0) }
        let labels = WindowLabeler.assign(apps: apps, pins: config.pins, suffixAlphabet: config.hintAlphabet)
        var used: [String: Int] = [:]
        for i in rows.indices {
            let id = Self.appID(rows[i])
            let n = used[id, default: 0]
            used[id] = n + 1
            rows[i].label = labels[id].flatMap { $0.indices.contains(n) ? $0[n] : nil } ?? ""
        }
        return rows
    }

    private static func appID(_ r: Row) -> String { r.launchBundleID ?? r.info?.appID ?? r.appName }

    private func refresh() {
        if let filter, !filter.isEmpty {
            let scored = rows.indices.compactMap { i -> (Int, Int)? in
                Fuzzy.score(filter, rows[i].appName + " " + rows[i].title).map { (i, $0) }
            }
            visible = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
            highlight = 0
        } else if !typed.isEmpty {
            visible = rows.indices.filter { rows[$0].label.hasPrefix(typed) }
            highlight = 0
        } else {
            visible = Array(rows.indices)
            highlight = min(highlight, max(0, visible.count - 1))
        }
        render()
    }

    private func render() {
        panel.show(rows: visible.map { rows[$0] }, typed: typed, filter: filter, highlight: highlight)
    }

    private func highlightedRow() -> Int? {
        visible.indices.contains(highlight) ? visible[highlight] : nil
    }

    private func moveHighlight(_ d: Int) {
        guard !visible.isEmpty else { return }
        highlight = (highlight + d + visible.count) % visible.count
        render()
    }

    private func backspace() {
        if var f = filter {
            if f.isEmpty { filter = nil } else { f.removeLast(); filter = f }
        } else if !typed.isEmpty {
            typed.removeLast()
        }
        refresh()
    }

    private func appendFilter(_ s: String) {
        filter = (filter ?? "") + s
        refresh()
    }

    // MARK: - Actions

    private func choose(_ index: Int?) {
        guard let index else { return }
        let row = rows[index]
        exit()
        if let id = row.launchBundleID {
            WindowActions.launch(bundleID: id)
        } else if let info = row.info {
            WindowActions.focus(info)
        }
    }

    private func commandKey(_ char: String) {
        guard let i = highlightedRow(), let info = rows[i].info else { return }
        switch char {
        case "w": WindowActions.close(info)
        case "m": WindowActions.minimize(info)
        case "h": info.app.hide()
        case "q": info.app.terminate()
        default: return
        }
        // Give the app a moment, then rebuild the list in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isActive else { return }
            let keep = self.highlight
            self.rows = self.buildRows(WindowProvider.shared.list())
            self.highlight = keep
            self.refresh()
        }
    }
}

/// The switcher panel. It never becomes key. Keys arrive through the event tap.
final class WindowPanel {
    private let window: NSPanel
    private let stack = NSStackView()
    private let header = NSTextField(labelWithString: "")

    static let width: CGFloat = 720
    static let rowHeight: CGFloat = 30

    init() {
        window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 100),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = Overlay.level
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
        ])
        header.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        header.textColor = .secondaryLabelColor
        window.contentView = bg
    }

    func show(rows: [WindowMode.Row], typed: String, filter: String?, highlight: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let filter {
            header.stringValue = "/ \(filter)▏"
        } else {
            header.stringValue = typed.isEmpty ? "type a label · / to search · ⏎ focus · ⌘W ⌘M ⌘H ⌘Q" : "› \(typed.uppercased())"
        }
        stack.addArrangedSubview(header)

        let maxRows = 24
        for (n, row) in rows.prefix(maxRows).enumerated() {
            stack.addArrangedSubview(rowView(row, typed: filter == nil ? typed.count : 0, selected: n == highlight))
        }
        if rows.isEmpty { stack.addArrangedSubview(NSTextField(labelWithString: "  no matches")) }

        let shown = CGFloat(min(rows.count, maxRows))
        let height = 20 + 22 + max(1, shown) * (Self.rowHeight + 2)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        window.setFrame(CGRect(x: f.midX - Self.width / 2, y: f.midY - height / 2 + f.height * 0.1,
                               width: Self.width, height: height), display: true)
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }

    private func rowView(_ row: WindowMode.Row, typed: Int, selected: Bool) -> NSView {
        let label = NSTextField(labelWithString: "")
        let s = NSMutableAttributedString(string: row.label.uppercased(), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ])
        if typed > 0 {
            s.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                           range: NSRange(location: 0, length: min(typed, row.label.count)))
        }
        label.attributedStringValue = s
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: row.label.isEmpty ? 0 : 0.9).cgColor
        label.layer?.cornerRadius = 4

        let icon = NSImageView(image: row.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown

        let app = NSTextField(labelWithString: row.appName)
        app.font = .systemFont(ofSize: 13, weight: .semibold)
        app.lineBreakMode = .byTruncatingTail

        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let h = NSStackView(views: [label, icon, app, title])
        h.orientation = .horizontal
        h.spacing = 10
        h.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        h.wantsLayer = true
        h.layer?.cornerRadius = 6
        if selected { h.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.6).cgColor }
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 38),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            app.widthAnchor.constraint(equalToConstant: 150),
            h.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            h.widthAnchor.constraint(equalToConstant: Self.width - 20),
        ])
        return h
    }
}
