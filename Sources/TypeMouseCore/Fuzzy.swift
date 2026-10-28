/// Small fuzzy matcher for element and window text.
public enum Fuzzy {
    /// Returns nil when `query` does not match `text`, otherwise a score where higher is better.
    /// Substring matches always beat scattered subsequence matches.
    public static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        guard !t.isEmpty, q.count <= t.count else { return nil }

        if let start = substringIndex(q, in: t) {
            var s = 10_000 - min(start, 1_000)
            if start == 0 || isBoundary(t, start) { s += 2_000 }
            if q.count == t.count { s += 5_000 }
            return s
        }

        // Subsequence: reward consecutive runs and word-boundary hits.
        var s = 0
        var ti = 0
        var prev = -2
        for qc in q {
            while ti < t.count, t[ti] != qc { ti += 1 }
            guard ti < t.count else { return nil }
            if ti == prev + 1 { s += 15 }
            if isBoundary(t, ti) { s += 10 }
            s -= 1
            prev = ti
            ti += 1
        }
        return max(1, 1_000 + s - t.count)
    }

    static func substringIndex(_ q: [Character], in t: [Character]) -> Int? {
        guard q.count <= t.count else { return nil }
        outer: for i in 0...(t.count - q.count) {
            for j in 0..<q.count where t[i + j] != q[j] { continue outer }
            return i
        }
        return nil
    }

    static func isBoundary(_ t: [Character], _ i: Int) -> Bool {
        i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber)
    }
}
