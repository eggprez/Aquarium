//  What the playlist, smart-playlist and further Settings tests share: the
//  way to Music's pages, system alerts and their fields, toasts, a
//  confirmation dialog's Cancel on an iPad, and the playlist calls of the
//  server's API (to set a test up, to check what the app did, and to put the
//  account back).

#if os(iOS)
import XCTest

extension PadUITestCase {
    struct PadTrack { let id: String; let name: String }

    /// A fixture album by name, with its tracks in album order.
    func fixtureAlbum(_ name: String) throws -> (id: String, tracks: [PadTrack]) {
        guard let all = try fx.raw["fixtures"] as? [String: Any],
              let music = all["music"] as? [String: Any],
              let albums = music["albums"] as? [[String: Any]],
              let album = albums.first(where: { $0["name"] as? String == name }),
              let id = album["id"] as? String else { throw XCTSkip("no album \(name) in fixtures.json") }
        let tracks = (album["tracks"] as? [[String: Any]] ?? []).compactMap { t -> PadTrack? in
            guard let id = t["id"] as? String else { return nil }
            return PadTrack(id: id, name: t["name"] as? String ?? "")
        }
        return (id, tracks)
    }

    /// A fixture artist's or genre's id (`artists`, `genres` in fixtures.json).
    func fixtureMusicId(_ list: String, named name: String) throws -> String {
        guard let all = try fx.raw["fixtures"] as? [String: Any],
              let music = all["music"] as? [String: Any],
              let rows = music[list] as? [[String: Any]],
              let id = rows.first(where: { $0["name"] as? String == name })?["id"] as? String
        else { throw XCTSkip("no \(name) in fixtures.json's \(list)") }
        return id
    }

    /// This suite's account name: every playlist a test makes starts with it,
    /// so `suite-reset.py` also deletes one a crashed test left behind.
    var accountName: String { QA.account()?.name ?? "suite-\(QA.suite)" }

    /// Home, then Music's Library page.
    func openMusicLibraryPage(file: StaticString = #filePath, line: UInt = #line) {
        if app == nil { launchHome(file: file, line: line) }
        showSection("music", file: file, line: line)
        app.element(TestID.Music.root).waitToExist(30, file: file, line: line)
        let picker = app.segmentedControls[TestID.Music.pagePicker]
        if picker.waitForExistence(timeout: 10) {
            picker.buttons["Library"].padTap()
        } else {
            app.button(TestID.Music.page("library")).padTap()
        }
        app.element(TestID.Music.library).waitToExist(20, file: file, line: line)
    }

    /// Music → Library → Playlists.
    func openPlaylistsPage(file: StaticString = #filePath, line: UInt = #line) {
        openMusicLibraryPage(file: file, line: line)
        app.button(TestID.Music.libraryDoor("playlists")).padTap()
        app.element(TestID.Playlists.root).waitToExist(20, file: file, line: line)
    }

    /// Music → Library → Albums → the album's page.
    func openAlbumPage(_ albumId: String, file: StaticString = #filePath, line: UInt = #line) {
        openMusicLibraryPage(file: file, line: line)
        app.button(TestID.Music.libraryDoor("albums")).padTap()
        app.element(TestID.Music.albums).waitToExist(20, file: file, line: line)
        let card = app.elements(prefix: TestID.Music.card(albumId)).firstMatch
        XCTAssertTrue(reveal(card), "the album among the albums", file: file, line: line)
        card.padTap()
        app.element(TestID.Music.album).waitToExist(30, file: file, line: line)
    }

    /// The navigation bar's Back.
    func goBack() {
        app.navigationBars.buttons.firstMatch.padTap()
    }

    /// Back up Music's stack to its Library page.
    func backToMusicLibrary(file: StaticString = #filePath, line: UInt = #line) {
        let library = app.element(TestID.Music.library)
        for _ in 0..<5 where !library.exists {
            goBack()
            _ = library.waitForExistence(timeout: 3)
        }
        library.waitToExist(10, file: file, line: line)
    }

    /// A playlist's row on the Playlists page.
    func playlistRow(_ id: String) -> XCUIElement {
        app.buttons.matching(identifier: TestID.Music.row(id)).firstMatch
    }

    /// The system alert with this title (New Playlist, Rename Playlist).
    func alert(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let alert = app.alerts[title]
        alert.waitToExist(10, file: file, line: line)
        return alert
    }

