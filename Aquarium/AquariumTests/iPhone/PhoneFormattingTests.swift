//  Pure helpers the phone draws text and choices from: times, sizes,
//  resolution and channel labels, the quality ladders, languages, artwork
//  steps, the Downloads season order, music and library sort keys, and the
//  "finished" rules for books and videos.

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class PhoneFormattingTests: PhoneUnitTestCase {
    // MARK: Format

    func testTicksReadAsHoursAndMinutes() {
        XCTAssertEqual(Format.ticks(nil), "")
        XCTAssertEqual(Format.ticks(0), "")
        XCTAssertEqual(Format.ticks(48 * 60 * 10_000_000), "48m")
        XCTAssertEqual(Format.ticks((2 * 3600 + 14 * 60) * 10_000_000), "2h 14m")
    }

    /// Regression R-TV-30s (master-fix-list, Apple TV #30; fixed only on
    /// branch claude/qa-fix-list-cb0b58 as 722a3fa): a 30-second clip read
    /// "1m" on its title page and "0m" in Info. Under a minute should read in
    /// seconds.
    func testShortRuntimeReadsSeconds() {
        XCTAssertEqual(Format.ticks(30 * 10_000_000), "30s")
    }

    func testClock() {
        XCTAssertEqual(Format.clock(0), "0:00")
        XCTAssertEqual(Format.clock(252), "4:12")
        XCTAssertEqual(Format.clock(3852), "1:04:12")
        XCTAssertEqual(Format.clock(-5), "0:00")
        XCTAssertEqual(Format.clock(.nan), "0:00")
        XCTAssertEqual(Format.clock(.infinity), "0:00")
    }

    func testBytes() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(2048), "2 KiB")
        XCTAssertEqual(Format.bytes(5 * 1024 * 1024 + 512 * 1024), "5.5 MiB")
        XCTAssertEqual(Format.bytes(3 * (1 << 30)), "3.00 GiB")
    }

    func testResolutionLabelUsesWidthForCroppedFilms() {
        func stream(_ w: Int, _ h: Int) -> MediaStream {
            PhoneJSON.decode(MediaStream.self, #"{"Type":"Video","Width":\#(w),"Height":\#(h)}"#)
        }
        XCTAssertEqual(Format.resolutionLabel(stream(3840, 2160)), "4K")
        XCTAssertEqual(Format.resolutionLabel(stream(1920, 800)), "1080p", "a scope film cropped to 800 lines is still 1080p")
        XCTAssertEqual(Format.resolutionLabel(stream(1280, 720)), "720p")
        XCTAssertEqual(Format.resolutionLabel(stream(720, 576)), "576p")
        XCTAssertEqual(Format.resolutionLabel(stream(854, 480)), "480p")
        XCTAssertEqual(Format.resolutionLabel(stream(320, 240)), "240p")
        XCTAssertNil(Format.resolutionLabel(nil))
    }

    func testChannelLabel() {
        func audio(_ json: String) -> MediaStream { PhoneJSON.decode(MediaStream.self, json) }
        XCTAssertEqual(Format.channelLabel(audio(#"{"Type":"Audio","Channels":8}"#)), "7.1")
        XCTAssertEqual(Format.channelLabel(audio(#"{"Type":"Audio","Channels":6}"#)), "5.1")
        XCTAssertEqual(Format.channelLabel(audio(#"{"Type":"Audio","Channels":2}"#)), "Stereo")
        XCTAssertEqual(Format.channelLabel(audio(#"{"Type":"Audio","Channels":1}"#)), "Mono")
        XCTAssertEqual(Format.channelLabel(audio(#"{"Type":"Audio","ChannelLayout":"mono","Channels":1}"#)), "Mono")
        XCTAssertEqual(Format.channelLabel(audio(#"{"Type":"Audio","ChannelLayout":"5.1(side)"}"#)), "5.1(side)")
        XCTAssertNil(Format.channelLabel(audio(#"{"Type":"Audio"}"#)))
    }

    func testMediaSummaryDescribesTheFile() {
        let item = PhoneJSON.item("""
        {"Id":"x","Type":"Movie","MediaSources":[{"Id":"x","Size":9019431321,"MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","Width":1920,"Height":1080},
          {"Index":1,"Type":"Audio","Codec":"eac3","Channels":6},
          {"Index":2,"Type":"Subtitle","Codec":"srt"},{"Index":3,"Type":"Subtitle","Codec":"srt"}]}]}
        """)
        XCTAssertEqual(Format.mediaSummary(item), ["1080p", "HEVC", "EAC3", "5.1", "2 subtitle tracks", "8.40 GiB"])
        XCTAssertEqual(Format.mediaSummary(PhoneJSON.item(#"{"Id":"y"}"#)), [])
    }

    func testItemSubtitle() {
        let item = PhoneJSON.item(#"{"Id":"x","ProductionYear":2001,"RunTimeTicks":72000000000,"OfficialRating":"PG"}"#)
        XCTAssertEqual(Format.itemSubtitle(item), "2001 · 2h 0m · PG")
        XCTAssertEqual(Format.itemSubtitle(PhoneJSON.item(#"{"Id":"x"}"#)), "")
    }

    func testTrackLabelPrefersTheServersName() {
        XCTAssertEqual(Format.trackLabel(PhoneJSON.decode(MediaStream.self, #"{"Type":"Audio","DisplayTitle":"English - AAC"}"#)), "English - AAC")
        XCTAssertEqual(Format.trackLabel(PhoneJSON.decode(MediaStream.self,
            #"{"Type":"Subtitle","Language":"eng","Codec":"srt","IsForced":true}"#)), "ENG · SRT · Forced")
        XCTAssertEqual(Format.trackLabel(PhoneJSON.decode(MediaStream.self, #"{"Type":"Audio","Index":4}"#)), "Track 4")
    }

    func testParseDateTakesDotNetFractions() {
        XCTAssertNotNil(Format.parseDate("2026-10-22T18:07:01.0441200Z"))
        XCTAssertNotNil(Format.parseDate("2026-10-22T18:07:01Z"))
        XCTAssertNil(Format.parseDate(""))
        XCTAssertNil(Format.parseDate(nil))
        XCTAssertNil(Format.parseDate("yesterday"))
    }

    func testProgramWindowAndProgress() {
        let start = Date().addingTimeInterval(-600), end = Date().addingTimeInterval(600)
        XCTAssertNotNil(Format.programWindow(start: start, end: end))
        XCTAssertNil(Format.programWindow(start: nil, end: end))
    }

    // MARK: PlayerTime

    func testPlayerTime() {
        XCTAssertEqual(PlayerTime.format(7), "0:07")
        XCTAssertEqual(PlayerTime.format(123), "2:03")
        XCTAssertEqual(PlayerTime.format(3723), "1:02:03")
        XCTAssertEqual(PlayerTime.format(-1), "0:00")
        XCTAssertEqual(PlayerTime.format(.infinity), "--:--", "an unknown duration must not trap")
        XCTAssertEqual(PlayerTime.spoken(.nan), "unknown")
        XCTAssertFalse(PlayerTime.spoken(3723).isEmpty)
    }

    // MARK: Quality ladder

    func testQualityLadderStartsWithDirectPlay() {
        XCTAssertNil(Quality.choices.first?.maxBitrate)
        XCTAssertEqual(Quality.label(for: nil), "Direct Play (original)")
        XCTAssertEqual(Quality.shortLabel(for: 5_000_000), "720p")
        XCTAssertEqual(Quality.label(for: 4_000_000), "Custom")
    }

    func testSnappedMovesOldRungsUpToTheNextOne() {
        XCTAssertNil(Quality.snapped(nil))
        XCTAssertEqual(Quality.snapped(5_000_000), 5_000_000)
        XCTAssertEqual(Quality.snapped(4_000_000), 5_000_000, "the old 4 Mbps 720p rung keeps meaning 720p")
        XCTAssertEqual(Quality.snapped(80_000_000), 36_000_000, "above the ladder is the top rung")
        XCTAssertEqual(Quality.rungIndex(nil), 0)
        XCTAssertEqual(Quality.rungIndex(2_500_000), Quality.choices.count - 1)
    }

    func testCapForAnyBitrateIsNeverNone() {
        XCTAssertNil(Quality.cap(for: nil))
        XCTAssertEqual(Quality.cap(for: 5_000_000)?.height, 720)
        XCTAssertEqual(Quality.cap(for: 36_000_000)?.width, 3840)
        XCTAssertNotNil(Quality.cap(for: 1_000), "an unknown small bitrate still gets a size cap")
    }

    /// Regression R-9534a90 ("Try a smaller stream" asked a flat 4 Mbps that
    /// was no rung: the pill read "Custom" and the cap fell to 480p).
    func testTrySmallerStreamAsksARealRung() {
        XCTAssertEqual(Quality.smallerStream(than: nil), 5_000_000)
        XCTAssertEqual(Quality.smallerStream(than: 16_000_000), 5_000_000)
        XCTAssertEqual(Quality.smallerStream(than: 5_000_000), 2_500_000)
        XCTAssertEqual(Quality.smallerStream(than: 2_500_000), 2_500_000)
        for b in [nil, 36_000_000, 10_000_000, 5_000_000, 2_500_000, 3_000_000] as [Int?] {
            let rung = Quality.smallerStream(than: b)
            XCTAssertTrue(Quality.choices.contains { $0.maxBitrate == rung }, "\(String(describing: rung)) is not a rung")
            XCTAssertNotEqual(Quality.shortLabel(for: rung), "Custom")
        }
    }

    /// Regression R-5095d5e (auto quality walked a 6 Mbps 1080p file through
    /// four rungs that all reopened the same file before anything changed).
    func testUntouchedRungForA1080pFile() {
        let source = PhoneJSON.videoSource(width: 1920, height: 1080, bitrate: 6_000_000)
        let rung = Quality.untouchedRung(for: source)
        XCTAssertEqual(Quality.choices[rung].maxBitrate, 10_000_000, "the smallest rung that still leaves 6 Mbps 1080p alone")
        XCTAssertEqual(Quality.untouchedRung(for: nil), 0)
    }

    func testDownloadQualityNamedSurvivesLadderChanges() {
        XCTAssertTrue(DownloadQualities.named("Original quality").original)
        XCTAssertEqual(DownloadQualities.named("1080p · 10 Mbps (transcoded)").maxHeight, 1080,
                       "a label from an older build keeps its resolution")
        let unknown = DownloadQualities.named("something else")
        XCTAssertFalse(unknown.original, "an unknown label must never become a full-size original download")
        XCTAssertEqual(unknown.maxHeight, 480)
        XCTAssertEqual(DownloadQualities.all.first?.menuLabel, "Original")
        XCTAssertEqual(DownloadQualities.all[3].menuLabel, "1080p · 9 Mbps")
    }

    func testDownloadQualityMenuKeysMatchTheCatalogue() {
        // TestID.Item.menuDownloadQuality is keyed by TestID.key(<label>), and
        // the UI tests use these exact keys.
        let keys = DownloadQualities.all.map { TestID.key($0.label) }
        XCTAssertEqual(keys, ["original-quality", "4k-34-mbps-transcoded", "1440p-18-mbps-transcoded",
                              "1080p-9-mbps-transcoded", "720p-4-5-mbps-transcoded", "480p-2-mbps-transcoded"])
    }

    // MARK: Languages

    /// Regression R-f66fe9c-lang: a "pol" preference matched a Portuguese
    /// ("por") track because only the first two letters were compared.
    func testPolishDoesNotMatchPortuguese() {
        XCTAssertFalse(Languages.matches(preference: "pol", tag: "por"))
        XCTAssertFalse(Languages.matches(preference: "por", tag: "pol"))
    }

    func testLanguageMatching() {
        XCTAssertTrue(Languages.matches(preference: "fre,fra", tag: "fra"))
        XCTAssertTrue(Languages.matches(preference: "fre,fra", tag: "fr"))
        XCTAssertTrue(Languages.matches(preference: "eng", tag: "en"))
        XCTAssertTrue(Languages.matches(preference: "eng", tag: "ENG"))
        XCTAssertFalse(Languages.matches(preference: "", tag: "eng"))
        XCTAssertFalse(Languages.matches(preference: "eng", tag: nil))
        XCTAssertFalse(Languages.matches(preference: "eng", tag: ""))
    }

    func testLanguageNames() {
        XCTAssertEqual(Languages.name(for: "deu"), "German")
        XCTAssertEqual(Languages.name(for: "ger"), "German")
        XCTAssertEqual(Languages.name(for: "jpn"), "Japanese")
        XCTAssertEqual(Languages.name(for: "xyz"), "XYZ", "an unknown code keeps its code")
        XCTAssertEqual(Languages.audioChoices.first?.code, "")
        XCTAssertEqual(Languages.subtitleChoices.map(\.code).prefix(3), ["", "off", TrackPreference.forcedOnly])
    }

    // MARK: Artwork and URLs

    func testArtworkLadderNeverRoundsDown() {
        XCTAssertEqual(Artwork.ladder(1), 160)
        XCTAssertEqual(Artwork.ladder(400), 400)
        XCTAssertEqual(Artwork.ladder(401), 480)
        XCTAssertEqual(Artwork.ladder(5000), 5000)
    }

    func testLenientURLTakesAddressesWithSpaces() {
        XCTAssertEqual(URL.lenient("https://a.example/x y.png")?.absoluteString, "https://a.example/x%20y.png")
        XCTAssertEqual(URL.lenient("https://a.example/x%20y.png")?.absoluteString, "https://a.example/x%20y.png",
                       "already-escaped addresses are not escaped twice")
        XCTAssertNil(URL.lenient("   "))
        XCTAssertEqual(URL.lenient("/logo.png", relativeTo: URL(string: "http://h:1/a/"))?.absoluteString, "http://h:1/logo.png")
    }

    // MARK: Downloads grouping

    func testDownloadSeasonsSortSpecialsAndLooseEpisodesLast() {
        let order = [nil, 0, 2, 1].sorted { DownloadGroups.seasonSortKey($0) < DownloadGroups.seasonSortKey($1) }
        XCTAssertEqual(order, [1, 2, 0, nil])
        XCTAssertEqual(DownloadGroups.seasonTitle(0), "Specials")
        XCTAssertEqual(DownloadGroups.seasonTitle(3), "Season 3")
        XCTAssertEqual(DownloadGroups.seasonTitle(nil), "Other episodes")
    }

    // MARK: Sort keys

    /// Regression R-6344432: Songs "by name" came out in track order (a
    /// song's SortName starts with its disc and track numbers) and the A–Z
    /// strip jumped to the wrong rows.
    func testSongsByNameSortByName() {
        XCTAssertEqual(JellyfinClient.sortBy(.name, types: "Audio"), "Name")
        XCTAssertEqual(JellyfinClient.sortBy(.name, types: "MusicAlbum"), MusicSort.name.rawValue)
        XCTAssertEqual(JellyfinClient.sortBy(.recentlyAdded, types: "Audio"), MusicSort.recentlyAdded.rawValue)
    }

    func testMusicSortLabelsAndDirections() {
        for sort in MusicSort.allCases { XCTAssertFalse(sort.label.isEmpty) }
        XCTAssertTrue(MusicSort.recentlyAdded.descending)
        XCTAssertFalse(MusicSort.name.descending)
    }

    /// Regression R-dbd3662b: two titles with the same date added swapped
    /// places between pages, so paging showed one twice and lost the other.
    func testLibrarySortsAreTieBrokenByName() {
        typealias Sort = LibraryView.SortOption
        XCTAssertEqual(Sort.name.tiebroken, "SortName")
        XCTAssertEqual(Sort.random.tiebroken, "Random")
        for sort in [Sort.dateAdded, .releaseDate, .rating, .runtime] {
            XCTAssertEqual(sort.tiebroken, "\(sort.field),SortName")
        }
        XCTAssertEqual(Sort.name.order, "Ascending")
        XCTAssertEqual(Sort.dateAdded.order, "Descending")
    }

    // MARK: Finished rules

    /// Regression R-1228f45: an audiobook stopped with under five minutes
    /// left was not marked finished, so it stayed in Continue Listening.
    func testBookFinishedWithUnderFiveMinutesLeft() {
        XCTAssertTrue(BookProgress.isFinished(position: 56 * 60, duration: 60 * 60))
        XCTAssertFalse(BookProgress.isFinished(position: 0.9 * 3 * 3600, duration: 3 * 3600),
                       "90% of a long book with 18 minutes left is not finished")
        XCTAssertFalse(BookProgress.isFinished(position: 0, duration: 120))
        XCTAssertFalse(BookProgress.isFinished(position: 10, duration: 0))
    }

    func testBookAccountsNewestWins() {
        let now = Date()
        XCTAssertTrue(BookProgress.isStale(eventAt: now.addingTimeInterval(-60), serverLastPlayed: now))
        XCTAssertFalse(BookProgress.isStale(eventAt: now, serverLastPlayed: now.addingTimeInterval(2)), "within the clock slack")
        XCTAssertFalse(BookProgress.isStale(eventAt: now, serverLastPlayed: nil))
        XCTAssertTrue(BookProgress.takesServer(synced: true, localChangedAt: now, serverLastPlayed: nil))
        XCTAssertFalse(BookProgress.takesServer(synced: false, localChangedAt: now, serverLastPlayed: nil))
        XCTAssertTrue(BookProgress.takesServer(synced: false, localChangedAt: now.addingTimeInterval(-60), serverLastPlayed: now))
    }

    func testVideoFinishedPastNinetyPercent() {
        XCTAssertTrue(VideoProgress.isFinished(positionTicks: 91, runTimeTicks: 100))
        XCTAssertFalse(VideoProgress.isFinished(positionTicks: 89, runTimeTicks: 100))
        XCTAssertFalse(VideoProgress.isFinished(positionTicks: 0, runTimeTicks: 100))
        XCTAssertFalse(VideoProgress.isFinished(positionTicks: 50, runTimeTicks: 0))
    }

    // MARK: Errors

    /// Regression R-TV-404 (master-fix-list; fixed only on the QA fix
    /// branch): a blocked title said "Server error 404 on /Items/…", a path
    /// the viewer can do nothing with.
    func testServerErrorDoesNotShowThePath() {
        let message = APIError.server(status: 404, path: "/Items/abc").localizedDescription
        XCTExpectFailure("bug: APIError.server's description includes the request path")
        XCTAssertFalse(message.contains("/Items/"), message)
    }
}
#endif
