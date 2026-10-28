/// Gives each app a stable one-letter key, and each of its windows a label.
///
/// Stability is the point: when the same apps are running, the same app keeps the same
/// letter, no matter which window has focus. Pins in the config make it permanent.
public enum WindowLabeler {
    public struct App: Equatable {
        public let id: String        // bundle identifier (or name when there is none)
        public let name: String
        public let windowCount: Int  // 0 means "pinned but not running": the label launches it

        public init(id: String, name: String, windowCount: Int) {
            self.id = id
            self.name = name
            self.windowCount = windowCount
        }
    }

    static let fallbackLetters = Array("asdfghjklqwertyuiopzxcvbnm")

    /// - Parameters:
    ///   - pins: letter -> app id.
    ///   - suffixAlphabet: characters for the second key when an app has several windows.
    /// - Returns: app id -> labels, one per window in the order the caller gave
    ///   (a single label for apps with 0 or 1 windows). Apps that get no letter are left out.
    public static func assign(apps: [App], pins: [Character: String], suffixAlphabet: [Character]) -> [String: [String]] {
        var keyFor: [String: Character] = [:]
        var used = Set<Character>()
        let runningOrPinned = Set(apps.map(\.id))

        for (letter, id) in pins where runningOrPinned.contains(id) {
            let l = Character(letter.lowercased())
            guard !used.contains(l), keyFor[id] == nil else { continue }
            keyFor[id] = l
            used.insert(l)
        }
        // Reserve every pinned letter, even for apps that are not present,
        // so an unpinned app never steals a pinned letter on some days and not others.
        let reserved = Set(pins.keys.map { Character($0.lowercased()) })

        // Unpinned apps in alphabetical order, so focus order does not move letters around.
        let unpinned = apps.filter { keyFor[$0.id] == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for app in unpinned {
            let nameLetters = app.name.lowercased().filter { $0.isASCII && $0.isLetter }
            let candidates = Array(nameLetters) + fallbackLetters
            if let l = candidates.first(where: { !used.contains($0) && !reserved.contains($0) }) {
                keyFor[app.id] = l
                used.insert(l)
            }
        }

        var result: [String: [String]] = [:]
        for app in apps {
            guard let key = keyFor[app.id] else { continue }
            if app.windowCount <= 1 {
                result[app.id] = [String(key)]
            } else {
                result[app.id] = Hints.generate(count: app.windowCount, alphabet: suffixAlphabet)
                    .map { String(key) + $0 }
            }
        }
        return result
    }
}
