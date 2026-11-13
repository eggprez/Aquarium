//  A title's page on an iPad: the two-column header (poster beside the
//  facts above 720 pt of column, a compact stack below), the disc actions,
//  the season switch with episodes two across, cast, and the bar's Back.
//  Deep Water, eff49a1; quality-wrap fix 4775e86 (not on main).

#if os(iOS)
import XCTest

final class PadDetailTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testTwoColumnHeaderInLandscape() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        turn(.landscapeLeft)
        openItem(film.id)
        let artwork = app.element(TestID.Detail.artwork)
        let title = app.element(TestID.Detail.title)
        artwork.waitToExist(20)
        title.waitToExist(20)
        XCTAssertLessThan(artwork.frame.maxX, title.frame.minX, "the poster stands beside the title")
        XCTAssertEqual(artwork.frame.minY, title.frame.minY, accuracy: 60, "poster and title start level")
        // In the wide header the synopsis and actions are in the facts column too.
        let actions = app.element(TestID.Detail.actions)
        XCTAssertGreaterThan(actions.frame.minX, artwork.frame.maxX, "actions sit in the facts column")
        attachScreenshot("title landscape")
    }

    func testHeaderInPortrait() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        let artwork = app.element(TestID.Detail.artwork)
        let title = app.element(TestID.Detail.title)
        artwork.waitToExist(20)
        XCTAssertLessThan(artwork.frame.maxX, title.frame.minX, "poster beside the title upright too")
        attachScreenshot("title portrait")
    }

    func testFactsAndOverview() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        XCTAssertTrue(app.element(TestID.Detail.title).label.contains("FX Long Direct Play"))
        app.element(TestID.Detail.facts).waitToExist(10)
        app.element(TestID.Detail.genres).waitToExist(10)
        let overview = app.element(TestID.Detail.overview)
        XCTAssertTrue(reveal(overview))
        // On an iPad a tap on the synopsis unfolds or folds it.
        let before = overview.frame.height
        overview.padTap()
        _ = eventually(5) { overview.frame.height != before }
        attachScreenshot("overview tapped")
    }

    func testResumeLabelAndRemainingOnAFilmInProgress() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        let play = app.button(TestID.Detail.play)
        play.waitToExist(20)
        XCTAssertTrue(play.label.localizedCaseInsensitiveContains("resume"), "the baseline has it at 5:00: \(play.label)")
        XCTAssertTrue(app.element(TestID.Detail.remaining).exists, "time left under Resume")
    }

    func testFavoriteDiscReachesTheServer() throws {
        let film = try fx.item("film.pcm_mov")
        let api = try api()
        try api.setFavorite(film.id, false)
        launchHome()
        openItem(film.id)
        let favorite = app.button(TestID.Detail.favorite)
        favorite.padTap()
        XCTAssertTrue(waitUntil(15, "the server to have it as a favourite") {
            (try? api.userData(film.id).favorite) == true
        })
        favorite.padTap()
        XCTAssertTrue(waitUntil(15, "the favourite to be removed") {
            (try? api.userData(film.id).favorite) == false
        })
    }

    func testWatchedDiscReachesTheServer() throws {
        let film = try fx.item("film.aac71_mp4")
        let api = try api()
        try api.markUnplayed(film.id)
        launchHome()
        openItem(film.id)
        app.button(TestID.Detail.watched).padTap()
        XCTAssertTrue(waitUntil(15, "played on the server") { (try? api.userData(film.id).played) == true })
        app.button(TestID.Detail.watched).padTap()
        XCTAssertTrue(waitUntil(15, "unplayed on the server") { (try? api.userData(film.id).played) == false })
    }

    func testQualityMenuListsTheLadder() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        app.button(TestID.Detail.quality).padTap()
        XCTAssertTrue(app.button(TestID.Detail.qualityOption(nil)).waitForExistence(timeout: 10), "Original")
        XCTAssertGreaterThan(app.elements(prefix: "detail.action.quality.").count, 2)
        attachScreenshot("quality menu")
    }

    func testQualityMenuPlaysAtTheRungChosen() throws {
        let film = try fx.item("film.hevc_mp4")
        launchHome()
        openItem(film.id)
        app.button(TestID.Detail.quality).padTap()
        let rungs = app.elements(prefix: "detail.action.quality.").allElementsBoundByIndex
            .filter { !$0.identifier.hasSuffix(".original") && $0.elementType == .button }
        try XCTSkipIf(rungs.isEmpty, "no transcode rungs offered")
        rungs.last!.padTap()
        player.waitToExist(40)
        showControls()
        let pill = app.button(TestID.Player.pillQuality)
        pill.waitToExist(15)
        // It does play at the rung (the pill reads "Auto, playing 2.5 Mbps"),
        // but the player stays on Auto, which is free to climb away from it:
        // `PlayerModel.qualitySelection` (PlayerModel+Playback.swift:885)
        // reads only `prefs.adaptiveQuality`, and the title page's
        // `play(options: StreamOptions(maxBitrate:))` leaves it on.
        XCTExpectFailure("bug: 'Play at a set quality' from a title page plays the rung but stays on Auto", strict: false)
        XCTAssertFalse(pill.label.contains("Auto"), "the pill holds the rung chosen: \(pill.label)")
        closePlayer()
    }

    func testDownloadMenuOffersQualities() throws {
        let film = try fx.item("film.rated_g")
        launchHome()
        openItem(film.id)
        let download = app.element(TestID.Detail.download)
        XCTAssertTrue(reveal(download))
        download.padTap()
        XCTAssertTrue(app.button(TestID.Detail.downloadQuality("Original quality")).waitForExistence(timeout: 10),
                      "Original quality in the Download menu")
        attachScreenshot("download menu")
    }

    func testSeriesPageHasSeasonSwitchAndEpisodesTwoAcrossInLandscape() throws {
        let show = try fx.item("show.long")
        let s1 = try season("show.long", 1)
        let s2 = try season("show.long", 2)
        let e1 = try episode("show.long", season: 1, episode: 1)
        let e2 = try episode("show.long", season: 1, episode: 2)
        let s2e1 = try episode("show.long", season: 2, episode: 1)
        launchHome()
        turn(.landscapeLeft)
        openItem(show.id)
        let picker = app.element(TestID.Detail.seasonPicker)
        XCTAssertTrue(reveal(picker), "season chips on a show's page")
        XCTAssertTrue(app.button(TestID.Detail.season(s1)).exists)
        XCTAssertTrue(app.button(TestID.Detail.season(s2)).exists)
        let row1 = app.button(TestID.Detail.episode(e1.id)).exists
            ? app.button(TestID.Detail.episode(e1.id)) : app.element(TestID.Detail.episode(e1.id))
        let row2 = app.element(TestID.Detail.episode(e2.id))
        XCTAssertTrue(reveal(row1), "S01E01's row")
        row2.waitToExist(10)
        XCTAssertEqual(row1.frame.minY, row2.frame.minY, accuracy: 4, "two across: E01 and E02 share a line")
        XCTAssertLessThan(row1.frame.maxX, row2.frame.minX)
        // Switch to Season 2.
        reveal(app.button(TestID.Detail.season(s2)))
        app.button(TestID.Detail.season(s2)).padTap()
        app.element(TestID.Detail.episode(s2e1.id)).waitToExist(20)
        XCTAssertTrue(app.button(TestID.Detail.season(s2)).isSelected)
        XCTAssertTrue(row2.waitToVanish(10), "Season 1's episodes went")
        attachScreenshot("season 2")
    }

    func testEpisodeSummaryAndPlayGlyph() throws {
        let show = try fx.item("show.short")
        let e3 = try episode("show.short", season: 1, episode: 3)
        launchHome()
        openItem(show.id)
        let summary = app.element(TestID.Detail.episodeSummary)
        XCTAssertTrue(reveal(summary))
        XCTAssertTrue(summary.label.contains("watched"), "\(summary.label)")
        let glyph = app.button(TestID.Detail.episodePlay(e3.id))
        XCTAssertTrue(reveal(glyph))
        glyph.padTap()
        player.waitToExist(40)
        closePlayer()
    }

    func testEpisodeRowOpensTheEpisodesPageWithItsTrail() throws {
        let show = try fx.item("show.long")
        let e1 = try episode("show.long", season: 1, episode: 1)
        launchHome()
        openItem(show.id)
        let row = app.element(TestID.Detail.episode(e1.id))
        XCTAssertTrue(reveal(row))
        row.padTap()
        app.element(TestID.Detail.page(e1.id)).waitToExist(30)
        app.element(TestID.Detail.ancestors).waitToExist(15)
        let crumb = app.button(TestID.Item.ancestor(show.id))
        XCTAssertTrue(crumb.waitForExistence(timeout: 10), "the show in the trail")
        crumb.padTap()
        app.element(TestID.Detail.page(show.id)).waitToExist(30)
    }

    func testAddToNextUpOnASeriesAsks() throws {
        let show = try fx.item("show.short")
        launchHome()
        openItem(show.id)
        app.button(TestID.Detail.addToNextUp).padTap()
        // On an iPad the confirmation dialog is a popover: no Cancel row (a
        // tap outside cancels), and the system draws its buttons, so they are
        // found by identifier or, failing that, by their words.
        let fromLast = app.button(TestID.Shell.nextUpFromLastWatched).exists
            ? app.button(TestID.Shell.nextUpFromLastWatched) : app.buttons["Add from Last Watched Episode"]
        let fromFirst = app.button(TestID.Shell.nextUpFromFirstEpisode).exists
            ? app.button(TestID.Shell.nextUpFromFirstEpisode) : app.buttons["Add from First Episode"]
        XCTAssertTrue(fromLast.waitForExistence(timeout: 10) || app.buttons["Add from Last Watched Episode"].exists,
                      "Add to Next Up asks where from")
        XCTAssertTrue(fromFirst.exists || app.buttons["Add from First Episode"].exists)
        // Dismiss without choosing: nothing changes on the server.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        XCTAssertTrue(app.buttons["Add from First Episode"].waitToVanish(10))
    }

    func testCastOpensAPersonsPage() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        let cast = app.element(TestID.Detail.cast)
        XCTAssertTrue(reveal(cast, maxSwipes: 15), "Cast & Crew on the page")
        let person = app.elements(prefix: "detail.cast.person.").firstMatch
        person.waitToExist(10)
        if !person.isHittable { reveal(person) }
        person.padTap()
        app.element(TestID.Person.root).waitToExist(30)
        app.element(TestID.Person.films).waitToExist(30)
    }

    func testMoreLikeThis() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        XCTAssertTrue(reveal(app.element(TestID.Detail.moreLikeThis), maxSwipes: 20))
    }

    func testBackReturnsToTheSectionsPage() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let card = cardButton(film.id)
        XCTAssertTrue(reveal(card))
        card.padTap()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
        app.button(TestID.Detail.back).padTap()
        app.element(TestID.Home.root).waitToExist(20)
        XCTAssertTrue(app.element(TestID.Detail.page(film.id)).waitToVanish(10))
    }

    func testTrailerOnATitleWithLocalTrailers() throws {
        let film = try fx.item("film.extras")
        launchHome()
        openItem(film.id)
        let trailer = app.button(TestID.Detail.trailer)
        XCTAssertTrue(reveal(trailer), "two local trailers: a Trailer disc")
        trailer.padTap()
        player.waitToExist(40)
        closePlayer()
    }

    /// Regression, "Multiple versions not selectable" (master-fix-list.md,
    /// TV and Pro Max #6; iPad confirms). FX Versions has three media
    /// sources; fixed on claude/qa-fix-list-cb0b58 as 4775e86 ("A title with
    /// several files offers them under Play at a Set Quality"), not on main.
    func testVersionsAreOfferedOnATitleWithThreeFiles() throws {
        let film = try fx.item("film.versions")
        launchHome()
        openItem(film.id)
        app.button(TestID.Detail.quality).padTap()
        app.button(TestID.Detail.qualityOption(nil)).waitToExist(10)
        // A version row names its file ("2160p HEVC", "1080p H.264", "480p
        // MPEG-2") or says "Version"; the quality ladder's rows and the
        // title's own card ("FX Versions") don't count.
        let rows = app.buttons.allElementsBoundByIndex.filter { b in
            let id = b.identifier
            guard !id.hasPrefix("detail.action.quality."), !id.hasPrefix("item.card."), !id.hasPrefix("home."),
                  !id.hasPrefix("sidebar."), !id.hasPrefix("library."), !id.hasPrefix("detail.header.") else { return false }
            return ["2160p", "HEVC", "MPEG-2", "Version"].contains { b.label.contains($0) }
        }
        let offered = !rows.isEmpty
        attachScreenshot("quality menu on FX Versions")
        XCTExpectFailure("bug: no way to choose one of a title's versions (4775e86 not on main)", strict: false)
        XCTAssertTrue(offered, "a version choice beside the quality ladder")
    }
}
#endif
