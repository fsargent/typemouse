import AppKit
import TypeMouseCore
import QuartzCore

/// One label to draw.
struct LabelSpec {
    enum Style { case normal, highlighted, outline }
    struct Caption {
        let lines: [String]
        let maxWidth: CGFloat
    }

    var text: String
    var typedCount: Int
    var rect: CGRect // AX coordinates
    var style: Style
    /// Overrides the overlay's font size for this label.
    var fontSize: CGFloat? = nil
    var caption: Caption? = nil
}

/// Click-through, transparent windows (one per screen) that draw labels with Core Animation.
/// They never take focus, so the target app keeps its menus and popovers open.
final class Overlay {
    private var windows: [(screen: NSScreen, window: NSWindow)] = []
    private let windowLevel: NSWindow.Level
    var fontSize: CGFloat = 12

    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    init(windowLevel: NSWindow.Level = Overlay.level) { self.windowLevel = windowLevel }

    func render(_ labels: [LabelSpec], banner: String? = nil, bannerPoint: CGPoint? = nil) {
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
                let badge = label(spec, in: local, bounds: root.bounds, scale: screen.backingScaleFactor)
                if let caption = spec.caption {
                    let panel = bannerLayer(caption.lines, maxWidth: min(caption.maxWidth, root.bounds.width),
                                            alignment: .center, scale: screen.backingScaleFactor)
                    let gap: CGFloat = 6
                    let spaceAbove = panel.bounds.height + gap
                    badge.frame.origin.y = max(root.bounds.minY, min(badge.frame.minY, root.bounds.maxY - badge.bounds.height - spaceAbove))
                    panel.frame.origin = CGPoint(x: min(max(root.bounds.minX, badge.frame.midX - panel.bounds.width / 2),
                                                        root.bounds.maxX - panel.bounds.width),
                                                 y: badge.frame.maxY + gap)
                    root.addSublayer(panel)
                }
                root.addSublayer(badge)
            }
        }

        let bannerScreen = bannerPoint.map { point in
            Geometry.cocoaRect(fromAX: CGRect(origin: point, size: .zero), primaryHeight: primaryHeight).origin
        }
        if let banner, let (screen, window) = windows.first(where: { entry in
            bannerScreen.map { entry.screen.frame.contains($0) } ?? (entry.screen == NSScreen.main)
        }) ?? windows.first,
           let root = window.contentView?.layer {
            let panel = bannerLayer([banner], minWidth: 280, maxWidth: root.bounds.width, scale: screen.backingScaleFactor)
            panel.frame.origin = CGPoint(x: root.bounds.midX - panel.bounds.width / 2, y: root.bounds.maxY - 140)
            root.addSublayer(panel)
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
            w.level = windowLevel
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.animationBehavior = .none
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
        let pointSize = spec.fontSize ?? fontSize
        let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
        // Padding, corners, border, and shadow grow with the font. At 12 pt they match the original look.
        let k = max(1, pointSize / 12)
        let highlighted = spec.style == .highlighted
        let fg = highlighted ? NSColor.white : NSColor.black
        let s = NSMutableAttributedString(string: spec.text.uppercased(), attributes: [.font: font, .foregroundColor: fg])
        if spec.typedCount > 0 {
            s.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.35),
                           range: NSRange(location: 0, length: min(spec.typedCount, spec.text.count)))
        }
        let textSize = s.size()
        let pad = CGSize(width: 4 * k, height: 1 * k)
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
        box.cornerRadius = 3 * k
        box.borderWidth = min(0.5 * k, 3)
        box.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor
        box.shadowOpacity = 0.3
        box.shadowRadius = 1.5 * k
        box.shadowOffset = CGSize(width: 0, height: -1 * k)

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

    private func bannerLayer(_ lines: [String], minWidth: CGFloat = 0, maxWidth: CGFloat,
                             alignment: CATextLayerAlignmentMode = .left, scale: CGFloat) -> CALayer {
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        let strings = lines.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.white]) }
        let lineHeight = ceil(strings.map { $0.size().height }.max() ?? font.pointSize)
        let textWidth = ceil(strings.map { $0.size().width }.max() ?? 0)
        let horizontalPadding = min(14, maxWidth / 4)
        let width = min(maxWidth, max(minWidth, textWidth + horizontalPadding * 2))
        let height = lineHeight * CGFloat(lines.count) + 16
        let box = CALayer()
        box.frame = CGRect(x: 0, y: 0, width: width, height: height)
        box.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        box.cornerRadius = 8
        let lineWidth = width - horizontalPadding * 2
        for (index, line) in strings.enumerated() {
            let layer = CATextLayer()
            layer.string = fitBannerLine(line, width: lineWidth)
            layer.contentsScale = scale
            layer.alignmentMode = alignment
            layer.isWrapped = false
            layer.frame = CGRect(x: horizontalPadding, y: height - 8 - CGFloat(index + 1) * lineHeight,
                                 width: lineWidth, height: lineHeight)
            box.addSublayer(layer)
        }
        return box
    }

    private func fitBannerLine(_ line: NSAttributedString, width: CGFloat) -> NSAttributedString {
        guard line.size().width > width, line.length > 0 else { return line }
        let attributes = line.attributes(at: 0, effectiveRange: nil)
        let ellipsis = NSAttributedString(string: "…", attributes: attributes)
        guard ellipsis.size().width <= width else { return NSAttributedString(string: "") }

        // Measure the text that will actually draw so a narrow caption never wraps.
        let characters = Array(line.string)
        var best = ellipsis
        var low = 1
        var high = characters.count - 1
        while low <= high {
            let count = (low + high) / 2
            let candidate = NSAttributedString(string: String(characters.prefix(count)) + "…", attributes: attributes)
            if candidate.size().width <= width {
                best = candidate
                low = count + 1
            } else {
                high = count - 1
            }
        }
        return best
    }
}
