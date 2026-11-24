//  Editing one of the server's playlists from the phone: a song's "…" menu
//  › Add to Playlist puts it on the server's playlist, the playlist's page
//  lists it, and its own "…" › Remove from Playlist takes it off again.
//  The suite account's "<name> Playlist" (FIXTURES.md) is left as it was
//  found, by the API if the test stops part-way.

#if os(iOS)
import XCTest

final class PhoneMusicPlaylistTests: PhoneMusicTestCase {
    private struct Entry { let id: String; let entryId: String? }

    private func playlistId(named name: String, _ api: JellyfinAPI) throws -> String? {
        let json = try api.json("/Users/\(api.userId)/Items?IncludeItemTypes=Playlist&Recursive=true") as? [String: Any]
        let items = json?["Items"] as? [[String: Any]] ?? []
        return items.first { ($0["Name"] as? String) == name }?["Id"] as? String
    }

    private func entries(_ api: JellyfinAPI, _ playlist: String) -> [Entry] {
        let json = (try? api.json("/Playlists/\(playlist)/Items?userId=\(api.userId)")) as? [String: Any]
        return (json?["Items"] as? [[String: Any]] ?? []).compactMap { item in
            (item["Id"] as? String).map { Entry(id: $0, entryId: item["PlaylistItemId"] as? String) }
        }
    }

    func testASongIsAddedToAPlaylistAndRemovedFromIt() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account())
        let api = try self.api
        let name = "\(account.name) Playlist"
        let playlist = try XCTUnwrap(try playlistId(named: name, api), "the suite account has no \(name)")
        let before = entries(api, playlist)

        launchHome()
        let album = try openAlbum("FX Formats")
        let song = try XCTUnwrap(tracks(album).first { id in !before.contains { $0.id == id } },
                                 "every FX Formats song is already in \(name)")
        addTeardownBlock {
            // Put the playlist back if the test stopped before removing it:
            // the song was not in it before, so every copy of it is ours.
            for entry in self.entries(api, playlist) where entry.id == song {
                if let e = entry.entryId { _ = try? api.request("DELETE", "/Playlists/\(playlist)/Items?EntryIds=\(e)") }
            }
        }

        any(TestID.Music.songMore(song)).tapNow(10)
        any(TestID.Music.menuAddToPlaylist).tapNow(10)
        menuItem(TestID.Music.menuPlaylist(playlist), label: name).tapNow(10)
        XCTAssertTrue(eventually(timeout: 20) { self.entries(api, playlist).contains { $0.id == song } },
                      "the server's playlist never got the song")

        // The playlist's own page, from Music › Library › Playlists.
        tab("Music")
        if !any(TestID.Music.page("library")).waitForExistence(timeout: 3) { tab("Music") }
        any(TestID.Music.page("library")).tapNow(10)
        any(TestID.Music.libraryDoor("playlists")).tapNow(10)
        app.element(TestID.Playlists.root).waitToExist(20)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        row.tapNow(20)
        app.element(TestID.Playlists.detail).waitToExist(20)
        let listed = any(TestID.Music.song(song))
        app.reveal(listed)
        XCTAssertTrue(listed.waitForExistence(timeout: 20), "the playlist page does not list the song added")
        attachScreenshot("playlist with the song")

        any(TestID.Music.songMore(song)).tapNow(10)
        any(TestID.Playlists.removeSong).tapNow(10)
        XCTAssertTrue(eventually(timeout: 20) { !self.entries(api, playlist).contains { $0.id == song } },
                      "Remove from Playlist did not reach the server")
        XCTAssertTrue(listed.waitToVanish(20), "the song is still on the playlist page")
        XCTAssertEqual(entries(api, playlist).count, before.count, "the rest of the playlist is untouched")
    }
}
#endif
