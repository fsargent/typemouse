import CoreGraphics

/// Grid coordinates use Quartz's top-left origin, including displays above the primary display.
public struct GridNavigation: Sendable {
    public enum Hand: String, Codable, CaseIterable, Sendable {
        case left, right

        var keys: [Character] { Array(self == .left ? "wersdfxcv" : "uiojklm,.") }
        var other: Hand { self == .left ? .right : .left }
    }

    public struct Region: Equatable, Sendable {
        public let frame: CGRect
        public let keys: [Character]

        public var cells: [CGRect] { (0..<9).map { GridNavigation.cell($0, in: frame) } }
    }

    private let screens: [CGRect]
    private var history: [CGRect] = []
    private var page = 0
    public var preferredHand: Hand

    public init(screens: [CGRect], pointer: CGPoint, preferredHand: Hand = .right) {
        self.preferredHand = preferredHand
        self.screens = screens.sorted { a, b in
            a.minX == b.minX ? a.minY < b.minY : a.minX < b.minX
        }
        if let index = self.screens.firstIndex(where: { $0.contains(pointer) }) {
            page = index / 2
        }
    }

    public var depth: Int { history.count }
    public var hasMoreScreens: Bool { screens.count > 2 }
    /// The center of the selected cell. No cell is selected when the grid opens.
    public var point: CGPoint? {
        guard let frame = history.last else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    public var regions: [Region] {
        if let selected = history.last { return [Region(frame: selected, keys: preferredHand.keys)] }
        let start = page * 2
        return screens.dropFirst(start).prefix(2).enumerated().map { index, frame in
            let hand: Hand = start + 1 >= screens.count ? preferredHand : (index == 0 ? .left : .right)
            return Region(frame: frame, keys: hand.keys)
        }
    }

    @discardableResult
    public mutating func select(_ key: Character) -> Bool {
        for region in regions {
            // After choosing a display, either hand can refine the target.
            let index =
                region.keys.firstIndex(of: key)
                ?? (history.isEmpty ? nil : preferredHand.other.keys.firstIndex(of: key))
            guard let index, min(region.frame.width, region.frame.height) > 1 else { continue }
            history.append(Self.cell(index, in: region.frame))
            return true
        }
        return false
    }

    public mutating func back() {
        if !history.isEmpty { history.removeLast() }
    }

    public mutating func nextScreens() {
        history = []
        page = (page + 1) % max(1, (screens.count + 1) / 2)
    }

    public static func cell(_ index: Int, in frame: CGRect) -> CGRect {
        let size = CGSize(width: frame.width / 3, height: frame.height / 3)
        return CGRect(
            x: frame.minX + CGFloat(index % 3) * size.width,
            y: frame.minY + CGFloat(index / 3) * size.height,
            width: size.width, height: size.height)
    }
}
