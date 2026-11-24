import CoreGraphics
import XCTest
@testable import TypeMouseCore

final class GridNavigationTests: XCTestCase {
    func testSingleDisplayRefinesAndUndoes() {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 900)
        var grid = GridNavigation(screens: [screen], pointer: CGPoint(x: 20, y: 20))
        XCTAssertEqual(grid.regions[0].keys, Array("uiojklm,."))
        XCTAssertFalse(grid.select("w"))
        XCTAssertTrue(grid.select("o"))
        XCTAssertEqual(grid.regions[0].frame, CGRect(x: 600, y: 0, width: 300, height: 300))
        XCTAssertTrue(grid.select("x")) // Either hand works after choosing the display.
        XCTAssertEqual(grid.point, CGPoint(x: 650, y: 250))
        XCTAssertEqual(grid.depth, 2)
        grid.back()
        XCTAssertEqual(grid.point, CGPoint(x: 750, y: 150))
        grid.back()
        grid.back()
        XCTAssertEqual(grid.depth, 0)
        XCTAssertEqual(grid.regions[0].frame, screen)
    }

    func testTwoDisplaysUsePhysicalOrderRatherThanPrimaryOrder() {
        let right = CGRect(x: 0, y: 0, width: 900, height: 900)
        let left = CGRect(x: -1200, y: -300, width: 1200, height: 900)
        var grid = GridNavigation(screens: [right, left], pointer: CGPoint(x: 0, y: 0))
        XCTAssertEqual(grid.regions.map(\.keys), [Array("wersdfxcv"), Array("uiojklm,.")])
        XCTAssertEqual(grid.regions.map(\.frame), [left, right])
        XCTAssertTrue(grid.select("v"))
        XCTAssertEqual(grid.regions[0].frame, CGRect(x: -400, y: 300, width: 400, height: 300))
        XCTAssertTrue(grid.select("u"))
        XCTAssertEqual(grid.point.x, -400 + 400.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(grid.point.y, 350)
    }

    func testEveryKeyMapsToItsRowAndColumn() {
        let screen = CGRect(x: 0, y: -900, width: 900, height: 900)
        for (index, key) in Array("uiojklm,.").enumerated() {
            var grid = GridNavigation(screens: [screen], pointer: .zero)
            XCTAssertTrue(grid.select(key))
            XCTAssertEqual(grid.point, CGPoint(x: (index % 3) * 300 + 150, y: (index / 3) * 300 - 750))
        }
    }

    func testAdditionalDisplaysRemainReachable() {
        let screens = (0..<3).map { CGRect(x: $0 * 900, y: 0, width: 900, height: 900) }
        var grid = GridNavigation(screens: screens, pointer: CGPoint(x: 50, y: 50))
        XCTAssertTrue(grid.hasMoreScreens)
        grid.nextScreens()
        XCTAssertEqual(grid.regions.map(\.frame), [screens[2]])
        XCTAssertEqual(grid.point, CGPoint(x: 2250, y: 450))
        XCTAssertTrue(grid.select("k"))
        XCTAssertEqual(grid.point, CGPoint(x: 2250, y: 450))
        grid.nextScreens()
        XCTAssertEqual(grid.depth, 0)
        XCTAssertEqual(grid.regions.map(\.frame), Array(screens.prefix(2)))
    }

    func testRefinementStopsAtPointerPrecision() {
        var grid = GridNavigation(screens: [CGRect(x: 0, y: 0, width: 1440, height: 900)], pointer: .zero)
        for _ in 0..<100 { grid.select("k") }
        XCTAssertLessThan(grid.depth, 10)
        XCTAssertGreaterThan(grid.regions[0].frame.width, 0)
        XCTAssertGreaterThan(grid.regions[0].frame.height, 0)
        XCTAssertEqual(grid.point.x, 720, accuracy: 0.0001)
        XCTAssertEqual(grid.point.y, 450, accuracy: 0.0001)
    }
}

final class ScrollingTests: XCTestCase {
    func testAllLayoutsAndArrowKeys() {
        let expected: [(ScrollKeys, String)] = [(.vim, "khjl"), (.esdf, "esdf"), (.wasd, "wasd"), (.ijkl, "ijkl")]
        for (layout, keys) in expected {
            for (character, direction) in zip(keys, [ScrollDirection.up, .left, .down, .right]) {
                XCTAssertEqual(layout.direction(character: String(character), keyCode: 0), direction)
            }
            for (code, direction) in [(126, ScrollDirection.up), (123, .left), (125, .down), (124, .right)] {
                XCTAssertEqual(layout.direction(character: "", keyCode: Int64(code)), direction)
            }
            XCTAssertNil(layout.direction(character: "z", keyCode: 6))
        }
    }

    func testOpposingAndDuplicateKeysDoNotIncreaseSpeed() {
        XCTAssertEqual(ScrollVector.combined([.up, .down]), ScrollVector(horizontal: 0, vertical: 0))
        XCTAssertEqual(ScrollVector.combined([.up, .up]), ScrollVector(horizontal: 0, vertical: 1))
        let diagonal = ScrollVector.combined([.up, .right])
        XCTAssertEqual(hypot(diagonal.horizontal, diagonal.vertical), 1, accuracy: 0.0001)
        XCTAssertLessThan(diagonal.horizontal, 0)
        XCTAssertGreaterThan(diagonal.vertical, 0)
    }

    func testNewSettingsKeepOldConfigCompatible() throws {
        let old = try Config.decode(Data(#"{"hotkeys":{"click":"hyper+j"}}"#.utf8))
        XCTAssertEqual(old.hotkeys.grid, ["hyper+h"])
        XCTAssertEqual(old.scrollKeys, .vim)
        XCTAssertEqual(old.scrollSpeed, 600)
        let custom = try Config.decode(Data(#"{"hotkeys":{"grid":["hyper+g","hyper+h"]},"scrollKeys":"esdf","scrollSpeed":1250}"#.utf8))
        XCTAssertEqual(custom.hotkeys.grid, ["hyper+g", "hyper+h"])
        XCTAssertEqual(custom.scrollKeys, .esdf)
        XCTAssertEqual(custom.scrollSpeed, 1250)
        XCTAssertEqual(try Config.decode(custom.encoded()), custom)
        let cleared = try Config.decode(Data(#"{"hotkeys":{"grid":[]},"scrollSpeed":-100}"#.utf8))
        XCTAssertEqual(cleared.hotkeys.grid, [])
        XCTAssertEqual(cleared.scrollSpeed, 50)
        XCTAssertEqual(try Config.decode(Data(#"{"scrollSpeed":999999}"#.utf8)).scrollSpeed, 5000)
    }
}
