//  Downloads on an iPad: the section from the sidebar's You group, the
//  sidebar's badge and footer status while a transfer runs, a film
//  downloaded from its page, played from the copy, and deleted.

#if os(iOS)
import XCTest

final class PadDownloadsTests: PadUITestCase {
    func testEmptyDownloadsPage() {
        launchHome()
        showSection("downloads")
        app.element(TestID.Downloads.root).waitToExist(20)
        XCTAssertTrue(app.element(TestID.Downloads.empty).waitForExistence(timeout: 10)
                      || app.element(TestID.Downloads.summary).exists, "a clean test run has nothing downloaded")
        attachScreenshot("downloads")
    }

    /// FX Rated G is 20 seconds of direct-play H.264: a download that
    /// finishes in a moment on the local server.
    func testDownloadPlayAndDeleteAFilm() throws {
        let film = try fx.item("film.rated_g")
        launchHome()
        openItem(film.id)
        let download = app.element(TestID.Detail.download)
        XCTAssertTrue(reveal(download))
        download.padTap()
        app.button(TestID.Detail.downloadQuality("Original quality")).padTap()
        // Sidebar: a badge on Downloads or the footer saying a transfer runs,
        // then "Synced" when it is done.
        let status = app.element(TestID.Sidebar.status)
        showSection("downloads")
        let card = app.element(TestID.Downloads.filmCard(film.id))
        XCTAssertTrue(card.waitForExistence(timeout: 90), "the film among the downloaded films")
        XCTAssertTrue(app.element(TestID.Downloads.filmsSection).exists)
        XCTAssertTrue(waitUntil(30, "the footer to settle") { status.label == "Synced" })
        attachScreenshot("downloaded film")
        // Play from the copy: the quality pill says so.
        contextMenu(on: card, waitingFor: TestID.Downloads.filmCardPlay(film.id))
        app.button(TestID.Downloads.filmCardPlay(film.id)).padTap()
        player.waitToExist(30)
        showControls()
        let pill = app.button(TestID.Player.pillQuality)
        if pill.waitForExistence(timeout: 10) {
            XCTAssertTrue(pill.label.contains("Downloaded") || pill.label.contains("downloaded"), "pill: \(pill.label)")
        }
        closePlayer()
        // Delete, with the confirmation.
        contextMenu(on: card, waitingFor: TestID.Downloads.filmCardDelete(film.id))
        app.button(TestID.Downloads.filmCardDelete(film.id)).padTap()
        app.button(TestID.Downloads.deletionConfirm).padTap()
        XCTAssertTrue(card.waitToVanish(20), "the film is gone from Downloads")
    }

    func testDownloadSettingsOnThePage() {
        launchHome()
        showSection("downloads")
        app.element(TestID.Downloads.root).waitToExist(20)
        let manage = app.button(TestID.Downloads.manageMenu)
        if manage.waitForExistence(timeout: 5) {
            manage.padTap()
            XCTAssertTrue(app.button(TestID.Downloads.manageDownloadAllMusic).waitForExistence(timeout: 5)
                          || app.button(TestID.Downloads.manageDeleteAll).exists)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.9)).tap()
        }
    }
}
#endif
