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

    public struct Placement: Equatable {
        /// The center of `area`. The label goes here.
        public let point: CGPoint
        /// The largest rectangle of the window that no window in front covers.
        /// The label scales to this rectangle.
        public let area: CGRect
    }

    /// - Parameters:
    ///   - windows: front to back, all in the same coordinate space.
    ///   - grid: cells per side. Higher finds smaller visible slivers.
    ///   - minimumFraction: windows with a smaller visible share get no label.
    /// - Returns: window id -> placement, for windows that show.
    public static func placements(_ windows: [Window], grid: Int = 24, minimumFraction: Double = 0.02) -> [UInt32: Placement] {
        var result: [UInt32: Placement] = [:]
        for (i, w) in windows.enumerated() where w.frame.width > 0 && w.frame.height > 0 {
            let above = windows[..<i].map(\.frame).filter { $0.intersects(w.frame) }
            let cw = w.frame.width / CGFloat(grid)
            let ch = w.frame.height / CGFloat(grid)

            // visible[row][col]: the center of that cell is not covered by a window in front.
            var visible = [[Bool]](repeating: [Bool](repeating: false, count: grid), count: grid)
            var count = 0
            for row in 0..<grid {
                for col in 0..<grid {
                    let p = CGPoint(x: w.frame.minX + (CGFloat(col) + 0.5) * cw, y: w.frame.minY + (CGFloat(row) + 0.5) * ch)
                    if !above.contains(where: { $0.contains(p) }) {
                        visible[row][col] = true
                        count += 1
                    }
                }
            }
            guard Double(count) / Double(grid * grid) >= minimumFraction,
                  let cells = largestRectangle(visible) else { continue }
            let area = CGRect(x: w.frame.minX + CGFloat(cells.minCol) * cw,
                              y: w.frame.minY + CGFloat(cells.minRow) * ch,
                              width: CGFloat(cells.maxCol - cells.minCol + 1) * cw,
                              height: CGFloat(cells.maxRow - cells.minRow + 1) * ch)
            result[w.id] = Placement(point: CGPoint(x: area.midX, y: area.midY), area: area)
        }
        return result
    }

    /// Compatibility wrapper: label points only.
    public static func labelPoints(_ windows: [Window], grid: Int = 24, minimumFraction: Double = 0.02) -> [UInt32: CGPoint] {
        placements(windows, grid: grid, minimumFraction: minimumFraction).mapValues(\.point)
    }

    struct CellRect: Equatable {
        let minRow, maxRow, minCol, maxCol: Int
    }

    /// The largest all-true rectangle in a grid, by area. Uses the row-histogram method.
    static func largestRectangle(_ grid: [[Bool]]) -> CellRect? {
        guard let width = grid.first?.count else { return nil }
        var heights = [Int](repeating: 0, count: width)
        var best: (area: Int, rect: CellRect)?
        for (row, cells) in grid.enumerated() {
            for col in 0..<width { heights[col] = cells[col] ? heights[col] + 1 : 0 }
            for col in 0..<width where heights[col] > 0 {
                // Widen left and right while the columns are at least this tall.
                let h = heights[col]
                var left = col
                while left > 0 && heights[left - 1] >= h { left -= 1 }
                var right = col
                while right < width - 1 && heights[right + 1] >= h { right += 1 }
                let area = h * (right - left + 1)
                if area > (best?.area ?? 0) {
                    best = (area, CellRect(minRow: row - h + 1, maxRow: row, minCol: left, maxCol: right))
                }
            }
        }
        return best?.rect
    }
}
