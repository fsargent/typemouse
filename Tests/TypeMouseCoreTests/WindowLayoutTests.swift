import CoreGraphics
import XCTest
@testable import TypeMouseCore

final class WindowLayoutTests: XCTestCase {
    private let display = CGRect(x: -1200, y: -600, width: 1200, height: 900)

    func testEdgeCyclesStayAnchored() {
        XCTAssertEqual(WindowCommand.left.frames(in: display), [
            CGRect(x: -1200, y: -600, width: 600, height: 900),
            CGRect(x: -1200, y: -600, width: 800, height: 900),
            CGRect(x: -1200, y: -600, width: 400, height: 900),
        ])
        let right = WindowCommand.right.frames(in: display)
        XCTAssertEqual(right.map(\.width), [600, 800, 400])
        XCTAssertEqual(right.map(\.maxX), [0, 0, 0])
        let top = WindowCommand.top.frames(in: display)
        XCTAssertEqual(top.map(\.height), [450, 600, 300])
        XCTAssertEqual(top.map(\.minY), [-600, -600, -600])
        let bottom = WindowCommand.bottom.frames(in: display)
        XCTAssertEqual(bottom.map(\.height), [450, 600, 300])
        XCTAssertEqual(bottom.map(\.maxY), [300, 300, 300])
    }

    func testCenterAndCorners() {
        XCTAssertEqual(WindowCommand.center.frames(in: display), [
            CGRect(x: -900, y: -600, width: 600, height: 900), display,
        ])
        XCTAssertEqual(WindowCommand.topLeft.frames(in: display), [CGRect(x: -1200, y: -600, width: 600, height: 450)])
        XCTAssertEqual(WindowCommand.topRight.frames(in: display), [CGRect(x: -600, y: -600, width: 600, height: 450)])
        XCTAssertEqual(WindowCommand.bottomLeft.frames(in: display), [CGRect(x: -1200, y: -150, width: 600, height: 450)])
        XCTAssertEqual(WindowCommand.bottomRight.frames(in: display), [CGRect(x: -600, y: -150, width: 600, height: 450)])
    }

    func testOddDimensionsSplitWithoutASeam() throws {
        let odd = CGRect(x: 0, y: 25, width: 1441, height: 829)
        let left = try XCTUnwrap(WindowCommand.left.frames(in: odd).first)
        let right = try XCTUnwrap(WindowCommand.right.frames(in: odd).first)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.union(right), odd)
    }

    func testNextDisplayUsesMostOverlapAndKeepsRelativeTile() {
        let right = CGRect(x: 0, y: 28, width: 1920, height: 1020)
        let spanning = CGRect(x: -300, y: 100, width: 800, height: 200)
        XCTAssertEqual(WindowLayout.displayIndex(for: spanning, displays: [display, right]), 1)
        let tile = CGRect(x: -600, y: -150, width: 600, height: 450)
        XCTAssertEqual(WindowLayout.move(tile, from: display, to: right),
                       CGRect(x: 960, y: 538, width: 960, height: 510))
    }

    func testWindowHotkeysHaveDefaultsAndIndividualOverrides() throws {
        let config = try Config.decode(Data(#"{"hotkeys":{"windowManagement":{"center":"ctrl+opt+d","nextDisplay":""}}}"#.utf8))
        XCTAssertEqual(config.hotkeys.shortcut(for: .center), "ctrl+opt+d")
        XCTAssertEqual(config.hotkeys.shortcut(for: .nextDisplay), "")
        XCTAssertEqual(config.hotkeys.shortcut(for: .left), "hyper+s")
        XCTAssertEqual(try Config.decode(config.encoded()), config)
        let defaults = WindowCommand.allCases.map(\.defaultHotkey)
        XCTAssertEqual(Set(defaults).count, defaults.count)
        XCTAssertTrue(defaults.allSatisfy { HotkeySpec($0) != nil })
    }
}
