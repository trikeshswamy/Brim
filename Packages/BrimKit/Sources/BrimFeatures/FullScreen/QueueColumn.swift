import SwiftUI
import BrimCore

/// The queue on the right of the full-screen player, in place of the lyrics (your picks, 2026-10-29): what plays next,
/// from the playing app; a click plays a song now. Where an app can't share its queue, it says so plainly.
struct QueueColumn: View {
    let queue: QueueStore
    let nowPlaying: NowPlayingStore
    var history: HistoryStore?
    /// The player's Shuffle and Repeat: changing either changes what plays next, so the list is read again.
    var modes: PlayerModes?
    @State private var hovered: String?
    @State private var viewport: CGFloat = 0
    /// Where the titles are in the visible scroll (nil until laid out: History then shows, so the column is never blank).
    @State private var upNextTop: CGFloat?
    @State private var historyTop: CGFloat?
    @State private var historyTitleHeight: CGFloat = 0
    @State private var upNextTitleHeight: CGFloat = 0
    /// Where Up Next's title starts in the whole list: the list opens scrolled exactly there.
    @State private var upNextY: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// Your fingers are on the trackpad: only then does History's reveal tick (not when a song change moves the list).
    @State private var scrolling = false

    /// History above Up Next in one scroll, like Apple Music's (your video, 2026-10-29): it opens at Up Next, and
    /// scrolling up from anywhere shows History; each title stays at the top while its songs scroll under it.
    ///
    /// A plain stack, laid out whole (at most 50 + 25 rows), so its height is always known. The lazy list it replaces
    /// estimated the part it hadn't laid out yet; with a long History, the jump to Up Next fell short and stopped in
    /// History (your videos, 2026-10-29). Titles stick at the top by a copy laid over the list.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !pastSongs.isEmpty {
                    historyTitle
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .scrollView).minY }) { historyTop = $0 }
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { historyTitleHeight = $0 }
                        .opacity((historyTop ?? 0) < 0 ? 0 : 1)  // the stuck copy shows instead
                    ForEach(pastSongs) { entry in historyRow(entry, last: entry.id == pastSongs.last?.id) }
                    Color.clear.frame(height: 16)  // room before Up Next
                }
                upNextTitle
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .scrollView).minY }) { upNextTop = $0 }
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.list)).minY }) { upNextY = $0 }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { upNextTitleHeight = $0 }
                    .opacity((upNextTop ?? 0) < 0 ? 0 : 1)
                content
                    // Tall enough that Up Next can always sit at the top, with History above it out of view.
                    .frame(minHeight: max(viewport - upNextTitleHeight - 10, 0), alignment: .top)
            }
            .coordinateSpace(.named(Self.list))
            .padding(.bottom, 8)
        }
        .scrollPosition($position)
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewport = $0 }
        .onScrollPhaseChange { _, phase in scrolling = phase == .interacting }
        // A light trackpad tick as History comes into view (your ask, 2026-10-29). Force Touch trackpads only.
        .onChange(of: historyShown) { _, shown in
            if shown, scrolling { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        // Fades where the list meets the bottom edge, instead of a hard cut.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92),
                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { stuckTitle }
        // Opens at Up Next, and goes back there when the song changes (it just joined History above).
        .task(id: ScrollTarget(song: nowPlaying.item?.identity, offset: upNextY)) {
            guard !scrolling else { return }  // never under your fingers
            try? await Task.sleep(for: .milliseconds(30))
            position.scrollTo(y: upNextY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // After Shuffle or Repeat changes (your reports, 2026-10-29: the list took 5–10 s to follow): read at 0.4 s
        // and again at 1.2 s, as Spotify takes a moment to rebuild its queue.
        .task(id: ModesKey(shuffle: modes?.shuffle, repeatMode: modes?.repeatMode)) {
            guard modes != nil else { return }
            for wait in [Duration.milliseconds(400), .milliseconds(800)] {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                await queue.refresh()
            }
        }
        // As it opens, when the song changes, and every 15 s while it shows: nothing is asked when it's hidden.
        .task(id: nowPlaying.item?.identity) {
            await queue.refresh()
            // Once more after 2 s: right after a song changes, the app may not have moved on yet.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await queue.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private static let list = "queueList"

    private var historyTitle: some View {
        header("History", rule: true) {
            Button("Clear") { history?.clear(app: app) }
                .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Color(red: 1, green: 0.36, blue: 0.4))
                .accessibilityLabel("Clear History")
        }
        .opacity(historyShown ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: historyShown)
    }

    private var upNextTitle: some View {
        header("Up Next", subtitle: source.map { "From \($0)" }) { EmptyView() }
    }

    /// The title stuck at the top: Up Next's once it reaches the top; History's while you're in History, pushed up
    /// by Up Next's as it arrives.
    @ViewBuilder
    private var stuckTitle: some View {
        if let top = upNextTop, top < 0 {
            upNextTitle
        } else if historyShown, let top = historyTop, top < 0 {
            historyTitle.offset(y: min(0, (upNextTop ?? .infinity) - historyTitleHeight))
        }
    }

    /// History follows the app that's playing: Apple Music's while it plays, Spotify's while it does.
    private var app: String? { nowPlaying.item?.sourceBundleIdentifier }
    private var pastSongs: [HistoryEntry] { history?.entries(for: app) ?? [] }
    /// History shows only once you pull the list down: Up Next's title is more than 24 pt below the top.
    private var historyShown: Bool { (upNextTop ?? .infinity) > 24 }

    private struct ModesKey: Equatable {
        let shuffle: Bool?
        let repeatMode: RepeatMode?
    }

    private struct ScrollTarget: Equatable {
        let song: TrackIdentity?
        let offset: CGFloat
    }

    private func header<Trailing: View>(_ title: String, subtitle: String? = nil, rule: Bool = false,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 22, weight: .bold))
                Spacer()
                trailing()
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // History's title has a line under it, like Apple Music's (your pick, 2026-10-29).
        .overlay(alignment: .bottom) { if rule { Self.hairline } }
        // Songs scroll under the pinned title: a frosted strip keeps it readable.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static var hairline: some View { Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5) }

    private var source: String? {
        switch queue.queue {
        case .items(let source, _), .shuffled(let source): source
        default: nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch queue.queue {
        case .loading:
            ProgressView().controlSize(.small).padding(.top, 8)
        case .items(_, let items):
            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                    row(item, position: position)
                }
            }
        case .shuffled:
            message("Shuffle is on: Apple Music doesn't share the shuffled order.")
        case .musicLibraryOnly:
            message("Apple Music shares what's next only when you play from your Library or a playlist.")
        case .spotifyNotConnected:
            message("Spotify's queue needs Spotify Premium: connect it in Settings → Media & Lyrics. Everything else works without it.")
        case .unavailable(let app):
            message("\(app ?? "This app") doesn't share its queue.")
        case .empty:
            message("Nothing after this song.")
        }
    }

    /// A song from History: the same look as Up Next's rows; a click plays it again in Music or Spotify (other apps
    /// can't be asked to, so their rows don't click).
    @ViewBuilder
    private func historyRow(_ entry: HistoryEntry, last: Bool) -> some View {
        let playable = ScriptablePlayer(bundleID: app) != nil
        let key = "history-\(entry.id)"
        Button {
            Task { await history?.play(entry, app: app) }
        } label: {
            HStack(spacing: 12) {
                let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
                if let cover = entry.cover, let image = NSImage(data: cover) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(tile)
                } else {
                    tile.fill(.white.opacity(0.1)).frame(width: 44, height: 44)
                        .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(trigger: key, gap: 52, bleed: 0) {
                        Text(entry.title).font(.system(size: 15, weight: .semibold))
                    }
                    if let artist = entry.artist {
                        MarqueeText(trigger: key, gap: 46, bleed: 0) {
                            Text(artist).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if history?.starting == entry.id { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovered == key ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // A thin line between songs, starting under the title (not the cover), like Apple Music's History.
            .overlay(alignment: .bottom) {
                if !last { Self.hairline.padding(.leading, 66).padding(.trailing, 10).offset(y: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playable || history?.starting != nil)
        // Hidden while Up Next sits at the top, so not even a sliver shows; pulling the list down brings it in.
        .opacity(historyShown ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: historyShown)
        .onHover { hovered = $0 && playable ? key : (hovered == key ? nil : hovered) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(playable ? "Play again" : "")
        .accessibilityLabel("\(playable ? "Play again: " : "")\(entry.title)\(entry.artist.map { " by \($0)" } ?? "")")
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func row(_ item: QueueItem, position: Int) -> some View {
        Button {
            Task { await queue.play(item, position: position) }
        } label: {
            HStack(spacing: 12) {
                cover(item)
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(trigger: item.id, gap: 52, bleed: 0) {
                        Text(item.title).font(.system(size: 15, weight: .semibold))
                    }
                    if let artist = item.artist {
                        MarqueeText(trigger: item.id, gap: 46, bleed: 0) {
                            Text(artist).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if queue.starting == item.id { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovered == item.id ? Color.white.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(queue.starting != nil)
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Play now")
        .accessibilityLabel("Play \(item.title)\(item.artist.map { " by \($0)" } ?? "")")
    }

    /// Spotify: its cover (from i.scdn.co, like the island's). Apple Music: the playing cover for songs from the same
    /// album; otherwise a plain tile.
    @ViewBuilder
    private func cover(_ item: QueueItem) -> some View {
        let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let url = item.artworkURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { tile.fill(.white.opacity(0.1)) }
                .frame(width: 44, height: 44).clipShape(tile)
        } else if item.sameAlbumAsPlaying {
            ArtworkView(image: nowPlaying.artwork, size: 44, cornerRadius: 6)
        } else {
            AppCover(item: item, queue: queue)
        }
    }
}

/// A cover the app keeps on your Mac (Music's playlist songs: each its own artwork, your video 2026-10-30 showed
/// blank tiles), asked for when the row appears; a plain tile until then or when there's none.
private struct AppCover: View {
    let item: QueueItem
    let queue: QueueStore
    @State private var image: NSImage?

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                tile.fill(.white.opacity(0.1)).overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(tile)
        .task(id: item.id) { image = await queue.cover(for: item) }
    }
}
