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
