import SwiftUI
import BrimCore

/// The open island's tabs, icons only, at the top (your picks, 2026-09-30): Music · Timers · Calendar.
/// The row sits above the page, so it never covers the lyrics or the island's content. The highlight slides
/// to the tab you pick; hovering a tab names it.
struct TabBar: View {
    let selected: ExpandedPage
    let onSelect: (ExpandedPage) -> Void
    /// Keep-awake at the end of the row (not a tab): lit while it's on; nil hides it.
    var keepAwake: Bool?
    /// Its hover text: "Keeping your Mac awake until 15:45".
    var keepAwakeHelp = ""
    /// Opens the lengths menu (10 min … Until I stop it, Turn Off).
    var onKeepAwake: () -> Void = {}
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            tab(.music, symbol: "music.note", name: "Music")
            tab(.timers, symbol: "timer", name: "Timers")
            tab(.calendar, symbol: "calendar", name: "Calendar")
            if let keepAwake {
                Divider().frame(height: 12).padding(.horizontal, 2)
                Button(action: onKeepAwake) {
                    Image(systemName: keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(keepAwake ? Color.orange : Color.secondary)
                        .frame(width: 30, height: 18)
                        .background(keepAwake ? Color.orange.opacity(0.2) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(keepAwake ? keepAwakeHelp : "Keep your Mac awake…")
                .accessibilityLabel("Keep Mac awake")
                .accessibilityValue(keepAwake ? keepAwakeHelp : "Off")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func tab(_ page: ExpandedPage, symbol: String, name: String) -> some View {
        Button { onSelect(page) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(page == selected ? (page == .timers ? Color.orange : Color.primary) : Color.secondary)
                .frame(width: 34, height: 18)
                .background {
                    if page == selected {
                        Capsule()
                            .fill(Color.primary.opacity(0.14))
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(page == selected ? .isSelected : [])
    }
}
