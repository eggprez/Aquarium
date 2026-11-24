//  The Jellyfin models (`Core/Models.swift`): what is read off an item once
//  it is decoded. The JSON is cut down from what the server sends, with the
//  server's own field names.

import XCTest
@testable import Aquarium

final class CoreModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func item(_ json: String) throws -> BaseItem { try decode(BaseItem.self, json) }

    // MARK: Decoding

    func testAnItemWithNothingButAnIdDecodes() throws {
        let bare = try item(#"{"Id":"abc"}"#)
        XCTAssertEqual(bare.id, "abc")
        XCTAssertEqual(bare.title, "Untitled")
        XCTAssertEqual(bare.kind, "")
        XCTAssertEqual(bare.runtimeSeconds, 0)
        XCTAssertFalse(bare.userData.played)
        XCTAssertFalse(bare.userData.isFavorite)
        XCTAssertEqual(bare.userData.positionTicks, 0)
        XCTAssertNil(bare.progressFraction)
        XCTAssertNil(bare.episodeLabel)
    }

    func testFieldsTheAppDoesNotKnowAreIgnored() throws {
        let film = try item("""
        {"Id":"f1","Name":"FX Long","Type":"Movie","SomethingNew":{"a":[1,2]},"RunTimeTicks":36000000000,
         "UserData":{"Played":true,"IsFavorite":true,"PlaybackPositionTicks":18000000000,"Unknown":1}}
        """)
        XCTAssertEqual(film.kind, "Movie", "the JSON's Type is the model's type")
        XCTAssertEqual(film.runtimeSeconds, 3600)
        XCTAssertTrue(film.userData.played)
        XCTAssertTrue(film.userData.isFavorite)
        XCTAssertEqual(film.progressFraction ?? 0, 0.5, accuracy: 0.0001)
    }

    func testAnItemsEnvelopeCountsWhatItHolds() throws {
        let counted = try decode(ItemsResponse.self, #"{"Items":[{"Id":"a"},{"Id":"b"}],"TotalRecordCount":40}"#)
        XCTAssertEqual(counted.items.count, 2)
        XCTAssertEqual(counted.total, 40)
        let uncounted = try decode(ItemsResponse.self, #"{"Items":[{"Id":"a"},{"Id":"b"}]}"#)
        XCTAssertEqual(uncounted.total, 2, "no total from the server: what arrived")
        let empty = try decode(ItemsResponse.self, "{}")
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.total, 0)
    }

    // MARK: Episodes

    func testEpisodeLabelIsSpelledOut() throws {
        XCTAssertEqual(BaseItem.episodeLabel(season: 2, episode: 4), "Season 2: Episode 4")
        XCTAssertEqual(BaseItem.episodeLabel(season: 0, episode: 3), "Specials: Episode 3")
        XCTAssertEqual(BaseItem.episodeLabel(season: nil, episode: 7), "Episode 7")
        XCTAssertNil(BaseItem.episodeLabel(season: 2, episode: nil))
        let episode = try item(#"{"Id":"e","Type":"Episode","ParentIndexNumber":1,"IndexNumber":12}"#)
        XCTAssertEqual(episode.episodeLabel, "Season 1: Episode 12")
        XCTAssertTrue(episode.isEpisode)
    }

    func testAGuideProgrammesEpisodeLine() throws {
        XCTAssertEqual(try item(#"{"Id":"p","EpisodeTitle":"  The Pilot ","ParentIndexNumber":5,"IndexNumber":12}"#).programmeEpisodeLine, "The Pilot")
        XCTAssertEqual(try item(#"{"Id":"p","EpisodeTitle":"  ","ParentIndexNumber":5,"IndexNumber":12}"#).programmeEpisodeLine, "S5 E12")
        XCTAssertEqual(try item(#"{"Id":"p","IndexNumber":12}"#).programmeEpisodeLine, "Episode 12")
        XCTAssertEqual(try item(#"{"Id":"p","ParentIndexNumber":0,"IndexNumber":3}"#).programmeEpisodeLine, "Episode 3",
                       "season 0 is no season to name")
        XCTAssertNil(try item(#"{"Id":"p","ParentIndexNumber":5}"#).programmeEpisodeLine, "a film or a one-off has no line")
    }

    // MARK: Progress

    func testProgressIsAFractionOnlyWhilePartWay() throws {
        func fraction(_ position: Int64, of total: Int64?) throws -> Double? {
            let run = total.map { ",\"RunTimeTicks\":\($0)" } ?? ""
            return try item("{\"Id\":\"x\"\(run),\"UserData\":{\"PlaybackPositionTicks\":\(position)}}").progressFraction
        }
        XCTAssertEqual(try fraction(300, of: 1000) ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertNil(try fraction(0, of: 1000), "not started")
        XCTAssertNil(try fraction(300, of: nil), "no length to measure against")
        XCTAssertNil(try fraction(300, of: 0))
        XCTAssertNil(try fraction(1, of: 10_000), "the first thousandth draws no bar")
        XCTAssertNil(try fraction(9_995, of: 10_000), "the last thousandth is finished, not part way")
    }

    // MARK: Kinds

    func testWhatCountsAsAudioAndWhatAVideoScreenLeavesOut() throws {
        let song = try item(#"{"Id":"s","Type":"Audio"}"#)
        XCTAssertTrue(song.isSong)
        XCTAssertTrue(song.isAudio)
        XCTAssertTrue(song.isNotVideo)
        let book = try item(#"{"Id":"b","Type":"AudioBook"}"#)
        XCTAssertTrue(book.isAudiobook)
        XCTAssertTrue(book.isAudio)
        XCTAssertFalse(book.isSong)
        let typedByMedia = try item(#"{"Id":"m","Type":"Folder","MediaType":"Audio"}"#)
        XCTAssertTrue(typedByMedia.isAudio, "MediaType alone makes it the music player's")
        for kind in ["Book", "MusicAlbum", "MusicArtist", "Photo", "PhotoAlbum"] {
            XCTAssertTrue(try item("{\"Id\":\"k\",\"Type\":\"\(kind)\"}").isNotVideo, kind)
        }
        for kind in ["Movie", "Series", "Season", "Episode", "BoxSet", "TvChannel", "Video"] {
            XCTAssertFalse(try item("{\"Id\":\"k\",\"Type\":\"\(kind)\"}").isNotVideo, kind)
        }
        XCTAssertTrue(try item(#"{"Id":"a","Type":"MusicAlbum"}"#).isAlbum)
        XCTAssertTrue(try item(#"{"Id":"a","Type":"MusicArtist"}"#).isArtist)
        XCTAssertTrue(try item(#"{"Id":"a","Type":"MusicGenre"}"#).isMusicGenre)
        XCTAssertTrue(try item(#"{"Id":"a","Type":"Playlist"}"#).isPlaylist)
    }

    func testFoldersAndWhatOpensAsItsContents() throws {
        for kind in ["Series", "Season", "BoxSet", "Folder", "CollectionFolder", "PhotoAlbum"] {
            XCTAssertTrue(try item("{\"Id\":\"k\",\"Type\":\"\(kind)\"}").isFolderLike, kind)
        }
        XCTAssertFalse(try item(#"{"Id":"k","Type":"Movie"}"#).isFolderLike)
        XCTAssertTrue(try item(#"{"Id":"k","Type":"Folder"}"#).opensAsContainer)
        XCTAssertTrue(try item(#"{"Id":"k","Type":"PhotoAlbum"}"#).opensAsContainer)
        XCTAssertFalse(try item(#"{"Id":"k","Type":"BoxSet"}"#).opensAsContainer, "a collection has a page of its own")
        XCTAssertFalse(try item(#"{"Id":"k","Type":"Series"}"#).opensAsContainer)
        XCTAssertTrue(try item(#"{"Id":"k","Type":"Series"}"#).isSeries)
        XCTAssertTrue(try item(#"{"Id":"k","Type":"Season"}"#).isSeason)
    }

    func testTheLineUnderASongNamesWhoMadeIt() throws {
        XCTAssertEqual(try item(#"{"Id":"s","Artists":["Ada","Bo"],"AlbumArtist":"Various"}"#).artistLine, "Ada, Bo")
        XCTAssertEqual(try item(#"{"Id":"s","Artists":[],"AlbumArtist":"Various","AlbumArtists":[{"Name":"X"}]}"#).artistLine, "Various")
        XCTAssertEqual(try item(#"{"Id":"s","AlbumArtist":"","AlbumArtists":[{"Name":"X","Id":"1"},{"Id":"2"},{"Name":"Y"}]}"#).artistLine, "X, Y")
        XCTAssertEqual(try item(#"{"Id":"s"}"#).artistLine, "")
    }

    // MARK: Live TV

    func testAProgrammeIsAiringBetweenItsEdges() throws {
        var programme = try item(#"{"Id":"p","Type":"Program"}"#)
        XCTAssertFalse(programme.isAiringNow, "no times, not on")
        programme.ExternalStart = Date().addingTimeInterval(-600)
        programme.ExternalEnd = Date().addingTimeInterval(600)
        XCTAssertTrue(programme.isAiringNow)
        programme.ExternalStart = Date().addingTimeInterval(300)
        XCTAssertFalse(programme.isAiringNow, "not started yet")
        programme.ExternalStart = Date().addingTimeInterval(-1200)
        programme.ExternalEnd = Date().addingTimeInterval(-600)
        XCTAssertFalse(programme.isAiringNow, "already over")
    }

    func testAProgrammesParsedDatesWinOverItsStrings() throws {
        var programme = try item(#"{"Id":"p","StartDate":"2026-10-22T18:00:00Z","EndDate":"2026-10-22T19:00:00Z"}"#)
        let start = try XCTUnwrap(programme.programStart)
        let end = try XCTUnwrap(programme.programEnd)
        XCTAssertEqual(end.timeIntervalSince(start), 3600, accuracy: 0.001)
        let moved = Date(timeIntervalSince1970: 1_000_000)
        programme.ExternalStart = moved
        XCTAssertEqual(programme.programStart, moved)
        XCTAssertEqual(programme.programEnd, end, "the end still comes from its string")
    }

    // MARK: Streams

    func testPictureSubtitlesAreToldFromText() throws {
        for codec in ["pgssub", "PGSSUB", "pgs", "dvdsub", "dvd_subtitle", "dvbsub", "DVB_Subtitle", "vobsub", "xsub"] {
            XCTAssertTrue(try decode(MediaStream.self, "{\"Type\":\"Subtitle\",\"Codec\":\"\(codec)\"}").isImageSubtitle, codec)
        }
        for codec in ["subrip", "srt", "ass", "webvtt", "mov_text"] {
            XCTAssertFalse(try decode(MediaStream.self, "{\"Type\":\"Subtitle\",\"Codec\":\"\(codec)\"}").isImageSubtitle, codec)
        }
        XCTAssertFalse(try decode(MediaStream.self, #"{"Type":"Subtitle"}"#).isImageSubtitle)
    }

    func testATracksMenuLabel() throws {
        func label(_ json: String) throws -> String { try decode(MediaStream.self, json).menuLabel }
        XCTAssertEqual(try label(#"{"Type":"Audio","DisplayTitle":"English - Dolby Digital - 5.1","Title":"x","Codec":"ac3"}"#),
                       "English - Dolby Digital - 5.1", "the server's own title wins")
        XCTAssertEqual(try label(#"{"Type":"Audio","DisplayTitle":"","Title":"Commentary","Codec":"ac3","ChannelLayout":"5.1","IsForced":true}"#),
                       "Commentary · AC3 · 5.1 · Forced")
        XCTAssertEqual(try label(#"{"Type":"Audio","Codec":"aac","Channels":2}"#), "AAC · 2ch")
        XCTAssertEqual(try label(#"{"Type":"Audio","Index":4}"#), "Track 4")
        XCTAssertEqual(try label(#"{"Type":"Audio"}"#), "Track 0")
    }

    func testASourcesTracksKeepTheServersOrder() throws {
        let source = try decode(MediaSource.self, """
        {"Id":"src","MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"h264"},
          {"Index":1,"Type":"Audio","Codec":"eac3"},
          {"Index":2,"Type":"Subtitle","Codec":"subrip"},
          {"Index":3,"Type":"Audio","Codec":"aac"},
          {"Index":4,"Type":"Subtitle","Codec":"pgssub"}]}
        """)
        XCTAssertEqual(source.streams.count, 5)
        XCTAssertEqual(source.audioStreams.map(\.Index), [1, 3])
        XCTAssertEqual(source.subtitleStreams.map(\.Index), [2, 4])
        XCTAssertTrue(try decode(MediaSource.self, #"{"Id":"src"}"#).streams.isEmpty)
    }

    func testChapterAndSegmentTimes() throws {
        XCTAssertEqual(try decode(ChapterInfo.self, #"{"Name":"One","StartPositionTicks":905000000}"#).startSeconds, 90.5)
        XCTAssertEqual(try decode(ChapterInfo.self, #"{"Name":"Start"}"#).startSeconds, 0)
        XCTAssertTrue(MediaSegment(type: "outro", start: 10, end: 20).isOutro)
        XCTAssertTrue(MediaSegment(type: "Outro", start: 10, end: 20).isOutro)
        XCTAssertFalse(MediaSegment(type: "Intro", start: 10, end: 20).isOutro)
        XCTAssertEqual(MediaSegment(type: "Intro", start: 10, end: 20).id, "Intro-10.0")
    }

    func testLyricsAreNumberedAndKnownAsSyncedByTheirTimes() throws {
        let synced = try decode(LyricsResponse.self, #"{"Lyrics":[{"Text":"One","Start":10000000},{"Text":"Two","Start":10000000},{"Text":"Three"}]}"#)
        XCTAssertEqual(synced.lines.map(\.index), [0, 1, 2])
        XCTAssertEqual(Set(synced.lines.map(\.id)).count, 3, "two lines at one time are still two lines")
        XCTAssertEqual(synced.lines[0].startSeconds, 1)
        XCTAssertNil(synced.lines[2].startSeconds)
        XCTAssertTrue(synced.isSynced)
        let plain = try decode(LyricsResponse.self, #"{"Lyrics":[{"Text":"One"},{"Text":"Two"}]}"#)
        XCTAssertFalse(plain.isSynced)
        XCTAssertTrue(try decode(LyricsResponse.self, "{}").lines.isEmpty)
    }

    // MARK: People and lists

    func testAPersonWithNoIdIsKnownByName() throws {
        XCTAssertEqual(try decode(Person.self, #"{"Id":"p1","Name":"Ada Fixture","Type":"Actor"}"#).id, "p1")
        let unnamed = try decode(Person.self, #"{"Name":"Ada Fixture","Role":"Herself"}"#)
        XCTAssertEqual(unnamed.id, "Ada Fixture")
        XCTAssertEqual(unnamed.Role, "Herself")
        XCTAssertEqual(try decode(NameGuidPair.self, #"{"Name":"Studio"}"#).id, "Studio")
    }

    /// A playlist can hold one song twice; the copy tapped is the one found.
    func testPositionInAListTellsTwoCopiesOfASongApart() throws {
        let first = try item(#"{"Id":"song","PlaylistItemId":"entry1"}"#)
        let other = try item(#"{"Id":"other","PlaylistItemId":"entry2"}"#)
        let second = try item(#"{"Id":"song","PlaylistItemId":"entry3"}"#)
        let list = [first, other, second]
        XCTAssertEqual(list.position(of: first), 0)
        XCTAssertEqual(list.position(of: second), 2)
        XCTAssertEqual(list.position(of: other), 1)
        XCTAssertNil(list.position(of: try item(#"{"Id":"song"}"#)), "the same song, but in no slot of this playlist")
        let plain = [try item(#"{"Id":"a"}"#), try item(#"{"Id":"b"}"#)]
        XCTAssertEqual(plain.position(of: try item(#"{"Id":"b","Name":"Renamed"}"#)), 1, "found by id, not by every field")
    }

    func testSongsSortTheWayASleeveListsThem() throws {
        let songs = [
            try item(#"{"Id":"d2t1","Name":"B","ParentIndexNumber":2,"IndexNumber":1}"#),
            try item(#"{"Id":"t2","Name":"A","IndexNumber":2}"#),
            try item(#"{"Id":"none10","Name":"Track 10"}"#),
            try item(#"{"Id":"t1","Name":"Z","ParentIndexNumber":1,"IndexNumber":1}"#),
            try item(#"{"Id":"none2","Name":"Track 2"}"#),
        ]
        XCTAssertEqual(songs.sortedByTrack().map(\.Id), ["t1", "t2", "none2", "none10", "d2t1"],
                       "disc, then track; a song with no disc is on the first; no track number goes last, by name as a person reads numbers")
    }

    func testAlbumsAreReadOffSongsOnceEachInOrder() throws {
        let songs = [
            try item(#"{"Id":"s1","Album":"Blue","AlbumId":"al1","AlbumArtist":"Ada","AlbumArtists":[{"Name":"Ada","Id":"ar1"}],"AlbumPrimaryImageTag":"tag1","ProductionYear":1999}"#),
            try item(#"{"Id":"s2","Album":"Red","AlbumId":"al2"}"#),
            try item(#"{"Id":"s3","Album":"Blue","AlbumId":"al1"}"#),
            try item(#"{"Id":"s4","Album":"Loose"}"#),
            try item(#"{"Id":"s5","AlbumId":""}"#),
        ]
        let albums = songs.albumsInOrder()
        XCTAssertEqual(albums.map(\.Id), ["al1", "al2"])
        XCTAssertEqual(albums[0].Name, "Blue")
        XCTAssertTrue(albums[0].isAlbum)
        XCTAssertEqual(albums[0].artistLine, "Ada")
        XCTAssertEqual(albums[0].ProductionYear, 1999)
        XCTAssertEqual(albums[0].ImageTags, ["Primary": "tag1"])
        XCTAssertNil(albums[1].ImageTags, "no cover tag on the song, none on the album")
    }
}

/// `HomeSection`: the server's home-row vocabulary, as far as this app draws it.
final class CoreHomeSectionTests: XCTestCase {
    func testServerNamesMapToRows() {
        XCTAssertEqual(HomeSection(serverName: "librarybuttons"), .libraries)
        XCTAssertEqual(HomeSection(serverName: "smalllibrarytiles"), .libraries)
        XCTAssertEqual(HomeSection(serverName: "librarytiles"), .libraries)
        XCTAssertEqual(HomeSection(serverName: "resume"), .resume)
        XCTAssertEqual(HomeSection(serverName: "resumevideo"), .resume)
        XCTAssertEqual(HomeSection(serverName: "nextup"), .nextUp)
        XCTAssertEqual(HomeSection(serverName: "latestmedia"), .latest)
        XCTAssertEqual(HomeSection(serverName: "livetv"), .liveTV)
    }

    func testNamesAreReadWhateverTheirCase() {
        XCTAssertEqual(HomeSection(serverName: "NextUp"), .nextUp)
        XCTAssertEqual(HomeSection(serverName: "LatestMedia"), .latest)
        XCTAssertEqual(HomeSection(serverName: "LIVETV"), .liveTV)
    }

    func testRowsThisAppHasNoScreenForAreLeftOut() {
        for name in ["none", "resumeaudio", "resumebook", "activerecordings", "", "something-new"] {
            XCTAssertNil(HomeSection(serverName: name), name)
        }
    }

    func testTheFallbackIsJellyfinsOwnOrderWithoutTheRowsLeftOut() {
        XCTAssertEqual((0..<7).map(HomeSection.jellyfinDefault),
                       ["smalllibrarytiles", "resume", "resumeaudio", "livetv", "nextup", "latestmedia", "none"])
        XCTAssertEqual(HomeSection.jellyfinDefault(9), "none")
        XCTAssertEqual(HomeSection.fallback, [.libraries, .resume, .liveTV, .nextUp, .latest])
        XCTAssertEqual(Set(HomeSection.fallback), Set(HomeSection.allCases), "every row the app draws is in the fallback once")
    }
}
