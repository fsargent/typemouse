import Foundation

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
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
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
