import CoreGraphics

public enum WindowCommand: String, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight, nextDisplay

    public var title: String {
        switch self {
        case .topLeft: return "Top left quarter"
        case .top: return "Top edge"
        case .topRight: return "Top right quarter"
        case .left: return "Left edge"
        case .center: return "Center"
        case .right: return "Right edge"
        case .bottomLeft: return "Bottom left quarter"
        case .bottom: return "Bottom edge"
        case .bottomRight: return "Bottom right quarter"
        case .nextDisplay: return "Move to next display"
        }
    }

    public var defaultHotkey: String {
        switch self {
        case .topLeft: return "hyper+w"
        case .top: return "hyper+e"
        case .topRight: return "hyper+r"
        case .left: return "hyper+s"
        case .center: return "hyper+d"
        case .right: return "hyper+f"
        case .bottomLeft: return "hyper+x"
        case .bottom: return "hyper+c"
        case .bottomRight: return "hyper+v"
        case .nextDisplay: return "hyper+g"
        }
    }

    /// Consecutive frames in Quartz coordinates, from the first press to the last.
    public func frames(in bounds: CGRect) -> [CGRect] {
        let widths: [CGFloat] = [0.5, 2.0 / 3, 1.0 / 3]
        let tiles: [CGRect]
        switch self {
        case .topLeft: tiles = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]
        case .top: tiles = widths.map { CGRect(x: 0, y: 0, width: 1, height: $0) }
        case .topRight: tiles = [CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)]
        case .left: tiles = widths.map { CGRect(x: 0, y: 0, width: $0, height: 1) }
        case .center: tiles = [1.0, 0.5, 1.0 / 3].map { CGRect(x: (1 - $0) / 2, y: 0, width: $0, height: 1) }
        case .right: tiles = widths.map { CGRect(x: 1 - $0, y: 0, width: $0, height: 1) }
        case .bottomLeft: tiles = [CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)]
        case .bottom: tiles = widths.map { CGRect(x: 0, y: 1 - $0, width: 1, height: $0) }
        case .bottomRight: tiles = [CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .nextDisplay: return []
        }

        return tiles.map { tile in
            let left = (bounds.minX + tile.minX * bounds.width).rounded()
            let top = (bounds.minY + tile.minY * bounds.height).rounded()
            let right = (bounds.minX + tile.maxX * bounds.width).rounded()
            let bottom = (bounds.minY + tile.maxY * bounds.height).rounded()
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}

public enum WindowLayout {
    public static func displayIndex(for window: CGRect, displays: [CGRect]) -> Int? {
        let center = CGPoint(x: window.midX, y: window.midY)
        return displays.indices.max { left, right in
            let a = window.intersection(displays[left])
            let b = window.intersection(displays[right])
            let areaA = a.isNull ? 0 : a.width * a.height
            let areaB = b.isNull ? 0 : b.width * b.height
            if areaA != areaB { return areaA < areaB }
            return distanceSquared(center, displays[left]) > distanceSquared(center, displays[right])
        }
    }

    /// Keep a window's relative size and position when the displays differ in size.
    public static func move(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return destination }
        let width = min(1, frame.width / source.width)
        let height = min(1, frame.height / source.height)
        let x = min(max(0, (frame.minX - source.minX) / source.width), 1 - width)
        let y = min(max(0, (frame.minY - source.minY) / source.height), 1 - height)
        let left = (destination.minX + x * destination.width).rounded()
        let top = (destination.minY + y * destination.height).rounded()
        let right = (destination.minX + (x + width) * destination.width).rounded()
        let bottom = (destination.minY + (y + height) * destination.height).rounded()
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func distanceSquared(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        let x = point.x - min(max(point.x, frame.minX), frame.maxX)
        let y = point.y - min(max(point.y, frame.minY), frame.maxY)
        return x * x + y * y
    }
}
