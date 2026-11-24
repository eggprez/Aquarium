//  A show's downloads on an iPad, which PadDownloadsTests (one film) leaves
//  out: a season downloaded from the show's Download menu arrives as one
//  poster under Shows, opens into the show's own page (title, "1 season ·
//  6 episodes", Play), and is deleted whole behind its confirmation, which
//  a tap outside the popover cancels.
//
//  FX Short Show's Season 1 is six 45-second episodes (one file holds
//  episodes 5 and 6), so "Original quality" is a copy that finishes in
//  moments on the local server. Nothing on the server changes.

#if os(iOS)
import XCTest

final class PadDownloadsMoreTests: PadUITestCase {
    private func menuRow(_ id: String, beginning words: String) -> XCUIElement {
        let byId = app.buttons.matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 3) { return byId }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    func testASeasonDownloadsAsOneShowAndIsDeletedWhole() throws {
        let show = try fx.item("show.short")
        let s1 = try season("show.short", 1)
        let episodes = (show.raw["seasons"] as? [[String: Any]] ?? [])
            .first { ($0["index"] as? Int) == 1 }?["episodes"] as? [[String: Any]] ?? []
        try XCTSkipUnless(episodes.count == 6, "fixture changed: \(episodes.count) episodes")
        launchHome()
        openItem(show.id)

        let download = app.element(TestID.Detail.download)
        XCTAssertTrue(reveal(download))
        download.padTap()
        let seasonRow = menuRow(TestID.Detail.downloadSeason(s1), beginning: "Season 1")
        XCTAssertTrue(seasonRow.waitForExistence(timeout: 10), "Season 1 in the show's Download menu")
        seasonRow.padTap()
        menuRow(TestID.Detail.downloadSeasonQuality(s1, "Original quality"), beginning: "Original").padTap()
        let anyway = app.button(TestID.Downloads.spacePromptAnyway)
        if anyway.waitForExistence(timeout: 3) { anyway.padTap() }

        showSection("downloads")
        let card = app.button(TestID.Downloads.showCard(show.id))
        XCTAssertTrue(card.waitForExistence(timeout: 180), "the show among the downloads, as one poster")
        XCTAssertTrue(app.element(TestID.Downloads.showsSection).exists, "under Shows")
        XCTAssertFalse(app.elements(prefix: "downloads.film.").firstMatch.exists, "no episode shown as a film")
        attachScreenshot("show downloaded")

        card.padTap()
        app.element(TestID.Downloads.seriesRoot).waitToExist(20)
        XCTAssertEqual(app.element(TestID.Downloads.seriesTitle).label, "FX Short Show")
        let subtitle = app.element(TestID.Downloads.seriesSubtitle)
        XCTAssertTrue(waitUntil(120, "all six episodes on the show's page") { subtitle.label == "1 season · 6 episodes" },
                      "reads \(subtitle.label)")
        XCTAssertTrue(app.button(TestID.Downloads.seriesPlay).exists, "Play on the show's page")
        XCTAssertFalse(app.element(TestID.Downloads.seriesSize).label.isEmpty, "the size it takes")

        // Delete the whole show: the confirmation first, and a tap outside it
        // (an iPad's popover has no Cancel) keeps everything.
        let deleteMenu = app.button(TestID.Downloads.seriesDeleteMenu)
        deleteMenu.padTap()
        tapMenuItem(TestID.Downloads.seriesDeleteAll, label: "Delete the whole show")
        cancelDialog(cancel: TestID.Downloads.deletionCancel, confirm: TestID.Downloads.deletionConfirm)
        XCTAssertEqual(subtitle.label, "1 season · 6 episodes", "Cancel kept the show")

        deleteMenu.padTap()
        tapMenuItem(TestID.Downloads.seriesDeleteAll, label: "Delete the whole show")
        app.button(TestID.Downloads.deletionConfirm).padTap()
        XCTAssertTrue(eventually(20) { [self] in
            app.element(TestID.Downloads.seriesEmpty).exists || !app.element(TestID.Downloads.seriesRoot).exists
        }, "the show's page emptied or went")
        showSection("downloads")
        XCTAssertTrue(card.waitToVanish(20), "the show is gone from Downloads")
    }
}
#endif
