import Testing
@testable import BrimFeatures

struct SettingsSearchTests {
    @Test func findsSettingsByTheirWords() {
        #expect(SettingsSearch.results(for: "airpods").map(\.title) == ["AirPods and headphones", "Buttons beside the controls"])
        #expect(SettingsSearch.results(for: "Slim").map(\.title) == ["Show it as", "In full-screen apps"])
        #expect(SettingsSearch.results(for: "movie").map(\.title) == ["In full-screen apps"])
        #expect(SettingsSearch.results(for: "volume").first?.page == .hud)
    }

    @Test func titleMatchesComeFirstAndEveryWordMustMatch() {
        #expect(SettingsSearch.results(for: "lyrics").first?.title == "Synced lyrics")
        #expect(SettingsSearch.results(for: "notch glass").map(\.title) == ["Appearance"])
        #expect(SettingsSearch.results(for: "zzz").isEmpty)
    }
}
