import Foundation
import SwiftUI
import BrimCore

/// Settings like System Settings (your 3.6, 2026-09-30): pages in a sidebar, controls on the right.
public struct SettingsView: View {
    let settings: SettingsModel
    let island: IslandSettings
    let nowPlaying: NowPlayingStore
    let keys: KeyTakeover
    /// For the AirPods notice's status in Settings → Notices.
    var headphones: HeadphonesStore?
    /// For Calendar access's status in Settings → Calendar.
    var calendar: CalendarStore?
    /// Your Spotify sign-in (Settings → Media & Lyrics).
    var spotify: SpotifyAccountStore?
    /// Focus labels (Settings → Timers).
    var focus: FocusHistoryStore?
    @State private var newFocusLabel = ""
    @Environment(\.openURL) private var openURL
    /// Optional app-level action for copying a redacted support report. Keeping the clipboard work outside
    /// BrimFeatures avoids making the settings feature own platform-wide diagnostics or pasteboard policy.
    private let copyDiagnostics: (() -> Void)?
    private let showWelcome: (() -> Void)?
    private let checkForUpdates: (() -> Void)?
    @State private var diagnosticsCopied = false
    /// A page ("island") or a search result ("island|Keep music visible").
    @State private var selection: String? = SettingsPage.general.rawValue
    @State private var query = ""
    private var page: SettingsPage? { selection.flatMap { SettingsPage(rawValue: String($0.split(separator: "|")[0])) } }

