import AppKit
import TypeMouseCore

/// Refines a screen area without moving windows or taking focus from the target app.
final class GridMode {
    private enum Phase: String { case grid, choosingScrollArea, scroll }
    private var phase: Phase?
    var isActive: Bool { phase != nil }
    var isChoosingPoint: Bool { phase == .grid }
    var isChoosingScrollArea: Bool { phase == .choosingScrollArea }

    private var navigation: GridNavigation?
    private var scrollAreas: [(label: String, target: ScrollAreas.Target)] = []
    private var prefix = ""
    private var scrollPoint = CGPoint.zero
    private var heldDirections: [Int64: ScrollDirection] = [:]
    private var speedMultiplier = 1.0
    private var timer: Timer?
    private var lastTick = 0.0
    private var remainder = CGPoint.zero
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var screenFrames: [CGRect] = []
    private let overlay = Overlay()
    private let capture: KeyCapture
    private var config: Config

    init(capture: KeyCapture, config: Config) {
        self.capture = capture
        self.config = config
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive, NSScreen.screens.map(\.frame) != self.screenFrames else { return }
            // A removed display invalidates the old target and scroll location.
            self.exit(movePointer: false)
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.exit(movePointer: false) }
    }

    deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    func update(config: Config) {
        stopScrolling()
        self.config = config
        if !config.isModeEnabled(isChoosingPoint ? .grid : .scroll) {
            exit(movePointer: false)
            return
        }
        navigation?.preferredHand = config.gridHand
        overlay.fontSize = CGFloat(config.labelFontSize)
        if isActive { render() }
    }

    func start() {
        screenFrames = NSScreen.screens.map(\.frame)
        let screens = quartzScreens
        guard !screens.isEmpty else { return }
        navigation = GridNavigation(screens: screens, pointer: pointerLocation ?? .zero, preferredHand: config.gridHand)
        phase = .grid
        capture.setActive(true)
        Log.info("grid started on \(screens.count) displays")
        render()
    }

    func startChoosingScrollArea() {
        screenFrames = NSScreen.screens.map(\.frame)
        phase = .choosingScrollArea
        overlay.fontSize = CGFloat(config.labelFontSize)
        capture.setActive(true)
        let targets =
            NSWorkspace.shared.frontmostApplication.map {
                ScrollAreas.collect(app: $0, config: config, displays: quartzScreens)
            } ?? []
        let labels = Hints.generate(count: targets.count, alphabet: config.hintAlphabet)
        scrollAreas = Array(zip(labels, targets))
        Log.info("scroll area picker found \(targets.count) targets")
        render()
    }

    private var quartzScreens: [CGRect] {
        let primaryHeight = AX.primaryHeight
        return screenFrames.map { Geometry.axRect(fromCocoa: $0, primaryHeight: primaryHeight) }
    }

    func exit(movePointer: Bool = true) {
        guard let phase else { return }
        let point = movePointer && phase == .grid ? navigation?.point : nil
        Log.info("\(phase.rawValue) exited, move pointer: \(point != nil)")
        stopScrolling()
        self.phase = nil
        navigation = nil
        scrollAreas = []
        prefix = ""
        overlay.hide()
        capture.setActive(false)
        if let point { Actuator.moveMouse(to: point) }
    }

    func handle(_ key: KeyEvent) {
        guard isActive else { return }
        if key.special == .escape {
            exit()
            return
        }
        if phase == .scroll {
            guard !key.isRepeat,
                let direction = config.scrollKeys.direction(character: key.char, keyCode: key.keyCode)
            else { return }
            updateScrollSpeed(shift: key.shift, command: key.command, hyperHeld: key.hyperHeld)
            heldDirections[key.keyCode] = direction
            if timer == nil {
                lastTick = ProcessInfo.processInfo.systemUptime
                scroll(elapsed: 1.0 / 60)
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            return
        }
        // A held key makes one selection, regardless of keyboard repeat settings.
        guard !key.isRepeat else { return }
        if isChoosingScrollArea {
            chooseScrollArea(key)
            return
        }
        switch key.special {
        case .space:
            guard let point = navigation?.point ?? pointerLocation else { return }
            exit(movePointer: false)
            Actuator.mouseClick(at: point, restore: false)
        case .enter:
            guard config.isModeEnabled(.scroll) else { return }
            let target = navigation?.point
            guard let point = target ?? pointerLocation else { return }
            startScrolling(at: point, movePointer: target != nil)
        case .backspace:
            navigation?.back()
            render()
        case .tab:
            navigation?.nextScreens()
            render()
        default:
            guard key.char.count == 1, let character = key.char.first else { return }
            if navigation?.select(character) == true { render() }
        }
    }

    private func chooseScrollArea(_ key: KeyEvent) {
        if key.special == .enter, let point = pointerLocation {
            startScrolling(at: point, movePointer: false)
            return
        }
        if key.special == .backspace {
            if !prefix.isEmpty { prefix.removeLast() }
            render()
            return
        }
        guard !key.char.isEmpty else { return }
        let next = prefix + key.char
        if let match = scrollAreas.first(where: { $0.label == next }) {
            startScrolling(at: match.target.point, movePointer: true)
        } else if scrollAreas.contains(where: { $0.label.hasPrefix(next) }) {
            prefix = next
            render()
        } else if !scrollAreas.isEmpty {
            NSSound.beep()
        }
    }

    private func startScrolling(at point: CGPoint, movePointer: Bool) {
        scrollPoint = point
        if movePointer { Actuator.moveMouse(to: point) }
        phase = .scroll
        Log.info("scroll started, keys: \(config.scrollKeys.rawValue), speed: \(config.scrollSpeed)")
        render()
    }

    func keyUp(_ keyCode: Int64) {
        heldDirections.removeValue(forKey: keyCode)
        if heldDirections.isEmpty { stopScrolling() }
    }

    func releaseKeys() { stopScrolling() }

    private var pointerLocation: CGPoint? { CGEvent(source: nil)?.location }

    func flagsChanged(_ flags: CGEventFlags) {
        updateScrollSpeed(
            shift: flags.contains(.maskShift), command: flags.contains(.maskCommand),
            hyperHeld: flags.contains(HyperKey.hyperFlags))
    }

    private func updateScrollSpeed(shift: Bool, command: Bool, hyperHeld: Bool) {
        guard shift, !hyperHeld else {
            speedMultiplier = 1
            return
        }
        speedMultiplier = command ? 6 : 3
    }

    private func stopScrolling() {
        timer?.invalidate()
        timer = nil
        heldDirections = [:]
        remainder = .zero
        speedMultiplier = 1
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        scroll(elapsed: min(0.05, max(0, now - lastTick)))
        lastTick = now
    }

    private func scroll(elapsed: Double) {
        let vector = ScrollVector.combined(Array(heldDirections.values))
        let distance = Double(config.scrollSpeed) * speedMultiplier * elapsed
        remainder.x += vector.horizontal * distance
        remainder.y += vector.vertical * distance
        let x = Int32(remainder.x.rounded(.towardZero))
        let y = Int32(remainder.y.rounded(.towardZero))
        remainder.x -= CGFloat(x)
        remainder.y -= CGFloat(y)
        guard x != 0 || y != 0,
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: y, wheel2: x, wheel3: 0)
        else { return }
        event.location = scrollPoint
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func render() {
        if phase == .scroll {
            overlay.render(
                [
                    LabelSpec(
                        text: "", typedCount: 0,
                        rect: CGRect(x: scrollPoint.x - 5, y: scrollPoint.y - 5, width: 10, height: 10),
                        style: .highlighted)
                ],
                banner:
                    "Scroll · \(config.scrollKeys.directions) / arrow keys · Shift: 3× · Command + Shift: 6× · Esc: exit",
                bannerPoint: scrollPoint)
            return
        }
        if isChoosingScrollArea {
            let matches = scrollAreas.filter { $0.label.hasPrefix(prefix) }
            let outlines = matches.map { LabelSpec(text: "", typedCount: 0, rect: $0.target.frame, style: .region) }
            let labels = matches.map { label, target in
                let anchor = CGRect(origin: target.point, size: .zero)
                return LabelSpec(text: label, typedCount: prefix.count, rect: anchor, style: .normal)
            }
            let banner =
                labels.isEmpty
                ? "No scrollable areas reported · Enter: scroll at pointer · Esc: exit"
                : "Scroll · Type a label to choose an area · Enter: scroll at pointer · Esc: exit"
            overlay.render(outlines + labels, banner: banner, bannerPoint: matches.first?.target.point)
            return
        }
        guard let navigation else { return }
        var labels: [LabelSpec] = []
        for region in navigation.regions {
            for (index, cell) in region.cells.enumerated() {
                labels.append(LabelSpec(text: "", typedCount: 0, rect: cell, style: .outline))
                if min(cell.width, cell.height) >= 24 {
                    labels.append(
                        LabelSpec(
                            text: String(region.keys[index]), typedCount: 0,
                            rect: CGRect(x: cell.midX - 1, y: cell.midY - 1, width: 2, height: 2),
                            style: .normal, fontSize: min(30, max(12, cell.height / 5))))
                }
            }
        }
        if let center = navigation.point {
            labels.append(
                LabelSpec(
                    text: "", typedCount: 0,
                    rect: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4), style: .highlighted))
        }
        let extra = navigation.hasMoreScreens ? " · Tab: screens" : ""
        let escape = navigation.point == nil ? "Esc: exit" : "Esc: move"
        let scroll = config.isModeEnabled(.scroll) ? " · Enter: scroll" : ""
        overlay.render(
            labels,
            banner: "Grid · \(escape) · Space: click\(scroll) · Backspace: undo\(extra)",
            bannerPoint: navigation.point ?? pointerLocation)
    }
}
