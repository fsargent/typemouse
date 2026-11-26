import Foundation

public enum ScrollViewport {
    /// Detects content far enough outside a viewport to distinguish overflow from padding and borders.
    public static func hasOverflow(viewport: CGRect, content: CGRect) -> Bool {
        guard viewport.width >= 24, viewport.height >= 24, content.width >= 8, content.height >= 8 else { return false }
        let overlapX = min(viewport.maxX, content.maxX) - max(viewport.minX, content.minX)
        let overlapY = min(viewport.maxY, content.maxY) - max(viewport.minY, content.minY)
        let spillsVertically = content.minY < viewport.minY - 24 || content.maxY > viewport.maxY + 24
        let spillsHorizontally = content.minX < viewport.minX - 24 || content.maxX > viewport.maxX + 24
        return (spillsVertically && overlapX >= min(viewport.width, content.width) / 2)
            || (spillsHorizontally && overlapY >= min(viewport.height, content.height) / 2)
    }
}

public enum ScrollKeys: String, Codable, CaseIterable {
    case vim, esdf, wasd, ijkl

    public var displayName: String {
        self == .vim ? "Vim (HJKL)" : rawValue.uppercased()
    }

    /// Keys in up, left, down, right order.
    public var directions: String {
        switch self {
        case .vim: return "K H J L"
        case .esdf: return "E S D F"
        case .wasd: return "W A S D"
        case .ijkl: return "I J K L"
        }
    }

    public func direction(character: String, keyCode: Int64) -> ScrollDirection? {
        // Arrow keys work with every layout.
        switch keyCode {
        case Int64(KeyCode.upArrow): return .up
        case Int64(KeyCode.downArrow): return .down
        case Int64(KeyCode.leftArrow): return .left
        case Int64(KeyCode.rightArrow): return .right
        default: break
        }
        let keys = directions.lowercased().split(separator: " ").map(String.init)
        guard let index = keys.firstIndex(of: character) else { return nil }
        return [ScrollDirection.up, .left, .down, .right][index]
    }
}

public enum ScrollDirection: Equatable {
    case up, left, down, right

    public var vector: ScrollVector {
        switch self {
        case .up: return ScrollVector(horizontal: 0, vertical: 1)
        case .left: return ScrollVector(horizontal: 1, vertical: 0)
        case .down: return ScrollVector(horizontal: 0, vertical: -1)
        case .right: return ScrollVector(horizontal: -1, vertical: 0)
        }
    }
}

public struct ScrollVector: Equatable {
    public var horizontal: Double
    public var vertical: Double

    /// Opposite keys cancel. Diagonal scrolling keeps the configured total speed.
    public static func combined(_ directions: [ScrollDirection]) -> ScrollVector {
        let unique = directions.reduce(into: [ScrollDirection]()) { result, direction in
            if !result.contains(direction) { result.append(direction) }
        }
        let x = unique.reduce(0.0) { $0 + $1.vector.horizontal }
        let y = unique.reduce(0.0) { $0 + $1.vector.vertical }
        let length = max(1, hypot(x, y))
        return ScrollVector(horizontal: x / length, vertical: y / length)
    }
}
