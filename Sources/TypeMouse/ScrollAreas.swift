import AppKit
import TypeMouseCore

/// Scrollable viewports in the focused window, in Quartz screen coordinates.
enum ScrollAreas {
    struct Target {
        let frame: CGRect
        let point: CGPoint
    }

    private struct Node {
        let element: AXUIElement
        let clip: CGRect
        var inWebArea = false
        var parentViewport: CGRect? = nil
    }

    private struct Region {
        let frame: CGRect
        var hasOverflow: Bool
    }

    static func collect(app: NSRunningApplication, config: Config, displays: [CGRect]) -> [Target] {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        AccessibilityActivator.activate(app, enhanced: config.enhancedUserInterfaceApps.contains(app.bundleIdentifier ?? ""))
        guard let window = AXUIElementCreateApplication(app.processIdentifier).element(kAXFocusedWindowAttribute),
              let windowFrame = window.frame else { return [] }

        let attributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
                          kAXVerticalScrollBarAttribute, kAXHorizontalScrollBarAttribute, "AXHidden"]
        var queue = [Node(element: window, clip: windowFrame)]
        var visited: Set<AXUIElement> = []
        var regions: [Region] = []
        var index = 0
        let limit = 2_000
        let webContainers = Set(["AXGroup", "AXList", "AXOutline", "AXTable", "AXWebArea"])

        func addFrame(_ frame: CGRect, hasOverflow: Bool = false) {
            let visible = displays.map { $0.intersection(frame) }
                .filter { $0.width >= 24 && $0.height >= 24 }
                .max { area($0) < area($1) }
            guard let visible else { return }
            if let existing = regions.firstIndex(where: { Geometry.nearlyEqual($0.frame, visible) }) {
                if hasOverflow { regions[existing].hasOverflow = true }
            } else {
                regions.append(Region(frame: visible, hasOverflow: hasOverflow))
            }
        }

        // Visit shallow branches first so a large document cannot hide a sibling pane from the scan.
        while index < queue.count, ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue[index]
            index += 1
            guard visited.insert(node.element).inserted else { continue }
            let values = node.element.values(attributes)
            guard let role = values[kAXRoleAttribute] as? String,
                  (values["AXHidden"] as? NSNumber)?.boolValue != true else { continue }
            let children = values[kAXChildrenAttribute] as? [AXUIElement] ?? []
            let isScrollArea = role == kAXScrollAreaRole
                || values[kAXVerticalScrollBarAttribute] != nil || values[kAXHorizontalScrollBarAttribute] != nil
            let isWebArea = role == "AXWebArea"
            let inWebArea = node.inWebArea || isWebArea
            let frame = AX.frame(position: values[kAXPositionAttribute], size: values[kAXSizeAttribute])
            if let viewport = node.parentViewport, let frame,
               ScrollViewport.hasOverflow(viewport: viewport, content: frame) {
                addFrame(viewport.intersection(node.clip), hasOverflow: true)
            }
            var childClip = node.clip
            if let frame, isScrollArea || isWebArea {
                childClip = childClip.intersection(frame)
                if isScrollArea { addFrame(childClip) }
            }
            guard !childClip.isEmpty else { continue }

            // Web content can expose a clipped container and its offscreen children without a scroll role.
            let viewport = inWebArea && webContainers.contains(role) ? frame : nil
            queue.append(contentsOf: children.prefix(limit - queue.count).map {
                Node(element: $0, clip: childClip, inWebArea: inWebArea, parentViewport: viewport)
            })
        }
        return targets(in: regions)
    }

    private static func area(_ frame: CGRect) -> CGFloat { frame.width * frame.height }

    private static func targets(in regions: [Region]) -> [Target] {
        // Aim outside nested panes so selecting the outer pane scrolls the outer pane.
        let ordered = regions.sorted { area($0.frame) < area($1.frame) }
        let windows = ordered.enumerated().map {
            Visibility.Window(id: UInt32($0.offset), frame: $0.element.frame)
        }
        let points = Visibility.labelPoints(windows)
        return windows.sorted {
            let first = ordered[Int($0.id)]
            let second = ordered[Int($1.id)]
            if first.hasOverflow != second.hasOverflow { return first.hasOverflow }
            return Geometry.readingOrder(first.frame, second.frame)
        }.compactMap { window in
            points[window.id].map { Target(frame: window.frame, point: $0) }
        }
    }
}
