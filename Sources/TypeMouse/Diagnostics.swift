import AppKit
import TypeMouseCore

/// Command-line diagnostics, so problems in a specific app can be seen and measured.
enum Diagnostics {
    static func dump(_ args: [String]) -> Int32 {
        Log.echo = true
        guard AX.isTrusted(prompt: false) else {
            print("No Accessibility permission for this process (or the terminal that started it).")
            return 1
        }
        AX.setGlobalTimeout(0.25)
        let app: NSRunningApplication?
        if let i = args.firstIndex(of: "--app"), i + 1 < args.count {
            let name = args[i + 1].lowercased()
            app = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.lowercased() == name || $0.bundleIdentifier?.lowercased() == name
            } ?? NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.lowercased().contains(name) == true
            }
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else { print("app not found"); return 1 }

        let config = ConfigStore.load()
        if args.contains("--webareas") { webAreas(app); return 0 }
        if args.contains("--disable-enhanced") {
            // Test aid: simulates another tool turning the flag off.
            AXUIElementCreateApplication(app.processIdentifier).set("AXEnhancedUserInterface", kCFBooleanFalse)
            print("AXEnhancedUserInterface turned off")
            return 0
        }
        var result = ElementProvider().collect(app: app, config: config)
        // A second scan shows the warm time (Chromium and Electron build their tree on the first request).
        let warm = ElementProvider().collect(app: app, config: config)
        ElementProvider.resolveText(&result.targets)
        let labels = Hints.generate(count: result.targets.count, alphabet: config.hintAlphabet)
        for (t, l) in zip(result.targets, labels) {
            let f = t.frame
            print(String(format: "%-4@ %-16@ %5.0f,%-5.0f %4.0fx%-4.0f %@ %@", l, t.role, f.minX, f.minY, f.width, f.height,
                         t.inWebArea ? "web" : "   ", String(t.text.prefix(60)) as NSString))
        }
        print(String(format: "\n%@: %d targets, %d elements visited. first scan %.0f ms, second scan %.0f ms (%d targets)%@",
                     app.localizedName ?? "?", result.targets.count, result.visited, result.duration * 1000,
                     warm.duration * 1000, warm.targets.count, result.menuOpen ? ", menu open" : ""))
        return 0
    }

    /// Shows the accessibility flags and every web area in the focused window, to debug empty pages.
    private static func webAreas(_ app: NSRunningApplication) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        print("AXEnhancedUserInterface:", appEl.value("AXEnhancedUserInterface") ?? "nil" as NSString)
        print("AXManualAccessibility:", appEl.value("AXManualAccessibility") ?? "nil" as NSString)
        guard let win = appEl.element(kAXFocusedWindowAttribute) else { print("no focused window"); return }
        print("window:", win.string(kAXTitleAttribute) ?? "", win.frame.map { "\($0)" } ?? "no frame")
        var found = 0
        func walk(_ el: AXUIElement, _ depth: Int, _ path: String) {
            guard depth < 40 else { return }
            let v = el.values([kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute])
            let role = v[kAXRoleAttribute] as? String ?? "?"
            let kids = (v[kAXChildrenAttribute] as? [AXUIElement]) ?? []
            if role == "AXWebArea" {
                found += 1
                let frame = AX.frame(position: v[kAXPositionAttribute], size: v[kAXSizeAttribute])
                let params = el.parameterizedAttributeNames().contains("AXUIElementsForSearchPredicate")
                print("AXWebArea depth \(depth) frame \(frame.map { "\($0)" } ?? "nil") children \(kids.count) searchPredicate \(params)")
                print("  path:", path)
                for visibleOnly in [true, false] {
                    var q: [String: Any] = ["AXDirection": "AXDirectionNext", "AXImmediateDescendantsOnly": false,
                                            "AXResultsLimit": -1, "AXVisibleOnly": visibleOnly]
                    q["AXSearchKey"] = ElementProvider.webSearchKeys
                    let multi = el.parameterized("AXUIElementsForSearchPredicate", q as CFDictionary)
                    print("  multi-key visibleOnly=\(visibleOnly):", (multi as? [AXUIElement])?.count.description ?? "nil (\(String(describing: multi)))")
                    for key in ["AXLinkSearchKey", "AXButtonSearchKey", "AXAnyTypeSearchKey"] {
                        q["AXSearchKey"] = key
                        let r = el.parameterized("AXUIElementsForSearchPredicate", q as CFDictionary) as? [AXUIElement]
                        print("    \(key):", r?.count.description ?? "nil")
                    }
                }
            }
            for k in kids { walk(k, depth + 1, path + "/" + role) }
        }
        walk(win, 0, "")
        print("web areas:", found)
    }

    static func windows() -> Int32 {
        guard AX.isTrusted(prompt: false) else {
            print("No Accessibility permission for this process (or the terminal that started it).")
            return 1
        }
        AX.setGlobalTimeout(0.25)
        let start = Date()
        let list = WindowProvider.shared.list()
        let elapsed = Date().timeIntervalSince(start)
        let config = ConfigStore.load()
        var order: [String] = []
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for w in list {
            if counts[w.appID] == nil { order.append(w.appID) }
            counts[w.appID, default: 0] += 1
            names[w.appID] = w.appName
        }
        let labels = WindowLabeler.assign(apps: order.map { .init(id: $0, name: names[$0]!, windowCount: counts[$0]!) },
                                          pins: config.pins, suffixAlphabet: config.hintAlphabet)
        var used: [String: Int] = [:]
        for w in list {
            let n = used[w.appID, default: 0]
            used[w.appID] = n + 1
            let label = labels[w.appID].flatMap { $0.indices.contains(n) ? $0[n] : nil } ?? "-"
            print("\(label.padding(toLength: 4, withPad: " ", startingAt: 0)) \(w.appName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(w.title)\(w.minimized ? "  (minimized)" : "")  [\(w.id.map(String.init) ?? "?")]")
        }
        print(String(format: "\n%d windows in %.0f ms", list.count, elapsed * 1000))
        return 0
    }
}
