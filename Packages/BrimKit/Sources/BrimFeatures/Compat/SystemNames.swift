/// Names of macOS places that changed between versions. Lives in Compat with the other version checks.
enum SystemNames {
    /// The Privacy & Security list that grants key access. macOS 27 renamed "Accessibility"
    /// (verified on 26A428: the pane's string for key ACCESSIBILITY is "Device Control and Data Access").
    static var keyAccessPane: String {
        if #available(macOS 27, *) {
            "Device Control and Data Access"
        } else {
            "Accessibility"
        }
    }
}
