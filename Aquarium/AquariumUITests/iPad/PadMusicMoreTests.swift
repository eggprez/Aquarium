//  More of Music on an iPad than PadMusicTests and PadMusicPagesTests reach:
//  the Albums sort menu, a genre's page, the Favorites door, a card's
//  press-and-hold menu (Play, Play Next, Play Later, Add to Favorites), the
//  artist page's order, the album page's facts, Discover's shelves and See
//  all, the Songs door's Play, Shuffle All, and the search field's Clear and
//  Cancel.
//
//  `PadMusicMoreTestCase` is what these and the Now Playing tests share
//  (PadNowPlayingTests.swift).

#if os(iOS)
import XCTest

class PadMusicMoreTestCase: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    // MARK: Getting there

    /// Music → Library → the door, waited on by the page it opens.
    func openDoor(_ door: String, page: String, file: StaticString = #filePath, line: UInt = #line) {
        openMusicLibraryPage(file: file, line: line)
        let button = app.button(TestID.Music.libraryDoor(door))
        XCTAssertTrue(reveal(button), "the \(door) door", file: file, line: line)
        button.padTap(file: file, line: line)
        app.element(page).waitToExist(30, file: file, line: line)
    }

    /// An album's (or genre's, or artist's) tile on the page in front.
    func musicCard(_ id: String) -> XCUIElement {
        app.buttons.matching(identifier: TestID.Music.card(id)).firstMatch
    }

    /// A song's row as the button it is.
    func songRow(_ id: String) -> XCUIElement {
        app.buttons.matching(identifier: TestID.Music.song(id)).firstMatch
    }

    /// Opens the album's page and taps the track, then waits for the
    /// sidebar's card to name it.
    @discardableResult
    func playTrack(_ index: Int, of albumName: String,
                   file: StaticString = #filePath, line: UInt = #line) throws -> (id: String, tracks: [PadTrack]) {
        let album = try fixtureAlbum(albumName)
        try XCTSkipUnless(album.tracks.count > index, "\(albumName) has no track \(index + 1) in fixtures.json")
        openAlbumPage(album.id, file: file, line: line)
        let row = songRow(album.tracks[index].id)
        XCTAssertTrue(reveal(row), "\(album.tracks[index].name)'s row", file: file, line: line)
        row.padTap(file: file, line: line)
        waitForCard(naming: album.tracks[index].name, file: file, line: line)
        return album
    }

    /// The sidebar's Now Playing card, once its title reads `name`.
    func waitForCard(naming name: String, _ timeout: TimeInterval = 40,
                     file: StaticString = #filePath, line: UInt = #line) {
        let title = app.element(TestID.Sidebar.nowPlayingTitle)
        title.waitToExist(timeout, file: file, line: line)
        waitUntil(timeout, "the sidebar's card to name \(name)", file: file, line: line) { title.label == name }
    }

    /// Now Playing, from the sidebar's card.
    func openNowPlaying(file: StaticString = #filePath, line: UInt = #line) {
        let root = app.element(TestID.NowPlaying.root)
        if root.exists { return }
        app.element(TestID.Sidebar.nowPlaying).padTap(30, file: file, line: line)
        root.waitToExist(15, file: file, line: line)
        app.button(TestID.NowPlaying.playPause).waitToExist(10, file: file, line: line)
    }

    func closeNowPlaying(file: StaticString = #filePath, line: UInt = #line) {
        let root = app.element(TestID.NowPlaying.root)
        guard root.exists else { return }
        app.button(TestID.NowPlaying.close).padTap(file: file, line: line)
        XCTAssertTrue(root.waitToVanish(10), "Now Playing closed", file: file, line: line)
    }

    /// What Now Playing says it is playing from.
    var playingFrom: String { app.element(TestID.NowPlaying.source).label }

    /// The song Now Playing names.
    var nowPlayingTitle: String { app.element(TestID.NowPlaying.title).label }

    /// The elapsed time Now Playing shows, in seconds.
    func nowPlayingElapsed() -> Double? {
        let elapsed = app.element(TestID.NowPlaying.elapsed)
        guard elapsed.exists else { return nil }
        return Self.seconds(in: text(elapsed))
    }

    /// Pauses from Now Playing and waits for the button to say Play.
    func pauseInNowPlaying(file: StaticString = #filePath, line: UInt = #line) {
        let button = app.button(TestID.NowPlaying.playPause)
        waitUntil(30, "the song to be playing", file: file, line: line) { button.label == "Pause" }
        button.padTap(file: file, line: line)
        waitUntil(10, "the song to pause", file: file, line: line) { button.label == "Play" }
    }

    // MARK: Menus

    /// Presses and holds a card or a row until its menu is up.
    func pressAndHold(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        element.waitToExist(20, file: file, line: line)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.2)
    }

    /// A row of the menu that is up, by its identifier and, where the
    /// identifier did not reach the system's menu, by how its words begin.
    func menuRow(_ id: String, beginning label: String) -> XCUIElement {
        let byId = app.buttons.matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 4) { return byId }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    func tapMenuRow(_ id: String, beginning label: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = menuRow(id, beginning: label)
        row.waitToExist(10, file: file, line: line)
        // A menu still sliding into place takes a tap beside the row, and
        // stays open with nothing chosen (the sleep timer's, 2026-11-26):
        // wait for the row to stop moving, and tap again while it is there.
        for _ in 0..<3 {
            var last = CGRect.null
            _ = eventually(4) {
                let now = row.frame
                defer { last = now }
                return now == last && !now.isEmpty
            }
            row.padTap(file: file, line: line)
            if row.waitToVanish(2) { return }
        }
    }

    /// Puts a menu away without choosing: a tap at the foot of the page.
    func dismissMenu() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.97)).tap()
    }

    // MARK: The queue

    /// Up Next's rows, top to bottom, by song id.
    func queueIds() -> [String] {
        // One snapshot of the whole tree: reading the rows one by one fails
        // ("no matches found for element at index 4") when the list is
        // re-ordering under the reads, as it is just after Shuffle.
        let prefix = TestID.NowPlaying.queueRow("")
        guard let root = try? app.snapshot() else { return [] }
        var rows: [(id: String, y: CGFloat)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix(prefix) { rows.append((String(node.identifier.dropFirst(prefix.count)), node.frame.minY)) }
            node.children.forEach(walk)
        }
        walk(root)
        return rows.sorted { $0.y < $1.y }.map(\.id)
    }

    func openQueue(file: StaticString = #filePath, line: UInt = #line) {
        app.button(TestID.NowPlaying.queue).padTap(file: file, line: line)
        app.element(TestID.NowPlaying.queueRoot).waitToExist(10, file: file, line: line)
    }

    func closeQueue(file: StaticString = #filePath, line: UInt = #line) {
        let card = app.element(TestID.NowPlaying.queueRoot)
        guard card.exists else { return }
        app.element(TestID.NowPlaying.queueClose).padTap(file: file, line: line)
        XCTAssertTrue(card.waitToVanish(10), "Up Next put away", file: file, line: line)
    }

    /// Where a tile sits in a grid that reads left to right, top to bottom.
    func reads(_ first: XCUIElement, before second: XCUIElement) -> Bool {
        let a = first.frame, b = second.frame
        if abs(a.minY - b.minY) > 24 { return a.minY < b.minY }
        return a.minX < b.minX
    }
}

