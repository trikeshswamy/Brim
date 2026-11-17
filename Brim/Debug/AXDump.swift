#if DEBUG
import AppKit

/// Debug-only: what VoiceOver would read in Brim's windows (the VoiceOver pass, 2026-11-17). Walks each window's
/// accessibility tree from inside the app (no Accessibility permission needed) and writes one line per element:
/// role, then what it's called. Buttons, images and controls with nothing to read are marked "⚠ NO NAME".
enum AXDump {
    /// SwiftUI builds a window's accessibility tree only once something asks for it: ask, then dump a moment later.
    static func warm(_ windows: [NSWindow]) {
        windows.forEach { _ = $0.contentView?.accessibilityChildren() }
    }

    static func text(for windows: [NSWindow]) -> String {
        var lines: [String] = []
        var unnamed = 0
        for window in windows {
            lines.append("=== \(window.title.isEmpty ? String(describing: type(of: window)) : window.title) visible=\(window.isVisible) frame=\(window.frame)")
            if let content = window.contentView { walk(content, depth: 0, into: &lines, unnamed: &unnamed) }
        }
        lines.append("--- \(unnamed) element(s) with no name")
        return lines.joined(separator: "\n") + "\n"
    }

    private static let needsName: Set<NSAccessibility.Role> = [.button, .image, .checkBox, .radioButton, .slider,
                                                                .popUpButton, .menuButton, .textField, .link]

    private static func walk(_ element: Any, depth: Int, into lines: inout [String], unnamed: inout Int) {
        guard depth < 40, let object = element as? NSObject else { return }
        // Plain Objective-C lookups: these are optional parts of NSAccessibility, and Swift's view of them varies.
        func get(_ key: String, _ selector: String) -> Any? {
            object.responds(to: Selector(selector)) ? object.value(forKey: key) : nil
        }
        let isElement = (get("accessibilityElement", "isAccessibilityElement") as? Bool) ?? false
        if isElement, let roleText = get("accessibilityRole", "accessibilityRole") as? String {
            let role = NSAccessibility.Role(rawValue: roleText)
            let label = get("accessibilityLabel", "accessibilityLabel") as? String ?? ""
            let title = get("accessibilityTitle", "accessibilityTitle") as? String ?? ""
            let value = get("accessibilityValue", "accessibilityValue").map { "\($0)" } ?? ""
            let help = get("accessibilityHelp", "accessibilityHelp") as? String ?? ""
            // What VoiceOver also reads: a linked title (a Form's label beside its switch), the placeholder, and for
            // macOS's own window and scroll buttons their kind (close, minimize, …).
            let linked = (get("accessibilityTitleUIElement", "accessibilityTitleUIElement") as? NSObject)
                .flatMap { $0.responds(to: Selector(("accessibilityValue"))) ? $0.value(forKey: "accessibilityValue") as? String : nil } ?? ""
            let placeholder = get("accessibilityPlaceholderValue", "accessibilityPlaceholderValue") as? String ?? ""
            let subrole = get("accessibilitySubrole", "accessibilitySubrole") as? String ?? ""
            let system = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXIncrementArrow",
                          "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"].contains(subrole) ? subrole : ""
            let name = [label, title, linked, placeholder, system].first { !$0.isEmpty } ?? ""
            var line = String(repeating: "  ", count: min(depth, 12)) + roleText.replacingOccurrences(of: "AX", with: "")
            if !name.isEmpty { line += " “\(name)”" }
            if !value.isEmpty, value != name, value.count < 80 { line += " = \(value)" }
            if !help.isEmpty, help != name { line += " (help: \(help))" }
            if name.isEmpty, needsName.contains(role) { line += "  ⚠ NO NAME"; unnamed += 1 }
            if role != .group || !name.isEmpty { lines.append(line) }
        }
        var children = get("accessibilityChildren", "accessibilityChildren") as? [Any] ?? []
        if children.isEmpty, let window = object as? NSWindow, let content = window.contentView { children = [content] }
        for child in children {
            walk(child, depth: depth + 1, into: &lines, unnamed: &unnamed)
        }
    }
}
#endif
