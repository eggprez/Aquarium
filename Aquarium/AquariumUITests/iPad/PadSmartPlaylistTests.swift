//  Smart playlists on an iPad (Music → Library → Playlists, under the
//  server's own): the rule editor (name, the genre picker and its filter,
//  artist search / add / remove, years, added within, played, minimum plays,
//  favourites, sort, limit, the summary sentence, Cancel and Save), the row
//  and its Edit Rules / Delete menu, and the page that answers a rule (its
//  summary, the songs it picks from the fixture music library, Nothing
//  matches, Edit Rules, Refresh, Save as Playlist on Server, Delete).
//
//  A smart playlist lives in the app's settings, which every launch here
//  starts empty. The editor's tests make theirs through the editor; the
//  tests of what a rule answers are launched with the rule already saved. "Save as
//  Playlist on Server" makes a real playlist: rules are named "<account> …"
//  and every such playlist is deleted afterwards.

#if os(iOS)
import XCTest

final class PadSmartPlaylistTests: PadUITestCase {
    private var server: JellyfinAPI?
    /// Songs a test made favourites, put back afterwards.
    private var favourited: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try api()
        server?.padDeleteTestPlaylists(account: accountName)
        // Now and then the app does not come to rest once the genre filter
        // has been typed in (XCUITest then waits out a minute around every
        // step in the picker): room for that, where the plan allows ten minutes.
        executionTimeAllowance = 25 * 60
    }

    override func tearDownWithError() throws {
        for id in favourited { try? server?.setFavorite(id, false) }
        favourited = []
        server?.padDeleteTestPlaylists(account: accountName)
        server?.signOut()
        server = nil
        try super.tearDownWithError()
    }

    private typealias Smart = TestID.SmartPlaylists

    private func name(_ suffix: String) -> String { "\(accountName) \(suffix)" }

    // MARK: Driving the editor

    private var editor: XCUIElement { app.element(Smart.editor) }
    private var typedSinceKeyboardAway = false

    /// `replaceText`, remembered: the keyboard is up afterwards.
    private func enter(in field: XCUIElement, with text: String, returns: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        typedSinceKeyboardAway = true
        replaceText(in: field, with: text, file: file, line: line)
        // Return ends the edit and takes the keyboard down with it; the
        // keyboard's own Hide key is not always there for XCUITest to find.
        if returns { field.typeText("\n") }
    }
    /// The sentence under the form. It is the form's last line, and a form
    /// only builds the rows near the screen: scrolled to when it isn't there.
    private var summary: String {
        let sentence = app.element(Smart.editorSummary)
        if !sentence.exists {
            keyboardAway()
            let low = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let high = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            for _ in 0..<6 where !sentence.exists { low.press(forDuration: 0.05, thenDragTo: high) }
        }
        return sentence.exists ? text(sentence) : ""
    }

    /// The keyboard put away by its own key, once it has finished coming up
    /// (asked for while it is still rising, the key reports a place below
    /// the screen and cannot be pressed).
    private func keyboardAway() {
        let keyboard = app.keyboards.firstMatch
        // The keyboard is another process's, and now and then a look at the
        // screen comes back without it: after typing, it is waited for.
        guard keyboard.exists || (typedSinceKeyboardAway && keyboard.waitForExistence(timeout: 3)) else {
            typedSinceKeyboardAway = false
            return
        }
        defer { typedSinceKeyboardAway = false }
        let keys = keyboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'keyboard'"))
        let screen = app.frame
        for attempt in 0..<3 where attempt == 0 || keyboard.exists {
            var key: XCUIElement?
            _ = eventually(5) {
                key = keys.allElementsBoundByIndex.max { $0.frame.maxX + $0.frame.maxY < $1.frame.maxX + $1.frame.maxY }
                guard let frame = key?.frame else { return false }
                return !frame.isEmpty && frame.maxY <= screen.maxY + 1
            }
            key?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = keyboard.waitToVanish(4)
        }
    }

    /// Scrolls the editor's form until `element` can be touched.
    @discardableResult
    private func show(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        keyboardAway()
        // On screen, and clear of the sheet's own bar: a row scrolled under
        // the bar still answers "hittable", and a tap there lands on the bar.
        func there() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let page = editor.frame, y = element.frame.midY
            return y > page.minY + 64 && y < page.maxY - 12
        }
        let low = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let high = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        for _ in 0..<6 where !there() { low.press(forDuration: 0.05, thenDragTo: high) }
        for _ in 0..<8 where !there() { high.press(forDuration: 0.05, thenDragTo: low) }
        if !there() { XCTFail("\(element) could not be brought on screen in the editor", file: file, line: line) }
        return there()
    }

    private func openNewEditor(file: StaticString = #filePath, line: UInt = #line) {
        if app == nil { launchHome(file: file, line: line) }
        if !app.element(TestID.Playlists.root).exists { openPlaylistsPage(file: file, line: line) }
        let new = app.button(Smart.new)
        XCTAssertTrue(reveal(new), "New beside the Smart Playlists heading", file: file, line: line)
        new.padTap()
        editor.waitToExist(15, file: file, line: line)
    }

    private func setName(_ name: String) {
        let field = app.textFields[Smart.editorName]
        show(field)
        enter(in: field, with: name)
    }

    /// Genres → the picker → each genre ticked → back.
    private func chooseGenres(_ genres: [String], file: StaticString = #filePath, line: UInt = #line) {
        let row = app.button(Smart.editorGenres)
        show(row, file: file, line: line)
        row.padTap()
        app.element(Smart.genres).waitToExist(15, file: file, line: line)
        // The library has some hundreds of genres: found with the filter.
        let filter = app.searchFields.firstMatch
        filter.waitToExist(10, file: file, line: line)
        for genre in genres {
            enter(in: filter, with: genre)
            let option = app.button(Smart.genreOption(TestID.key(genre)))
            option.waitToExist(20, file: file, line: line)
            option.padTap()
            app.button(Smart.genreChosen(TestID.key(genre))).waitToExist(10, file: file, line: line)
        }
        leaveGenrePicker()
    }

    private func leaveGenrePicker() {
        app.navigationBars["Genres"].buttons.firstMatch.padTap()
        XCTAssertTrue(app.element(Smart.genres).waitToVanish(10))
    }

    private func addArtist(named name: String, id: String, file: StaticString = #filePath, line: UInt = #line) {
        let search = app.textFields[Smart.editorArtistSearch]
        show(search, file: file, line: line)
        enter(in: search, with: name, returns: false)
        let match = app.button(Smart.editorArtistMatch(id))
        match.waitToExist(20, file: file, line: line)
        if !match.isHittable { show(match, file: file, line: line) }
        match.padTap()
        app.element(Smart.editorArtist(id)).waitToExist(10, file: file, line: line)
    }

    private func setYears(from: String, to: String) {
        let fromField = app.textFields[Smart.editorYearFrom]
        show(fromField)
        enter(in: fromField, with: from)
        enter(in: app.textFields[Smart.editorYearTo], with: to)
    }

    /// A picker row of the form, and one of the options its menu lists.
    private func pick(_ row: String, option: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.element(row)
        show(picker, file: file, line: line)
        picker.padTap()
        tapMenuItem(option, label: label, file: file, line: line)
    }

    private func setFavouritesOnly(_ on: Bool) {
        let toggle = app.switches[Smart.editorFavoritesOnly]
        show(toggle)
        guard ((toggle.value as? String) == "1") != on else { return }
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertTrue(waitUntil(5, "Favourites only \(on ? "on" : "off")") { ((toggle.value as? String) == "1") == on })
    }

    private func save(file: StaticString = #filePath, line: UInt = #line) {
        app.button(Smart.editorSave).padTap()
        XCTAssertTrue(editor.waitToVanish(10), "Save closes the editor", file: file, line: line)
    }

    /// The UUIDs of the smart playlists listed, top to bottom.
    private func listedIds() -> [String] { keysInOrder(prefix: "smartPlaylists.row.", type: .button) }

    private func smartRow(_ id: String) -> XCUIElement { app.button(Smart.row(id)) }

    /// A rule made through the editor and saved; returns its row's id.
    private func makeRule(_ name: String, genres: [String] = [], artist: (name: String, id: String)? = nil,
                          years: (String, String)? = nil, addedDays: Int? = nil, favourites: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) -> String {
        let before = Set(app == nil ? [] : listedIds())
        openNewEditor(file: file, line: line)
        setName(name)
        if !genres.isEmpty { chooseGenres(genres, file: file, line: line) }
        if let artist { addArtist(named: artist.name, id: artist.id, file: file, line: line) }
        if let years { setYears(from: years.0, to: years.1) }
        if let addedDays { pick(Smart.editorAddedWithin, option: Smart.editorAddedWithinOption(addedDays), label: "\(addedDays) days", file: file, line: line) }
        if favourites { setFavouritesOnly(true) }
        pick(Smart.editorSort, option: Smart.editorSortOption("SortName"), label: "Title", file: file, line: line)
        pick(Smart.editorLimit, option: Smart.editorLimitOption(25), label: "25 songs", file: file, line: line)
        save(file: file, line: line)
        var made: String?
        waitUntil(10, "the new rule's row", file: file, line: line) { [self] in
            made = listedIds().first { !before.contains($0) }
            return made != nil
        }
        return made ?? ""
    }

    /// Launches with one rule already in the app's settings, as if made
    /// earlier (`smart_playlists`, handed in as a launch argument the way
    /// `defaults write` would), and opens the Playlists page. The editor has
    /// its own tests; this keeps the tests of what a rule answers off the
    /// genre picker, whose filter can leave the app unsettled for minutes.
    private func launchWithRule(_ name: String, genres: [String], years: (String, String)? = nil,
                                addedDays: Int? = nil, favourites: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) -> String {
        let id = UUID().uuidString
        var rule: [String: Any] = ["id": id, "name": name, "genres": genres, "artists": [], "favoritesOnly": favourites,
                                   "played": "any", "sort": "SortName", "limit": 25]
        if let years {
            rule["yearFrom"] = Int(years.0)
            rule["yearTo"] = Int(years.1)
        }
        if let addedDays { rule["addedWithinDays"] = addedDays }
        let json = (try? JSONSerialization.data(withJSONObject: [rule])) ?? Data()
        launchHome(arguments: ["-smart_playlists", "<data>\(json.base64EncodedString())</data>"], file: file, line: line)
        openPlaylistsPage(file: file, line: line)
        XCTAssertTrue(reveal(smartRow(id)), "the rule the launch was given, listed", file: file, line: line)
        return id
    }

    private func openRule(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = smartRow(id)
        XCTAssertTrue(reveal(row), "the rule's row", file: file, line: line)
        row.padTap()
        app.element(Smart.detail).waitToExist(15, file: file, line: line)
    }

    private func detailMenu(_ id: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        app.button(Smart.detailMore).padTap(file: file, line: line)
        tapMenuItem(id, label: label, file: file, line: line)
    }

    // MARK: The list and the editor

    func testListStartsEmptyAndCancelMakesNothing() {
        launchHome()
        openPlaylistsPage()
        let heading = app.element(Smart.heading)
        XCTAssertTrue(reveal(heading), "the Smart Playlists heading under the server's playlists")
        XCTAssertEqual(heading.label, "Smart Playlists")
        let empty = app.element(Smart.listEmpty)
        XCTAssertTrue(empty.exists, "None yet")
        XCTAssertTrue(empty.label.hasPrefix("None yet."), "reads \(empty.label)")
        XCTAssertTrue(listedIds().isEmpty)

        openNewEditor()
        let nameField = app.textFields[Smart.editorName]
        XCTAssertEqual(nameField.value as? String, "New Smart Playlist")
        XCTAssertEqual(summary, "Every song · random · 100", "an empty rule is every song")
        XCTAssertTrue(app.button(Smart.editorSave).isEnabled)
        attachScreenshot("new smart playlist")

        // No name, no Save.
        show(nameField)
        enter(in: nameField, with: "", returns: false)
        XCTAssertTrue(waitUntil(5, "Save off without a name") { [self] in !app.button(Smart.editorSave).isEnabled })
        nameField.typeText(name("Never Saved"))
        XCTAssertTrue(waitUntil(5, "Save back on") { [self] in app.button(Smart.editorSave).isEnabled })

        app.button(Smart.editorCancel).padTap()
        XCTAssertTrue(editor.waitToVanish(10), "Cancel closes the editor")
        XCTAssertTrue(empty.exists, "and nothing was made")
        XCTAssertTrue(listedIds().isEmpty)
    }

    /// The genre picker: its filter, choosing, taking one back from Chosen,
    /// and the editor's Genres row and sentence following.
    func testGenrePickerFiltersChoosesAndTakesBack() {
        launchHome()
        openNewEditor()
        let genresRow = app.button(Smart.editorGenres)
        show(genresRow)                                   // and the keyboard away, as a person would before tapping on
        XCTAssertTrue(genresRow.label.contains("Any"), "no genre yet: \(genresRow.label)")
        genresRow.padTap()
        let picker = app.element(Smart.genres)
        picker.waitToExist(15)
        let jazz = app.button(Smart.genreOption("fx-jazz"))
        let rock = app.button(Smart.genreOption("fx-rock"))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "smartPlaylists.genres.option.")).firstMatch
            .waitForExistence(timeout: 20), "the library's genres listed")
        let filter = app.searchFields.firstMatch
        filter.waitToExist(10)
        enter(in: filter, with: "FX")
        XCTAssertTrue(rock.waitForExistence(timeout: 10), "FX Rock once the filter is down to FX")
        // Both FX genres listed: one chosen, then taken back from Chosen.
        rock.padTap()
        let chosenRock = app.button(Smart.genreChosen("fx-rock"))
        chosenRock.waitToExist(10)
        attachScreenshot("genre picker")
        chosenRock.padTap()                               // a tap on a chosen genre takes it out
        XCTAssertTrue(chosenRock.waitToVanish(10))
        // The filter narrowed further (typed on, not retyped): Rock goes, Jazz stays.
        if (filter.value(forKey: "hasKeyboardFocus") as? Bool) != true {
            filter.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        }
        filter.typeText(" J")
        XCTAssertTrue(rock.waitToVanish(10), "the filter leaves only what matches")
        XCTAssertTrue(jazz.exists)
        jazz.padTap()
        XCTAssertTrue(app.button(Smart.genreChosen("fx-jazz")).waitForExistence(timeout: 10), "FX Jazz under Chosen")
        leaveGenrePicker()
        XCTAssertTrue(waitUntil(10, "the Genres row to name the genre") { genresRow.label.contains("FX Jazz") }, "reads \(genresRow.label)")
        XCTAssertFalse(genresRow.label.contains("FX Rock"))
        XCTAssertEqual(summary, "FX Jazz · random · 100")

        // Saved with its default name, the rule is listed with the genre in its sentence.
        save()
        XCTAssertTrue(waitUntil(10, "one rule listed") { [self] in listedIds().count == 1 })
        let row = smartRow(listedIds()[0])
        XCTAssertTrue(row.label.contains("New Smart Playlist"), "row reads \(row.label)")
        XCTAssertTrue(row.label.contains("FX Jazz · random · 100"), "row reads \(row.label)")
    }

    /// Every other control of the form, each watched in the summary
    /// sentence, then Save: the row carries the name and the sentence.
    func testEditorControlsWriteTheSummaryAndSaveListsTheRule() throws {
        let duo = try fixtureMusicId("artists", named: "FX Duo")
        let title = name("Every Control")
        launchHome()
        openNewEditor()
        setName(title)

        // Artists: search, add, the search clears, remove.
        addArtist(named: "FX Duo", id: duo)
        XCTAssertEqual(app.element(Smart.editorArtist(duo)).label, "FX Duo")
        XCTAssertEqual((app.textFields[Smart.editorArtistSearch].value as? String) ?? "",
                       app.textFields[Smart.editorArtistSearch].placeholderValue ?? "", "the search empties once an artist is added")
        XCTAssertFalse(app.button(Smart.editorArtistMatch(duo)).exists, "and its matches go")
        XCTAssertTrue(summary.hasPrefix("FX Duo · "), "summary: \(summary)")
        show(app.button(Smart.editorArtistRemove(duo)))
        app.button(Smart.editorArtistRemove(duo)).padTap()
        XCTAssertTrue(app.element(Smart.editorArtist(duo)).waitToVanish(10), "the − takes the artist out")
        XCTAssertFalse(summary.contains("FX Duo"), "summary: \(summary)")

        // Years: from alone, to alone, both (written low to high).
        let from = app.textFields[Smart.editorYearFrom], to = app.textFields[Smart.editorYearTo]
        show(from)
        enter(in: from, with: "2021")
        XCTAssertTrue(waitUntil(5, "from 2021") { [self] in summary.contains("from 2021") }, "summary: \(summary)")
        show(to)
        enter(in: to, with: "2019")
        XCTAssertTrue(waitUntil(5, "2019–2021") { [self] in summary.contains("2019–2021") }, "summary: \(summary)")
        show(from)
        enter(in: from, with: "")
        XCTAssertTrue(waitUntil(5, "up to 2019") { [self] in summary.contains("up to 2019") }, "summary: \(summary)")
        show(from)
        enter(in: from, with: "2021")
        enter(in: to, with: "2021")

        // Listening.
        pick(Smart.editorAddedWithin, option: Smart.editorAddedWithinOption(90), label: "90 days")
        XCTAssertTrue(waitUntil(5, "added within") { [self] in summary.contains("added in the last 90 days") }, "summary: \(summary)")
        pick(Smart.editorAddedWithin, option: Smart.editorAddedWithinOption(0), label: "Any time")
        XCTAssertTrue(waitUntil(5, "any time") { [self] in !summary.contains("added in the last") }, "summary: \(summary)")

        pick(Smart.editorPlayed, option: Smart.editorPlayedOption("unplayed"), label: "Never played")
        XCTAssertTrue(waitUntil(5, "never played") { [self] in summary.contains("never played") }, "summary: \(summary)")
        pick(Smart.editorPlayed, option: Smart.editorPlayedOption("played"), label: "Played before")
        XCTAssertTrue(waitUntil(5, "played before") { [self] in summary.contains("played before") }, "summary: \(summary)")
        pick(Smart.editorPlayed, option: Smart.editorPlayedOption("any"), label: "Any")
        XCTAssertTrue(waitUntil(5, "any") { [self] in !summary.contains("played") }, "summary: \(summary)")

        let stepper = app.element(Smart.editorMinPlays)
        show(stepper)
        XCTAssertTrue(text(stepper).contains("Played at least 0 times"), "reads \(text(stepper))")
        let up = app.buttons["\(Smart.editorMinPlays)-Increment"]
        let down = app.buttons["\(Smart.editorMinPlays)-Decrement"]
        up.padTap()
        XCTAssertTrue(waitUntil(5, "one play") { [self] in summary.contains("played 1+ times") }, "summary: \(summary)")
        XCTAssertTrue(text(stepper).contains("Played at least 1 time"), "reads \(text(stepper))")
        up.padTap()
        XCTAssertTrue(waitUntil(5, "two plays") { [self] in summary.contains("played 2+ times") }, "summary: \(summary)")
        down.padTap()
        down.padTap()
        XCTAssertTrue(waitUntil(5, "no floor") { [self] in !summary.contains("times") }, "summary: \(summary)")

        setFavouritesOnly(true)
        XCTAssertTrue(waitUntil(5, "favourites") { [self] in summary.contains("favourites") }, "summary: \(summary)")
        setFavouritesOnly(false)

        // Order.
        pick(Smart.editorSort, option: Smart.editorSortOption("PlayCount,SortName"), label: "Most played")
        XCTAssertTrue(waitUntil(5, "most played") { [self] in summary.contains("· most played ·") }, "summary: \(summary)")
        pick(Smart.editorSort, option: Smart.editorSortOption("SortName"), label: "Title")
        pick(Smart.editorLimit, option: Smart.editorLimitOption(50), label: "50 songs")
        let sentence = "2021–2021 · title · 50"
        XCTAssertTrue(waitUntil(5, "the whole sentence") { [self] in summary == sentence }, "summary: \(summary)")
        attachScreenshot("smart playlist editor")

        save()
        XCTAssertTrue(waitUntil(10, "one rule listed") { [self] in listedIds().count == 1 })
        let row = smartRow(listedIds()[0])
        XCTAssertTrue(row.label.contains(title), "row reads \(row.label)")
        XCTAssertTrue(row.label.contains(sentence), "row reads \(row.label)")
        XCTAssertFalse(app.element(Smart.listEmpty).exists, "None yet goes once there is one")
    }

    // MARK: A rule against the fixture library

    func testGenreAndYearRulePicksExactlyTheMatchingSongs() throws {
        let formats = try fixtureAlbum("FX Formats")     // FX Jazz, 2021: the only album that is both
        let title = name("Jazz 2021")
        let id = launchWithRule(title, genres: ["FX Jazz"], years: ("2021", "2021"))
        openRule(id)
        XCTAssertTrue(waitUntil(10, "the page's title") { [self] in app.element(TestID.Music.headerTitle).label == title })
        XCTAssertEqual(app.element(TestID.Music.headerKicker).label.lowercased(), "smart playlist")
        XCTAssertEqual(text(app.element(Smart.detailSummary)), "FX Jazz · 2021–2021 · title · 25")
        // By title, as the rule sorts: AAC 256, AIFF 16-44, Hi-Res FLAC 24-96, MP3 VBR, WAV 16-44.
        let expected = formats.tracks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id)
        XCTAssertTrue(waitUntil(20, "the five FX Formats songs, by title") { [self] in songIdsInOrder() == expected },
                      "rows: \(songIdsInOrder()), expected \(expected)")
        XCTAssertFalse(app.element(Smart.detailOffline).exists, "answered by the server")
        XCTAssertTrue(app.button(TestID.Music.playBarPlay).isEnabled)
        attachScreenshot("smart playlist")
    }

    func testArtistRulePicksThatArtistsSongs() throws {
        let duo = try fixtureMusicId("artists", named: "FX Duo")
        let compilation = try fixtureAlbum("FX Compilation")
        launchHome()
        let id = makeRule(name("Duo"), artist: ("FX Duo", duo))
        openRule(id)
        XCTAssertEqual(text(app.element(Smart.detailSummary)), "FX Duo · title · 25")
        // FX Duo is on Compilation Two, and with FX Singer on Compilation Four.
        let expected = [compilation.tracks[3].id, compilation.tracks[1].id]
        XCTAssertTrue(waitUntil(20, "FX Duo's two songs, by title") { [self] in songIdsInOrder() == expected }, "rows: \(songIdsInOrder())")
    }

    func testFavouritesOnlyRulePicksTheFavouriteSong() throws {
        let api = try XCTUnwrap(server)
        let discs = try fixtureAlbum("FX Two Discs")
        // The baseline's one favourite song is Disc One Opener (FIXTURES.md).
        let favourites = discs.tracks.filter { (try? api.userData($0.id).favorite) == true }.map(\.id)
        try XCTSkipUnless(favourites == [discs.tracks[0].id], "the account is not at its baseline: favourite songs \(favourites)")
        let id = launchWithRule(name("Rock Favourites"), genres: ["FX Rock"], favourites: true)
        openRule(id)
        XCTAssertEqual(text(app.element(Smart.detailSummary)), "FX Rock · favourites · title · 25")
        XCTAssertTrue(waitUntil(20, "Disc One Opener alone") { [self] in songIdsInOrder() == favourites }, "rows: \(songIdsInOrder())")
    }

    /// "Added in the last N days" is settled in the app, walking the library
    /// newest first (SmartPlaylist.resolve): the songs are those of the genre
    /// whose DateCreated is inside the window, by title.
    func testAddedWithinRuleIsSettledAgainstTheDateAdded() throws {
        let api = try XCTUnwrap(server)
        let long = try fixtureAlbum("FX Long Tracks")    // FX Ambient: Twelve Minutes, Six Minutes
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let inside = try long.tracks.filter { track in
            let item = try api.json("/Items/\(track.id)?userId=\(api.userId)") as? [String: Any]
            let stamp = (item?["DateCreated"] as? String ?? "").replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            guard let added = parser.date(from: stamp) else { throw XCTSkip("no DateCreated for \(track.name)") }
            return added >= cutoff
        }
        let expected = inside.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id)
        let id = launchWithRule(name("New Ambient"), genres: ["FX Ambient"], addedDays: 365)
        openRule(id)
        XCTAssertEqual(text(app.element(Smart.detailSummary)), "FX Ambient · added in the last 365 days · title · 25")
        if expected.isEmpty {
            XCTAssertTrue(app.element(TestID.Music.empty).waitForExistence(timeout: 20), "nothing that new")
        } else {
            XCTAssertTrue(waitUntil(20, "the FX Ambient songs added in the last year") { [self] in Set(songIdsInOrder()) == Set(expected) },
                          "rows: \(songIdsInOrder()), expected \(expected)")
            continueAfterFailure = true
            XCTExpectFailure("bug: a rule settled in the app sorts 'Title' by SortName, which Jellyfin prefixes with the disc and track number, so it comes out in album order where the server-answered rules sort by Name: SmartPlaylist.resolve's byName, Music/Playlists.swift:222") {
                XCTAssertEqual(songIdsInOrder(), expected, "by title: Six Minutes before Twelve Minutes")
            }
        }
    }

    func testARuleNothingMatchesSaysSo() {
        let id = launchWithRule(name("Nothing"), genres: ["FX Ambient"], years: ("1990", "1991"))
        openRule(id)
        XCTAssertTrue(app.element(TestID.Music.empty).waitForExistence(timeout: 20), "Nothing matches")
        XCTAssertTrue(app.staticTexts["Nothing matches"].exists)
        XCTAssertTrue(songIdsInOrder().isEmpty)
        XCTAssertFalse(app.button(TestID.Music.playBarPlay).isEnabled, "nothing to play")
        // And nothing to freeze: Save as Playlist on Server is off.
        app.button(Smart.detailMore).padTap()
        let saveToServer = menuItem(Smart.detailSaveToServer, label: "Save as Playlist on Server")
        saveToServer.waitToExist(10)
        XCTAssertFalse(saveToServer.isEnabled, "Save as Playlist on Server is off with no songs")
        attachScreenshot("nothing matches")
    }

    // MARK: The row's menu

    func testRowMenuEditsTheRuleAndDeletesIt() {
        let title = name("Row Menu"), renamed = name("Row Menu Edited")
        let id = launchWithRule(title, genres: ["FX Rock"])
        let row = smartRow(id)
        XCTAssertTrue(reveal(row))
        XCTAssertTrue(row.label.contains("FX Rock · title · 25"), "row reads \(row.label)")

        contextMenu(on: row, waitingFor: Smart.menuEdit)
        XCTAssertTrue(app.button(Smart.menuDelete).exists)
        app.button(Smart.menuEdit).padTap()
        editor.waitToExist(15)
        XCTAssertEqual(app.textFields[Smart.editorName].value as? String, title, "the editor opens on the rule")
        XCTAssertTrue(app.button(Smart.editorGenres).label.contains("FX Rock"))
        XCTAssertEqual(summary, "FX Rock · title · 25")
        setName(renamed)
        pick(Smart.editorLimit, option: Smart.editorLimitOption(100), label: "100 songs")
        save()
        XCTAssertTrue(waitUntil(10, "the row to follow the edit") { row.label.contains(renamed) && row.label.contains("FX Rock · title · 100") },
                      "row reads \(row.label)")
        XCTAssertEqual(listedIds(), [id], "the same rule, not a second one")

        contextMenu(on: row, waitingFor: Smart.menuDelete)
        app.button(Smart.menuDelete).padTap()
        XCTAssertTrue(row.waitToVanish(10), "Delete takes the row")
        XCTAssertTrue(app.element(Smart.listEmpty).waitForExistence(timeout: 10), "None yet again")
    }

    // MARK: The page's menu

    func testDetailMenuEditsRefreshesSavesToTheServerAndDeletes() throws {
        let api = try XCTUnwrap(server)
        let formats = try fixtureAlbum("FX Formats")
        let song = formats.tracks[2]                     // MP3 VBR
        try XCTSkipIf(try api.userData(song.id).favorite, "MP3 VBR is a favourite: not the baseline")
        let title = name("Smart Frozen")
        let id = launchWithRule(title, genres: ["FX Jazz"], years: ("2021", "2021"))
        openRule(id)
        XCTAssertTrue(waitUntil(20, "the five songs") { [self] in songIdsInOrder().count == 5 }, "rows: \(songIdsInOrder())")

        // Edit Rules: favourites only. No FX Jazz song is one, so the page empties.
        detailMenu(Smart.detailEdit, label: "Edit Rules")
        editor.waitToExist(15)
        XCTAssertEqual(app.textFields[Smart.editorName].value as? String, title)
        setFavouritesOnly(true)
        save()
        XCTAssertTrue(waitUntil(10, "the summary to follow") { [self] in
            text(app.element(Smart.detailSummary)) == "FX Jazz · 2021–2021 · favourites · title · 25"
        }, "summary: \(text(app.element(Smart.detailSummary)))")
        XCTAssertTrue(app.element(TestID.Music.empty).waitForExistence(timeout: 20), "no favourite FX Jazz song yet")

        // Refresh asks the library again: a song made a favourite meanwhile turns up.
        favourited.append(song.id)
        try api.setFavorite(song.id, true)
        detailMenu(Smart.detailRefresh, label: "Refresh")
        XCTAssertTrue(waitUntil(20, "MP3 VBR after Refresh") { [self] in songIdsInOrder() == [song.id] }, "rows: \(songIdsInOrder())")

        // Save as Playlist on Server: a real playlist of what the rule says now, opened.
        detailMenu(Smart.detailSaveToServer, label: "Save as Playlist on Server")
        expectToast(containing: "Saved 1 songs as “\(title)” on the server")
        app.element(TestID.Playlists.detail).waitToExist(20)
        let frozen = try XCTUnwrap(api.padPlaylist(named: title), "the playlist on the server")
        XCTAssertEqual(try api.padPlaylistEntries(frozen.id).map(\.songId), [song.id])
        XCTAssertTrue(waitUntil(20, "the playlist's page with the song") { [self] in songIdsInOrder() == [song.id] })
        attachScreenshot("frozen playlist")

        // Back on the rule's page: Delete leaves "Gone", and the list is empty again.
        goBack()
        app.element(Smart.detail).waitToExist(10)
        detailMenu(Smart.detailDelete, label: "Delete")
        XCTAssertTrue(app.element(Smart.detailGone).waitForExistence(timeout: 10), "Gone")
        XCTAssertFalse(app.button(Smart.detailMore).exists, "no menu for a rule that is gone")
        goBack()
        app.element(TestID.Playlists.root).waitToExist(10)
        XCTAssertTrue(reveal(app.element(Smart.listEmpty)), "no smart playlists left")
        // The frozen playlist stays: it is the server's now.
        XCTAssertNotNil(try api.padPlaylist(named: title))
    }
}
#endif
