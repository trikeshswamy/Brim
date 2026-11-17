/// Which HUD is showing.
public enum HUDKind: Equatable, Sendable {
    case volume
    case brightness
}

/// PRD F4: two looks for the same HUD.
public enum HUDStyle: String, Equatable, Sendable, CaseIterable {
    /// The island grows below the menu bar with a larger bar and the output device name.
    case standard = "default"
    /// Icon + thin bar inside the pill-sized island.
    case inline

    public var title: String {
        switch self {
        case .standard: "Default"
        case .inline: "Inline"
        }
    }
}
