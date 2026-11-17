import SwiftUI
import BrimCore

/// Right-click items for lyrics that run early or late: in the island's menu while it shows lyrics, and on the
/// full-screen lyrics. "Fix Lyrics Timing…" opens the bar under the lyrics (your pick, 2026-11-16; it replaced
/// Earlier / Later, one menu per 0.25 s); Reset shows the fix in use; another version is a different upload on
/// LRCLIB. All remembered for the song.
struct LyricsTimingMenuItems: View {
    let lyrics: LyricsStore
    let place: LyricsStore.SyncPlace

    var body: some View {
        Button("Fix Lyrics Timing…") { lyrics.startSync(in: place) }
        if lyrics.timingOffset != 0 {
            Button(Self.resetTitle(offset: lyrics.timingOffset)) { lyrics.resetTiming() }
        }
        Divider()
        versions
    }

    /// First "Find Other Versions" (asks LRCLIB), then the list: each version labelled by how it differs
    /// from the one in use, from earliest to latest (your pick, 2026-09-30).
    @ViewBuilder
    private var versions: some View {
        switch lyrics.versionSearch {
        case .idle:
            Button("Find Other Versions") { lyrics.findVersions() }
        case .unavailable:
            Button("Find Other Versions (LRCLIB didn't answer)") { lyrics.findVersions() }
        case .searching:
            Button("Looking for Other Versions…") {}.disabled(true)
        case .found(_, let count) where count < 2:
            Button("No Other Versions") {}.disabled(true)
        case .found(let current, let count):
            Menu("Versions") {
                ForEach(0..<count, id: \.self) { index in
                    Toggle(Self.versionLabel(index: index, comparison: lyrics.versionComparison(index), inUse: index == current),
                           isOn: Binding(get: { index == current }, set: { if $0 { lyrics.useVersion(index) } }))
                }
            }
        }
    }

    /// "Reset Timing (now −0.50 s)": the current fix, so you can see what you've done.
    static func resetTitle(offset: TimeInterval) -> String {
        guard offset != 0 else { return "Reset Timing" }
        return "Reset Timing (now \(offsetText(offset)))"
    }

    /// "−0.50 s", "+1.25 s", "0.00 s".
    static func offsetText(_ offset: TimeInterval) -> String {
        (offset < 0 ? "−" : offset > 0 ? "+" : "") + String(format: "%.2f s", abs(offset))
    }
}

/// The bar under the lyrics while you fix their timing (your pick, 2026-11-16). The lyrics keep playing above it:
/// click lines as they start and every line lines up (each click refines the last); − and + move them 0.25 s, live, no menu. Done closes.
struct LyricsSyncBar: View {
    let lyrics: LyricsStore
    var large = false

    var body: some View {
        HStack(spacing: large ? 12 : 8) {
            Text("Click lines as they start")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Text(LyricsTimingMenuItems.offsetText(lyrics.timingOffset))
                .monospacedDigit()
                .help("How far the lyrics are moved for this song: − is earlier")
            step("minus", by: -0.25, label: "Lyrics 0.25 s earlier")
            step("plus", by: 0.25, label: "Lyrics 0.25 s later")
            Button("Done") { lyrics.endSync() }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .padding(.horizontal, large ? 14 : 10)
                .frame(height: large ? 30 : 22)
                .background(Color.white.opacity(0.18), in: Capsule())
                .accessibilityLabel("Done fixing lyrics timing")
        }
        .font(.system(size: large ? 14 : 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.leading, large ? 16 : 12).padding(.trailing, large ? 6 : 4)
        .frame(height: large ? 42 : 30)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func step(_ symbol: String, by seconds: TimeInterval, label: String) -> some View {
        Button { lyrics.nudge(by: seconds) } label: {
            Image(systemName: symbol)
                .font(.system(size: large ? 13 : 11, weight: .bold))
                .frame(width: large ? 30 : 24, height: large ? 30 : 22)
                .background(Color.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension LyricsTimingMenuItems {

    /// "2 · 0.43 s earlier", "6 · same timing", "4 · 0.43 s earlier · some lines differ", "7 · other lyrics".
    static func versionLabel(index: Int, comparison: LRCLIBVersions.Comparison?, inUse: Bool) -> String {
        let number = "\(index + 1) · "
        if inUse { return number + "in use" }
        guard let comparison, let shift = comparison.shift, comparison.coverage >= 0.5 else { return number + "other lyrics" }
        let timing = abs(shift) < 0.05 ? "same timing" : String(format: "%.2f s ", abs(shift)) + (shift < 0 ? "earlier" : "later")
        return number + timing + (comparison.coverage < 0.9 ? " · some lines differ" : "")
    }
}
