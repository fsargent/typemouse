import CoreGraphics

/// The one place that converts between coordinate spaces.
///
/// - AX / Quartz global: origin at the top-left of the primary display, y grows down.
/// - Cocoa global: origin at the bottom-left of the primary display, y grows up.
///
/// Getting this wrong is the classic multi-monitor bug, so nothing else should do it by hand.
public enum Geometry {
    public static func cocoaRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func axRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        // The conversion is its own inverse.
        cocoaRect(fromAX: r, primaryHeight: primaryHeight)
    }

    /// True when two rects are the same within `tolerance` points on every edge.
    public static func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Sort key for reading order: rows of `rowHeight` points, then left to right.
    public static func readingOrder(_ a: CGRect, _ b: CGRect, rowHeight: CGFloat = 12) -> Bool {
        let ra = Int((a.minY / rowHeight).rounded(.down))
        let rb = Int((b.minY / rowHeight).rounded(.down))
        if ra != rb { return ra < rb }
        return a.minX < b.minX
    }
}
