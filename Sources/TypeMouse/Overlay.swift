import AppKit
import TypeMouseCore
import QuartzCore

/// One label to draw.
struct LabelSpec {
    enum Style { case normal, highlighted, outline }
    var text: String
    var typedCount: Int
    var rect: CGRect // AX coordinates
    var style: Style
}

/// Click-through, transparent windows (one per screen) that draw labels with Core Animation.
/// They never take focus, so the target app keeps its menus and popovers open.
final class Overlay {
    private var windows: [(screen: NSScreen, window: NSWindow)] = []
    var fontSize: CGFloat = 12

    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    func render(_ labels: [LabelSpec], banner: String? = nil) {
        syncWindows()
        let primaryHeight = AX.primaryHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, w) in windows { w.contentView?.layer?.sublayers = nil }

        for spec in labels {
            let cocoa = Geometry.cocoaRect(fromAX: spec.rect, primaryHeight: primaryHeight)
            let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
            guard let (screen, window) = windows.first(where: { $0.screen.frame.contains(center) }) ?? windows.first,
                  let root = window.contentView?.layer else { continue }
            let local = cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            if spec.style == .outline || spec.style == .highlighted {
                root.addSublayer(outline(local, strong: spec.style == .highlighted))
            }
            if !spec.text.isEmpty {
                root.addSublayer(label(spec, in: local, bounds: root.bounds, scale: screen.backingScaleFactor))
            }
        }

        if let banner, let (screen, window) = windows.first(where: { $0.screen == NSScreen.main }) ?? windows.first,
           let root = window.contentView?.layer {
            root.addSublayer(bannerLayer(banner, bounds: root.bounds, scale: screen.backingScaleFactor))
        }
        CATransaction.commit()
        for (_, w) in windows { w.orderFrontRegardless() }
    }

    func hide() {
        for (_, w) in windows {
            w.contentView?.layer?.sublayers = nil
            w.orderOut(nil)
        }
    }

    // MARK: - Windows

    private func syncWindows() {
        let screens = NSScreen.screens
        if windows.count == screens.count, zip(windows, screens).allSatisfy({ $0.screen.frame == $1.frame }) { return }
        windows.forEach { $0.window.orderOut(nil) }
        windows = screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = Self.level
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            return (screen, w)
        }
    }

    // MARK: - Layers

    private func label(_ spec: LabelSpec, in rect: CGRect, bounds: CGRect, scale: CGFloat) -> CALayer {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let highlighted = spec.style == .highlighted
        let fg = highlighted ? NSColor.white : NSColor.black
        let s = NSMutableAttributedString(string: spec.text.uppercased(), attributes: [.font: font, .foregroundColor: fg])
        if spec.typedCount > 0 {
            s.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.35),
                           range: NSRange(location: 0, length: min(spec.typedCount, spec.text.count)))
        }
        let textSize = s.size()
        let pad = CGSize(width: 4, height: 1)
        let size = CGSize(width: ceil(textSize.width) + pad.width * 2, height: ceil(textSize.height) + pad.height * 2)

        // Small targets: centered. Wide targets: at the left edge, so labels do not land on text.
        var origin = rect.width < size.width * 3
            ? CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            : CGPoint(x: rect.minX + 2, y: rect.midY - size.height / 2)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)

        let box = CALayer()
        box.frame = CGRect(origin: origin, size: size)
        box.backgroundColor = (highlighted ? NSColor.systemBlue : NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 1)).cgColor
        box.cornerRadius = 3
        box.borderWidth = 0.5
        box.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor
        box.shadowOpacity = 0.3
        box.shadowRadius = 1.5
        box.shadowOffset = CGSize(width: 0, height: -1)

        let text = CATextLayer()
        text.string = s
        text.contentsScale = scale
        text.frame = CGRect(x: pad.width, y: pad.height - 0.5, width: ceil(textSize.width), height: ceil(textSize.height))
        box.addSublayer(text)
        return box
    }

    private func outline(_ rect: CGRect, strong: Bool) -> CALayer {
        let l = CALayer()
        l.frame = rect.insetBy(dx: -2, dy: -2)
        l.borderColor = NSColor.systemBlue.withAlphaComponent(strong ? 0.95 : 0.45).cgColor
        l.borderWidth = strong ? 2.5 : 1
        l.cornerRadius = 4
        if strong { l.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor }
        return l
    }

    private func bannerLayer(_ text: String, bounds: CGRect, scale: CGFloat) -> CALayer {
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = s.size()
        let box = CALayer()
        let w = max(280, ceil(size.width) + 28)
        box.frame = CGRect(x: bounds.midX - w / 2, y: bounds.maxY - 140, width: w, height: ceil(size.height) + 16)
        box.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        box.cornerRadius = 8
        let t = CATextLayer()
        t.string = s
        t.contentsScale = scale
        t.frame = CGRect(x: 14, y: 8, width: w - 28, height: ceil(size.height))
        box.addSublayer(t)
        return box
    }
}
