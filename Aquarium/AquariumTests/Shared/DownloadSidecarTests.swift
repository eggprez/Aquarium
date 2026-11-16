//  The small files kept beside a download so it is whole with no server to
//  ask: its subtitles, the list of its soundtracks, its skip markers, what
//  the Info page says about it, and the note of whether its stream has been
//  looked over for holes. Signed in to the stub server; every answer is
//  `StubURLProtocol`'s. See Support/DownloadHarness.swift.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadSidecarTests: DownloadTestCase {
    override var signedIn: Bool { true }

    private nonisolated static let streams = """
    {"Index":0,"Type":"Video","Codec":"h264"},
    {"Index":1,"Type":"Audio","Codec":"aac","Language":"eng","DisplayTitle":"English AAC"},
    {"Index":2,"Type":"Subtitle","Codec":"subrip","Language":"eng","DisplayTitle":"English","IsDefault":true},
    {"Index":3,"Type":"Subtitle","Codec":"ass","Language":"jpn","IsForced":true,"DisplayTitle":"Japanese (Forced)"},
    {"Index":4,"Type":"Subtitle","Codec":"pgssub","Language":"eng","DisplayTitle":"English (PGS)"},
    {"Index":5,"Type":"Subtitle","Codec":"subrip","Language":"pt-BR","IsExternal":true,"DisplayTitle":"Português"},
    {"Index":6,"Type":"Subtitle","Codec":"mov_text","DisplayTitle":"Unlabelled"}
    """

    private func episode(_ id: String, streams: String? = DownloadSidecarTests.streams) -> BaseItem {
        let media = streams.map { #","MediaStreams":[\#($0)]"# } ?? ""
        return item("""
        {"Id":"\(id)","Name":"Episode","Type":"Episode","People":[{"Name":"Someone","Type":"Actor"}],
         "Overview":"What happens.","Genres":["Drama"],"Chapters":[{"Name":"One","StartPositionTicks":0}],
         "MediaSources":[{"Id":"src","Container":"mkv","DefaultSubtitleStreamIndex":2\(media)}]}
        """)
    }

    private func subtitle(_ index: Int, of id: String, source: String = "src", format: String = "srt") -> String {
        "/Videos/\(id)/\(source)/Subtitles/\(index)/0/Stream.\(format)"
    }

    private func stubSubtitles(_ indexes: [Int], of id: String) {
        for index in indexes {
            let format = index == 3 ? "ass" : "srt"
            StubURLProtocol.stub(subtitle(index, of: id, format: format),
                                 .init(headers: ["Content-Type": "text/plain"], body: Data("subtitle \(index)".utf8)))
        }
    }

    private var subtitleRequests: [String] {
        StubURLProtocol.requests.compactMap { $0.url?.path }.filter { $0.contains("/Subtitles/") }
    }

    private func requests(to path: String) -> Int {
        StubURLProtocol.requests.filter { $0.url?.path == path }.count
    }

    /// How many times the server has been asked to describe `id` afresh. The
    /// app's own pages ask `/Items` for things of their own meanwhile.
    private func descriptionsAsked(of id: String) -> Int {
        StubURLProtocol.requests.filter {
            guard $0.url?.path == "/Items", let query = $0.url?.query else { return false }
            return query.contains(id) && query.contains("Fields=")
        }.count
    }

    /// A finished download's own folder.
    private func folder(_ id: String, _ configure: (inout DownloadRecord) -> Void = { _ in }) -> URL {
        seed(id, .complete, type: "Episode", configure)
        return DownloadManager.folder(for: id)
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    // MARK: Subtitles

    func testEveryTextSubtitleIsFetchedAndListed() async throws {
        let id = newId()
        let folder = folder(id)
        stubSubtitles([2, 3, 5, 6], of: id)
        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)

        XCTAssertEqual(Set(subtitleRequests), [
            subtitle(2, of: id), subtitle(3, of: id, format: "ass"), subtitle(5, of: id), subtitle(6, of: id),
        ], "picture subtitles have no text to fetch; ASS keeps its styling")
        let index = try XCTUnwrap(DownloadSubtitles.index(in: folder))
        XCTAssertTrue(index.complete)
        XCTAssertEqual(index.attempts, 1)
        XCTAssertEqual(index.mediaSourceId, "src")
        XCTAssertEqual(index.defaultIndex, 2, "what the server would have shown with nothing asked for")
        XCTAssertEqual(index.entries.map(\.index), [2, 3, 5, 6])
        XCTAssertEqual(index.entries.map(\.fileName), [
            "subtitle-2.eng.srt", "subtitle-3.jpn.forced.ass", "subtitle-5.ptbr.srt", "subtitle-6.und.srt",
        ], "plain ASCII, so the name reads back out of an engine's track list as it went in")
        XCTAssertEqual(index.entries.map(\.title), ["English", "Japanese (Forced)", "Português", "Unlabelled"])
        XCTAssertEqual(index.entries.map(\.isDefault), [true, false, false, false])
        XCTAssertEqual(index.entries.map(\.isForced), [false, true, false, false])
        XCTAssertEqual(index.entries.map(\.isExternal), [false, false, true, false])
        XCTAssertEqual(index.entries.map(\.codec), ["subrip", "ass", "subrip", "mov_text"])
        XCTAssertEqual(index.entries.first?.language, "eng")

        XCTAssertEqual(DownloadSubtitles.local(in: folder), index.entries)
        let file = folder.appendingPathComponent("subtitle-3.jpn.forced.ass")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "subtitle 3")
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        // Done: asked again, it ends before the network.
        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        XCTAssertEqual(subtitleRequests.count, 4)
        XCTAssertEqual(DownloadSubtitles.index(in: folder)?.attempts, 1)
    }

    func testAStreamTheServerRefusesIsTriedThreeTimesThenLeft() async throws {
        // Closed captions, a codec it can't convert: left incomplete for
        // good, every play asked for the item and that stream again.
        let id = newId()
        let folder = folder(id)
        stubSubtitles([2, 5, 6], of: id)   // 3 is answered 404
        let refused = subtitle(3, of: id, format: "ass")

        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        var index = try XCTUnwrap(DownloadSubtitles.index(in: folder))
        XCTAssertFalse(index.complete)
        XCTAssertEqual(index.attempts, 1)
        XCTAssertEqual(index.entries.map(\.index), [2, 5, 6], "the rest are still worth having")

        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        index = try XCTUnwrap(DownloadSubtitles.index(in: folder))
        XCTAssertFalse(index.complete)
        XCTAssertEqual(index.attempts, 2)
        XCTAssertEqual(requests(to: subtitle(2, of: id)), 1, "a file already here is not fetched twice")
        XCTAssertEqual(requests(to: refused), 2)

        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        index = try XCTUnwrap(DownloadSubtitles.index(in: folder))
        XCTAssertTrue(index.complete, "three goes: left as it is")
        XCTAssertEqual(index.attempts, 3)

        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        XCTAssertEqual(requests(to: refused), 3)
        XCTAssertEqual(DownloadSubtitles.index(in: folder)?.entries.count, 3)
    }

    func testAnEmptyAnswerIsNotASubtitle() async throws {
        let id = newId()
        let folder = folder(id)
        stubSubtitles([3, 5, 6], of: id)
        StubURLProtocol.stub(subtitle(2, of: id), .init(body: Data()))
        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        let index = try XCTUnwrap(DownloadSubtitles.index(in: folder))
        XCTAssertFalse(index.complete)
        XCTAssertEqual(index.entries.map(\.index), [3, 5, 6])
        XCTAssertFalse(names(in: folder).contains("subtitle-2.eng.srt"))
    }

    func testASubtitleFileThatHasGoneIsFetchedAgain() async throws {
        let id = newId()
        let folder = folder(id)
        stubSubtitles([2, 3, 5, 6], of: id)
        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("subtitle-5.ptbr.srt"))
        XCTAssertEqual(DownloadSubtitles.local(in: folder).map(\.index), [2, 3, 6], "only the files that are actually there")

        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: folder)
        XCTAssertEqual(DownloadSubtitles.local(in: folder).map(\.index), [2, 3, 5, 6])
        XCTAssertEqual(requests(to: subtitle(5, of: id)), 2)
        XCTAssertEqual(requests(to: subtitle(2, of: id)), 1)
    }

    func testAListItemWithoutItsStreamsIsLookedUpFirst() async throws {
        let id = newId()
        let folder = folder(id)
        StubURLProtocol.stub("/Items/\(id)", .init(body: try JSONEncoder().encode(episode(id))))
        stubSubtitles([2, 3, 5, 6], of: id)
        await DownloadSubtitles.fetch(for: episode(id, streams: nil), source: nil, into: folder)
        XCTAssertEqual(requests(to: "/Items/\(id)"), 1)
        XCTAssertEqual(DownloadSubtitles.index(in: folder)?.entries.count, 4)
    }

    func testNoSubtitlesForASongOrADownloadThatHasGone() async {
        let songId = newId()
        let songFolder = folder(songId)
        await DownloadSubtitles.fetch(for: song(songId), source: nil, into: songFolder)
        XCTAssertNil(DownloadSubtitles.index(in: songFolder))
        XCTAssertTrue(DownloadSubtitles.local(in: songFolder).isEmpty)

        // Deleted mid-fetch: nothing is written that would bring the folder back.
        let id = newId()
        let gone = DownloadManager.folderPath(for: id)
        stubSubtitles([2, 3, 5, 6], of: id)
        await DownloadSubtitles.fetch(for: episode(id), source: nil, into: gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    func testAVideoWithNoTextSubtitlesIsCompleteWithNone() async throws {
        let id = newId()
        let folder = folder(id)
        let pictureOnly = #"{"Index":0,"Type":"Video","Codec":"h264"},{"Index":4,"Type":"Subtitle","Codec":"pgssub"}"#
        await DownloadSubtitles.fetch(for: episode(id, streams: pictureOnly), source: nil, into: folder)
        let index = try XCTUnwrap(DownloadSubtitles.index(in: folder))
        XCTAssertTrue(index.complete)
        XCTAssertTrue(index.entries.isEmpty)
        XCTAssertTrue(subtitleRequests.isEmpty)
    }

    // MARK: A download known only by its id

    func testTheVersionThatWasDownloadedIsTheOneAskedAbout() async throws {
        // The first of several versions has its own, differently numbered,
        // streams; the download's address names the one it is.
        let id = newId()
        let folder = folder(id) {
            $0.transport = .hls
            $0.hlsPath = "tmp/DownloadSidecarTests-\(id).movpkg"
            $0.sourceURL = "\(Self.host)/Videos/\(id)/master.m3u8?mediasourceid=v2&AudioStreamIndex=2&PlaySessionId=p"
        }
        StubURLProtocol.stub("/Items/\(id)", json: """
        {"Id":"\(id)","Name":"Film","Type":"Movie","MediaSources":[
          {"Id":"v1","MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264"},
            {"Index":2,"Type":"Subtitle","Codec":"subrip","Language":"eng"}]},
          {"Id":"v2","DefaultAudioStreamIndex":1,"MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264"},
            {"Index":1,"Type":"Audio","Codec":"dts","Language":"eng","DisplayTitle":"English DTS"},
            {"Index":2,"Type":"Audio","Codec":"aac","Language":"fra","DisplayTitle":"Français"},
            {"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"deu"}]}]}
        """)
        StubURLProtocol.stub(subtitle(3, of: id, source: "v2"), .init(body: Data("drei".utf8)))

        await DownloadSubtitles.fetch(itemId: id, into: folder)
        let index = try XCTUnwrap(DownloadSubtitles.index(in: folder))
        XCTAssertEqual(index.mediaSourceId, "v2")
        XCTAssertEqual(index.entries.map(\.fileName), ["subtitle-3.deu.srt"])
        XCTAssertEqual(subtitleRequests, [subtitle(3, of: id, source: "v2")])

        // The list of its soundtracks rides on the same look-up.
        let audio = try XCTUnwrap(DownloadAudioList.index(in: folder))
        XCTAssertEqual(audio.mediaSourceId, "v2")
        XCTAssertEqual(audio.main?.index, 2, "the one the address asked for, not the default")
        XCTAssertEqual(audio.main?.title, "Français")
        XCTAssertEqual(audio.others.map(\.index), [1])

        // Both there: nothing more is asked.
        await DownloadSubtitles.fetch(itemId: id, into: folder)
        XCTAssertEqual(requests(to: "/Items/\(id)"), 1)
    }

    func testAnItemTheServerNoLongerHasLeavesTheDownloadAsItIs() async {
        let id = newId()
        let folder = folder(id)
        await DownloadSubtitles.fetch(itemId: id, into: folder)
        XCTAssertNil(DownloadSubtitles.index(in: folder))
        XCTAssertFalse(DownloadAudioList.exists(in: folder))
        XCTAssertEqual(requests(to: "/Items/\(id)"), 1)
    }

    // MARK: The soundtrack list

    func testAStreamDownloadListsTheSoundtracksItLeftBehind() throws {
        let id = newId()
        let folder = folder(id)
        let source = try JSONDecoder().decode(MediaSource.self, from: Data("""
        {"Id":"src","DefaultAudioStreamIndex":2,"MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"h264"},
          {"Index":1,"Type":"Audio","Codec":"aac","Language":"eng","DisplayTitle":"English"},
          {"Index":2,"Type":"Audio","Codec":"ac3","Language":"spa","DisplayTitle":"Español"},
          {"Index":3,"Type":"Audio","Codec":"aac","Language":"eng","DisplayTitle":"Commentary"}]}
        """.utf8))
        XCTAssertFalse(DownloadAudioList.exists(in: folder))

        DownloadAudioList.save(source: source, sourceURL: "http://h/master.m3u8?audiostreamindex=3", isStream: true, into: folder)
        var index = try XCTUnwrap(DownloadAudioList.index(in: folder))
        XCTAssertTrue(DownloadAudioList.exists(in: folder))
        XCTAssertEqual(index.main, .init(index: 3, language: "eng", title: "Commentary"))
        XCTAssertEqual(index.others.map(\.title), ["English", "Español"])

        // Nothing asked for: the server's default is what came down.
        DownloadAudioList.save(source: source, sourceURL: "http://h/master.m3u8", isStream: true, into: folder)
        index = try XCTUnwrap(DownloadAudioList.index(in: folder))
        XCTAssertEqual(index.main?.index, 2)
        XCTAssertEqual(index.others.map(\.index), [1, 3])

        // The file itself has every track in it: an empty list says so.
        DownloadAudioList.save(source: source, sourceURL: "http://h/Items/x/Download", isStream: false, into: folder)
        index = try XCTUnwrap(DownloadAudioList.index(in: folder))
        XCTAssertNil(index.main)
        XCTAssertTrue(index.others.isEmpty)
        XCTAssertEqual(index.mediaSourceId, "src")

        let gone = DownloadManager.folderPath(for: newId())
        DownloadAudioList.save(source: source, sourceURL: "", isStream: true, into: gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
        XCTAssertNil(DownloadAudioList.index(in: gone))
    }

    // MARK: Skip markers

    func testSkipMarkersAreKeptAndNeverReplacedByAnEmptyAnswer() async {
        let id = newId()
        let folder = folder(id)
        XCTAssertTrue(DownloadSegments.local(in: folder).isEmpty)
        StubURLProtocol.stub("/MediaSegments/\(id)", json: #"{"Items":[{"Type":"Intro","StartTicks":100000000,"EndTicks":400000000}]}"#)
        let first = await DownloadSegments.fetch(itemId: id, into: folder)
        XCTAssertEqual(first.map(\.type), ["Intro"])
        XCTAssertEqual(DownloadSegments.local(in: folder), first)
        XCTAssertEqual(first.first?.start, 10)
        XCTAssertEqual(first.first?.end, 40)

        // Offline, or a server that has forgotten: what is kept is answered.
        StubURLProtocol.stub("/MediaSegments/\(id)", status: 500)
        let second = await DownloadSegments.fetch(itemId: id, into: folder)
        XCTAssertEqual(second, first)

        // Deleted mid-fetch: the answer is passed on and nothing is written.
        let goneId = newId()
        let gone = DownloadManager.folderPath(for: goneId)
        StubURLProtocol.stub("/MediaSegments/\(goneId)", json: #"{"Items":[{"Type":"Outro","StartTicks":0,"EndTicks":10000000}]}"#)
        let third = await DownloadSegments.fetch(itemId: goneId, into: gone)
        XCTAssertEqual(third.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    // MARK: The Info page

    func testWhatTheItemIsIsKeptWithoutItsBulk() async throws {
        let id = newId()
        let folder = folder(id)
        XCTAssertNil(DownloadItemInfo.local(in: folder))
        StubURLProtocol.stub("/Items/\(id)", .init(body: try JSONEncoder().encode(episode(id))))

        let fetched = await DownloadItemInfo.fetch(itemId: id, into: folder)
        XCTAssertEqual(fetched?.Overview, "What happens.")
        let kept = try XCTUnwrap(DownloadItemInfo.local(in: folder))
        XCTAssertEqual(kept.Id, id)
        XCTAssertEqual(kept.Overview, "What happens.")
        XCTAssertEqual(kept.Genres, ["Drama"])
        XCTAssertNil(kept.People, "nothing the Info page draws, and the bulk of the answer")
        XCTAssertNil(kept.Chapters)
        XCTAssertEqual(kept.MediaSources?.first?.streams.count, 7, "the file the server holds is what the page describes")

        // The server gone: what is on disk stays as it was.
        StubURLProtocol.stub("/Items/\(id)", status: 500)
        let again = await DownloadItemInfo.fetch(itemId: id, into: folder)
        XCTAssertNil(again)
        XCTAssertEqual(DownloadItemInfo.local(in: folder)?.Overview, "What happens.")
    }

    func testNoInfoIsKeptForASongOrForSomethingNotDownloaded() async {
        let songId = newId()
        seed(songId, .complete, type: "Audio")
        let song = await DownloadItemInfo.fetch(itemId: songId, into: DownloadManager.folder(for: songId))
        XCTAssertNil(song)
        let unknownId = newId()
        let unknown = await DownloadItemInfo.fetch(itemId: unknownId, into: DownloadManager.folderPath(for: unknownId))
        XCTAssertNil(unknown)
        XCTAssertEqual(requests(to: "/Items/\(songId)") + requests(to: "/Items/\(unknownId)"), 0, "not even asked")
    }

    // MARK: Keeping finished downloads' descriptions up to date

    func testFinishedFilmsAndEpisodesAreDescribedAfreshFromTheServer() async throws {
        let renamed = newId(), dropped = newId(), track = newId(), arriving = newId()
        seed(renamed, .complete, name: "Old Name")
        seed(dropped, .complete, name: "No Longer On The Server")
        seed(track, .complete, type: "Audio", name: "Song")
        seed(arriving, .error, name: "Arriving")
        StubURLProtocol.stub("/Items", json: #"{"Items":[{"Id":"\#(renamed)","Name":"New Name","Type":"Movie","ProductionYear":1995}]}"#)

        await manager.refreshDescriptions(force: true)
        XCTAssertEqual(manager.record(for: renamed)?.name, "New Name")
        XCTAssertEqual(manager.record(for: renamed)?.year, 1995)
        XCTAssertEqual(manager.record(for: dropped)?.name, "No Longer On The Server",
                       "not in the answer: left exactly as it was, still here and still playable")
        let asked = try XCTUnwrap(StubURLProtocol.requests.first {
            $0.url?.path == "/Items" && $0.url?.query?.contains(renamed) == true
        }?.url?.query)
        XCTAssertTrue(asked.contains(dropped))
        XCTAssertFalse(asked.contains(track), "songs are asked about by the music index, not here")
        XCTAssertFalse(asked.contains(arriving), "described seconds ago, from the same item")

        // A few times a day at most.
        await manager.refreshDescriptions()
        XCTAssertEqual(descriptionsAsked(of: renamed), 1)
        await manager.refreshDescriptions(force: true)
        XCTAssertEqual(descriptionsAsked(of: renamed), 2)
    }

    func testDescribeAnswersWithWhatTheServerSaidAndThrowsWhenItCannotBeAsked() async throws {
        let id = newId()
        seed(id, .complete, name: "Old Name")
        let none = try await manager.describe(ids: [])
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(descriptionsAsked(of: id), 0)

        StubURLProtocol.stub("/Items", json: #"{"Items":[{"Id":"\#(id)","Name":"New Name","Type":"Movie"}]}"#)
        let items = try await manager.describe(ids: [id, newId()])
        XCTAssertEqual(items.map(\.Id), [id])
        XCTAssertEqual(manager.record(for: id)?.name, "New Name")

        StubURLProtocol.stub("/Items", status: 500)
        do {
            _ = try await manager.describe(ids: [id])
            XCTFail("a server that could not be asked is not an empty answer")
        } catch {}
        XCTAssertEqual(manager.record(for: id)?.name, "New Name")
    }

    // MARK: Looked over for holes

    private func emptyPackage() throws -> String {
        let url = AppDirectory.url(.cachesDirectory)
            .appendingPathComponent("DownloadSidecarTests-\(UUID().uuidString).movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return DownloadManager.homeRelativePath(url)
    }

    func testAStreamWithNothingMissingIsNotedAsLookedOver() async throws {
        let id = newId()
        let path = try emptyPackage()
        let folder = folder(id) {
            $0.transport = .hls
            $0.hlsPath = path
        }
        XCTAssertNil(DownloadRepair.note(in: folder))
        let mended = await DownloadRepair.mend(id)
        let note = try XCTUnwrap(mended)
        XCTAssertEqual(note.version, DownloadRepair.version)
        XCTAssertEqual(note.mended, 0)
        XCTAssertEqual(note.left, 0)
        let kept = try XCTUnwrap(DownloadRepair.note(in: folder), "kept beside it, so it is looked over once")
        XCTAssertEqual(kept.left, 0)
        XCTAssertEqual(kept.version, 1)
        XCTAssertTrue(names(in: folder).contains(DownloadRepair.fileName))
    }

    func testOnlyAFinishedStreamOfThisAccountIsLookedOver() async throws {
        let path = try emptyPackage()
        let file = newId(), unfinished = newId(), theirs = newId()
        seed(file, .complete) { $0.fileName = "Film.mp4" }
        seed(unfinished, .error) { $0.hlsPath = path }
        seed(theirs, .complete) {
            $0.hlsPath = path
            $0.ownerUserId = "someone-else"
        }
        for id in [file, unfinished, theirs, newId()] {
            let note = await DownloadRepair.mend(id)
            XCTAssertNil(note, "worth another try some other time, and nothing written now")
            XCTAssertNil(DownloadRepair.note(in: DownloadManager.folderPath(for: id)))
        }
    }

    func testTheSweepLooksOverEachFinishedStreamOnce() async throws {
        let first = newId(), second = newId(), film = newId()
        for id in [first, second] {
            let path = try emptyPackage()
            seed(id, .complete) {
                $0.transport = .hls
                $0.hlsPath = path
            }
        }
        seed(film, .complete) { $0.fileName = "Film.mp4" }
        DownloadRepair.sweep()
        DownloadRepair.sweep()   // does nothing while one is running
        await waitUntil("both streams have been looked over") {
            [first, second].allSatisfy { DownloadRepair.note(in: DownloadManager.folderPath(for: $0)) != nil }
        }
        XCTAssertNil(DownloadRepair.note(in: DownloadManager.folderPath(for: film)), "a file download has no segments to mend")
    }
}
#endif
