import CoreGraphics

/// Finds where to put a label on each window that is at least partly visible.
public enum Visibility {
    public struct Window: Equatable {
        public let id: UInt32
        public let frame: CGRect

        public init(id: UInt32, frame: CGRect) {
            self.id = id
            self.frame = frame
        }
    }

    /// - Parameters:
    ///   - windows: front to back, all in the same coordinate space.
    ///   - grid: samples per side. Higher finds smaller visible slivers.
    ///   - minimumFraction: windows with a smaller visible share get no label.
    /// - Returns: window id -> a visible point near the middle of the visible area.
    public static func labelPoints(_ windows: [Window], grid: Int = 24, minimumFraction: Double = 0.02) -> [UInt32: CGPoint] {
        var result: [UInt32: CGPoint] = [:]
        for (i, w) in windows.enumerated() where w.frame.width > 0 && w.frame.height > 0 {
            let above = windows[..<i].map(\.frame).filter { $0.intersects(w.frame) }
            var visible: [CGPoint] = []
            for gx in 0..<grid {
                for gy in 0..<grid {
                    let p = CGPoint(x: w.frame.minX + (CGFloat(gx) + 0.5) * w.frame.width / CGFloat(grid),
                                    y: w.frame.minY + (CGFloat(gy) + 0.5) * w.frame.height / CGFloat(grid))
                    if !above.contains(where: { $0.contains(p) }) { visible.append(p) }
                }
            }
            guard Double(visible.count) / Double(grid * grid) >= minimumFraction else { continue }
            // The centroid can fall on a window in front (an L-shaped visible area), so snap to the
            // nearest visible sample.
            let cx = visible.map(\.x).reduce(0, +) / CGFloat(visible.count)
            let cy = visible.map(\.y).reduce(0, +) / CGFloat(visible.count)
            result[w.id] = visible.min { hypot($0.x - cx, $0.y - cy) < hypot($1.x - cx, $1.y - cy) }
        }
        return result
    }
}