final class PadMusicMoreTests: PadMusicMoreTestCase {
    // MARK: Library pages

    /// By Title the compilation leads the four fixture albums; by Artist it
    /// follows them, since its album artist is Various Artists and the
    /// others' is FX Band (FIXTURES.md, Music).
    func testAlbumsSortByArtistMovesTheCompilationBehindFXBand() throws {
        let compilation = try fixtureAlbum("FX Compilation")
        let discs = try fixtureAlbum("FX Two Discs")
        openDoor("albums", page: TestID.Music.albums)
        let first = musicCard(compilation.id), last = musicCard(discs.id)
        XCTAssertTrue(reveal(first) && last.waitForExistence(timeout: 10), "both albums in the grid")
        XCTAssertTrue(reads(first, before: last), "by Title: FX Compilation before FX Two Discs")

        app.button(TestID.Music.sortMenu).padTap()
        tapMenuRow(TestID.Music.sortOption(sortKeyArtist), beginning: "Artist")
        // By Artist the compilation goes near the end (Various Artists, after
        // Vangelis), far enough down a 37-album grid that it isn't loaded at
        // the top: FX Two Discs there and the compilation not yet, or behind it.
        XCTAssertTrue(waitUntil(20, "the grid to be by artist") { [self] in
            last.exists && (!first.exists || reads(last, before: first))
        }, "by Artist: FX Band's albums before Various Artists'")
        attachScreenshot("albums by artist")
        XCTAssertTrue(reveal(first), "the compilation further down the grid")
        XCTAssertTrue(!last.exists || reads(last, before: first), "FX Two Discs still reads before it")
        _ = reveal(last)   // back up, where both are by Title

        app.button(TestID.Music.sortMenu).padTap()
        tapMenuRow(TestID.Music.sortOption(sortKeyTitle), beginning: "Title")
        XCTAssertTrue(waitUntil(20, "the grid to be by title again") { [self] in
            first.exists && last.exists && reads(first, before: last)
        })
    }

