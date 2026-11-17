import AppKit

/// Runs a closure from a menu item: the pill's right-click menu is built fresh each time, from what's true now.
/// (A target object, not an NSMenuItem subclass: Swift 6 won't let a main-actor subclass override AppKit's
/// nonisolated initializers.)
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

extension NSMenuItem {
    /// A menu item that runs `handler`. The item keeps its action alive (a menu item's target is weak).
    static func closure(_ title: String, enabled: Bool = true, checked: Bool = false,
                        _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        return item
    }
}