    /// Replaces what a text field holds with `text`.
    func replaceText(in field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        field.waitToExist(10, file: file, line: line)
        // A tap on a second field while the keyboard is still settling for
        // the first can leave the caret where it was: tapped until it has it.
        func focused() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
        for _ in 0..<4 where !focused() {
            field.padTap()
            _ = eventually(3) { focused() }
        }
        let placeholder = field.placeholderValue ?? ""
        func held() -> String {
            let value = (field.value as? String) ?? ""
            return value == placeholder ? "" : value
        }
        // The caret to the end (a tap at the field's trailing edge), then
        // Delete for every character, until the field is empty.
        // Short of the very end, where a search field keeps its clear button.
        for _ in 0..<3 where !held().isEmpty {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
            _ = eventually(3) { focused() }
            let count = held().count
            if count > 0, focused() { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)) }
        }
        XCTAssertEqual(held(), "", "the field emptied", file: file, line: line)
        for _ in 0..<3 where !focused() {
            field.padTap()
            _ = eventually(3) { focused() }
        }
        if !text.isEmpty { field.typeText(text) }
    }

    /// The words of every toast showing.
    func toastTexts() -> [String] {
        app.descendants(matching: .any).matching(identifier: TestID.Shell.toastText)
            .allElementsBoundByIndex.map { text($0) }
    }

    /// Waits for a toast with these words. A toast is up for three seconds,
    /// so this looks as fast as the app answers rather than once a second,
    /// and it is called straight after the tap that raises the toast.
    @discardableResult
    func waitForToast(containing words: String, _ timeout: TimeInterval = 15,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let toast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
        let end = Date().addingTimeInterval(timeout)
        var seen: [String] = []
        attachScreenshot("looking for the toast")
        while Date() < end {
            if toast.exists { return true }
            seen = toastTexts()
            if seen.contains(where: { $0.contains(words) }) { return true }
        }
        XCTFail("no toast saying \(words); last showing: \(seen)", file: file, line: line)
        return false
    }

    static let toastBug = "bug: toasts are not drawn in the iPad's sidebar shell: no toast card and no shell.toast.root in the element tree, and none in a screenshot taken as the action lands (ToastOverlay hung on the split view's detail column, Views/RootView.swift:532)"

    /// A toast the app raises in the sidebar shell, which an iPad does not
    /// show today: looked for, and its absence recorded as the known bug.
    func expectToast(containing words: String, file: StaticString = #filePath, line: UInt = #line) {
        // An expected failure still ends a test that stops at its first
        // failure, so that is lifted while the toast is looked for.
        let stops = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = stops }
        XCTExpectFailure(Self.toastBug) {
            _ = waitForToast(containing: words, 5, file: file, line: line)
        }
    }

    /// Answers a confirmation dialog with its Cancel. An iPad draws the
    /// dialog as a popover, which has no Cancel button of its own: a tap
    /// outside it is the Cancel. `confirm` is the dialog's other button,
    /// waited on to know the dialog came and went.
    func cancelDialog(cancel: String, confirm: String, file: StaticString = #filePath, line: UInt = #line) {
        let confirmButton = app.button(confirm)
        confirmButton.waitToExist(10, file: file, line: line)
        let cancelButton = app.button(cancel)
        if cancelButton.exists, cancelButton.isHittable {
            cancelButton.tap()
        } else {
            // Clear of the popover: the foot of the window, in the page's column.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.96)).tap()
        }
        XCTAssertTrue(confirmButton.waitToVanish(10), "the dialog closed", file: file, line: line)
    }

    /// The identifiers under `prefix` on screen, top to bottom, the prefix dropped.
    func keysInOrder(prefix: String, type: XCUIElement.ElementType = .any) -> [String] {
        let found = app.descendants(matching: type)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        var seen = Set<String>()
        return found.sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst(prefix.count)) }
            .filter { seen.insert($0).inserted }
    }

    /// The song rows on screen, top to bottom, by song id.
    func songIdsInOrder() -> [String] {
        keysInOrder(prefix: "music.song.", type: .button).filter { !$0.hasPrefix("more.") }
    }

    /// Opens a menu row whose identifier may not have reached the system's
    /// menu (see `menuItem`), by identifier and then by its words.
    func tapMenuItem(_ id: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = menuItem(id, label: label)
        item.waitToExist(10, file: file, line: line)
        // A submenu slides out from its parent: a tap while it moves lands
        // beside the row and closes the whole menu. Wait for it to settle.
        var last = CGRect.null
        _ = eventually(5) {
            let now = item.frame
            defer { last = now }
            return now == last && !now.isEmpty
        }
        item.padTap()
    }
}

extension JellyfinAPI {
    struct PadPlaylist { let id: String; let name: String; let count: Int }
    struct PadPlaylistEntry { let entryId: String; let songId: String; let name: String }

    /// Every playlist this account can see (its own and the public ones).
    func padPlaylists() throws -> [PadPlaylist] {
        let reply = try json("/Items?userId=\(userId)&Recursive=true&IncludeItemTypes=Playlist&Fields=ChildCount") as? [String: Any]
        return (reply?["Items"] as? [[String: Any]] ?? []).map {
            PadPlaylist(id: $0["Id"] as? String ?? "", name: $0["Name"] as? String ?? "", count: $0["ChildCount"] as? Int ?? 0)
        }
    }

    func padPlaylist(named name: String) throws -> PadPlaylist? {
        try padPlaylists().first { $0.name == name }
    }

    /// A private audio playlist of this account's, as `suite-reset.py` makes its own.
    @discardableResult
    func padCreatePlaylist(_ name: String, songs: [String]) throws -> String {
        let data = try request("POST", "/Playlists",
                               body: ["Name": name, "Ids": songs, "UserId": userId, "MediaType": "Audio", "IsPublic": false])
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = reply?["Id"] as? String else { throw Failure.noAnswer("/Playlists") }
        return id
    }

    /// A playlist's entries, in its own order.
    func padPlaylistEntries(_ id: String) throws -> [PadPlaylistEntry] {
        let reply = try json("/Playlists/\(id)/Items?userId=\(userId)") as? [String: Any]
        return (reply?["Items"] as? [[String: Any]] ?? []).map {
            PadPlaylistEntry(entryId: $0["PlaylistItemId"] as? String ?? "", songId: $0["Id"] as? String ?? "",
                             name: $0["Name"] as? String ?? "")
        }
    }

    /// Deletes every playlist named "<account> …" but the baseline's
    /// "<account> Playlist": what a test made, whatever it was called after.
    func padDeleteTestPlaylists(account: String) {
        for list in (try? padPlaylists()) ?? [] where list.name.hasPrefix(account + " ") && list.name != "\(account) Playlist" {
            _ = try? request("DELETE", "/Items/\(list.id)")
        }
    }
}
#endif
