import AppKit
import ApplicationServices
import TypeMouseCore

/// A clickable thing on screen.
struct Target {
    let element: AXUIElement
    /// Visible part of the element, in AX (top-left origin) coordinates.
    let frame: CGRect
    let role: String
    let subrole: String?
    var text: String
    let inWebArea: Bool
    let depth: Int
    /// Menu-bar items get the longest labels, so window content gets the short ones.
    var inMenuBar = false

    var isTextInput: Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
}

/// Walks the accessibility tree of the frontmost app and returns clickable targets.
final class ElementProvider {
    struct Result {
        var targets: [Target]
        var visited: Int
        var duration: TimeInterval
        var menuOpen: Bool
    }

    /// Roles that are clickable by definition. We skip the extra action-names IPC for these.
    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXDisclosureTriangle", "AXColorWell", "AXDockItem", "AXTab", "AXSegment", "AXSwitch",
        "AXToggle",
    ]

    /// Containers and decoration: never targets themselves, so do not ask for their actions.
    static let structuralRoles: Set<String> = [
        "AXWindow", "AXSheet", "AXDrawer", "AXScrollArea", "AXSplitGroup", "AXSplitter",
        "AXLayoutArea", "AXLayoutItem", "AXToolbar", "AXTabGroup", "AXMenuBar", "AXMenu",
        "AXList", "AXTable", "AXOutline", "AXBrowser", "AXColumn", "AXWebArea", "AXGrowArea",
        "AXScrollBar", "AXValueIndicator", "AXStaticText", "AXHeading", "AXUnknown", "AXRuler",
        "AXRulerMarker", "AXMatte", "AXLevelIndicator", "AXProgressIndicator", "AXBusyIndicator",
        "AXRelevanceIndicator", "AXGrid", "AXApplication", "AXHelpTag", "AXPopover",
    ]

    /// Leaves we never descend into. Their children are labels and images, not new targets.
    static let leafRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXTextField",
        "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider", "AXStaticText", "AXScrollBar",
        "AXDisclosureTriangle", "AXColorWell", "AXIncrementor", "AXImage", "AXValueIndicator",
    ]

    static let baseAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXChildrenAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute,
    ]

    static let webSearchKeys = [
        "AXButtonSearchKey", "AXCheckBoxSearchKey", "AXControlSearchKey", "AXGraphicSearchKey",
        "AXLinkSearchKey", "AXRadioGroupSearchKey", "AXTextFieldSearchKey",
    ]

    let maxTargets = 4000
    let maxDepth = 60

    private let lock = NSLock()
    private var found: [Target] = []
    private var visited = 0

    func collect(app: NSRunningApplication, config: Config) -> Result {
        let start = Date()
        let enhanced = config.enhancedUserInterfaceApps.contains(app.bundleIdentifier ?? "")
        AccessibilityActivator.activate(app, enhanced: enhanced)
        var result = scan(app: app, start: start)
        guard enhanced, !result.targets.contains(where: \.inWebArea) else { return result }

        // The browser builds its page tree in the background after the flag turns on, and the flag
        // can read as on before the tree exists. The tree also fills in over several scans, so stop
        // when the page target count stops growing, or after 2 s.
        var lastWebCount = 0
        while Date().timeIntervalSince(start) < 2 {
            usleep(150_000)
            AccessibilityActivator.activate(app, enhanced: true)
            result = scan(app: app, start: start)
            let webCount = result.targets.filter(\.inWebArea).count
            if webCount > 0 && webCount == lastWebCount { break }
            lastWebCount = webCount
        }
        Log.info(String(format: "waited for page tree in %@: %d page targets after %.0f ms", app.localizedName ?? "?",
                        lastWebCount, Date().timeIntervalSince(start) * 1000))
        return result
    }

    private func scan(app: NSRunningApplication, start: Date) -> Result {
        found = []
        visited = 0

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let desktop = AX.desktopBounds()

        // If a menu is open, the user wants its items and nothing else.
        let menus = openMenus(appEl)
        if !menus.isEmpty {
            parallel(menus) { self.visit($0, clip: desktop, depth: 0, inWeb: false) }
            return finish(start: start, menuOpen: true)
        }

        var roots: [(AXUIElement, CGRect)] = []
        var menuBarItems: [AXUIElement] = []
        if let win = appEl.element(kAXFocusedWindowAttribute) ?? appEl.element(kAXMainWindowAttribute),
           let wf = win.frame {
            roots.append((win, wf.intersection(desktop)))
        }
        if let bar = appEl.element(kAXMenuBarAttribute) {
            menuBarItems = bar.elements(kAXChildrenAttribute)
        }
        parallel(roots) { self.visit($0.0, clip: $0.1, depth: 0, inWeb: false) }
        let windowCount = count()
        // Menu-bar items are leaves here (their menus are closed), so one visit each is enough.
        for item in menuBarItems { visit(item, clip: desktop, depth: 0, inWeb: false) }
        lock.lock()
        for i in windowCount..<found.count { found[i].inMenuBar = true }
        lock.unlock()
        return finish(start: start, menuOpen: false)
    }

    /// Search mode needs text for elements that have no title. This costs extra IPC, so it runs only then.
    static func resolveText(_ targets: inout [Target]) {
        let snapshot = targets
        var texts = [String](repeating: "", count: snapshot.count)
        texts.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: snapshot.count) { i in
                buf[i] = fallbackText(snapshot[i])
            }
        }
        for i in targets.indices where targets[i].text.isEmpty { targets[i].text = texts[i] }
    }

    private static func fallbackText(_ t: Target) -> String {
        guard t.text.isEmpty else { return t.text }
        let v = t.element.values([kAXValueAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXChildrenAttribute])
        var text = ""
        if let s = v[kAXValueAttribute] as? String, s.count < 200 { text = s }
        if text.isEmpty, let s = v[kAXPlaceholderValueAttribute] as? String { text = s }
        if text.isEmpty, let s = v[kAXHelpAttribute] as? String { text = s }
        if text.isEmpty, let kids = v[kAXChildrenAttribute] as? [AXUIElement] {
            text = kids.prefix(5).compactMap { k -> String? in
                let kv = k.values([kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
                return (kv[kAXValueAttribute] as? String) ?? (kv[kAXTitleAttribute] as? String) ?? (kv[kAXDescriptionAttribute] as? String)
            }.joined(separator: " ")
        }
        return text
    }

    // MARK: - Traversal

    private func openMenus(_ appEl: AXUIElement) -> [AXUIElement] {
        var menus = appEl.elements(kAXChildrenAttribute).filter { $0.string(kAXRoleAttribute) == "AXMenu" }
        if let bar = appEl.element(kAXMenuBarAttribute) {
            for item in bar.elements(kAXChildrenAttribute) where item.bool(kAXSelectedAttribute) == true {
                menus += item.elements(kAXChildrenAttribute).filter { $0.string(kAXRoleAttribute) == "AXMenu" }
            }
        }
        return menus
    }

    private func visit(_ el: AXUIElement, clip: CGRect, depth: Int, inWeb: Bool) {
        guard depth < maxDepth, count() < maxTargets else { return }
        let v = el.values(Self.baseAttributes)
        bump()
        guard let role = v[kAXRoleAttribute] as? String else { return }
        let frame = AX.frame(position: v[kAXPositionAttribute], size: v[kAXSizeAttribute])

        // Prune anything outside the visible area. Elements with no frame (some groups) pass through.
        var childClip = clip
        if let frame {
            let visible = frame.intersection(clip)
            if visible.isNull || visible.width < 1 || visible.height < 1 { return }
            if !Self.passThroughRoles.contains(role) { childClip = visible }
            consider(el, role: role, values: v, visible: visible, depth: depth, inWeb: inWeb)
        }

        // An empty answer is common for pages built from iframes. Walk the tree instead.
        if role == "AXWebArea", let results = webTargets(el), !results.isEmpty {
            parallel(results) { self.visitWebResult($0, clip: childClip, depth: depth + 1) }
            return
        }
        if Self.leafRoles.contains(role) { return }

        let children: [AXUIElement]
        if role == "AXTable" || role == "AXOutline" {
            children = el.elements(kAXVisibleRowsAttribute)
        } else {
            children = (v[kAXChildrenAttribute] as? [AXUIElement]) ?? []
        }
        // Fan out near the root, where subtrees are big. Deeper down, threads cost more than they save.
        if depth < 6 && children.count > 1 {
            parallel(children) { self.visit($0, clip: childClip, depth: depth + 1, inWeb: inWeb || role == "AXWebArea") }
        } else {
            for c in children { visit(c, clip: childClip, depth: depth + 1, inWeb: inWeb || role == "AXWebArea") }
        }
    }

    /// Groups whose frame can be smaller than their visible children (for example, zero-size wrappers).
    static let passThroughRoles: Set<String> = ["AXGroup", "AXMenuBarItem", "AXMenuItem"]

    private func consider(_ el: AXUIElement, role: String, values v: [String: AnyObject], visible: CGRect, depth: Int, inWeb: Bool) {
        guard visible.width >= 3, visible.height >= 3 else { return }
        if (v[kAXEnabledAttribute] as? NSNumber)?.boolValue == false { return }
        if Self.structuralRoles.contains(role) { return }

        var clickable = Self.clickableRoles.contains(role)
        if !clickable && role == "AXRow" { clickable = true } // table and outline rows select on click
        if !clickable {
            let actions = el.actionNames()
            clickable = actions.contains(kAXPressAction) || actions.contains("AXOpen")
        }
        guard clickable else { return }

        let text = (v[kAXTitleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (v[kAXDescriptionAttribute] as? String) ?? ""
        add(Target(element: el, frame: visible, role: role, subrole: v[kAXSubroleAttribute] as? String,
                   text: text, inWebArea: inWeb, depth: depth))
    }

    /// Asks the web engine for its controls in one call instead of walking a huge DOM tree.
    /// WebKit takes several search keys at once. Older Chromium takes one key per call.
    private func webTargets(_ webArea: AXUIElement) -> [AXUIElement]? {
        guard webArea.parameterizedAttributeNames().contains("AXUIElementsForSearchPredicate") else { return nil }
        let base: [String: Any] = [
            "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false,
            "AXResultsLimit": -1,
            "AXVisibleOnly": true,
        ]
        var multi = base
        multi["AXSearchKey"] = Self.webSearchKeys
        if let all = webArea.parameterized("AXUIElementsForSearchPredicate", multi as CFDictionary) as? [AXUIElement], !all.isEmpty {
            return all
        }
        var seen = Set<AXUIElement>()
        var out: [AXUIElement] = []
        for key in Self.webSearchKeys {
            var q = base
            q["AXSearchKey"] = key
            let hits = (webArea.parameterized("AXUIElementsForSearchPredicate", q as CFDictionary) as? [AXUIElement]) ?? []
            for h in hits where seen.insert(h).inserted { out.append(h) }
        }
        return out
    }

    private func visitWebResult(_ el: AXUIElement, clip: CGRect, depth: Int) {
        let v = el.values(Self.baseAttributes)
        bump()
        guard let role = v[kAXRoleAttribute] as? String,
              let frame = AX.frame(position: v[kAXPositionAttribute], size: v[kAXSizeAttribute]) else { return }
        let visible = frame.intersection(clip)
        guard !visible.isNull, visible.width >= 3, visible.height >= 3 else { return }
        if (v[kAXEnabledAttribute] as? NSNumber)?.boolValue == false { return }
        // Search keys already selected controls, so no action check here.
        if role == "AXWebArea" || role == "AXStaticText" { return }
        let text = (v[kAXTitleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (v[kAXDescriptionAttribute] as? String) ?? ""
        add(Target(element: el, frame: visible, role: role, subrole: v[kAXSubroleAttribute] as? String,
                   text: text, inWebArea: true, depth: depth))
    }

    // MARK: - Results

    private func finish(start: Date, menuOpen: Bool) -> Result {
        let targets = Self.dedupe(found).sorted {
            $0.inMenuBar != $1.inMenuBar ? !$0.inMenuBar : Geometry.readingOrder($0.frame, $1.frame)
        }
        return Result(targets: targets, visited: visited, duration: Date().timeIntervalSince(start), menuOpen: menuOpen)
    }

    /// A group and the button inside it often share a frame. Keep the deepest one.
    static func dedupe(_ targets: [Target]) -> [Target] {
        var kept: [Target] = []
        for t in targets.sorted(by: { $0.depth > $1.depth }) {
            if !kept.contains(where: { Geometry.nearlyEqual($0.frame, t.frame) }) { kept.append(t) }
        }
        return kept
    }

    private func parallel<T>(_ items: [T], _ body: (T) -> Void) {
        if items.count == 1 { body(items[0]); return }
        DispatchQueue.concurrentPerform(iterations: items.count) { body(items[$0]) }
    }

    private func add(_ t: Target) { lock.lock(); found.append(t); lock.unlock() }
    private func bump() { lock.lock(); visited += 1; lock.unlock() }
    private func count() -> Int { lock.lock(); defer { lock.unlock() }; return found.count }
}
