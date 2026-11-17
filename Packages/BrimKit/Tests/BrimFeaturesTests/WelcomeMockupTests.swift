import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// The welcome as it ships (round 3, your picks 2026-11-11), drawn by the real `WelcomeView` at each step: Hello
/// (and after pointing), Look in each of the three looks, Ready (all off, some on, and with the one restart).
/// Glass can't render offscreen, so its frame is approximate. `BRIM_SNAPSHOTS=<folder> swift test --filter
/// WelcomeMockupTests` writes welcome-mockups.png.
@MainActor
struct WelcomeMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    /// Switches set by hand, so each frame shows one state.
    private final class Answers {
        var calendar = false
        var airPods = false
        var volume = false
        var volumeAllowed = false
        var actions: WelcomeFlow.Actions {
            WelcomeFlow.Actions(turnOnCalendar: {}, turnOffCalendar: {}, calendarIsOn: { [self] in calendar },
                                turnOnAirPods: {}, turnOffAirPods: {}, airPodsAreOn: { [self] in airPods },
                                turnOnVolume: {}, turnOffVolume: {},
                                volumeIsOn: { [self] in volume && volumeAllowed },
                                volumeNeedsRestart: { [self] in volume && volumeAllowed }, restart: {},
                                launchAtLoginIsOn: { false }, setLaunchAtLogin: { _ in })
        }
    }

    private func flow(at step: WelcomeFlow.Step, _ set: (Answers) -> Void = { _ in },
                      waitingForVolume: Bool = false) -> WelcomeFlow {
        let answers = Answers()
        set(answers)
        let flow = WelcomeFlow(actions: answers.actions, defaults: UserDefaults(suiteName: testSuiteName("brim.welcome.mockup"))!,
                               resultPause: .seconds(60))
        flow.startIfNeeded()
        while flow.step != step { flow.next() }
        if waitingForVolume { flow.setVolume(true) }
        return flow
    }

    private func settings(_ look: IslandAppearance) -> IslandSettings {
        let settings = IslandSettings(defaults: UserDefaults(suiteName: testSuiteName("brim.welcome.mockup"))!)
        settings.appearance = look
        return settings
    }

    @Test(.enabled(if: folder != nil)) func renderWelcomeMockups() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let notch = settings(.black)
        // Hello, a moment after you point: the result holds for its pause (60 s here, so it stays still).
        let pointed = flow(at: .hello)
        let pointing = Task { await pointed.pointedAtTop() }
        for _ in 0..<50 where pointed.outcome == nil { await Task.yield() }
        let frames: [(String, WelcomeFlow, IslandSettings)] = [
            ("1 · Hello (nothing playing: a made-up song)", flow(at: .hello), notch),
            ("1 · after you point at the top", pointed, notch),
            ("2 · Look: Notch", flow(at: .look), notch),
            ("2 · Look: Black Pill", flow(at: .look), settings(.blackPill)),
            ("2 · Look: Glass (approximate offscreen)", flow(at: .look), settings(.liquidGlass)),
            ("3 · Ready (all off)", flow(at: .ready), notch),
            ("3 · Ready: meetings on, volume waiting for System Settings",
             flow(at: .ready, { $0.calendar = true }, waitingForVolume: true), notch),
            ("3 · Ready: volume allowed (Done restarts once)",
             flow(at: .ready, { $0.airPods = true; $0.volume = true; $0.volumeAllowed = true }), notch),
        ]
        let sheet = VStack(alignment: .leading, spacing: 18) {
            Text("Welcome round 3, as built · the real WelcomeView at each step (previews at the end of their animation)")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            ForEach([0, 2, 4, 6], id: \.self) { row in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row..<row + 2, id: \.self) { i in
                        TopOfScreen(label: frames[i].0) { WelcomeView(flow: frames[i].1, settings: frames[i].2) }
                    }
                }
            }
        }
        .padding(28)
        .background(Color(white: 0.09))
        .environment(\.offscreenRender, true)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        pointing.cancel()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("welcome-mockups.png"))
    }
}

/// The top of a Mac's screen, the welcome hanging from its edge.
private struct TopOfScreen: View {
    let label: String
    let content: AnyView
    init(label: String, @ViewBuilder content: () -> some View) {
        self.label = label
        self.content = AnyView(content())
    }
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.2), Color(red: 0.2, green: 0.14, blue: 0.24)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                content.frame(width: WelcomeView.width + 12, height: WelcomeView.windowHeight)
            }
            .frame(width: 500, height: WelcomeView.windowHeight + 20)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}
