import AppKit
import TypeMouseCore

final class WindowTiler {
    private struct Placement {
        let window: AXUIElement
        let command: WindowCommand
        let bounds: CGRect
        let step: Int
        let frame: CGRect
    }

    private var lastPlacement: Placement?
    private var revision = 0

    func apply(_ command: WindowCommand, enhancedApps: [String]) {
        revision &+= 1
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let keepEnhanced = enhancedApps.contains(app.bundleIdentifier ?? "")
        guard let window = application.element(kAXFocusedWindowAttribute),
              window.bool("AXFullScreen") != true,
              let frame = window.frame else { return }

        let primaryHeight = AX.primaryHeight
        let screens = NSScreen.screens.sorted { a, b in
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return a.frame.maxY > b.frame.maxY
        }
        let displays = screens.map { Geometry.axRect(fromCocoa: $0.frame, primaryHeight: primaryHeight) }
        guard let index = WindowLayout.displayIndex(for: frame, displays: displays) else { return }
        let bounds = Geometry.axRect(fromCocoa: screens[index].visibleFrame, primaryHeight: primaryHeight)

        if command == .nextDisplay {
            guard screens.count > 1 else { return }
            let next = screens[(index + 1) % screens.count]
            let destination = Geometry.axRect(fromCocoa: next.visibleFrame, primaryHeight: primaryHeight)
            lastPlacement = nil
            let target = WindowLayout.move(frame, from: bounds, to: destination)
            if let applied = place(window, in: application, at: target, original: frame,
                                   anchorIn: destination, changesDisplay: true),
               !Geometry.nearlyEqual(applied, target) {
                let requestedRevision = revision
                // Some apps update their resize limits after the display move settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self, self.revision == requestedRevision,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                          let current = window.frame, Geometry.nearlyEqual(current, applied) else { return }
                    _ = self.place(window, in: application, at: target, original: current, anchorIn: destination)
                }
            }
            return
        }

        let frames = command.frames(in: bounds)
        let step: Int
        if let last = lastPlacement, command == last.command, CFEqual(window, last.window),
           bounds == last.bounds, Geometry.nearlyEqual(frame, last.frame) {
            step = (last.step + 1) % frames.count
        } else {
            step = 0
        }
        lastPlacement = nil
        let target = frames[step]
        guard let applied = place(window, in: application, at: target, original: frame,
                                  anchorIn: bounds, keepEnhanced: keepEnhanced)
                ?? (keepEnhanced ? window.frame : nil) else { return }
        lastPlacement = Placement(window: window, command: command, bounds: bounds, step: step, frame: applied)
        if keepEnhanced, applied.size != target.size {
            let requestedRevision = revision
            // A browser can drop the resize while its move animation is still running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.revision == requestedRevision,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let current = window.frame, Geometry.nearlyEqual(current, applied) else { return }
                guard self.resize(window, to: target.size),
                      let settled = self.finishPlacement(window, at: target, in: bounds,
                                                         retrySize: false, repeatMove: false) else { return }
                self.lastPlacement = Placement(window: window, command: command, bounds: bounds, step: step, frame: settled)
            }
        }
    }

    private func place(_ window: AXUIElement, in application: AXUIElement, at target: CGRect, original: CGRect, anchorIn bounds: CGRect,
                       changesDisplay: Bool = false, keepEnhanced: Bool = false) -> CGRect? {
        // Enhanced accessibility can animate each frame write. Pause it while setting the frame.
        // Chromium can apply the change even when the AX setter reports an error.
        let enhanced = "AXEnhancedUserInterface"
        // Chromium delays page accessibility after this attribute is re-enabled.
        let restoreEnhanced = !keepEnhanced && application.bool(enhanced) == true
        if restoreEnhanced { application.set(enhanced, kCFBooleanFalse) }
        defer { if restoreEnhanced { application.set(enhanced, kCFBooleanTrue) } }

        var canMove = DarwinBoolean(false)
        var canResize = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &canMove) == .success,
              canMove.boolValue else { return nil }
        let resizable = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &canResize) == .success
            && canResize.boolValue
        let sizeChanges = original.size != target.size
        guard !sizeChanges || resizable || changesDisplay else { return nil }

        // Shrink before moving across displays so a large window fits the destination on arrival.
        let interimSize = CGSize(width: min(original.width, target.width), height: min(original.height, target.height))
        if changesDisplay, resizable, interimSize != original.size { _ = resize(window, to: interimSize) }
        guard move(window, to: target.origin) else {
            if changesDisplay, resizable, interimSize != original.size { _ = resize(window, to: original.size) }
            return nil
        }
        if resizable, sizeChanges, !resize(window, to: target.size), !changesDisplay {
            _ = move(window, to: original.origin)
            return nil
        }

        return finishPlacement(window, at: target, in: bounds, retrySize: changesDisplay && resizable,
                               repeatMove: !keepEnhanced)
    }

    private func finishPlacement(_ window: AXUIElement, at target: CGRect, in bounds: CGRect,
                                 retrySize: Bool, repeatMove: Bool) -> CGRect? {
        if repeatMove { _ = move(window, to: target.origin) }
        guard var resized = window.frame else { return nil }
        // AppKit can clip a resize until the window has entered the destination display.
        if retrySize, resized.size != target.size, resize(window, to: target.size) {
            resized = window.frame ?? resized
        }

        // Apps can enforce a minimum size or adjust position during a resize.
        var point = target.origin
        if target.maxX == bounds.maxX && target.minX != bounds.minX { point.x = max(bounds.minX, bounds.maxX - resized.width) }
        if target.maxY == bounds.maxY && target.minY != bounds.minY { point.y = max(bounds.minY, bounds.maxY - resized.height) }
        if abs(target.midX - bounds.midX) <= 1 && target.width < bounds.width { point.x = bounds.midX - resized.width / 2 }
        if point != resized.origin { _ = move(window, to: point) }
        return window.frame
    }

    private func move(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return window.set(kAXPositionAttribute, value) == .success
    }

    private func resize(_ window: AXUIElement, to size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return window.set(kAXSizeAttribute, value) == .success
    }
}
