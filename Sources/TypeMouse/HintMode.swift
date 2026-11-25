import AppKit
import TypeMouseCore

/// Click mode (type a label) and search mode (type text, Enter to click).
final class HintMode {
    enum Phase { case labels, search }

    private(set) var isActive = false
    private(set) var isLoading = false
    private var scanID = UUID()
    private var interactedWithLabels = false
    private var phase = Phase.labels
    private var app: NSRunningApplication?
    private var targets: [Target] = []
    private var labels: [String] = []
    private var typed = ""
    private var query = ""
    private var matches: [Int] = []
    private var highlight = 0
    private var textResolved = false
    /// Space turns this on: every click chains until Space again or the mode closes.
    private var chainMode = false

    private let overlay = Overlay()
    private let capture: KeyCapture
    private var config: Config

    init(capture: KeyCapture, config: Config) {
        self.capture = capture
        self.config = config
    }

    func update(config: Config) {
        self.config = config
        if !config.isModeEnabled(phase == .search ? .search : .click) { exit("mode disabled") }
    }

    /// - Parameter keepChain: true for the rescan after a chain click, so chain mode stays on.
    func start(search: Bool, keepChain: Bool = false) {
        guard config.isModeEnabled(search ? .search : .click) else { return }
        if !keepChain { chainMode = config.chainModeByDefault }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Escape can dismiss the overlay while the browser supplies its controls.
        capture.setActive(true)
        isActive = true
        scanID = UUID()
        let id = scanID
        interactedWithLabels = false
        phase = search ? .search : .labels
        self.app = app
        targets = []
        labels = []
        typed = ""
        query = ""
        highlight = 0
        textResolved = false

        let config = config
        let enhanced = config.enhancedUserInterfaceApps.contains(app.bundleIdentifier ?? "")
        if enhanced && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            isLoading = true
            let desktop = AX.desktopBounds()
            let fallbackDeadline = DispatchTime.now() + 0.85
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.scanID == id, self.isLoading else { return }
                self.overlay.render([], banner: "Loading controls in \(app.localizedName ?? "browser")…")
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = ElementProvider().collect(app: app, config: config, desktop: desktop) { fallback in
                    DispatchQueue.main.asyncAfter(deadline: fallbackDeadline) { [weak self] in
                        guard let self, self.scanID == id, self.isLoading, !fallback.targets.isEmpty else { return }
                        Log.info("Showing browser controls while the page tree loads")
                        self.finishScan(fallback, app: app, id: id)
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanID == id, !self.interactedWithLabels else { return }
                    if self.isLoading || result.menuOpen || result.targets.contains(where: \.inWebArea) {
                        self.finishScan(result, app: app, id: id)
                    }
                }
            }
        } else {
            finishScan(ElementProvider().collect(app: app, config: config), app: app, id: id)
        }
    }

    private func finishScan(_ result: ElementProvider.Result, app: NSRunningApplication, id: UUID) {
        guard isActive, scanID == id else { return }
        guard app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            exit("app changed during scan")
            return
        }
        isLoading = false
        Log.info(String(format: "scan %@: %d targets (%d weak duplicates removed), %d visited, %.0f ms%@", app.localizedName ?? "?",
                        result.targets.count, result.weakRemoved, result.visited, result.duration * 1000, result.menuOpen ? " (menu)" : ""))
        targets = result.targets
        guard !targets.isEmpty else {
            overlay.render([], banner: "No clickable elements in \(app.localizedName ?? "this app")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.scanID == id, self?.targets.isEmpty == true { self?.exit("no targets") }
            }
            return
        }
        labels = Hints.spread(Hints.generate(count: targets.count, alphabet: config.hintAlphabet), alphabet: config.hintAlphabet)
        overlay.fontSize = CGFloat(config.labelFontSize)
        if phase == .search { enterSearch() } else { render() }
    }

    func exit(_ reason: String = "done") {
        guard isActive else { return }
        Log.info("click mode closed: \(reason)")
        isActive = false
        isLoading = false
        capture.setActive(false)
        overlay.hide()
        targets = []
        labels = []
    }

    /// Exit when the user switches apps some other way.
    func appDidActivate(_ other: NSRunningApplication) {
        if isActive, other.processIdentifier != app?.processIdentifier { exit("\(other.localizedName ?? "?") became active") }
    }

    func handle(_ key: KeyEvent) {
        guard isActive else { return }
        if key.special == .escape { exit("escape"); return }
        guard !targets.isEmpty else { return }
        interactedWithLabels = true
        switch phase {
        case .labels: handleLabels(key)
        case .search: handleSearch(key)
        }
    }

    // MARK: - Labels

    private func handleLabels(_ key: KeyEvent) {
        switch key.special {
        case .backspace:
            if !typed.isEmpty { typed.removeLast(); render() }
            return
        case .enter:
            let hits = labels.indices.filter { labels[$0].hasPrefix(typed) }
            if hits.count == 1 { fire(hits[0], ClickKind(key), chain: ClickKind.isChain(key) || chainMode) }
            return
        case .tab:
            enterSearch()
            return
        case .space:
            chainMode.toggle()
            render()
            return
        case .up where chainMode:
            changeChainDelay(by: 50)
            return
        case .down where chainMode:
            changeChainDelay(by: -50)
            return
        default: break
        }
        if key.char == "/" { enterSearch(); return }
        guard key.char.count == 1, config.hintAlphabet.contains(Character(key.char)) else { return }

        let next = typed + key.char
        let hits = labels.indices.filter { labels[$0].hasPrefix(next) }
        guard !hits.isEmpty else { NSSound.beep(); return }
        if hits.count == 1, labels[hits[0]] == next {
            fire(hits[0], ClickKind(key), chain: ClickKind.isChain(key) || chainMode)
            return
        }
        typed = next
        render()
    }

    /// Up and Down in chain mode. The new delay is saved, so it also shows in Settings.
    private func changeChainDelay(by delta: Int) {
        config.chainDelayMs = min(max(config.chainDelayMs + delta, 0), 5000)
        ConfigStore.save(config)
        render()
    }

    private func render() {
        let specs = labels.indices.compactMap { i -> LabelSpec? in
            guard labels[i].hasPrefix(typed) else { return nil }
            return LabelSpec(text: labels[i], typedCount: typed.count, rect: targets[i].frame, style: .normal)
        }
        overlay.render(specs, banner: chainMode ? "Chain mode · \(config.chainDelayMs) ms (↑↓) · Space to stop" : nil)
    }

    // MARK: - Search

    private func enterSearch() {
        guard config.isModeEnabled(.search) else { return }
        phase = .search
        if !textResolved {
            ElementProvider.resolveText(&targets)
            textResolved = true
        }
        query = ""
        updateMatches()
    }

    private func handleSearch(_ key: KeyEvent) {
        switch key.special {
        case .enter:
            if matches.indices.contains(highlight) { fire(matches[highlight], ClickKind(key), chain: ClickKind.isChain(key) || chainMode) }
            return
        case .backspace:
            if query.isEmpty { phase = .labels; typed = ""; render(); return }
            query.removeLast()
            updateMatches()
            return
        case .tab:
            moveHighlight(key.shift ? -1 : 1)
            return
        case .down:
            moveHighlight(1)
            return
        case .up:
            moveHighlight(-1)
            return
        default: break
        }
        if key.control && key.char == "n" { moveHighlight(1); return }
        if key.control && key.char == "p" { moveHighlight(-1); return }
        if key.command || key.control { return }
        guard !key.char.isEmpty || key.special == .space else { return }
        query += key.special == .space ? " " : key.char
        updateMatches()
    }

    private func updateMatches() {
        if query.isEmpty {
            matches = []
        } else {
            let scored = targets.indices.compactMap { i -> (Int, Int)? in
                Fuzzy.score(query, targets[i].text).map { (i, $0) }
            }
            // Best score first. Reading order breaks ties.
            matches = scored.sorted { a, b in
                a.1 != b.1 ? a.1 > b.1 : Geometry.readingOrder(targets[a.0].frame, targets[b.0].frame)
            }.map(\.0)
        }
        highlight = 0
        renderSearch()
    }

    private func moveHighlight(_ delta: Int) {
        guard !matches.isEmpty else { return }
        highlight = (highlight + delta + matches.count) % matches.count
        renderSearch()
    }

    private func renderSearch() {
        let specs = matches.prefix(200).enumerated().map { n, i in
            LabelSpec(text: "", typedCount: 0, rect: targets[i].frame, style: n == highlight ? .highlighted : .outline)
        }
        let count = query.isEmpty ? "" : "  (\(matches.count))"
        overlay.render(specs, banner: "/ \(query)▏\(count)")
    }

    // MARK: - Action

    private func fire(_ index: Int, _ kind: ClickKind, chain: Bool = false) {
        let target = targets[index]
        let strategy = config.clickStrategy[app?.bundleIdentifier ?? ""] ?? .auto
        let restore = config.restoreMousePosition
        let delay = Double(config.chainDelayMs) / 1000
        if chain {
            let id = scanID
            // Stay in click mode. Empty targets make key presses wait (Esc still exits) until the new scan.
            overlay.hide()
            targets = []
            labels = []
            DispatchQueue.main.async { [weak self] in
                Actuator.perform(kind, on: target, strategy: strategy, restoreMouse: restore)
                // Give the app a moment to react to the click, then label what is on screen now.
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.isActive, self.scanID == id else { return }
                    self.start(search: false, keepChain: true)
                }
            }
            return
        }
        exit()
        // Let the overlay leave the screen before we post events.
        DispatchQueue.main.async {
            Actuator.perform(kind, on: target, strategy: strategy, restoreMouse: restore)
        }
    }
}
