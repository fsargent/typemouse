import CoreGraphics
import XCTest
@testable import TypeMouseCore

final class HintsTests: XCTestCase {
    let home = Array("asdfghjkl")

    func testCountsAndUniqueness() {
        for n in [1, 2, 9, 10, 50, 81, 82, 500, 2000] {
            let hints = Hints.generate(count: n, alphabet: home)
            XCTAssertEqual(hints.count, n)
            XCTAssertEqual(Set(hints).count, n, "duplicates for n=\(n)")
        }
    }

    func testPrefixFree() {
        let hints = Hints.generate(count: 300, alphabet: home)
        for a in hints {
            for b in hints where a != b {
                XCTAssertFalse(b.hasPrefix(a), "\(a) is a prefix of \(b)")
            }
        }
    }

    func testMinimalLengths() {
        XCTAssertTrue(Hints.generate(count: 9, alphabet: home).allSatisfy { $0.count == 1 })
        XCTAssertTrue(Hints.generate(count: 81, alphabet: home).allSatisfy { $0.count == 2 })
        let mixed = Hints.generate(count: 10, alphabet: home)
        XCTAssertEqual(mixed.filter { $0.count == 1 }.count, 8)
        XCTAssertEqual(mixed.first, "s")
    }

    func testShortestFirst() {
        let hints = Hints.generate(count: 40, alphabet: home)
        XCTAssertEqual(hints.map(\.count), hints.map(\.count).sorted())
    }

    func testDefaultAlphabetPrefersHomeRow() {
        let alphabet = Config().hintAlphabet
        XCTAssertEqual(alphabet.count, 23)
        for excluded in "qpz/" { XCTAssertFalse(alphabet.contains(excluded)) }
        // Up to 23 targets: one key each, home row first.
        XCTAssertEqual(Hints.generate(count: 9, alphabet: alphabet).joined(), "fjdkslagh")
        // Two-key labels start with home-row pairs.
        let two = Hints.generate(count: 100, alphabet: alphabet).filter { $0.count == 2 }
        XCTAssertEqual(two.first, "ff")
        XCTAssertTrue(two.prefix(9).allSatisfy { $0.allSatisfy { "fjdkslagh".contains($0) } })
    }

    func testDegenerateAlphabets() {
        XCTAssertEqual(Hints.generate(count: 5, alphabet: []), [])
        XCTAssertEqual(Hints.generate(count: 5, alphabet: ["a"]), ["a"])
        XCTAssertEqual(Hints.generate(count: 3, alphabet: Array("aab")).count, 3)
    }
}

final class FuzzyTests: XCTestCase {
    func testNoMatch() {
        XCTAssertNil(Fuzzy.score("xyz", "Save"))
        XCTAssertNil(Fuzzy.score("saves", "Save"))
    }

    func testRanking() {
        let exact = Fuzzy.score("save", "Save")!
        let prefix = Fuzzy.score("save", "Save As…")!
        let inner = Fuzzy.score("save", "Autosave")!
        let scattered = Fuzzy.score("sve", "Save")!
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, inner)
        XCTAssertGreaterThan(inner, scattered)
    }

    func testWordBoundary() {
        XCTAssertGreaterThan(Fuzzy.score("as", "Save As")!, Fuzzy.score("as", "Database")!)
    }

    func testEmptyQueryMatchesAll() {
        XCTAssertEqual(Fuzzy.score("", "anything"), 0)
    }
}

final class GeometryTests: XCTestCase {
    func testConversionRoundTrip() {
        let ax = CGRect(x: 100, y: 50, width: 30, height: 20)
        let cocoa = Geometry.cocoaRect(fromAX: ax, primaryHeight: 1000)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 930, width: 30, height: 20))
        XCTAssertEqual(Geometry.axRect(fromCocoa: cocoa, primaryHeight: 1000), ax)
    }

    func testSecondaryDisplayAbovePrimary() {
        // A display above the primary has negative AX y. In Cocoa, its y is above the primary height.
        let ax = CGRect(x: 0, y: -800, width: 10, height: 10)
        XCTAssertEqual(Geometry.cocoaRect(fromAX: ax, primaryHeight: 1000).minY, 1790)
    }

    func testReadingOrder() {
        let rects = [CGRect(x: 200, y: 100, width: 1, height: 1),
                     CGRect(x: 10, y: 103, width: 1, height: 1),
                     CGRect(x: 50, y: 10, width: 1, height: 1)]
        let sorted = rects.sorted { Geometry.readingOrder($0, $1) }
        XCTAssertEqual(sorted.map(\.minX), [50, 10, 200])
    }
}

