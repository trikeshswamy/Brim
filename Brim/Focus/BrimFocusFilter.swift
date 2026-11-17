import AppIntents
import BrimCore
import BrimFeatures

/// Brim's Focus filter (feature 2, your picks 2026-10-02). In System Settings → Focus, choose a Focus → Focus filters →
/// Add filter → Brim, and pick the island and the notices for that Focus. macOS tells Brim when that Focus turns on or
/// off: Apple's own mechanism, no Shortcuts, no polling. Apple never tells apps a Focus's name; these choices stand in.
struct BrimFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Brim"
    static let description: IntentDescription? = IntentDescription("How Brim's island behaves during this Focus.")

    @Parameter(title: "Island")
    var island: FocusIslandChoice?

    @Parameter(title: "Notices")
    var notices: FocusNoticesChoice?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Island: \(island?.label ?? "as usual")",
                              subtitle: "Notices: \(notices?.label ?? "all")")
    }

    func perform() async throws -> some IntentResult {
        let island = island
        let notices = notices
        await MainActor.run { FocusFilterBridge.apply(island: island, notices: notices) }
        return .result()
    }
}

nonisolated enum FocusIslandChoice: String, AppEnum {
    case pill, slimLine, hidden

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Island"
    static let caseDisplayRepresentations: [FocusIslandChoice: DisplayRepresentation] = [
        .pill: "Pill",
        .slimLine: "Slim line",
        .hidden: "Hidden",
    ]

    var label: String {
        switch self {
        case .pill: "Pill"
        case .slimLine: "Slim line"
        case .hidden: "Hidden"
        }
    }
}

nonisolated enum FocusNoticesChoice: String, AppEnum {
    case all, importantOnly

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Notices"
    static let caseDisplayRepresentations: [FocusNoticesChoice: DisplayRepresentation] = [
        .all: "All",
        .importantOnly: "Important only",
    ]

    var label: String {
        switch self {
        case .all: "All"
        case .importantOnly: "Important only"
        }
    }
}

/// Hands the filter's choices to the island. Set up at launch, where it also reads the Focus already on (macOS tells
/// Brim only of changes).
enum FocusFilterBridge {
    static weak var island: IslandCoordinator?

    static func apply(island choice: FocusIslandChoice?, notices: FocusNoticesChoice?) {
        island?.setFocusFilter(island: choice.flatMap { FocusIsland(rawValue: $0.rawValue) },
                               importantOnly: notices == .importantOnly)
    }

    static func syncCurrent() async {
        guard let current = try? await BrimFocusFilter.current else { return }
        apply(island: current.island, notices: current.notices)
    }
}
