//  `DownloadRecord` on its own: how meta.json is read back (the only record
//  that a download exists), and what a row works out from it — how far along,
//  out of what, where to resume, whether it is an episode or a song.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadRecordTests: XCTestCase {
    private func decode(_ json: String) throws -> DownloadRecord {
        try JSONDecoder().decode(DownloadRecord.self, from: Data(json.utf8))
    }

    private func record(_ configure: (inout DownloadRecord) -> Void = { _ in }) -> DownloadRecord {
        var rec = DownloadRecord(itemId: "abc", title: "Film", name: "Film", type: "Movie")
        configure(&rec)
        return rec
    }

    private func item(_ json: String) throws -> BaseItem {
        try JSONDecoder().decode(BaseItem.self, from: Data(json.utf8))
    }

    // MARK: meta.json

    func testARecordFromAnOlderBuildStillDecodes() throws {
        // One field added to the struct must not make every download written
        // by the build before it disappear: only the id is required.
        let rec = try decode(#"{"itemId":"abc"}"#)
        XCTAssertEqual(rec.itemId, "abc")
        XCTAssertEqual(rec.id, "abc")
        XCTAssertEqual(rec.title, "abc", "named after its id when it knows nothing else")
        XCTAssertEqual(rec.name, "abc")
        XCTAssertEqual(rec.status, .queued)
        XCTAssertEqual(rec.transport, .file, "old records were all single-file transfers")
        XCTAssertEqual(rec.quality, "")
        XCTAssertEqual(rec.fileName, "")
        XCTAssertEqual(rec.sourceURL, "")
        XCTAssertEqual(rec.receivedBytes, 0)
        XCTAssertEqual(rec.totalBytes, 0)
        XCTAssertEqual(rec.runTimeTicks, 0)
        XCTAssertEqual(rec.positionTicks, 0)
        XCTAssertFalse(rec.played)
        XCTAssertTrue(rec.progressSynced, "nothing to send for a record that never noted any")
        XCTAssertFalse(rec.unplayedPending)
        XCTAssertEqual(rec.progressRevision, 0)
        XCTAssertEqual(rec.verifyFailures, 0)
        XCTAssertEqual(rec.autoRetries, 0)
        XCTAssertNil(rec.ownerUserId, "from before owners were kept: anyone's")
        XCTAssertNil(rec.needsMPV)
        XCTAssertNil(rec.hlsPath)
        XCTAssertNil(rec.estimatedBytes)
        XCTAssertNil(rec.type)
        XCTAssertEqual(rec.createdAt.timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testNameFallsBackToTitle() throws {
        let rec = try decode(#"{"itemId":"abc","title":"Show · Season 1: Episode 2 · Pilot"}"#)
        XCTAssertEqual(rec.name, "Show · Season 1: Episode 2 · Pilot")
    }

    func testARecordThatDoesNotKnowWhatItIsIsNotARecord() {
        XCTAssertThrowsError(try decode(#"{"title":"Film","status":"complete"}"#))
    }

    func testKeysFromANewerBuildAreIgnored() throws {
        let rec = try decode(#"{"itemId":"abc","status":"complete","somethingNew":{"a":1},"another":[1,2]}"#)
        XCTAssertEqual(rec.status, .complete)
    }

    func testEveryFieldSurvivesTheRoundTrip() throws {
        var rec = DownloadRecord(
            itemId: "abc", title: "Show · Season 2: Episode 3 · System", name: "System", type: "Episode",
            series: "Show", seriesId: "s1", season: 2, seasonId: "se2", episode: 3, year: 2022,
            runTimeTicks: 18_000_000_000, quality: "720p · 4.5 Mbps (transcoded)", fileName: "System",
            transport: .hls, sourceURL: "http://h/Videos/abc/master.m3u8?PlaySessionId=1",
            estimatedBytes: 1_000_000, positionTicks: 600_000_000, played: true,
            imageURL: "http://h/a", seasonImageURL: "http://h/b", seriesImageURL: "http://h/c",
            album: "Album", albumId: "al1", artist: "Band", track: 4, disc: 2
        )
        rec.hlsPath = "Library/x.movpkg"
        rec.partialPath = "Library/y.movpkg"
        rec.loadedFraction = 0.42
        rec.projectedBytes = 900_000
        rec.receivedBytes = 400_000
        rec.totalBytes = 0
        rec.status = .downloading
        rec.errorMessage = "Paused"
        rec.progressSynced = false
        rec.unplayedPending = true
        rec.progressRevision = 7
        rec.progressChangedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        rec.ownerUserId = "user1"
        rec.verifyFailures = 1
        rec.needsMPV = true
        rec.autoRetries = 3
        rec.createdAt = Date(timeIntervalSinceReferenceDate: 690_000_000)
        let back = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(rec))
        // `needsMPV` is the one field the hand-written decoder has to be
        // taught about and wasn't checked by the compiler; see below.
        var expected = rec
        expected.needsMPV = back.needsMPV
        XCTAssertEqual(back, expected)
    }

    func testNeedsMPVSurvivesARelaunch() throws {
        // A file kept for mpv because AVFoundation won't open it has to
        // still say so after the app has been relaunched, or the player
        // hands it to AVFoundation again.
        var rec = record()
        rec.needsMPV = true
        let back = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(back.needsMPV, true, "read back from meta.json (it was never decoded, so mpv was forgotten at a relaunch)")
    }

    func testStatusNamesOnDisk() throws {
        for status in ["queued", "downloading", "complete", "error", "canceled"] {
            let rec = try decode(#"{"itemId":"a","status":"\#(status)"}"#)
            XCTAssertEqual(rec.status.rawValue, status)
        }
        XCTAssertEqual(try decode(#"{"itemId":"a","transport":"hls"}"#).transport, .hls)
    }

    // MARK: How far along

    func testFractionAgainstTheServersLength() {
        let rec = record {
            $0.receivedBytes = 250
            $0.totalBytes = 1_000
            $0.estimatedBytes = 5_000
        }
        XCTAssertEqual(rec.fraction, 0.25, "a real length beats the estimate")
        XCTAssertEqual(rec.progressTotal?.bytes, 1_000)
        XCTAssertEqual(rec.progressTotal?.estimated, false)
    }

    func testFractionAgainstTheEstimateWhenThereIsNoLength() {
        var rec = record {
            $0.receivedBytes = 500
            $0.estimatedBytes = 2_000
        }
        XCTAssertEqual(rec.fraction, 0.25)
        XCTAssertEqual(rec.progressTotal?.bytes, 2_000)
        XCTAssertEqual(rec.progressTotal?.estimated, true)
        // An encode is variable bitrate: past the estimate the bar holds full.
        rec.receivedBytes = 3_000
        XCTAssertEqual(rec.fraction, 1)
    }

    func testNothingToMeasureAgainstIsNoFraction() {
        let rec = record { $0.receivedBytes = 500 }
        XCTAssertNil(rec.fraction)
        XCTAssertNil(rec.progressTotal)
        XCTAssertNil(record { $0.estimatedBytes = 0 }.progressTotal)
    }

    func testAStreamsFractionIsItsShareOfTheRunningTime() {
        var rec = record {
            $0.transport = .hls
            $0.loadedFraction = 0.4
            $0.receivedBytes = 100
            $0.estimatedBytes = 10_000
        }
        XCTAssertEqual(rec.fraction, 0.4, "time, not bytes: no estimate involved")
        rec.loadedFraction = 1.2
        XCTAssertEqual(rec.fraction, 1)
        rec.loadedFraction = -0.5
        XCTAssertEqual(rec.fraction, 0)
    }

    func testAStreamsTotalIsWhatItsBytesImplyOnceThereIsEnoughToGoOn() {
        var rec = record {
            $0.transport = .hls
            $0.estimatedBytes = 1_200
            $0.receivedBytes = 300
            $0.loadedFraction = 0.4
        }
        // 40% and 300 bytes is 750, not the 1,200 guessed before it began:
        // the percentage, the bar and the bytes are one figure.
        XCTAssertEqual(rec.progressTotal?.bytes, 750)
        XCTAssertEqual(rec.progressTotal?.estimated, true)

        // One segment out of six hundred is not a sample.
        rec.loadedFraction = 0.02
        XCTAssertEqual(rec.progressTotal?.bytes, 1_200)
        rec.loadedFraction = DownloadRecord.projectableFraction
        XCTAssertEqual(rec.progressTotal?.bytes, 10_000)

        // The smoothed projection wins once there is one…
        rec.projectedBytes = 900
        XCTAssertEqual(rec.progressTotal?.bytes, 900)
        // …but a total below what has arrived is a contradiction on screen.
        rec.receivedBytes = 950
        XCTAssertEqual(rec.progressTotal?.bytes, 950)
        // And the finished size beats them all.
        rec.totalBytes = 1_000
        XCTAssertEqual(rec.progressTotal?.bytes, 1_000)
        XCTAssertEqual(rec.progressTotal?.estimated, false)
    }

    func testAStreamWithNothingReceivedFallsBackToTheEstimate() {
        let rec = record {
            $0.loadedFraction = 0.5
            $0.estimatedBytes = 4_000
        }
        XCTAssertEqual(rec.progressTotal?.bytes, 4_000)
    }

    // MARK: Watching

    func testWatchedFraction() {
        var rec = record { $0.runTimeTicks = 1_000 }
        XCTAssertNil(rec.watchedFraction, "untouched")
        rec.positionTicks = 250
        XCTAssertEqual(rec.watchedFraction, 0.25)
        rec.positionTicks = 5_000
        XCTAssertEqual(rec.watchedFraction, 1)
        rec.played = true
        XCTAssertNil(rec.watchedFraction, "finished: nothing to draw")
        XCTAssertNil(record { $0.positionTicks = 10 }.watchedFraction, "no length to measure against")
    }

    func testResumePointOfAFilm() {
        let hour: Int64 = 36_000_000_000
        var rec = record { $0.runTimeTicks = 2 * hour }
        XCTAssertEqual(rec.resumeSeconds, 0)
        rec.positionTicks = hour
        XCTAssertEqual(rec.resumeSeconds, 3_600)
        // Past the server's 90%: it is watched, and resuming it would open
        // on its closing seconds.
        rec.positionTicks = Int64(Double(2 * hour) * 0.95)
        XCTAssertEqual(rec.resumeSeconds, 0)
        rec.positionTicks = hour
        rec.played = true
        XCTAssertEqual(rec.resumeSeconds, 0, "watched starts from the top")
    }

    func testResumePointOfABookGoesByTimeLeftNotByShare() {
        let hour: Int64 = 36_000_000_000
        var book = DownloadRecord(itemId: "b", title: "Book", name: "Book", type: "AudioBook", runTimeTicks: 20 * hour)
        // 95% of a twenty-hour book leaves an hour: not finished.
        book.positionTicks = 19 * hour
        XCTAssertEqual(book.resumeSeconds, 19 * 3_600)
        // Four minutes from the end is.
        book.positionTicks = 20 * hour - 4 * 60 * 10_000_000
        XCTAssertEqual(book.resumeSeconds, 0)
    }

    // MARK: What it is

    func testWhatCountsAsAnEpisodeOrASong() {
        XCTAssertTrue(record { $0.type = "Episode" }.isEpisode)
        XCTAssertFalse(record { $0.type = "Movie" }.isEpisode)
        XCTAssertFalse(record {
            $0.type = "Movie"
            $0.series = "Show"
        }.isEpisode, "a film is a film, whatever it carries")
        XCTAssertTrue(record {
            $0.type = nil
            $0.series = "Show"
        }.isEpisode, "from before types were kept: it has a show, so it is an episode")
        XCTAssertFalse(record { $0.type = nil }.isEpisode)

        XCTAssertTrue(record { $0.type = "Audio" }.isAudio)
        XCTAssertTrue(record { $0.type = "AudioBook" }.isAudio)
        XCTAssertFalse(record { $0.type = "Episode" }.isAudio)
        XCTAssertFalse(record { $0.type = nil }.isAudio)
    }

    func testASongAsAnItemForTheMusicPlayer() {
        var rec = DownloadRecord(
            itemId: "song1", title: "Song", name: "Song", type: "Audio", year: 1999, runTimeTicks: 2_400_000_000,
            positionTicks: 100, played: true, album: "Album", albumId: "al1", artist: "Band", track: 4, disc: 2
        )
        var item = rec.asItem
        XCTAssertEqual(item.Id, "song1")
        XCTAssertEqual(item.Name, "Song")
        XCTAssertEqual(item.type, "Audio")
        XCTAssertEqual(item.MediaType, "Audio")
        XCTAssertTrue(item.isAudio)
        XCTAssertEqual(item.Album, "Album")
        XCTAssertEqual(item.AlbumId, "al1")
        XCTAssertEqual(item.AlbumArtist, "Band")
        XCTAssertEqual(item.Artists, ["Band"])
        XCTAssertEqual(item.IndexNumber, 4)
        XCTAssertEqual(item.ParentIndexNumber, 2)
        XCTAssertEqual(item.RunTimeTicks, 2_400_000_000)
        XCTAssertEqual(item.ProductionYear, 1999)
        XCTAssertEqual(item.userData.positionTicks, 100)
        XCTAssertTrue(item.userData.played)
        XCTAssertNil(item.ExternalLogoURL, "no cover on disk and none on the server")

        rec.artist = ""
        item = rec.asItem
        XCTAssertNil(item.Artists)
        rec.imageURL = "http://h/Items/song1/Images/Primary?tag=t"
        XCTAssertEqual(rec.asItem.ExternalLogoURL, "http://h/Items/song1/Images/Primary?tag=t",
                       "the server's address where nothing has been kept here")
    }

    func testAnEpisodeAsAnItemForThePlayersInfoPage() {
        let rec = DownloadRecord(
            itemId: "ep1", title: "Show · Season 2: Episode 3 · System", name: "System", type: nil,
            series: "Show", seriesId: "s1", season: 2, seasonId: "se2", episode: 3, year: 2022, runTimeTicks: 99
        )
        let item = rec.asVideoItem
        XCTAssertEqual(item.Id, "ep1")
        XCTAssertEqual(item.Name, "System")
        XCTAssertEqual(item.type, "Episode", "worked out, where the record predates types")
        XCTAssertEqual(item.SeriesName, "Show")
        XCTAssertEqual(item.SeriesId, "s1")
        XCTAssertEqual(item.SeasonId, "se2")
        XCTAssertEqual(item.ParentIndexNumber, 2)
        XCTAssertEqual(item.IndexNumber, 3)
        XCTAssertEqual(item.RunTimeTicks, 99)
        XCTAssertEqual(item.ProductionYear, 2022)
        XCTAssertEqual(item.episodeLabel, "Season 2: Episode 3")

        let film = DownloadRecord(itemId: "f", title: "Film", name: "Film").asVideoItem
        XCTAssertEqual(film.type, "Movie")
    }

    // MARK: Taking the server's description

    func testDescribeTakesTheServersWordAndLeavesTheFileAlone() throws {
        ClientStub.install()
        defer { ClientStub.remove() }
        var rec = DownloadRecord(itemId: "ep1", title: "Old", name: "Old", type: "Episode")
        rec.quality = "720p · 4.5 Mbps (transcoded)"
        rec.receivedBytes = 123
        rec.positionTicks = 456
        rec.status = .complete
        let episode = try item("""
        {"Id":"ep1","Name":"System","Type":"Episode","SeriesName":"The Bear","SeriesId":"s1","SeasonId":"se1",
         "ParentIndexNumber":1,"IndexNumber":3,"ProductionYear":2022,"ImageTags":{"Primary":"own"},
         "SeriesPrimaryImageTag":"show"}
        """)
        XCTAssertTrue(rec.describe(episode))
        XCTAssertEqual(rec.title, "The Bear · Season 1: Episode 3 · System")
        XCTAssertEqual(rec.name, "System")
        XCTAssertEqual(rec.series, "The Bear")
        XCTAssertEqual(rec.seriesId, "s1")
        XCTAssertEqual(rec.season, 1)
        XCTAssertEqual(rec.seasonId, "se1")
        XCTAssertEqual(rec.episode, 3)
        XCTAssertEqual(rec.year, 2022)
        // Three levels of picture, kept apart: the episode's own, its
        // season's, its show's.
        XCTAssertTrue(rec.imageURL?.contains("/Items/ep1/Images/Primary") == true, rec.imageURL ?? "nil")
        XCTAssertTrue(rec.imageURL?.contains("tag=own") == true)
        XCTAssertTrue(rec.seasonImageURL?.contains("/Items/se1/Images/Primary") == true)
        XCTAssertTrue(rec.seriesImageURL?.contains("/Items/s1/Images/Primary") == true)
        XCTAssertTrue(rec.seriesImageURL?.contains("tag=show") == true)
        XCTAssertNil(rec.artist, "an episode has no artist, track or disc")
        XCTAssertNil(rec.track)
        XCTAssertNil(rec.disc)
        // Nothing about the file on this device moved.
        XCTAssertEqual(rec.quality, "720p · 4.5 Mbps (transcoded)")
        XCTAssertEqual(rec.receivedBytes, 123)
        XCTAssertEqual(rec.positionTicks, 456)
        XCTAssertEqual(rec.status, .complete)

        XCTAssertFalse(rec.describe(episode), "the same description again changes nothing")
    }

    func testAnEpisodeWithNoStillOfItsOwnBorrowsNone() throws {
        // A row that quietly showed the show's poster is why every episode
        // used to look the same in the downloads list.
        ClientStub.install()
        defer { ClientStub.remove() }
        var rec = DownloadRecord(itemId: "ep1", title: "Old", name: "Old", type: "Episode")
        rec.describe(try item("""
        {"Id":"ep1","Name":"System","Type":"Episode","SeriesName":"Show","SeriesId":"s1","SeriesPrimaryImageTag":"show"}
        """))
        XCTAssertNil(rec.imageURL)
        XCTAssertNotNil(rec.seriesImageURL)
        XCTAssertNil(rec.seasonImageURL, "no season id, no season poster")
    }

    func testDescribeASong() throws {
        var rec = DownloadRecord(itemId: "song1", title: "Old", name: "Old", type: "Audio")
        let described = try item("""
        {"Id":"song1","Name":"Song","Type":"Audio","Album":"Album","AlbumId":"al1","Artists":["A","B"],
         "IndexNumber":4,"ParentIndexNumber":2}
        """)
        XCTAssertTrue(rec.describe(described))
        XCTAssertEqual(rec.title, "Song")
        XCTAssertEqual(rec.album, "Album")
        XCTAssertEqual(rec.albumId, "al1")
        XCTAssertEqual(rec.artist, "A, B", "the album artist, or failing that whoever is on the song")
        XCTAssertEqual(rec.track, 4)
        XCTAssertEqual(rec.disc, 2)
        XCTAssertNil(rec.seriesImageURL)

        rec.describe(try item(#"{"Id":"song1","Name":"Song","Type":"Audio","AlbumArtist":"Band","Artists":["A"]}"#))
        XCTAssertEqual(rec.artist, "Band")
    }
}
#endif