final class WindowLabelerTests: XCTestCase {
    let suffix = Array("asdfghjkl")

    func testNameLettersAndMultipleWindows() {
        let apps = [WindowLabeler.App(id: "chrome", name: "Google Chrome", windowCount: 3),
                    WindowLabeler.App(id: "slack", name: "Slack", windowCount: 1)]
        let r = WindowLabeler.assign(apps: apps, pins: [:], suffixAlphabet: suffix)
        XCTAssertEqual(r["slack"], ["s"])
        XCTAssertEqual(r["chrome"], ["ga", "gs", "gd"])
    }

    func testPinsWinAndAreReserved() {
        let apps = [WindowLabeler.App(id: "chrome", name: "Google Chrome", windowCount: 1),
                    WindowLabeler.App(id: "ghostty", name: "Ghostty", windowCount: 1)]
        // "g" is pinned to an app that is not running. Neither app may take it.
        let r = WindowLabeler.assign(apps: apps, pins: ["c": "chrome", "g": "notrunning"], suffixAlphabet: suffix)
        XCTAssertEqual(r["chrome"], ["c"])
        XCTAssertEqual(r["ghostty"], ["h"])
    }

    func testStableRegardlessOfInputOrder() {
        let a = WindowLabeler.App(id: "safari", name: "Safari", windowCount: 1)
        let b = WindowLabeler.App(id: "slack", name: "Slack", windowCount: 1)
        let r1 = WindowLabeler.assign(apps: [a, b], pins: [:], suffixAlphabet: suffix)
        let r2 = WindowLabeler.assign(apps: [b, a], pins: [:], suffixAlphabet: suffix)
        XCTAssertEqual(r1, r2)
    }

    func testAllLabelsPrefixFree() {
        let apps = (0..<30).map { WindowLabeler.App(id: "app\($0)", name: "App \($0)", windowCount: $0 % 4) }
        let r = WindowLabeler.assign(apps: apps, pins: [:], suffixAlphabet: suffix)
        let labels = r.values.flatMap { $0 }
        XCTAssertEqual(Set(labels).count, labels.count)
        for x in labels { for y in labels where x != y { XCTAssertFalse(y.hasPrefix(x)) } }
    }
}

final class HotkeyAndConfigTests: XCTestCase {
    func testHotkeyParsing() {
        let h = HotkeySpec("hyper+space")!
        XCTAssertEqual(h.keyCode, 49)
        XCTAssertEqual(h.modifiers, .hyper)
        XCTAssertEqual(HotkeySpec("Cmd + Shift + K")?.modifiers, [.command, .shift])
        XCTAssertEqual(HotkeySpec("hyper+backspace")?.keyCode, 51)
        XCTAssertNil(HotkeySpec("hyper+nosuchkey"))
        XCTAssertNil(HotkeySpec("super+a"))
    }

    func testPartialConfigKeepsDefaults() throws {
        let json = #"{"hotkeys": {"window": "hyper+w"}, "windowPins": {"s": "com.tinyspeck.slackmacgap"}}"#
        let c = try Config.decode(Data(json.utf8))
        XCTAssertEqual(c.hotkeys.window, "hyper+w")
        XCTAssertEqual(c.hotkeys.click, "hyper+space")
        XCTAssertEqual(c.hintCharacters, "fjdkslaghrueiwotyvmcxbn")
        XCTAssertEqual(c.pins, ["s": "com.tinyspeck.slackmacgap"])
    }

    func testRoundTrip() throws {
        var c = Config()
        c.clickStrategy = ["com.example": .mouse]
        XCTAssertEqual(try Config.decode(c.encoded()), c)
    }
}