    /// `MusicSort.artist` and `.name`, as the catalogue keys the options.
    private let sortKeyArtist = "AlbumArtist,SortName"
    private let sortKeyTitle = "SortName"

    /// Recently Added has no sort of its own: it is the Albums page held to
    /// one order.
    func testRecentlyAddedHasNoSortMenu() throws {
        let formats = try fixtureAlbum("FX Formats")
        launchHome()
        showSection("music")
        app.element(TestID.Music.listenNow).waitToExist(30)
        let seeAll = app.button(TestID.Music.shelfSeeAll("new-in-your-library"))
        XCTAssertTrue(reveal(seeAll), "See all on New in Your Library")
        seeAll.padTap()
        app.element(TestID.Music.recentlyAdded).waitToExist(30)
        XCTAssertTrue(app.navigationBars["Recently Added"].waitForExistence(timeout: 10), "the page is titled Recently Added")
        XCTAssertTrue(reveal(musicCard(formats.id)), "a fixture album among the recently added")
        XCTAssertFalse(app.button(TestID.Music.sortMenu).exists, "no Sort on Recently Added")
    }

    /// A genre from the Genres door: its albums, and Play plays the genre,
    /// named for it.
    func testGenrePageListsItsAlbumsAndPlaysTheGenre() throws {
        let genreId = try fixtureMusicId("genres", named: "FX Jazz")
        openDoor("genres", page: TestID.Music.genres)
        var tile = musicCard(genreId)
        if !tile.waitForExistence(timeout: 15) {
            tile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "FX Jazz")).firstMatch
        }
        XCTAssertTrue(reveal(tile), "FX Jazz among the genres")
        tile.padTap()
        app.element(TestID.Music.genre).waitToExist(30)
        XCTAssertTrue(app.navigationBars["FX Jazz"].waitForExistence(timeout: 10), "the page is titled for the genre")
        XCTAssertTrue(app.elements(prefix: TestID.Music.card("")).firstMatch.waitForExistence(timeout: 20),
                      "the genre's albums (or its artists) are listed")
        XCTAssertFalse(app.element(TestID.Music.empty).exists, "FX Jazz is not an empty genre")
        app.button(TestID.Music.playBarPlay).padTap()
        XCTAssertTrue(app.element(TestID.Sidebar.nowPlaying).waitForExistence(timeout: 40), "Play starts the genre")
        openNowPlaying()
        XCTAssertEqual(playingFrom, "FX Jazz", "Now Playing says it plays from the genre")
        attachScreenshot("genre playing")
    }

    /// The baseline's favourites (FIXTURES.md): artist FX Band, album FX
    /// Two Discs, song Disc One Opener, each on its own shelf.
    func testFavoritesDoorShowsTheBaselinesArtistAlbumAndSong() throws {
        let discs = try fixtureAlbum("FX Two Discs")
        let band = try fixtureMusicId("albumArtists", named: "FX Band")
        let server = try api()
        try XCTSkipUnless((try? server.userData(discs.id).favorite) == true
                          && (try? server.userData(discs.tracks[0].id).favorite) == true,
                          "the account is not at its baseline favourites")
        openDoor("favorites", page: TestID.Music.favorites)
        XCTAssertTrue(app.element(TestID.Music.shelf("albums")).waitForExistence(timeout: 30), "an Albums shelf")
        XCTAssertTrue(musicCard(discs.id).exists, "FX Two Discs on it")
        XCTAssertTrue(app.element(TestID.Music.shelf("artists")).exists, "an Artists shelf")
        XCTAssertTrue(musicCard(band).exists
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "FX Band")).firstMatch.exists,
                      "FX Band on it")
        let songs = app.element(TestID.Music.shelf("songs"))
        XCTAssertTrue(reveal(songs), "a Songs shelf")
        XCTAssertTrue(reveal(songRow(discs.tracks[0].id)), "Disc One Opener on it")
        XCTAssertFalse(app.element(TestID.Music.empty).exists)
        // The shelf's See all is the whole list of favourite songs.
        let seeAll = app.button(TestID.Music.shelfSeeAll("songs"))
        XCTAssertTrue(reveal(seeAll))
        seeAll.padTap()
        app.element(TestID.Music.songList).waitToExist(20)
        XCTAssertTrue(app.navigationBars["Favorite Songs"].waitForExistence(timeout: 10))
        XCTAssertTrue(songRow(discs.tracks[0].id).waitForExistence(timeout: 20), "Disc One Opener in Favorite Songs")
    }

    /// Add to Favorites in an album's press-and-hold menu reaches the server,
    /// says so, and the album joins the Favorites page; the menu then offers
    /// to take it out again.
    func testFavouriteFromAnAlbumsMenuReachesTheServerAndTheFavoritesPage() throws {
        let formats = try fixtureAlbum("FX Formats")
        let server = try api()
        try server.setFavorite(formats.id, false)
        addTeardownBlock { try? server.setFavorite(formats.id, false) }
        openDoor("albums", page: TestID.Music.albums)
        let card = musicCard(formats.id)
        XCTAssertTrue(reveal(card), "FX Formats among the albums")
        pressAndHold(card)
        let add = menuRow(TestID.Music.menuFavorite, beginning: "Add to Favorites")
        add.waitToExist(10)
        XCTAssertEqual(add.label, "Add to Favorites")
        add.padTap()
        expectToast(containing: "Added to Favorites")
        XCTAssertTrue(waitUntil(20, "the server to hold the favourite") { (try? server.userData(formats.id).favorite) == true })

        pressAndHold(card)
        let remove = menuRow(TestID.Music.menuFavorite, beginning: "Remove from Favorites")
        remove.waitToExist(10)
        XCTAssertEqual(remove.label, "Remove from Favorites", "the menu follows the favourite")
        dismissMenu()

        // A back tap while the menu is still closing is taken by the menu.
        let library = app.element(TestID.Music.library)
        for _ in 0..<3 where !library.exists {
            goBack()
            _ = library.waitForExistence(timeout: 4)
        }
        library.waitToExist(10)
        let door = app.button(TestID.Music.libraryDoor("favorites"))
        XCTAssertTrue(reveal(door))
        door.padTap()
        app.element(TestID.Music.favorites).waitToExist(20)
        XCTAssertTrue(musicCard(formats.id).waitForExistence(timeout: 20), "FX Formats among the favourite albums")
    }

    // MARK: A card's menu

    /// Play starts the album; Play Next puts another album straight after
    /// what is playing; Play Later puts a third at the end. Up Next shows
    /// the three in that order.
    func testAlbumMenuPlaysThenQueuesNextAndLater() throws {
        let long = try fixtureAlbum("FX Long Tracks")
        let compilation = try fixtureAlbum("FX Compilation")
        let formats = try fixtureAlbum("FX Formats")
        try XCTSkipUnless(long.tracks.count == 2, "fixture changed")
        openDoor("albums", page: TestID.Music.albums)

        let longCard = musicCard(long.id)
        XCTAssertTrue(reveal(longCard))
        pressAndHold(longCard)
        XCTAssertTrue(menuRow(TestID.Music.menuShuffle, beginning: "Shuffle").waitForExistence(timeout: 10),
                      "an album's menu has Shuffle")
        XCTAssertFalse(app.buttons.matching(identifier: TestID.Music.menuSongInfo).firstMatch.exists,
                       "Song Info is a song's alone")
        tapMenuRow(TestID.Music.menuPlay, beginning: "Play")
        waitForCard(naming: long.tracks[0].name)

        let compilationCard = musicCard(compilation.id)
        XCTAssertTrue(reveal(compilationCard))
        pressAndHold(compilationCard)
        tapMenuRow(TestID.Music.menuPlayNext, beginning: "Play Next")
        expectToast(containing: "Playing next")

        let formatsCard = musicCard(formats.id)
        XCTAssertTrue(reveal(formatsCard))
        pressAndHold(formatsCard)
        tapMenuRow(TestID.Music.menuPlayLater, beginning: "Play Later")
        expectToast(containing: "Added to the queue")

        openNowPlaying()
        XCTAssertEqual(playingFrom, "FX Long Tracks")
        openQueue()
        let expected = compilation.tracks.map(\.id) + [long.tracks[1].id] + formats.tracks.map(\.id)
        XCTAssertTrue(waitUntil(15, "Up Next to list the three albums in order") { [self] in
            Array(queueIds().prefix(compilation.tracks.count + 1)) == Array(expected.prefix(compilation.tracks.count + 1))
        }, "Up Next begins \(queueIds().prefix(6)), expected \(expected.prefix(6))")
        // A list builds the rows near the screen; what it has built is the
        // expected order as far as it goes.
        let shown = queueIds()
        XCTAssertEqual(shown, Array(expected.prefix(shown.count)), "Play Later's album follows what was already queued")
        attachScreenshot("queued next and later")
    }

    // MARK: Detail pages

    /// The artist's page: the name over the hero, Top Songs above the grid
    /// of albums (FEATURE-LIST, "Artist page"), every FX Band album in the
    /// grid, and Play plays the artist.
    func testArtistPageHasTopSongsThenEveryAlbumAndPlays() throws {
        let formats = try fixtureAlbum("FX Formats")
        let long = try fixtureAlbum("FX Long Tracks")
        let discs = try fixtureAlbum("FX Two Discs")
        openAlbumPage(formats.id)
        app.button(TestID.Music.detailArtist).padTap()
        app.element(TestID.Music.artist).waitToExist(30)
        let name = app.element(TestID.Music.artistName)
        name.waitToExist(20)
        XCTAssertEqual(name.label, "FX Band")
        let albums = app.element(TestID.Music.shelf("albums"))
        XCTAssertTrue(reveal(albums), "the Albums grid")
        let top = app.element(TestID.Music.shelf("top-songs"))
        if top.exists {
            XCTAssertLessThan(top.frame.minY, albums.frame.minY, "Top Songs comes before Albums")
        }
        for album in [formats, long, discs] {
            XCTAssertTrue(reveal(musicCard(album.id)), "album \(album.id) in FX Band's grid")
        }
        let play = app.button(TestID.Music.playBarPlay)
        XCTAssertTrue(reveal(play, maxSwipes: 4), "the artist's Play")
        play.padTap()
        XCTAssertTrue(app.element(TestID.Sidebar.nowPlaying).waitForExistence(timeout: 40), "Play starts the artist's songs")
        openNowPlaying()
        XCTAssertEqual(playingFrom, "FX Band")
    }

    /// An album's page: its name in the header, the count and length under
    /// the tracks, and the artist's other albums below.
    func testAlbumPageHeaderFooterAndMoreByTheArtist() throws {
        let long = try fixtureAlbum("FX Long Tracks")
        let formats = try fixtureAlbum("FX Formats")
        openAlbumPage(long.id)
        let title = app.element(TestID.Music.headerTitle)
        title.waitToExist(20)
        XCTAssertEqual(title.label, "FX Long Tracks")
        XCTAssertEqual(app.button(TestID.Music.detailArtist).label, "FX Band")
        let footer = app.element(TestID.Music.detailFooter)
        XCTAssertTrue(reveal(footer), "the line under the tracks")
        // Twelve minutes and six.
        XCTAssertEqual(footer.label, "2 songs, 18 min")
        let more = app.element(TestID.Music.shelf("moreByArtist"))
        XCTAssertTrue(reveal(more), "More by FX Band")
        XCTAssertTrue(musicCard(formats.id).waitForExistence(timeout: 10), "another FX Band album on it")
        XCTAssertFalse(musicCard(long.id).exists, "the album itself is not among the others")
    }

    // MARK: Discover

    /// Discover greets by the time of day and, at the baseline, has New in
    /// Your Library and the favourite album and artist on their shelves.
    func testDiscoverGreetsAndShelvesTheBaselinesFavourites() throws {
        let discs = try fixtureAlbum("FX Two Discs")
        let server = try api()
        try XCTSkipUnless((try? server.userData(discs.id).favorite) == true, "the account is not at its baseline favourites")
        launchHome()
        showSection("music")
        app.element(TestID.Music.listenNow).waitToExist(30)
        let greeting = app.element(TestID.Music.greeting)
        greeting.waitToExist(30)
        XCTAssertTrue(["Good Morning", "Good Afternoon", "Good Evening"].contains(greeting.label), greeting.label)
        XCTAssertTrue(reveal(app.element(TestID.Music.shelf("new-in-your-library"))), "New in Your Library")
        let favourites = app.element(TestID.Music.shelf("favorite-albums"))
        XCTAssertTrue(reveal(favourites), "Favorite Albums")
        XCTAssertTrue(musicCard(discs.id).waitForExistence(timeout: 10), "FX Two Discs on Favorite Albums")
        XCTAssertTrue(reveal(app.element(TestID.Music.shelf("favorite-artists"))), "Favorite Artists")
        // Favorite Albums' See all is the Favorites page.
        let seeAll = app.button(TestID.Music.shelfSeeAll("favorite-albums"))
        XCTAssertTrue(reveal(seeAll))
        seeAll.padTap()
        app.element(TestID.Music.favorites).waitToExist(20)
    }

    func testShuffleAllPlaysFromTheWholeLibrary() {
        launchHome()
        showSection("music")
        app.element(TestID.Music.listenNow).waitToExist(30)
        app.button(TestID.Music.shuffleAll).padTap(30)
        XCTAssertTrue(app.element(TestID.Sidebar.nowPlaying).waitForExistence(timeout: 40), "Shuffle All starts something")
        openNowPlaying()
        XCTAssertEqual(playingFrom, "Shuffle All")
        openQueue()
        XCTAssertTrue(app.elements(prefix: TestID.NowPlaying.queueRow("")).firstMatch.waitForExistence(timeout: 10),
                      "the rest of the library is queued behind it")
        XCTAssertTrue(app.button(TestID.NowPlaying.queueClear).exists, "Clear is offered while something is queued")
    }

    /// The Songs door: Play on the bar plays the list, named "Songs".
    func testSongsDoorPlayBarPlaysTheList() {
        openDoor("songs", page: TestID.Music.songs)
        let play = app.button(TestID.Music.playBarPlay)
        play.padTap(30)
        XCTAssertTrue(app.element(TestID.Sidebar.nowPlaying).waitForExistence(timeout: 40))
        XCTAssertTrue(app.button(TestID.Music.sortMenu).exists, "Songs has a Sort menu")
        openNowPlaying()
        XCTAssertEqual(playingFrom, "Songs")
    }

    // MARK: Search

    /// The field under the bar: the prompt while it is empty, "No matches"
    /// for a word nothing has, Clear empties it back to the prompt, Cancel
    /// leaves the search for Discover.
    func testSearchPromptNoMatchesClearAndCancel() {
        launchHome()
        showSection("music")
        app.element(TestID.Music.root).waitToExist(30)
        let field = app.textFields[TestID.Music.searchField]
        field.padTap(30)
        XCTAssertTrue(app.element(TestID.Music.searchPrompt).waitForExistence(timeout: 10), "\"Search your music\" before a word is typed")
        let cancel = app.button(TestID.Music.searchCancel)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel beside the field while it has the keyboard")
        XCTAssertFalse(app.button(TestID.Music.searchClear).exists, "nothing to clear yet")

        field.typeText("zzqxj")
        XCTAssertTrue(app.element(TestID.Music.empty).waitForExistence(timeout: 20), "No matches")
        XCTAssertTrue(app.staticTexts["No matches"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Nothing in your music matches")).firstMatch.exists,
                      "and says what was searched")
        XCTAssertFalse(app.element(TestID.Music.searchResults).exists)

        app.button(TestID.Music.searchClear).padTap()
        XCTAssertTrue(app.element(TestID.Music.searchPrompt).waitForExistence(timeout: 10), "Clear goes back to the prompt")
        XCTAssertEqual((field.value as? String) ?? "", field.placeholderValue ?? "", "the field is empty")

        cancel.padTap()
        XCTAssertTrue(app.element(TestID.Music.listenNow).waitForExistence(timeout: 10), "Cancel goes back to Discover")
        XCTAssertTrue(cancel.waitToVanish(5), "and Cancel goes with it")
    }

    /// A song found by the search plays, with the results as its queue.
    func testASongFoundBySearchPlaysFromSearch() throws {
        let long = try fixtureAlbum("FX Long Tracks")
        launchHome()
        showSection("music")
        app.element(TestID.Music.root).waitToExist(30)
        let field = app.textFields[TestID.Music.searchField]
        field.padTap(30)
        field.typeText("Twelve Minutes")
        app.element(TestID.Music.searchResults).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Music.shelf("songs")).waitForExistence(timeout: 10), "a Songs section in the results")
        let row = songRow(long.tracks[0].id)
        row.waitToExist(20)
        dismissKeyboard()
        row.padTap()
        waitForCard(naming: long.tracks[0].name)
        openNowPlaying()
        XCTAssertEqual(playingFrom, "Search")
    }
}
#endif