    public init(settings: SettingsModel, island: IslandSettings, nowPlaying: NowPlayingStore, keys: KeyTakeover,
                headphones: HeadphonesStore? = nil, calendar: CalendarStore? = nil, spotify: SpotifyAccountStore? = nil,
                focus: FocusHistoryStore? = nil, copyDiagnostics: (() -> Void)? = nil, showWelcome: (() -> Void)? = nil,
                checkForUpdates: (() -> Void)? = nil) {
        self.showWelcome = showWelcome
        self.checkForUpdates = checkForUpdates
        self.focus = focus
        self.headphones = headphones
        self.calendar = calendar
        self.spotify = spotify
        self.copyDiagnostics = copyDiagnostics
        self.settings = settings
        self.island = island
        self.nowPlaying = nowPlaying
        self.keys = keys
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if query.isEmpty {
                    ForEach(SettingsPage.allCases) { page in
                        Label { Text(page.title) } icon: { page.icon }
                            .tag(page.rawValue)
                    }
                } else {
                    // Like System Settings: matching settings, each with its page; picking one opens the page.
                    let results = SettingsSearch.results(for: query)
                    if results.isEmpty {
                        Text("No results").foregroundStyle(.secondary)
                    }
                    ForEach(results) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                Text(item.page.title).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { item.page.icon }
                        .tag(item.id)
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 230)
        } detail: {
            Form { pageContent }
                .formStyle(.grouped)
                .navigationTitle((page ?? .general).title)
        }
        .frame(width: 720, height: 520)
        .onAppear {
            settings.refresh()
            keys.refreshPermissionStatus()
        }
    }

    /// Like System Settings: the sections of one page at a time (your 3.6, 2026-09-30).
    @ViewBuilder
    private var pageContent: some View {
        @Bindable var island = island
        switch page ?? .general {
        case .general:
            Section("General") {
                Toggle("Open Brim at login", isOn: Binding(
                    get: { settings.launchAtLogin != .off },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if settings.launchAtLogin == .needsApproval {
                    LabeledContent("Allow Brim in System Settings") {
                        Button("Open Login Items", action: settings.openLoginItems)
                    }
                }
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let showWelcome {
                    LabeledContent("Welcome") {
                        Button("Show Welcome Again", action: showWelcome)
                    }
                }
            }

        case .island:
            Section {
                Picker("Appearance", selection: $island.appearance) {
                    ForEach(IslandAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Keep music visible", isOn: $island.keepPillVisible)
                Picker("Show it as", selection: $island.keptStyle) {
                    ForEach(KeptStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!island.keepPillVisible)
                Picker("When nothing plays", selection: $island.idleStyle) {
                    ForEach(IdleStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("In full-screen apps", selection: $island.fullScreen) {
                    ForEach(FullScreenIsland.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Island")
            } footer: {
                Text((island.keptStyle == .pill
                      ? "The pill stays while music plays. "
                      : "A thin line at the top, covering nothing. ")
                     + (island.fullScreen == .hide
                        ? "Full-screen apps: only important alerts show."
                        : "Full-screen apps: music shows as the thin line."))
            }

            Section {
                Button("Open Focus Settings…") {
                    openURL(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                }
            } header: {
                Text("With macOS Focus")
            } footer: {
                Text("In System Settings → Focus → Focus filters, add Brim to pick its look for each Focus.")
            }

            Section {
                openToggle("Resting the pointer at the top", isOn: $island.openOnRest)
                openToggle("Pushing up against the top edge", isOn: $island.openOnPush)
                openToggle("Clicking the top edge", isOn: $island.openOnClick)
            } header: {
                Text("Open the island from the top edge by")
            } footer: {
                Text("These apply everywhere, the pill included: with only \"click\" on, hovering never opens Brim. One must stay on.")
            }

        case .hud:
            Section {
                Picker("Style", selection: $island.hudStyle) {
                    ForEach(HUDStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text(island.hudStyle == .standard
                     ? "The island becomes a slider that fills with white as you turn it up."
                     : "An icon and a thin bar inside the pill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show only Brim's HUD", isOn: $island.brimHUDOnly)
                if island.brimHUDOnly {
                    keyAccessRow
                }
            } header: {
                Text("HUD")
            } footer: {
                Text(island.brimHUDOnly
                     ? "Brim's own volume and brightness. Hold ⌥⇧ for small steps. Earbud buttons still show Apple's."
                     : "Apple's own HUD also appears, just below Brim's.")
            }

        case .media:
            Section {
                Toggle("Synced lyrics", isOn: $island.lyricsEnabled)
                Toggle("Light up words as they're sung (when the lyrics have word timing)", isOn: $island.lyricsSweep)
                    .disabled(!island.lyricsEnabled)
                Picker("Buttons beside the controls", selection: $island.sideButtons) {
                    ForEach(SideButtons.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if island.sideButtons == .favoriteOutput {
                    Text("★ adds the song to Favorites (Apple Music) or Liked Songs (Spotify).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Media & Lyrics")
            } footer: {
                Text("Lyrics come free from LRCLIB. Only the song's name and length are sent.")
            }
            if let spotify { spotifySection(spotify) }

        case .notices:
            Section {
                Toggle("Battery", isOn: $island.batteryNotices)
                Toggle("AirPods and headphones", isOn: $island.headphonesNotices)
                headphonesStatus
            } header: {
                Text("Notices in the island")
            } footer: {
                Text("Short notices when you plug in, and when AirPods connect.")
            }
            .onAppear { headphones?.refreshAvailability() }
        case .calendar:
            Section {
                Toggle("Show your next event", isOn: $island.calendarEnabled)
                Toggle("Remind me 5 minutes before", isOn: $island.calendarReminders)
                    .disabled(!island.calendarEnabled)
                calendarStatus
            } header: {
                Text("Calendar")
            } footer: {
                Text("Shows your next event, and reminds you 5 minutes before.")
            }
            .onAppear { calendar?.refresh() }
            if let calendar, island.calendarEnabled, !calendar.calendars.isEmpty {
                calendarsSection(calendar)
            }
        case .timers:
            if let focus { focusLabelsSection(focus) }
        case .keyboard:
            keyboardPage
        case .permissions:
            permissionsPage
                .onAppear {
                    calendar?.refresh()
                    headphones?.refreshAvailability()
                }
        case .help:
            helpPage
        case .about:
            Section("About") {
                LabeledContent("Version", value: Self.version)
                if let checkForUpdates {
                    LabeledContent("Updates") {
                        Button("Check for Updates…", action: checkForUpdates)
                    }
                    Text("Checks once a day. Always asks before installing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Now Playing uses mediaremote-adapter (BSD-3-Clause) by Jonas van den Berg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Now Playing") {
                LabeledContent("Status", value: statusText)
                if nowPlaying.unavailableReason != nil {
                    Button("Retry Now", action: nowPlaying.retryHelper)  // instead of waiting out the helper's backoff
                }
                LabeledContent("Helper", value: nowPlaying.helper.processID.map { "Running (PID \($0))" } ?? "Not running")
                LabeledContent("Helper restarts", value: "\(nowPlaying.helper.restarts)")
                LabeledContent("Last update") {
                    if let at = nowPlaying.lastEventAt {
                        Text(at, style: .relative) + Text(" ago")
                    } else {
                        Text("—")
                    }
                }
            }
            if let copyDiagnostics {
                Section("Support") {
                    Button(diagnosticsCopied ? "Copied" : "Copy Diagnostics") {
                        copyDiagnostics()
                        diagnosticsCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            diagnosticsCopied = false
                        }
                    }
                    Text("Copies a report for bug fixes. No song names or personal info.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
    }

    /// Where the key takeover stands, with a shortcut to the permission when it's missing.
    @ViewBuilder
    private var keyAccessRow: some View {
        switch keys.access {
        case .active:
            Label("Active: Apple's HUD won't appear", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsPermission:
            LabeledContent("Allow Brim in Privacy & Security → \(SystemNames.keyAccessPane)") {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                        openURL(url)
                    }
                }
            }
        case .failed(let reason):
            Text(reason).foregroundStyle(.red)
        case .off:
            EmptyView()
        }
    }

    /// Why the calendar can't show anything, when it can't.
    @ViewBuilder
    private var calendarStatus: some View {
        if island.calendarEnabled, calendar?.availability == .starting {
            HStack {
                Text("Calendar access has not been requested yet.").foregroundStyle(.secondary)
                Spacer()
                Button("Grant Access") { Task { await calendar?.requestPermission() } }
                    .controlSize(.small)
            }
        } else if island.calendarEnabled, calendar?.availability == .needsPermission {
            HStack {
                Text("Brim isn't allowed to read your calendar.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars") {
                        openURL(url)
                    }
                }
            }
            .font(.caption)
        }
    }

    /// Why the AirPods notice can't work, when it can't.
    @ViewBuilder
    private var headphonesStatus: some View {
        switch headphones?.availability {
        case .needsPermission?:
            HStack {
                Text("Needs the Bluetooth permission.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth") {
                        openURL(url)
                    }
                }
            }
            .font(.caption)
        case .unavailable(let reason)?:
            Text(reason).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// A toggle that can't switch off the last remaining way to open the island.
    private func openToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .disabled(isOn.wrappedValue && island.enabledOpenTriggers == 1)
    }

    private var statusText: String {
        switch nowPlaying.availability {
        case .starting: "Starting…"
        case .ready: "Working"
        case .needsPermission: "Needs permission"
        case .unavailable(let reason): reason
        }
    }

    @ViewBuilder
    private var permissionsPage: some View {
        Section {
            accessibilityPermission
            calendarPermission
            bluetoothPermission
        } header: {
            Text("Permissions")
        } footer: {
            Text("Brim asks only when a feature needs it.")
        }
        Section("No permission required") {
            LabeledContent("Now Playing", value: "Built in")
            LabeledContent("Lyrics", value: "Song name only, when lyrics show")
            LabeledContent("Spotify", value: "Optional sign-in")
        }
    }

    @ViewBuilder
    private var accessibilityPermission: some View {
        if keys.permissionGranted {
            permissionRow("Accessibility / Device Control", detail: keys.access == .active
                          ? "Allowed: Safari video controls and volume keys work."
                          : "Allowed. Restart Brim to use it.", status: "Allowed") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
            }
        } else {
            switch keys.access {
            case .active:
                permissionRow("Accessibility / Device Control", detail: "Quit and reopen Brim to use the new permission.", status: "Restart required") {
                    openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
                }
            case .off:
                permissionRow("Accessibility / Device Control", detail: "Optional: for Safari video controls and Brim's volume HUD.", status: "Optional") {
                    openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
                }
            case .needsPermission:
                permissionRow("Accessibility / Device Control", detail: "Needed for Safari video controls and Brim's volume HUD.", status: "Needs permission") {
                    openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
                }
            case .failed(let reason):
                permissionRow("Accessibility / Device Control", detail: reason, status: "Unavailable") {
                    openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
                }
            }
        }
    }

    @ViewBuilder
    private var calendarPermission: some View {
        switch calendar?.availability {
        case .ready:
            permissionRow("Calendar", detail: "For your next event and reminders.", status: "Allowed")
        case .needsPermission:
            permissionRow("Calendar", detail: "Needed for the Calendar tab and reminders.", status: "Needs permission") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")!)
            }
        case .starting:
            permissionRow("Calendar", detail: "Not requested yet.", status: "Not requested",
                          action: { Task { await calendar?.requestPermission() } }, actionTitle: "Grant Access")
        case .unavailable(let reason):
            permissionRow("Calendar", detail: reason, status: "Unavailable")
        case nil:
            permissionRow("Calendar", detail: "Available when Calendar is enabled.", status: "Not loaded")
        }
    }

    @ViewBuilder
    private var bluetoothPermission: some View {
        switch headphones?.availability {
        case .ready:
            permissionRow("Bluetooth", detail: "For AirPods battery notices.", status: "Allowed")
        case .needsPermission:
            permissionRow("Bluetooth", detail: "Needed for AirPods and headphone battery notices.", status: "Needs permission") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth")!)
            }
        case .starting:
            permissionRow("Bluetooth", detail: "Not requested yet. Brim will not ask on launch.", status: "Not requested",
                          action: { headphones?.requestPermission() }, actionTitle: "Grant Access")
        case .unavailable(let reason):
            permissionRow("Bluetooth", detail: reason, status: "Unavailable")
        case nil:
            permissionRow("Bluetooth", detail: "Available when AirPods and headphones notices are enabled.", status: "Not loaded")
        }
    }

    private func permissionRow(_ title: String, detail: String, status: String, action: (() -> Void)? = nil,
                               actionTitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(status)
                    .foregroundStyle(status == "Allowed" ? .green : .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let action {
                    Spacer(minLength: 4)
                    Button(actionTitle ?? (status == "Needs permission" ? "Grant Access" : "Open Settings"), action: action)
                        .controlSize(.small)
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// The sidebar's pages.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, island, hud, media, notices, calendar, timers, keyboard, permissions, help, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .island: "Island"
        case .hud: "HUD"
        case .media: "Media & Lyrics"
        case .notices: "Notices"
        case .calendar: "Calendar"
        case .timers: "Timers"
        case .keyboard: "Keyboard"
        case .permissions: "Permissions"
        case .help: "Help & Feedback"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .island: "capsule.fill"  // drawn by hand below: a pill at the top of a dark screen
        case .hud: "speaker.wave.2.fill"
        case .media: "music.note"
        case .notices: "bell.badge.fill"
        case .calendar: "calendar"
        case .timers: "timer"
        case .keyboard: "keyboard.fill"
        case .permissions: "hand.raised.fill"
        case .help: "questionmark"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        // System Settings' palette (your screenshot, 2026-10-30): one colour per page, none repeated.
        case .general: .gray
        case .island: Color(white: 0.16)
        case .hud: .pink
        case .media: .red
        case .notices: .orange
        case .calendar: .teal
        case .timers: .purple
        case .keyboard: .indigo
        case .permissions: .blue
        case .help: .green
        case .about: .gray
        }
    }
}

extension SettingsView {
    /// Focus labels (feature 3): typed here once, picked in the island with "For:" next to Start.
    @ViewBuilder
    func focusLabelsSection(_ focus: FocusHistoryStore) -> some View {
        Section {
            ForEach(focus.labels, id: \.self) { label in
                HStack {
                    Text(label)
                    Spacer()
                    Button { focus.removeLabel(label) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove \(label)")
                }
            }
            if focus.labels.count < FocusHistory.maximumLabels {
                HStack {
                    TextField("New label", text: $newFocusLabel, prompt: Text("Work, Reading, Writing…"))
                        .onSubmit { addFocusLabel(focus) }
                    Button("Add") { addFocusLabel(focus) }
                        .disabled(FocusHistory.cleaned(newFocusLabel) == nil)
                }
            }
        } header: {
            Text("Focus labels")
        } footer: {
            Text("Pick one with \"For:\" next to Start in the island's Timers tab; it stays picked for your next Focus timers. Each Focus timer that runs a minute or more is kept on your Mac with its label and length, and clicking today's focused time shows your labels and each session. Nothing leaves your Mac.")
        }
    }


    private func addFocusLabel(_ focus: FocusHistoryStore) {
        focus.addLabel(newFocusLabel)
        newFocusLabel = ""
    }

    /// Settings → Calendar → which calendars count (0.18.2): a switch per calendar, all on at first.
    @ViewBuilder
    func calendarsSection(_ calendar: CalendarStore) -> some View {
        @Bindable var island = island
        Section {
            ForEach(calendar.calendars) { source in
                Toggle(isOn: Binding(
                    get: { !island.hiddenCalendars.contains(source.id) },
                    set: { on in
                        if on { island.hiddenCalendars.remove(source.id) } else { island.hiddenCalendars.insert(source.id) }
                    })) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(source.color)).frame(width: 9, height: 9)
                        Text(source.title)
                        Text(source.account).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Calendars")
        } footer: {
            Text("Calendars you switch off never show in the island.")
        }
    }

    /// Spotify 1.3.3 answers no other app on your Mac, so Shuffle & Repeat from anywhere go through Spotify's Web API
    /// (your decision, 2026-10-02). One-time setup, then Connect.
    @ViewBuilder
    func spotifySection(_ spotify: SpotifyAccountStore) -> some View {
        @Bindable var island = island
        Section {
            switch spotify.state {
            case .signedIn:
                LabeledContent("Spotify", value: "Connected")
                Button("Disconnect", action: spotify.signOut)
            case .signingIn:
                LabeledContent("Spotify", value: "Waiting for your browser…")
            case .signedOut, .failed:
                TextField("Client ID", text: $island.spotifyClientID, prompt: Text("From your Spotify app"))
                Button("Connect Spotify…") { spotify.signIn(clientID: island.spotifyClientID) }
                    .disabled(island.spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                if case .failed(let reason) = spotify.state {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            }
            // If this, you get that: no paragraphs (your ask, 2026-10-30).
            LabeledContent("Not connected") {
                Text("Play, skip, Shuffle, Repeat, lyrics, History").foregroundStyle(.secondary)
            }
            LabeledContent("Connected, with Premium") {
                Text("Also Up Next, ★ Liked Songs, Repeat One").foregroundStyle(.secondary)
            }
            if spotify.state != .signedIn {
                DisclosureGroup("How to connect (3 steps, about 3 minutes)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Open developer.spotify.com/dashboard → Create app")
                        Text("2. Redirect URI: \(SpotifyWeb.registeredRedirect) · tick Web API · Save")
                            .textSelection(.enabled)
                        Text("3. Copy its Client ID → paste above → Connect Spotify")
                        Text("Didn't connect? Use one browser window, and check the Redirect URI matches exactly.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Your sign-in stays in your Mac's Keychain.")
        }
        .onAppear(perform: spotify.refresh)
    }
}

extension SettingsView {
    /// Every key Brim answers, in one place (your ask, 2026-11-17), the same as the site's Keys section.
    @ViewBuilder
    var keyboardPage: some View {
        @Bindable var island = island
        Section {
            Toggle(isOn: $island.settingsShortcut) {
                LabeledContent("⌥⌘,") { Text("Open Brim's Settings") }
            }
            if island.settingsShortcut, island.settingsShortcutTaken {
                Text("Another app already uses ⌥⌘,, so macOS gave it to that app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("From any app")
        } footer: {
            Text("⌘, alone opens Brim's Settings while a Brim window is in front; in other apps it's their own.")
        }
        Section {
            ForEach(HelpAnswers.keys, id: \.action) { item in
                LabeledContent(item.action) { Text(item.result) }
            }
        } header: {
            Text("Volume and brightness")
        } footer: {
            Text(island.brimHUDOnly ? "Brim takes these keys (HUD → Show only Brim's HUD)."
                                    : "Turn on HUD → Show only Brim's HUD for these.")
        }
        Section("Full-screen player") {
            ForEach(HelpAnswers.fullScreen, id: \.action) { item in
                LabeledContent(item.action) { Text(item.result) }
            }
        }
        // Your ask, 2026-11-17: list ⌘W here too.
        Section("Settings window") {
            LabeledContent("⌘W") { Text("Close Settings") }
            LabeledContent("⌘Q") { Text("Quit Brim") }
        }
    }

    /// Help & Feedback (your idea, 2026-10-30): the questions people get stuck on, one line each, then a way to
    /// tell us. Feedback goes to the public repo's issues: free, no extra account for you, and people see the fix.
    @ViewBuilder
    var helpPage: some View {
        @Bindable var island = island
        // How to use (your pick, 2026-11-10): one row per thing you can do, the same lines as the site's.
        Section("How to use") {
            ForEach(HelpAnswers.howTo, id: \.action) { item in
                LabeledContent(item.action) { Text(item.result) }
            }
        }
        Section("Full-screen player") {
            ForEach(HelpAnswers.fullScreen, id: \.action) { item in
                LabeledContent(item.action) { Text(item.result) }
            }
        }
        Section("Common questions") {
            ForEach(HelpAnswers.all, id: \.question) { item in
                DisclosureGroup(item.question) {
                    Text(item.answer).foregroundStyle(.secondary).padding(.vertical, 2)
                }
            }
        }
        Section("Tips") {
            Toggle("Show a tip when I find something new", isOn: $island.tipsEnabled)
            LabeledContent("Seen \(min(island.tipsSeen.count, Tip.allCases.count)) of \(Tip.allCases.count)") {
                Button("Show Tips Again") { island.tipsSeen = [] }
                    .disabled(island.tipsSeen.isEmpty)
            }
        }
        Section {
            Button("Send Feedback or Report a Bug…") { openURL(HelpAnswers.feedback) }
        } footer: {
            Text("Opens Brim's feedback board. Something broke? Paste About → Copy Diagnostics into your post.")
        }
    }
}

/// Short answers to what people get stuck on: one line each, plain words.
enum HelpAnswers {
    /// What you do → what you get. Checked against the code on 2026-11-10; change both when a gesture changes.
    static let howTo: [(action: String, result: String)] = [
        ("Point at the top of the screen", "The island opens"),
        ("Click the album cover", "The song fills the screen"),
        ("Click the quote button", "Lyrics in the island"),
        ("Click the app's icon", "That app comes forward"),
        ("Swipe two fingers on the controls", "Shuffle & Repeat ↔ Favorite & Output"),
        ("⌃ + volume keys", "Only Music's or Spotify's volume; other apps keep the Mac's (needs Show only Brim's HUD)"),
        ("Right-click the island", "Timers, Keep Mac Awake, Settings"),
        ("⌥⌘,", "Brim's Settings, from any app"),
    ]
    /// The volume and brightness keys (Settings → Keyboard).
    static let keys: [(action: String, result: String)] = [
        ("Volume keys", "The Mac's volume, in Brim's HUD"),
        ("⌃ + volume keys", "Only Music's or Spotify's own volume"),
        ("⌥⇧ + volume or brightness", "Smaller steps"),
    ]
    static let fullScreen: [(action: String, result: String)] = [
        ("Space", "Play or pause"),
        ("⌘→  /  ⌘←", "Next song  /  start again"),
        ("Pull down in Queue", "Songs you played before"),
        ("Esc", "Close"),
    ]
    static let all: [(question: String, answer: String)] = [
        ("The island doesn't show my music", "Play something and wait a second. For Safari videos, allow Accessibility in Permissions."),
        ("A song has no lyrics", "LRCLIB doesn't have it yet. Wrong lyrics? Right-click them → Find Other Versions."),
        ("Lyrics are early or late", "Right-click the lyrics → Fix Lyrics Timing…, then click lines as they start; more clicks, more exact. Brim remembers it."),
        ("Up Next is empty", "Apple Music: play from your Library or a playlist. Spotify: needs Premium, connected."),
        ("Apple's volume box still shows", "Turn on HUD → Show only Brim's HUD. Earbud buttons always show Apple's."),
        ("The island covers my apps", "Island → Show it as → Slim line, or pick Hide for full-screen apps."),
        ("Brim sits there with nothing playing", "That's Brim resting. Island → When nothing plays → Slim line or Hidden."),
    ]
    /// Brim's public feedback board on UserJot (2026-11-17): ideas and bug reports, no GitHub account needed.
    static let feedback = URL(string: "https://brim-notch.userjot.com")!
}

extension SettingsPage {
    /// The coloured square icon, built like System Settings' (your screenshot, 2026-10-30): a rounded square with the
    /// system's soft top-to-bottom gradient, and one white filled symbol at one size, so no glyph looks bigger than
    /// another. Island is drawn: its own pill at the top of a dark screen.
    var icon: some View {
        let tile = RoundedRectangle(cornerRadius: 5.5, style: .continuous)
        return ZStack(alignment: .top) {
            tile.fill(color.gradient)
            if self == .island {
                Capsule().fill(.white).frame(width: 12, height: 4.5).padding(.top, 4)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 22, height: 22)
        .overlay(tile.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Settings search: every setting's name and the words people might type for it. Pure, so it's tested.
enum SettingsSearch {
    struct Item: Identifiable, Equatable {
        let title: String
        let page: SettingsPage
        let keywords: [String]
        var id: String { "\(page.rawValue)|\(title)" }
    }

    static let items: [Item] = [
        Item(title: "Open Brim at login", page: .general, keywords: ["login", "startup", "launch"]),
        Item(title: "Show Welcome Again", page: .general, keywords: ["welcome", "setup", "onboarding", "permissions", "tour"]),
        Item(title: "Appearance", page: .island, keywords: ["liquid glass", "black", "notch", "look", "theme"]),
        Item(title: "Keep music visible", page: .island, keywords: ["pill", "always", "music"]),
        Item(title: "Show it as", page: .island, keywords: ["slim line", "pill", "line"]),
        Item(title: "When nothing plays", page: .island, keywords: ["hide", "idle", "resting", "asleep", "sleeping", "eyes", "empty", "where"]),
        Item(title: "In full-screen apps", page: .island, keywords: ["full screen", "fullscreen", "video", "movie", "hide", "slim line"]),
        Item(title: "With macOS Focus", page: .island, keywords: ["focus", "do not disturb", "dnd", "work", "night", "fitness", "personal", "filter"]),
        Item(title: "Open the island from the top edge", page: .island, keywords: ["hover", "rest", "push", "click", "open"]),
        Item(title: "HUD style", page: .hud, keywords: ["volume", "brightness", "slider", "inline"]),
        Item(title: "Show only Brim's HUD", page: .hud, keywords: ["keys", "apple hud", "permission", "accessibility", "media keys"]),
        Item(title: "Synced lyrics", page: .media, keywords: ["lyrics", "lrclib", "karaoke"]),
        Item(title: "Light up words as they're sung", page: .media, keywords: ["sweep", "word", "karaoke", "highlight"]),
        Item(title: "Keyboard shortcuts", page: .keyboard, keywords: ["keys", "shortcut", "hotkey", "command", "control", "volume keys", "settings", "close", "quit", "cmd w"]),
        Item(title: "Buttons beside the controls", page: .media, keywords: ["shuffle", "repeat", "favorite", "star", "heart", "output", "airpods", "speakers"]),
        Item(title: "Spotify account", page: .media, keywords: ["spotify", "shuffle", "repeat", "premium", "sign in", "connect", "web api", "cover", "artwork", "favorite", "liked songs", "star"]),
        Item(title: "Battery", page: .notices, keywords: ["charging", "plugged", "power", "low power mode", "full"]),
        Item(title: "AirPods and headphones", page: .notices, keywords: ["airpods", "bluetooth", "battery", "case", "headphones"]),
        Item(title: "Show your next event", page: .calendar, keywords: ["calendar", "event", "meeting", "class", "join", "next"]),
        Item(title: "Remind me 5 minutes before", page: .calendar, keywords: ["reminder", "alert", "calendar", "meeting", "class"]),
        Item(title: "Calendars", page: .calendar, keywords: ["which calendars", "holidays", "birthdays", "hide", "account", "google", "icloud"]),
        Item(title: "Focus labels", page: .timers, keywords: ["focus", "label", "history", "project", "timer", "session", "work"]),
        Item(title: "Permissions", page: .permissions, keywords: ["privacy", "access", "accessibility", "calendar", "bluetooth", "grant", "permission"]),
        Item(title: "Now Playing status", page: .about, keywords: ["helper", "diagnostics", "working"]),
        Item(title: "Version", page: .about, keywords: ["about", "build", "credits"]),
        Item(title: "Help & Feedback", page: .help, keywords: ["help", "faq", "question", "feedback", "bug", "report", "problem", "issue", "how to", "shortcuts", "keyboard", "gestures", "swipe", "tips"]),
        Item(title: "Show Tips Again", page: .help, keywords: ["tips", "hints", "guide", "tutorial", "bubble"]),
    ]

    /// Settings whose name or words contain every word you typed (in any order), best matches first.
    static func results(for query: String) -> [Item] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let haystack = ([item.title, item.page.title] + item.keywords).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        .sorted { a, b in
            let aTitle = words.allSatisfy { a.title.lowercased().contains($0) }
            let bTitle = words.allSatisfy { b.title.lowercased().contains($0) }
            return aTitle && !bTitle
        }
    }
}
