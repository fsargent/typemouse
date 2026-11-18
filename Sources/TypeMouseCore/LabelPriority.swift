import CoreGraphics

/// Decides which click targets get the shortest, easiest labels.
///
/// Vimium and Vimac hand out labels in page order. Vimium C ranks elements by click type
/// (real controls first, "weak" elements such as bare click listeners last), but uses the
/// rank only to remove duplicates. TypeMouse uses a similar rank to order labels.
public enum LabelPriority {
    public enum Tier: Int, Comparable {
        case button = 0, field, link, other, appUI, menuBar

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    static let buttonRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXSwitch",
        "AXToggle", "AXDisclosureTriangle", "AXTab", "AXSegment", "AXColorWell",
    ]
    static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles that are clickable only because something listens for clicks on them.
    /// Vimium C calls these "weak" click types.
    static let weakRoles: Set<String> = ["AXGroup", "AXImage", "AXStaticText", "AXGenericElement", "AXUnknown", "AXList"]

    public struct Candidate {
        public let frame: CGRect
        public let role: String

        public init(frame: CGRect, role: String) {
            self.frame = frame
            self.role = role
        }
    }

    /// Vimium C's duplicate removal: drop a weak target when it sits inside a button, link, or field
    /// (an icon inside a button), or when it wraps one that covers at least `coverage` of it
    /// (a card around its title link). Returns the indices to keep.
    public static func removeWeakDuplicates(_ items: [Candidate], coverage: CGFloat = 0.4) -> [Int] {
        let strong = items.indices.filter { !weakRoles.contains(items[$0].role) && isControl(items[$0].role) }
        return items.indices.filter { i in
            guard weakRoles.contains(items[i].role) else { return true }
            let weak = items[i].frame
            let area = weak.width * weak.height
            for s in strong {
                let f = items[s].frame.insetBy(dx: -1, dy: -1)
                if f.contains(weak) { return false }
                if weak.insetBy(dx: -1, dy: -1).contains(items[s].frame), area > 0,
                   items[s].frame.width * items[s].frame.height / area >= coverage { return false }
            }
            return true
        }
    }

    static func isControl(_ role: String) -> Bool {
        buttonRoles.contains(role) || fieldRoles.contains(role) || role == "AXLink"
    }

    /// - Parameters:
    ///   - inWebArea: the target is inside web content.
    ///   - appHasWebContent: some target of this scan is inside web content. Then every target
    ///     outside it is the app's own UI (a browser's tabs, toolbar, and bookmarks).
    public static func tier(role: String, inWebArea: Bool, appHasWebContent: Bool, inMenuBar: Bool) -> Tier {
        if inMenuBar { return .menuBar }
        if appHasWebContent && !inWebArea { return .appUI }
        if buttonRoles.contains(role) { return .button }
        if fieldRoles.contains(role) { return .field }
        if role == "AXLink" { return .link }
        return .other
    }
}
