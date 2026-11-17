import AppKit
import SwiftUI
import BrimCore

/// Brim's HUD for volume and brightness: as wide as the pill, 6 pt taller, so the pill grows into it (PRD §7.3).
/// - Default: the whole island is the slider, like your iPhone's turned sideways (your pick, 2026-09-29), at the
///   pill's own size (2026-09-30). In Black it fills the floating capsule edge to edge: no black rim (your note).
/// - Inline: icon + thin bar inside the pill.
struct LevelHUDView: View {
    let level: Double
    let dimmed: Bool
    let symbol: String
    let label: String?
    let style: HUDStyle
    let appearance: IslandAppearance
    let spokenText: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch style {
            case .standard:
                if appearance.isSolidBlack {
                    FillBar(level: level, dimmed: dimmed, symbol: symbol, label: label, track: .white.opacity(0.18))
                } else {
                    // Darker in Light Mode, so the track still reads as the iPhone's dark glass.
                    FillBar(level: level, dimmed: dimmed, symbol: symbol, label: label,
                            track: .black.opacity(colorScheme == .dark ? 0.28 : 0.45))
                }
            case .inline:
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 20)
                    LevelBar(level: level, dimmed: dimmed, height: 4)
                }
                .padding(.horizontal, 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }
}

extension LevelHUDView {
    init(volume: VolumeState, style: HUDStyle, appearance: IslandAppearance) {
        // The output's icon, not its name (your pick, 2026-10-01: "OnePlus N…" got cut off).
        self.init(level: volume.level, dimmed: volume.isMuted, symbol: volume.hudSymbol, label: nil,
                  style: style, appearance: appearance,
                  spokenText: volume.isMuted ? "Volume muted" : "Volume \(Int((volume.level * 100).rounded())) percent")
    }

    /// The music app's own volume (⌃ + a volume key): a note instead of the speaker, so it reads as "only the music".
    init(appVolume level: Double, app: String?, style: HUDStyle, appearance: IslandAppearance) {
        self.init(level: level, dimmed: false, symbol: level <= 0.001 ? "speaker.slash.fill" : "music.note", label: app,
                  style: style, appearance: appearance,
                  spokenText: "\(app ?? "Music") volume \(Int((level * 100).rounded())) percent")
    }

    init(brightness: BrightnessState, style: HUDStyle, appearance: IslandAppearance) {
        self.init(level: brightness.level, dimmed: false, symbol: brightness.symbolName, label: nil,
                  style: style, appearance: appearance,
                  spokenText: "Brightness \(Int((brightness.level * 100).rounded())) percent")
    }
}

/// Your iPhone's slider, sideways: a white fill grows from the left over a dark glass track, with round ends.
/// Where the fill covers the icon and label, they turn dark (a mask), so they stay readable at any level.
struct FillBar: View {
    let level: Double
    let dimmed: Bool
    let symbol: String
    let label: String?
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * min(max(level, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle()
                    .fill(Color.white.opacity(dimmed ? 0.4 : 0.97))
                    .frame(width: fillWidth)
                content(color: .white)
                content(color: Color(white: 0.28))
                    .mask(alignment: .leading) { Rectangle().frame(width: fillWidth) }
            }
            .animation(.spring(duration: 0.25, bounce: 0.1), value: level)
        }
        .clipShape(Capsule())
    }

    private func content(color: Color) -> some View {
        HStack {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))  // one size up for the 36 pt HUD
                .contentTransition(.symbolEffect(.replace))
            Spacer(minLength: 8)
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
    }
}

/// Icon + thin bar, used by the Inline style.
struct LevelBar: View {
    let level: Double
    let dimmed: Bool
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                Capsule().fill(Color.primary.opacity(dimmed ? 0.35 : 1))
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
