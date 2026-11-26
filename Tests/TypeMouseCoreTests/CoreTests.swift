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

final class HotkeyAndConfigTests: XCTestCase {
    func testDefaultHotkeys() {
        let hotkeys = Config().hotkeys
        XCTAssertEqual(hotkeys.click, ["hyper+j"])
        XCTAssertEqual(hotkeys.grid, ["hyper+h"])
        XCTAssertEqual(hotkeys.missionControl, ["hyper+k"])
        XCTAssertEqual(hotkeys.window, ["hyper+l"])
        XCTAssertEqual(hotkeys.scroll, ["hyper+u"])
        XCTAssertTrue(hotkeys.picker.isEmpty)
        XCTAssertTrue(hotkeys.search.isEmpty)
    }

    func testDisablingModesKeepsTheirBindingsAndChildPreferences() throws {
        var config = try Config.decode(Data(#"{"hotkeys":{"window":"hyper+t","search":"hyper+o"}}"#.utf8))
        XCTAssertTrue(Config.Mode.allCases.allSatisfy(config.isModeEnabled))
        config.setModeEnabled(.windowPicker, false)
        config.setModeEnabled(.windowSelection, false)
        config.setModeEnabled(.click, false)
        config.setModeEnabled(.grid, false)
        XCTAssertFalse(config.isModeEnabled(.windowList))
        XCTAssertFalse(config.isModeEnabled(.missionControl))
        XCTAssertFalse(config.isModeEnabled(.search))
        XCTAssertFalse(config.isModeEnabled(.scroll))
        XCTAssertTrue(config.isModeEnabled(.windowManagement))
        XCTAssertEqual(try Config.decode(config.encoded()), config)

        config.setModeEnabled(.windowSelection, true)
        config.setModeEnabled(.click, true)
        XCTAssertTrue(config.isModeEnabled(.windowList))
        XCTAssertFalse(config.isModeEnabled(.windowPicker))
        XCTAssertTrue(config.isModeEnabled(.search))
        XCTAssertEqual(config.hotkeys.window, ["hyper+t"])
        XCTAssertEqual(config.hotkeys.search, ["hyper+o"])
    }
    func testMissionControlHotkeyKeepsDefaultAndCanBeCleared() throws {
        let defaults = try Config.decode(Data(#"{"hotkeys":{"click":"hyper+j"}}"#.utf8))
        XCTAssertEqual(defaults.hotkeys.missionControl, ["hyper+k"])
        XCTAssertTrue(defaults.hotkeys.picker.isEmpty)
        let cleared = try Config.decode(Data(#"{"hotkeys":{"missionControl":[]}}"#.utf8))
        XCTAssertTrue(cleared.hotkeys.missionControl.isEmpty)
        XCTAssertEqual(try Config.decode(cleared.encoded()), cleared)
    }
    func testMissionControlFallbackPreservesAnExistingHyperKBinding() throws {
        let existing = try Config.decode(Data(#"{"hotkeys":{"picker":"Command + Control + Option + Shift + K"}}"#.utf8))
        XCTAssertEqual(existing.hotkeys.picker, ["Command + Control + Option + Shift + K"])
        XCTAssertEqual(existing.hotkeys.missionControl, ["hyper+return"])
    }
    func testScrollHotkeyKeepsDefaultAndCanBeCleared() throws {
        let defaults = try Config.decode(Data(#"{"hotkeys":{"grid":"hyper+h"}}"#.utf8))
        XCTAssertEqual(defaults.hotkeys.scroll, ["hyper+u"])
        let cleared = try Config.decode(Data(#"{"hotkeys":{"scroll":[]}}"#.utf8))
        XCTAssertTrue(cleared.hotkeys.scroll.isEmpty)
        XCTAssertEqual(try Config.decode(cleared.encoded()), cleared)
    }
    func testChangingAndRemovingWindowPinsPreservesOtherApps() throws {
        var config = try Config.decode(Data(#"{"windowPins":{"S":"com.example.slack","b":"com.example.browser"}}"#.utf8))
        XCTAssertFalse(config.availableWindowPinLetters.contains("s"))
        XCTAssertTrue(config.setWindowPin("L", for: "com.example.slack"))
        XCTAssertEqual(config.windowPins, ["l": "com.example.slack", "b": "com.example.browser"])
        XCTAssertEqual(try Config.decode(config.encoded()).pins, config.pins)

        config.removeWindowPin(for: "com.example.slack")
        XCTAssertEqual(config.pins, ["b": "com.example.browser"])
        XCTAssertTrue(config.availableWindowPinLetters.contains("l"))
    }

    func testWindowPinCannotTakeAnotherAppsLetter() {
        var config = Config()
        config.windowPins = ["B": "com.example.browser", "s": "com.example.slack"]

        XCTAssertFalse(config.setWindowPin("b", for: "com.example.slack"))
        XCTAssertEqual(config.pins, ["b": "com.example.browser", "s": "com.example.slack"])
    }

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
        XCTAssertEqual(c.hotkeys.window, ["hyper+w"])
        XCTAssertEqual(c.hotkeys.click, ["hyper+j"])
        XCTAssertEqual(c.hintCharacters, "fjdkslaghrueiwotyvmcxbn")
        XCTAssertEqual(c.pins, ["s": "com.tinyspeck.slackmacgap"])
    }

    func testChromiumBrowsersGetEnhancedUIByDefault() throws {
        XCTAssertTrue(Config().enhancedUserInterfaceApps.contains("com.google.Chrome"))
        let c = try Config.decode(Data(#"{"enhancedUserInterfaceApps": []}"#.utf8))
        XCTAssertEqual(c.enhancedUserInterfaceApps, [])
    }

    func testHotkeysTakeAStringOrAList() throws {
        let json = #"{"hotkeys": {"search": ["hyper+k", "hyper+backspace"], "window": "hyper+l"}}"#
        let c = try Config.decode(Data(json.utf8))
        XCTAssertEqual(c.hotkeys.search, ["hyper+k", "hyper+backspace"])
        XCTAssertEqual(c.hotkeys.window, ["hyper+l"])
        XCTAssertEqual(try Config.decode(c.encoded()), c)
        // A single hotkey is written as a plain string.
        let text = String(decoding: try c.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""window" : "hyper+l""#), text)
        XCTAssertTrue(text.contains(#""hyper+backspace""#), text)
    }

    func testClearedHotkeysStayCleared() throws {
        let c = try Config.decode(Data(#"{"hotkeys": {"click": [], "picker": ""}}"#.utf8))
        XCTAssertEqual(c.hotkeys.click, [])
        XCTAssertEqual(c.hotkeys.picker, [])
        XCTAssertEqual(c.hotkeys.window, ["hyper+l"]) // missing key: default
        XCTAssertEqual(try Config.decode(c.encoded()).hotkeys, c.hotkeys)
    }

    func testChainModeByDefaultIsOff() throws {
        XCTAssertFalse(Config().chainModeByDefault)
        XCTAssertTrue(try Config.decode(Data(#"{"chainModeByDefault": true}"#.utf8)).chainModeByDefault)
    }

    func testChainDelay() throws {
        XCTAssertEqual(Config().chainDelayMs, 250)
        XCTAssertEqual(try Config.decode(Data(#"{"chainDelayMs": 1200}"#.utf8)).chainDelayMs, 1200)
        XCTAssertEqual(try Config.decode(Data(#"{"chainDelayMs": -5}"#.utf8)).chainDelayMs, 0)
        XCTAssertEqual(try Config.decode(Data(#"{"chainDelayMs": 99999}"#.utf8)).chainDelayMs, 5000)
    }

    func testLabelFontSizeClampsOnDecode() throws {
        XCTAssertEqual(try Config.decode(Data(#"{"labelFontSize": 2}"#.utf8)).labelFontSize, 8)
        XCTAssertEqual(try Config.decode(Data(#"{"labelFontSize": 200}"#.utf8)).labelFontSize, 48)
        XCTAssertEqual(try Config.decode(Data(#"{"labelFontSize": 18}"#.utf8)).labelFontSize, 18)
    }

    func testClickAfterPickerDefaultsOn() throws {
        XCTAssertTrue(Config().clickAfterPicker)
        XCTAssertFalse(try Config.decode(Data(#"{"clickAfterPicker": false}"#.utf8)).clickAfterPicker)
    }

    func testRoundTrip() throws {
        var c = Config()
        c.clickStrategy = ["com.example": .mouse]
        XCTAssertEqual(try Config.decode(c.encoded()), c)
    }
}

final class VisibilityTests: XCTestCase {
    func testFullyVisibleWindowGetsItsCenter() {
        let p = Visibility.labelPoints([.init(id: 1, frame: CGRect(x: 0, y: 0, width: 240, height: 240))])
        XCTAssertEqual(p[1]!.x, 120, accuracy: 6)
        XCTAssertEqual(p[1]!.y, 120, accuracy: 6)
    }

    func testCoveredWindowGetsNoLabel() {
        let front = Visibility.Window(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let back = Visibility.Window(id: 2, frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertNil(Visibility.labelPoints([front, back])[2])
    }

    func testLabelLandsOnTheVisiblePart() {
        // The front window covers the left 3/4 of the back window.
        let front = Visibility.Window(id: 1, frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let back = Visibility.Window(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let p = Visibility.labelPoints([front, back])[2]!
        XCTAssertGreaterThan(p.x, 300)
        XCTAssertFalse(front.frame.contains(p))
    }

    func testLShapedVisibleAreaStaysVisible() {
        // The front window covers the middle of the back window's bottom-left, leaving an L shape.
        let front = Visibility.Window(id: 1, frame: CGRect(x: 0, y: 100, width: 300, height: 300))
        let back = Visibility.Window(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let p = Visibility.labelPoints([front, back])[2]!
        XCTAssertFalse(front.frame.contains(p))
    }

    func testAreaIsTheLargestUncoveredRectangle() {
        // The front window covers the left 3/4, so the free area is the right quarter.
        let front = Visibility.Window(id: 1, frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let back = Visibility.Window(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let area = Visibility.placements([front, back])[2]!.area
        XCTAssertEqual(area.minX, 300, accuracy: 17)
        XCTAssertEqual(area.width, 100, accuracy: 17)
        XCTAssertEqual(area.height, 400, accuracy: 1)
        XCTAssertFalse(area.insetBy(dx: 1, dy: 1).intersects(front.frame))
    }

    func testFullyVisibleAreaIsTheWholeWindow() {
        let frame = CGRect(x: 10, y: 20, width: 480, height: 240)
        let p = Visibility.placements([.init(id: 1, frame: frame)])[1]!
        XCTAssertEqual(p.area, frame)
        XCTAssertEqual(p.point, CGPoint(x: frame.midX, y: frame.midY))
    }

    func testLargestRectangle() {
        let grid: [[Bool]] = [
            [true, true, false, false],
            [true, true, true, true],
            [true, true, true, true],
        ]
        // Rows 1-2, all four columns (8 cells) beats columns 0-1, all rows (6 cells).
        XCTAssertEqual(Visibility.largestRectangle(grid), .init(minRow: 1, maxRow: 2, minCol: 0, maxCol: 3))
        XCTAssertNil(Visibility.largestRectangle([[false]]))
    }
}

final class HotkeyFormattingTests: XCTestCase {
    func testConfigStringRoundTrips() {
        for string in ["hyper+j", "hyper+space", "hyper+backspace", "ctrl+opt+k", "cmd+shift+return", "hyper+/"] {
            let spec = HotkeySpec(string)!
            let written = HotkeySpec.configString(keyCode: spec.keyCode, modifiers: spec.modifiers)!
            XCTAssertEqual(HotkeySpec(written)!.keyCode, spec.keyCode, string)
            XCTAssertEqual(HotkeySpec(written)!.modifiers, spec.modifiers, string)
        }
        XCTAssertEqual(HotkeySpec.configString(keyCode: 38, modifiers: .hyper), "hyper+j")
    }

    func testAliasesWriteCanonicalNames() {
        XCTAssertEqual(HotkeySpec.configString(keyCode: HotkeySpec("hyper+delete")!.keyCode, modifiers: .hyper), "hyper+backspace")
        XCTAssertEqual(HotkeySpec.configString(keyCode: HotkeySpec("cmd+enter")!.keyCode, modifiers: .command), "cmd+return")
    }

    func testUnknownKeyCode() {
        XCTAssertNil(HotkeySpec.configString(keyCode: 999, modifiers: .hyper))
    }

    func testDisplayString() {
        XCTAssertEqual(HotkeySpec("hyper+j")!.displayString, "Hyper J")
        XCTAssertEqual(HotkeySpec("ctrl+opt+k")!.displayString, "⌃⌥K")
        XCTAssertEqual(HotkeySpec("hyper+space")!.displayString, "Hyper Space")
    }
}

final class PickerLabelsTests: XCTestCase {
    let keys = Array("fjdkslagh")

    func item(_ id: UInt32, _ app: String) -> PickerLabels.Item {
        .init(windowID: id, appID: app.lowercased(), appName: app)
    }

    func testUniqueFirstLetterIsOneKey() {
        let r = PickerLabels.assign([item(1, "Slack"), item(2, "Ghostty")], windowKeys: keys)
        XCTAssertEqual(r, [1: "s", 2: "g"])
    }

    func testSharedFirstLetterUsesNextLetters() {
        let r = PickerLabels.assign([item(1, "Slack"), item(2, "Safari"), item(3, "Ghostty")], windowKeys: keys)
        XCTAssertEqual(r[1], "sl")
        XCTAssertEqual(r[2], "sa")
        XCTAssertEqual(r[3], "g")
    }

    func testSeveralWindowsOfOneAppAreStableByWindowID() {
        let a = PickerLabels.assign([item(30, "Chrome"), item(10, "Chrome")], windowKeys: keys)
        let b = PickerLabels.assign([item(10, "Chrome"), item(30, "Chrome")], windowKeys: keys)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a[10], "cf")
        XCTAssertEqual(a[30], "cj")
    }

    func testPinsOverrideTheFirstLetter() {
        let r = PickerLabels.assign([item(1, "Google Chrome"), item(2, "Ghostty")],
                                    pins: ["c": "google chrome"], windowKeys: keys)
        XCTAssertEqual(r, [1: "c", 2: "g"])
    }

    func testPinnedLetterBelongsToThePinnedApp() {
        let r = PickerLabels.assign([item(1, "Google Chrome"), item(2, "Cursor"), item(3, "Calendar")],
                                    pins: ["c": "google chrome"], windowKeys: keys)
        XCTAssertEqual(r[1], "c")
        XCTAssertEqual(r[2], "u") // Cursor skips the pinned c
        XCTAssertEqual(r[3], "a") // Calendar skips the pinned c
    }

    func testMovedAppContinuesFromItsNewLetter() {
        // Cursor and Ulysses share "u" once "c" is pinned. Cursor continues with "r", not "u".
        let r = PickerLabels.assign([item(1, "Google Chrome"), item(2, "Cursor"), item(3, "Ulysses")],
                                    pins: ["c": "google chrome"], windowKeys: keys)
        XCTAssertEqual(r[2], "ur")
        XCTAssertEqual(r[3], "ul")
    }

    func testPinOfAnAbsentAppReservesNothing() {
        let r = PickerLabels.assign([item(1, "Cursor")], pins: ["c": "google chrome"], windowKeys: keys)
        XCTAssertEqual(r[1], "c")
    }

    func testNamesStartingWithDigits() {
        XCTAssertEqual(PickerLabels.assign([item(1, "1Password")], windowKeys: keys), [1: "p"])
    }

    func testSharedLetterWithSeveralWindows() {
        let r = PickerLabels.assign([item(1, "Slack"), item(2, "Safari"), item(3, "Safari")], windowKeys: keys)
        XCTAssertEqual(r[1], "sl")
        XCTAssertEqual(r[2], "saf")
        XCTAssertEqual(r[3], "saj")
    }

    func testAlwaysPrefixFree() {
        let names = ["Slack", "Safari", "Signal", "Spotify", "Chrome", "Chrome", "Calendar", "Code", "Ghostty", "Mail", "Messages"]
        let items = names.enumerated().map { item(UInt32($0.offset + 1), $0.element) }
        let labels = Array(PickerLabels.assign(items, windowKeys: keys).values)
        XCTAssertEqual(labels.count, items.count)
        XCTAssertEqual(Set(labels).count, labels.count)
        for x in labels { for y in labels where x != y { XCTAssertFalse(y.hasPrefix(x), "\(x) / \(y)") } }
    }
}

final class LabelPriorityTests: XCTestCase {
    func tier(_ role: String, web: Bool = true, appWeb: Bool = true, menu: Bool = false) -> LabelPriority.Tier {
        LabelPriority.tier(role: role, inWebArea: web, appHasWebContent: appWeb, inMenuBar: menu)
    }

    func testPageElementsByType() {
        XCTAssertEqual(tier("AXButton"), .button)
        XCTAssertEqual(tier("AXCheckBox"), .button)
        XCTAssertEqual(tier("AXTextField"), .field)
        XCTAssertEqual(tier("AXLink"), .link)
        XCTAssertEqual(tier("AXGroup"), .other)
        XCTAssertLessThan(tier("AXButton"), tier("AXTextField"))
        XCTAssertLessThan(tier("AXTextField"), tier("AXLink"))
        XCTAssertLessThan(tier("AXLink"), tier("AXGroup"))
    }

    func testBrowserUIComesAfterThePage() {
        // A Chrome toolbar button is outside the web area while the page has content.
        XCTAssertEqual(tier("AXButton", web: false, appWeb: true), .appUI)
        XCTAssertLessThan(tier("AXGroup"), tier("AXButton", web: false, appWeb: true))
    }

    func testNativeAppsUseRoleTiers() {
        XCTAssertEqual(tier("AXButton", web: false, appWeb: false), .button)
        XCTAssertEqual(tier("AXTextField", web: false, appWeb: false), .field)
    }

    func testMenuBarIsLast() {
        XCTAssertEqual(tier("AXMenuBarItem", web: false, menu: true), .menuBar)
        XCTAssertLessThan(tier("AXButton", web: false, appWeb: true), .menuBar)
    }

    func testDefaultOn() throws {
        XCTAssertTrue(Config().prioritizeLabels)
        XCTAssertFalse(try Config.decode(Data(#"{"prioritizeLabels": false}"#.utf8)).prioritizeLabels)
    }
}

final class SpreadAndWeakTests: XCTestCase {
    let home = Array("fjdkslagh")

    func testSpreadKeepsTheSetAndLengthOrder() {
        let labels = Hints.generate(count: 40, alphabet: home)
        let spread = Hints.spread(labels, alphabet: home)
        XCTAssertEqual(Set(spread), Set(labels))
        XCTAssertEqual(spread.map(\.count), labels.map(\.count))
    }

    func testSpreadVariesTheFirstCharacter() {
        let labels = Hints.generate(count: 81, alphabet: home) // all two-letter
        let spread = Hints.spread(labels, alphabet: home)
        XCTAssertEqual(Array(spread.prefix(3)), ["ff", "jf", "df"])
        XCTAssertEqual(Set(spread.prefix(9).map(\.first!)).count, 9)
    }

    func testIconInsideAButtonIsDropped() {
        let items = [LabelPriority.Candidate(frame: CGRect(x: 0, y: 0, width: 100, height: 30), role: "AXButton"),
                     LabelPriority.Candidate(frame: CGRect(x: 5, y: 5, width: 16, height: 16), role: "AXImage")]
        XCTAssertEqual(LabelPriority.removeWeakDuplicates(items), [0])
    }

    func testCardAroundItsLinkIsDropped() {
        let items = [LabelPriority.Candidate(frame: CGRect(x: 0, y: 0, width: 300, height: 60), role: "AXGroup"),
                     LabelPriority.Candidate(frame: CGRect(x: 10, y: 10, width: 260, height: 40), role: "AXLink")]
        XCTAssertEqual(LabelPriority.removeWeakDuplicates(items), [1])
    }

    func testLargeAreaWithASmallButtonStays() {
        // A big clickable row with a small button in a corner: both stay.
        let items = [LabelPriority.Candidate(frame: CGRect(x: 0, y: 0, width: 600, height: 80), role: "AXGroup"),
                     LabelPriority.Candidate(frame: CGRect(x: 560, y: 20, width: 30, height: 30), role: "AXButton")]
        XCTAssertEqual(LabelPriority.removeWeakDuplicates(items), [0, 1])
    }

    func testStrongTargetsAreNeverDropped() {
        let items = [LabelPriority.Candidate(frame: CGRect(x: 0, y: 0, width: 100, height: 30), role: "AXButton"),
                     LabelPriority.Candidate(frame: CGRect(x: 5, y: 5, width: 20, height: 20), role: "AXLink")]
        XCTAssertEqual(LabelPriority.removeWeakDuplicates(items), [0, 1])
    }
}

final class CapsLockMappingTests: XCTestCase {
    let other: [String: UInt64] = [CapsLockMapping.sourceKey: 0x7_0000_0064, CapsLockMapping.destinationKey: 0x7_0000_0035]

    func testAddKeepsOtherRemaps() {
        let r = CapsLockMapping.adding(to: [other])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0], other)
        XCTAssertEqual(r[1][CapsLockMapping.destinationKey], CapsLockMapping.f18)
    }

    func testAddTwiceAddsOnce() {
        let r = CapsLockMapping.adding(to: CapsLockMapping.adding(to: []))
        XCTAssertEqual(r.count, 1)
    }

    func testAddReplacesAnOlderCapsLockRemap() {
        let capsToControl: [String: UInt64] = [CapsLockMapping.sourceKey: CapsLockMapping.capsLock,
                                               CapsLockMapping.destinationKey: 0x7_0000_00E0]
        XCTAssertEqual(CapsLockMapping.adding(to: [capsToControl]).count, 1)
    }

    func testRemoveTakesOnlyOurs() {
        let r = CapsLockMapping.removing(from: CapsLockMapping.adding(to: [other]))
        XCTAssertEqual(r, [other])
    }

    func testOffByDefault() throws {
        XCTAssertFalse(Config().capsLockToHyper)
        XCTAssertTrue(try Config.decode(Data(#"{"capsLockToHyper": true}"#.utf8)).capsLockToHyper)
    }
}

