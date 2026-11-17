/// Things the island asks the app to do. The app target owns windows, so it provides these.
public struct IslandActions {
    public var openSettings: () -> Void
    public var openFullScreenPlayer: () -> Void
    public var quit: () -> Void
    /// The coffee in the tab row: keep-awake's lengths, as the same menu the pill's right-click shows.
    public var keepAwakeMenu: () -> Void

    public init(openSettings: @escaping () -> Void, openFullScreenPlayer: @escaping () -> Void = {},
                quit: @escaping () -> Void, keepAwakeMenu: @escaping () -> Void = {}) {
        self.openSettings = openSettings
        self.openFullScreenPlayer = openFullScreenPlayer
        self.quit = quit
        self.keepAwakeMenu = keepAwakeMenu
    }

    /// For previews and tests: does nothing.
    public static let none = IslandActions(openSettings: {}, quit: {})
}
