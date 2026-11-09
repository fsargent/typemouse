/// Name-based labels for the window picker: Slack is "s", unless another visible app also
/// starts with "s". Then both get two letters from their names ("sl" and "sa").
///
/// The labels are prefix-free: a one-letter label never starts a longer one.
public enum PickerLabels {
    public struct Item: Equatable {
        public let windowID: UInt32
        public let appID: String   // bundle identifier, or name when there is none
        public let appName: String

        public init(windowID: UInt32, appID: String, appName: String) {
            self.windowID = windowID
            self.appID = appID
            self.appName = appName
        }
    }

    /// - Parameters:
    ///   - pins: letter -> app id. A pinned app uses its letter instead of its first letter.
    ///   - windowKeys: characters that tell apart several windows of one app (the hint characters).
    /// - Returns: window id -> label.
    public static func assign(_ items: [Item], pins: [Character: String] = [:], windowKeys: [Character]) -> [UInt32: String] {
        let pinnedKey = Dictionary(pins.map { ($0.value, Character($0.key.lowercased())) }, uniquingKeysWith: { a, _ in a })
        let windowKeys = Hints.unique(windowKeys.map { Character($0.lowercased()) })

        // App id -> its windows, oldest first. Window IDs grow over time, so the order is stable.
        var windows: [String: [UInt32]] = [:]
        var names: [String: String] = [:]
        for item in items {
            windows[item.appID, default: []].append(item.windowID)
            names[item.appID] = item.appName
        }
        for id in windows.keys { windows[id]!.sort() }

        // First key per app, then apps grouped by that key.
        var buckets: [Character: [String]] = [:]
        for id in windows.keys {
            let key = pinnedKey[id] ?? letters(names[id] ?? id).first ?? windowKeys.first ?? "a"
            buckets[key, default: []].append(id)
        }

        var result: [UInt32: String] = [:]
        for (key, apps) in buckets {
            let sortedApps = apps.sorted { (names[$0] ?? $0).localizedCaseInsensitiveCompare(names[$1] ?? $1) == .orderedAscending }
            let total = sortedApps.reduce(0) { $0 + windows[$1]!.count }

            if total == 1 {
                result[windows[sortedApps[0]]![0]] = String(key)
            } else if sortedApps.count == 1 {
                // One app, several windows: the app letter plus a window key.
                let ids = windows[sortedApps[0]]!
                for (id, suffix) in zip(ids, Hints.generate(count: ids.count, alphabet: windowKeys)) {
                    result[id] = String(key) + suffix
                }
            } else {
                // Several apps share the letter: each takes the next unused letter of its name.
                var used = Set<Character>()
                for app in sortedApps {
                    let name = letters(names[app] ?? app)
                    let candidates = Array(name.dropFirst()) + windowKeys + Array("abcdefghijklmnopqrstuvwxyz")
                    guard let second = candidates.first(where: { !used.contains($0) }) else { continue }
                    used.insert(second)
                    let prefix = String(key) + String(second)
                    let ids = windows[app]!
                    if ids.count == 1 {
                        result[ids[0]] = prefix
                    } else {
                        for (id, suffix) in zip(ids, Hints.generate(count: ids.count, alphabet: windowKeys)) {
                            result[id] = prefix + suffix
                        }
                    }
                }
            }
        }
        return result
    }

    /// Lowercase ASCII letters of a name, in order ("1Password" -> "password").
    static func letters(_ name: String) -> [Character] {
        name.lowercased().filter { $0.isASCII && $0.isLetter }.map { $0 }
    }
}
