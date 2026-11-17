import Foundation
import Testing
@testable import BrimCore

/// The Queue for an Apple Music album that isn't in your Library, from Apple's public catalog.
struct AppleCatalogTests {
    private func json(_ results: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["results": results])
    }

    @Test func findsTheAlbumThroughThePlayingSong() {
        let data = json([["collectionId": 1, "collectionName": "Other"],
                         ["collectionId": 2, "collectionName": "Café Songs (Deluxe)"],
                         ["collectionId": 3, "collectionName": "Cafe Songs"]])
        #expect(AppleCatalog.albumID(in: data, album: "Café Songs") == 3)  // the exact edition wins
        #expect(AppleCatalog.albumID(in: json([["collectionId": 2, "collectionName": "Café Songs (Deluxe)"]]), album: "Cafe Songs") == 2)
    }

    @Test func listsTheSongsAfterThePlayingOneInAlbumOrder() {
        let data = json([["wrapperType": "collection", "collectionId": 2],
                         ["wrapperType": "track", "trackId": 13, "trackName": "Three", "trackNumber": 3,
                          "trackViewUrl": "https://music.apple.com/in/album/x/2?i=13"],
                         ["wrapperType": "track", "trackId": 11, "trackName": "One", "trackNumber": 1],
                         ["wrapperType": "track", "trackId": 12, "trackName": "Two (feat. Someone)", "trackNumber": 2]])
        let next = AppleCatalog.upNext(in: data, currentTitle: "One", currentNumber: nil)
        #expect(next.map(\.title) == ["Two (feat. Someone)", "Three"])
        #expect(next.last?.storeURL?.host == "music.apple.com")
        // Found by the start of its title, else by its number.
        #expect(AppleCatalog.upNext(in: data, currentTitle: "Two", currentNumber: nil).map(\.title) == ["Three"])
        #expect(AppleCatalog.upNext(in: data, currentTitle: "Renamed", currentNumber: 2).map(\.title) == ["Three"])
    }
}
