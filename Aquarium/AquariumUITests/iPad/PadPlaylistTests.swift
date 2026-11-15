//  The server's playlists on an iPad (Music → Library → Playlists): making
//  one with the +, renaming and deleting one from its row's menu (with the
//  confirmation, and its Cancel), adding a song from a song's "…" menu to a
//  new playlist and to an existing one, a playlist's page (its songs in
//  order, the empty state), removing a song from its menu, and Edit Songs
//  (the handles out: remove, reorder, Done).
//
//  Every playlist a test makes is named "<account> …" and deleted afterwards,
//  on the server, whatever the test renamed it to; the baseline's
//  "<account> Playlist" is only read.

#if os(iOS)
import XCTest

final class PadPlaylistTests: PadUITestCase {
    private var server: JellyfinAPI?

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try api()
        server?.padDeleteTestPlaylists(account: accountName)
    }

    override func tearDownWithError() throws {
        server?.padDeleteTestPlaylists(account: accountName)
        server?.signOut()
        server = nil
        try super.tearDownWithError()
    }

    private func name(_ suffix: String) -> String { "\(accountName) \(suffix)" }

    private func formats() throws -> [PadTrack] { try fixtureAlbum("FX Formats").tracks }

    /// The playlist's page, from its row on the Playlists page.
    private func openPlaylist(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        openPlaylistsPage(file: file, line: line)
        let row = playlistRow(id)
        XCTAssertTrue(reveal(row), "the playlist's row", file: file, line: line)
        row.padTap()
        app.element(TestID.Playlists.detail).waitToExist(20, file: file, line: line)
    }

    // MARK: The list

    func testPlaylistsPageListsTheAccountsAndThePublicOnes() throws {
        let api = try XCTUnwrap(server)
        let own = try XCTUnwrap(api.padPlaylist(named: "\(accountName) Playlist"), "the baseline playlist")
        let shared = try XCTUnwrap(api.padPlaylist(named: "FX Music Playlist"), "the public fixture playlist")
        launchHome()
        openPlaylistsPage()
        let row = playlistRow(own.id)
        XCTAssertTrue(reveal(row), "the account's own playlist")
        XCTAssertTrue(row.label.contains("\(accountName) Playlist"), "row reads \(row.label)")
        XCTAssertTrue(row.label.contains("3 songs"), "its count under the name: \(row.label)")
        XCTAssertTrue(reveal(playlistRow(shared.id)), "the public playlist")
        XCTAssertFalse(app.element(TestID.Playlists.empty).exists, "not the empty state with playlists listed")
        XCTAssertFalse(app.element(TestID.Playlists.error).exists)
        XCTAssertTrue(app.button(TestID.Playlists.new).exists, "the + in the bar")
        attachScreenshot("playlists")
    }

    func testCreatingWithThePlusOpensTheNewEmptyPlaylist() throws {
        let api = try XCTUnwrap(server)
        let title = name("Made With Plus")
        launchHome()
        openPlaylistsPage()

        // Cancel makes nothing.
        app.button(TestID.Playlists.new).padTap()
        var prompt = alert("New Playlist")
        replaceText(in: prompt.textFields.firstMatch, with: title)
        prompt.buttons["Cancel"].tap()
        XCTAssertTrue(prompt.waitToVanish(10))
        XCTAssertNil(try api.padPlaylist(named: title), "Cancel made no playlist")

        app.button(TestID.Playlists.new).padTap()
        prompt = alert("New Playlist")
        XCTAssertEqual((prompt.textFields.firstMatch.value as? String) ?? "", prompt.textFields.firstMatch.placeholderValue ?? "",
                       "the field starts empty each time")
        replaceText(in: prompt.textFields.firstMatch, with: title)
        prompt.buttons["Create"].tap()

        // Straight to the new playlist's page, which says it is empty.
        app.element(TestID.Playlists.detail).waitToExist(20)
        XCTAssertTrue(waitUntil(15, "the page's title") { [self] in app.element(TestID.Music.headerTitle).label == title })
        XCTAssertEqual(app.element(TestID.Music.headerKicker).label.lowercased(), "playlist")
        XCTAssertTrue(app.element(TestID.Music.empty).waitForExistence(timeout: 15), "Empty playlist")
        XCTAssertTrue(app.staticTexts["Empty playlist"].exists)
        XCTAssertFalse(app.button(TestID.Music.playBarPlay).isEnabled, "nothing to play")
        attachScreenshot("empty playlist")

        let made = try XCTUnwrap(api.padPlaylist(named: title), "the playlist on the server")
        XCTAssertEqual(try api.padPlaylistEntries(made.id).count, 0)

        // And back on the list it has its row.
        goBack()
        app.element(TestID.Playlists.root).waitToExist(15)
        XCTAssertTrue(reveal(playlistRow(made.id)), "the new playlist's row")
    }

    func testRenameFromTheRowsMenu() throws {
        let api = try XCTUnwrap(server)
        let tracks = try formats()
        let id = try api.padCreatePlaylist(name("Rename Me"), songs: [tracks[0].id, tracks[1].id])
        let renamed = name("Renamed")
        XCTExpectFailure("bug: Rename and Delete Playlist never appear on a playlist's row: MusicListRow's own .musicContextMenu (Music/MusicComponents.swift:512) shadows the menu PlaylistsView adds, Music/MusicLibraryView.swift:557")
        launchHome()
        openPlaylistsPage()
        let row = playlistRow(id)
        XCTAssertTrue(reveal(row))

        // Cancel leaves the name.
        contextMenu(on: row, waitingFor: TestID.Playlists.menuRename)
        XCTAssertTrue(app.button(TestID.Playlists.menuDelete).exists, "Delete Playlist beside Rename")
        XCTAssertFalse(app.button(TestID.Music.menuAddToPlaylist).exists, "a playlist is not added to a playlist")
        app.button(TestID.Playlists.menuRename).padTap()
        var prompt = alert("Rename Playlist")
        XCTAssertEqual(prompt.textFields.firstMatch.value as? String, name("Rename Me"), "the field starts with the name")
        replaceText(in: prompt.textFields.firstMatch, with: renamed)
        prompt.buttons["Cancel"].tap()
        XCTAssertTrue(prompt.waitToVanish(10))
        XCTAssertTrue(row.label.contains("Rename Me"), "row reads \(row.label)")
        XCTAssertNotNil(try api.padPlaylist(named: name("Rename Me")))

        contextMenu(on: row, waitingFor: TestID.Playlists.menuRename)
        app.button(TestID.Playlists.menuRename).padTap()
        prompt = alert("Rename Playlist")
        replaceText(in: prompt.textFields.firstMatch, with: renamed)
        prompt.buttons["Rename"].tap()
        XCTAssertTrue(waitUntil(15, "the row to take the new name") { row.label.contains(renamed) }, "row reads \(row.label)")
        XCTAssertTrue(waitUntil(15, "the new name on the server") { (try? api.padPlaylist(named: renamed))?.id == id })
        XCTAssertTrue(row.label.contains("2 songs"), "still its two songs: \(row.label)")
    }

    func testDeleteAsksFirstAndCancelKeepsThePlaylist() throws {
        let api = try XCTUnwrap(server)
        let tracks = try formats()
        let title = name("Delete Me")
        let id = try api.padCreatePlaylist(title, songs: [tracks[0].id])
        XCTExpectFailure("bug: Rename and Delete Playlist never appear on a playlist's row: MusicListRow's own .musicContextMenu (Music/MusicComponents.swift:512) shadows the menu PlaylistsView adds, Music/MusicLibraryView.swift:557")
        launchHome()
        openPlaylistsPage()
        let row = playlistRow(id)
        XCTAssertTrue(reveal(row))

        contextMenu(on: row, waitingFor: TestID.Playlists.menuDelete)
        app.button(TestID.Playlists.menuDelete).padTap()
        app.button(TestID.Playlists.deleteConfirm).waitToExist(10)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Delete “\(title)”?")).firstMatch.exists,
                      "the question names the playlist")
        attachScreenshot("delete playlist")
        cancelDialog(cancel: TestID.Playlists.deleteCancel, confirm: TestID.Playlists.deleteConfirm)
        XCTAssertTrue(row.exists, "still listed after Cancel")
        XCTAssertNotNil(try api.padPlaylist(named: title), "still on the server after Cancel")

        contextMenu(on: row, waitingFor: TestID.Playlists.menuDelete)
        app.button(TestID.Playlists.menuDelete).padTap()
        app.button(TestID.Playlists.deleteConfirm).padTap()
        expectToast(containing: "Deleted \(title)")
        XCTAssertTrue(row.waitToVanish(15), "the row goes")
        XCTAssertTrue(waitUntil(15, "gone from the server") { (try? api.padPlaylists().contains { $0.name == title }) == false })
    }

    // MARK: From a song's menu

    func testASongsMenuMakesANewPlaylistWithTheSongInIt() throws {
        let api = try XCTUnwrap(server)
        let album = try fixtureAlbum("FX Formats")
        let song = album.tracks[2]                       // MP3 VBR
        let title = name("From A Song")
        launchHome()
        openAlbumPage(album.id)
        let more = app.button(TestID.Music.songMore(song.id))
        XCTAssertTrue(reveal(more))
        more.padTap()
        tapMenuItem(TestID.Music.menuAddToPlaylist, label: "Add to Playlist")
        tapMenuItem(TestID.Music.menuNewPlaylist, label: "New Playlist…")
        let prompt = app.alerts["New Playlist"]
        guard prompt.waitForExistence(timeout: 10) else {
            // Adding to an existing playlist from the same submenu works
            // (the test below); the name is never asked for.
            continueAfterFailure = true
            XCTExpectFailure("bug: New Playlist… in a song's Add to Playlist menu raises no alert on an iPad, so a playlist cannot be made from a song: PlaylistPrompt.ask (Music/MusicComponents.swift:851) sets the item, PlaylistPromptHost's alert (Music/MusicTabView.swift:296) never presents") {
                XCTFail("no New Playlist alert within 10 s of choosing New Playlist…")
            }
            XCTAssertNil(try api.padPlaylist(named: "FX Formats"), "and nothing was made unasked")
            return
        }
        XCTAssertEqual(prompt.textFields.firstMatch.value as? String, "FX Formats", "a song's new playlist starts named for its album")
        replaceText(in: prompt.textFields.firstMatch, with: title)
        prompt.buttons["Create"].tap()
        expectToast(containing: "Created \(title) with 1 song")
        let made = try XCTUnwrap(api.padPlaylist(named: title), "the playlist on the server")
        XCTAssertEqual(try api.padPlaylistEntries(made.id).map(\.songId), [song.id])
    }

    func testASongsMenuAddsToAnExistingPlaylist() throws {
        let api = try XCTUnwrap(server)
        let album = try fixtureAlbum("FX Formats")
        let title = name("Add Here")
        let id = try api.padCreatePlaylist(title, songs: [album.tracks[0].id])
        let song = album.tracks[3]                       // AAC 256
        launchHome()
        openAlbumPage(album.id)
        let more = app.button(TestID.Music.songMore(song.id))
        XCTAssertTrue(reveal(more))
        more.padTap()
        tapMenuItem(TestID.Music.menuAddToPlaylist, label: "Add to Playlist")
        XCTAssertTrue(menuItem(TestID.Music.menuNewPlaylist, label: "New Playlist…").waitForExistence(timeout: 10), "New Playlist… leads the list")
        tapMenuItem(TestID.Music.menuPlaylist(id), label: title)
        expectToast(containing: "Added \(song.name) to \(title)")
        XCTAssertTrue(waitUntil(15, "the song on the server's playlist") {
            (try? api.padPlaylistEntries(id).map(\.songId)) == [album.tracks[0].id, song.id]
        })

        // The list's count follows without being asked again.
        backToMusicLibrary()
        app.button(TestID.Music.libraryDoor("playlists")).padTap()
        app.element(TestID.Playlists.root).waitToExist(20)
        let row = playlistRow(id)
        XCTAssertTrue(reveal(row))
        XCTAssertTrue(waitUntil(15, "the row's count") { row.label.contains("2 songs") }, "row reads \(row.label)")
    }

    // MARK: One playlist's page

    func testPlaylistPageShowsItsSongsInTheirOrder() throws {
        let api = try XCTUnwrap(server)
        let tracks = try formats()
        let own = try XCTUnwrap(api.padPlaylist(named: "\(accountName) Playlist"), "the baseline playlist")
        launchHome()
        openPlaylist(own.id)
        XCTAssertTrue(waitUntil(15, "the page's title") { [self] in app.element(TestID.Music.headerTitle).label == "\(accountName) Playlist" })
        XCTAssertEqual(app.element(TestID.Music.headerKicker).label.lowercased(), "playlist")
        let expected = [tracks[0].id, tracks[2].id, tracks[3].id]   // FX Formats 1, 3, 4 (FIXTURES.md)
        XCTAssertTrue(waitUntil(20, "its three songs in order") { [self] in songIdsInOrder() == expected }, "rows: \(songIdsInOrder())")
        XCTAssertTrue(text(app.element(TestID.Music.headerFacts)).contains("3 songs"), "facts read \(text(app.element(TestID.Music.headerFacts)))")
        XCTAssertFalse(app.element(TestID.Music.empty).exists)
        XCTAssertTrue(app.button(TestID.Music.playBarPlay).isEnabled)

        // The "…" in the bar: the playlist's own actions, then Edit Songs.
        app.button(TestID.Music.detailMore).padTap()
        XCTAssertTrue(menuItem(TestID.Playlists.editSongs, label: "Edit Songs").waitForExistence(timeout: 10))
        XCTAssertTrue(menuItem(TestID.Music.menuShuffle, label: "Shuffle").exists)
        attachScreenshot("playlist menu")
    }

    func testRemoveFromPlaylistInASongsMenu() throws {
        let api = try XCTUnwrap(server)
        let tracks = try formats()
        let id = try api.padCreatePlaylist(name("Remove One"), songs: [tracks[0].id, tracks[1].id, tracks[2].id])
        XCTExpectFailure("bug: Remove from Playlist never appears in a song's menu on a playlist's page: SongRow's own .musicContextMenu (Music/MusicComponents.swift:425) shadows the menu PlaylistDetailView adds, Music/MusicDetails.swift:522")
        launchHome()
        openPlaylist(id)
        let song = app.button(TestID.Music.song(tracks[1].id))
        XCTAssertTrue(reveal(song))
        contextMenu(on: song, waitingFor: TestID.Playlists.removeSong)
        app.button(TestID.Playlists.removeSong).padTap()
        XCTAssertTrue(song.waitToVanish(15), "the song's row goes")
        XCTAssertTrue(waitUntil(15, "two songs left on the server") {
            (try? api.padPlaylistEntries(id).map(\.songId)) == [tracks[0].id, tracks[2].id]
        })
        XCTAssertTrue(waitUntil(10, "the header's count") { [self] in text(app.element(TestID.Music.headerFacts)).contains("2 songs") })
    }

    func testEditSongsRemovesASongAndDoneGoesBack() throws {
        let api = try XCTUnwrap(server)
        let tracks = try formats()
        let id = try api.padCreatePlaylist(name("Edit Remove"), songs: [tracks[0].id, tracks[1].id, tracks[2].id])
        let entries = try api.padPlaylistEntries(id)
        try XCTSkipUnless(entries.count == 3 && entries.allSatisfy { !$0.entryId.isEmpty }, "the server gave no entry ids")
        launchHome()
        openPlaylist(id)
        app.button(TestID.Music.detailMore).padTap()
        tapMenuItem(TestID.Playlists.editSongs, label: "Edit Songs")
        app.element(TestID.Playlists.editor).waitToExist(10)
        let status = app.element(TestID.Playlists.editorStatus)
        XCTAssertTrue(text(status).localizedCaseInsensitiveContains("Drag to reorder, swipe to remove"), "reads \(text(status))")
        XCTAssertEqual(keysInOrder(prefix: "playlists.detail.editor.row."), entries.map(\.entryId), "a row an entry, in order")
        XCTAssertTrue(app.button(TestID.Playlists.editDone).exists, "Done in the bar")
        XCTAssertFalse(app.button(TestID.Music.detailMore).exists, "no … menu while editing")
        attachScreenshot("playlist editor")

        // The red − at the row's leading edge, then Delete.
        let middle = app.element(TestID.Playlists.editorRow(entries[1].entryId))
        let cell = app.cells.containing(.any, identifier: TestID.Playlists.editorRow(entries[1].entryId)).firstMatch
        let minus = cell.images["minus.circle.fill"].firstMatch
        minus.waitToExist(10)
        minus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let delete = app.buttons["Delete"]
        delete.waitToExist(10)
        delete.tap()
        XCTAssertTrue(middle.waitToVanish(15), "the row goes")
        XCTAssertTrue(waitUntil(15, "two songs left on the server") {
            (try? api.padPlaylistEntries(id).map(\.songId)) == [tracks[0].id, tracks[2].id]
        })

        app.button(TestID.Playlists.editDone).padTap()
        XCTAssertTrue(app.element(TestID.Playlists.editor).waitToVanish(10), "Done puts the handles away")
        XCTAssertTrue(waitUntil(15, "the page with the two songs") { [self] in songIdsInOrder() == [tracks[0].id, tracks[2].id] },
                      "rows: \(songIdsInOrder())")
    }

    func testEditSongsReordersByDragging() throws {
        let api = try XCTUnwrap(server)
        let tracks = try formats()
        let id = try api.padCreatePlaylist(name("Edit Reorder"), songs: [tracks[0].id, tracks[1].id, tracks[2].id])
        let entries = try api.padPlaylistEntries(id)
        try XCTSkipUnless(entries.count == 3 && entries.allSatisfy { !$0.entryId.isEmpty }, "the server gave no entry ids")
        launchHome()
        openPlaylist(id)
        app.button(TestID.Music.detailMore).padTap()
        tapMenuItem(TestID.Playlists.editSongs, label: "Edit Songs")
        app.element(TestID.Playlists.editor).waitToExist(10)

        // The first row's handle, dragged below the last row.
        let first = app.cells.containing(.any, identifier: TestID.Playlists.editorRow(entries[0].entryId)).firstMatch
        let last = app.cells.containing(.any, identifier: TestID.Playlists.editorRow(entries[2].entryId)).firstMatch
        let handle = first.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "a reorder handle on each row")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: handle.frame.midX - last.frame.midX, dy: last.frame.height * 0.6))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)

        let expected = [tracks[1].id, tracks[2].id, tracks[0].id]
        XCTAssertTrue(waitUntil(20, "the first song last on the server") {
            (try? api.padPlaylistEntries(id).map(\.songId)) == expected
        }, "server order: \((try? api.padPlaylistEntries(id).map(\.name)) ?? [])")
        XCTAssertTrue(waitUntil(10, "the status back from Saving…") { [self] in
            text(app.element(TestID.Playlists.editorStatus)).localizedCaseInsensitiveContains("Drag to reorder")
        })
        app.button(TestID.Playlists.editDone).padTap()
        XCTAssertTrue(waitUntil(15, "the page in the new order") { [self] in songIdsInOrder() == expected }, "rows: \(songIdsInOrder())")
    }
}
#endif
