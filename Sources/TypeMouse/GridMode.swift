import AppKit
import TypeMouseCore

/// Refines a screen area without moving windows or taking focus from the target app.
final class GridMode {
    private(set) var isActive = false
    private var isScrolling = false
    private var navigation: GridNavigation?
    private var scrollPoint = CGPoint.zero
    private var heldDirections: [Int64: ScrollDirection] = [:]
    private var fast = false
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
        if isActive { render() }
    }

    func start() {
        screenFrames = NSScreen.screens.map(\.frame)
        let screens = NSScreen.screens.map { Geometry.axRect(fromCocoa: $0.frame, primaryHeight: AX.primaryHeight) }
        guard !screens.isEmpty else { return }
        navigation = GridNavigation(screens: screens, pointer: CGEvent(source: nil)?.location ?? .zero)
        isActive = true
        isScrolling = false
        capture.setActive(true)
        Log.info("grid started on \(screens.count) displays")
        render()
    }

    func exit(movePointer: Bool = true) {
        guard isActive else { return }
        let point = navigation?.point
        Log.info("\(isScrolling ? "scroll" : "grid") exited, move pointer: \(movePointer)")
        stopScrolling()
        isActive = false
        isScrolling = false
        navigation = nil
        overlay.hide()
        capture.setActive(false)
        if movePointer, let point { Actuator.moveMouse(to: point) }
    }

    func handle(_ key: KeyEvent) {
        guard isActive else { return }
        if key.special == .escape { exit(); return }
        if isScrolling {
            guard !key.isRepeat,
                  let direction = config.scrollKeys.direction(character: key.char, keyCode: key.keyCode) else { return }
            fast = key.shift && !key.hyperHeld
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
        // A held key selects one cell, regardless of keyboard repeat settings.
        guard !key.isRepeat else { return }
        switch key.special {
        case .space:
            guard let point = navigation?.point else { return }
            exit(movePointer: false)
            Actuator.mouseClick(at: point, restore: false)
        case .enter:
            guard let point = navigation?.point else { return }
            scrollPoint = point
            Actuator.moveMouse(to: point)
            isScrolling = true
            Log.info("scroll started, keys: \(config.scrollKeys.rawValue), speed: \(config.scrollSpeed)")
            render()
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

    func keyUp(_ keyCode: Int64) {
        heldDirections.removeValue(forKey: keyCode)
        if heldDirections.isEmpty { stopScrolling() }
    }

    func releaseKeys() { stopScrolling() }

    func flagsChanged(_ flags: CGEventFlags) {
        let hyper: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
        fast = flags.contains(.maskShift) && !flags.contains(hyper)
    }

    private func stopScrolling() {
        timer?.invalidate()
        timer = nil
        heldDirections = [:]
        remainder = .zero
        fast = false
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        scroll(elapsed: min(0.05, max(0, now - lastTick)))
        lastTick = now
    }

    private func scroll(elapsed: Double) {
        let vector = ScrollVector.combined(Array(heldDirections.values))
        let distance = Double(config.scrollSpeed) * (fast ? 3 : 1) * elapsed
        remainder.x += vector.horizontal * distance
        remainder.y += vector.vertical * distance
        let x = Int32(remainder.x.rounded(.towardZero))
        let y = Int32(remainder.y.rounded(.towardZero))
        remainder.x -= CGFloat(x)
        remainder.y -= CGFloat(y)
        guard x != 0 || y != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: y, wheel2: x, wheel3: 0) else { return }
        event.location = scrollPoint
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func render() {
        guard let navigation else { return }
        if isScrolling {
            overlay.render([LabelSpec(text: "", typedCount: 0,
                                      rect: CGRect(x: scrollPoint.x - 5, y: scrollPoint.y - 5, width: 10, height: 10),
                                      style: .highlighted)],
                           banner: "Scroll · \(config.scrollKeys.directions) / arrow keys · Shift: faster · Esc: exit",
                           bannerPoint: scrollPoint)
            return
        }
        var labels: [LabelSpec] = []
        for region in navigation.regions {
            for (index, cell) in region.cells.enumerated() {
                labels.append(LabelSpec(text: "", typedCount: 0, rect: cell, style: .outline))
                if min(cell.width, cell.height) >= 24 {
                    labels.append(LabelSpec(text: String(region.keys[index]), typedCount: 0,
                                            rect: CGRect(x: cell.midX - 1, y: cell.midY - 1, width: 2, height: 2),
                                            style: .normal, fontSize: min(30, max(12, cell.height / 5))))
                }
            }
            let center = CGPoint(x: region.frame.midX, y: region.frame.midY)
            labels.append(LabelSpec(text: "", typedCount: 0,
                                    rect: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4), style: .highlighted))
        }
        let extra = navigation.hasMoreScreens ? " · Tab: screens" : ""
        overlay.render(labels,
                       banner: "Grid \(navigation.depth) · Esc: move · Space: click · Enter: scroll · Backspace: undo\(extra)",
                       bannerPoint: navigation.point)
    }
}
