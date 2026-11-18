/// Generates prefix-free hint labels.
public enum Hints {
    /// Returns `count` labels built from `alphabet`. No label is a prefix of another,
    /// and the labels are as short as possible. Shorter labels come first, so give
    /// them to the targets you want cheapest to reach (we use reading order).
    public static func generate(count: Int, alphabet: [Character]) -> [String] {
        guard count > 0 else { return [] }
        let alphabet = unique(alphabet)
        guard alphabet.count >= 2 else {
            // A one-letter alphabet cannot be prefix-free beyond one label.
            return alphabet.isEmpty ? [] : [String(alphabet[0])]
        }
        // Breadth-first expansion: expanding a leaf removes it (offset += 1) and
        // appends its children, so everything from `offset` on is a leaf.
        var hints = [""]
        var offset = 0
        while hints.count - offset < count || hints.count == 1 {
            let parent = hints[offset]
            offset += 1
            for ch in alphabet { hints.append(parent + String(ch)) }
        }
        // Expanding the next leaf replaces 1 label with k, so the leftover leaves
        // after the cut are always the longest ones.
        return Array(hints[offset..<(offset + count)])
    }

    /// Vimium's spreading: inside each group of labels with the same length, order them so that
    /// neighbors start with different characters ("ff", "jf", "df" instead of "ff", "fj", "fd").
    /// After the first key press, the remaining labels are then spread out, not clustered.
    /// Shorter labels stay first, so the targets that come first still get the shortest labels.
    public static func spread(_ labels: [String], alphabet: [Character]) -> [String] {
        let rank = Dictionary(unique(alphabet).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ s: String) -> [Int] { s.reversed().map { rank[$0] ?? Int.max } }
        var out: [String] = []
        var i = 0
        while i < labels.count {
            var j = i
            while j < labels.count && labels[j].count == labels[i].count { j += 1 }
            out += labels[i..<j].sorted { key($0).lexicographicallyPrecedes(key($1)) }
            i = j
        }
        return out
    }

    static func unique(_ chars: [Character]) -> [Character] {
        var seen = Set<Character>()
        return chars.filter { seen.insert($0).inserted }
    }
}
