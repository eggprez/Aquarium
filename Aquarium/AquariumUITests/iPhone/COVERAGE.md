# iPhone coverage

Every iPhone-reachable function, the test that covers it, the kind of test
and its status on the last full run (see the foot of this file for the run
and how to repeat it).

Kinds: **unit** (`AquariumTests/iPhone`, or the shared unit tests in
`AquariumTests/Shared` that also run on the iPhone simulator), **UI**
(`AquariumUITests/iPhone`, against the QA server), **manual** (MANUAL.md).
Status: **pass**, **xfail** (an open app bug, wrapped in `XCTExpectFailure`
and listed in the report), **skip** (with the reason), **fail** (test still
wrong, see notes), **flaky**.

Devices: functional UI tests run on the standard phone only
(`standardOnly()`); layout tests run on all four (SE, 17, 18 Pro Max, Duo
front screen). `AQUARIUM_PHONE_ALL_DEVICES=1` runs everything everywhere.

## Logic (unit)

| Function | Test | Kind | Status |
|---|---|---|---|
| `Format.ticks/clock/bytes/resolutionLabel/channelLabel/mediaSummary/itemSubtitle/trackLabel/parseDate/programWindow` | PhoneFormattingTests | unit | pass |
| `Format.ticks` under a minute | PhoneFormattingTests.testShortRuntimeReadsSeconds | unit | xfail (R-TV-30s) |
| `PlayerTime.format/spoken` | PhoneFormattingTests.testPlayerTime | unit | pass |
| `Quality.choices/label/shortLabel/snapped/rungIndex/cap/smallerStream/untouchedRung` | PhoneFormattingTests (quality group) | unit | pass |
| `DownloadQualities.named/menuLabel`, catalogue keys | PhoneFormattingTests | unit | pass |
| `Languages.matches/name/audioChoices/subtitleChoices` | PhoneFormattingTests | unit | pass |
| `Artwork.ladder`, `URL.lenient` | PhoneFormattingTests | unit | pass |
| `DownloadGroups.seasonSortKey/seasonTitle` | PhoneFormattingTests | unit | pass |
| `JellyfinClient.sortBy`, `MusicSort` | PhoneFormattingTests | unit | pass |
| `LibraryView.SortOption.tiebroken/order` | PhoneFormattingTests | unit | pass |
| `BookProgress.isFinished/isStale/takesServer`, `VideoProgress.isFinished` | PhoneFormattingTests | unit | pass |
| `APIError` wording | PhoneFormattingTests.testServerErrorDoesNotShowThePath | unit | xfail (R-TV-404) |
| `JellyfinClient.withPlaySession/withNewPlaySession/playSessionId` | PhoneClientURLTests | unit | pass |
| `JellyfinClient.subtitleTimedSegments` | PhoneClientURLTests | unit | pass |
| `JellyfinClient.encode/pathId/safeFileName/subtitlePath/claimsHDRItCannotCarry` | PhoneClientURLTests | unit | pass |
| `JellyfinClient.clientVersion` | PhoneClientURLTests.testClientVersionIsTheBundleVersion | unit | xfail (R-80113a1) |
| `mediaSegments` (Intro and Outro asked apart) | PhoneClientStubTests | unit | pass |
| `resolvePlayback` body (MediaSourceId with track index) | PhoneClientStubTests | unit | pass |
| `nextUp` (cutoff, resumable, rewatching) | PhoneClientStubTests | unit | pass |
| `seriesNextUp` (in-progress episode wins) | PhoneClientStubTests | unit | pass |
| `removeFromNextUp`, `addToNextUp(.lastWatched)` | PhoneClientStubTests | unit | pass |
| `search` request | PhoneClientStubTests | unit | pass |
| `search` types (collections, people) | PhoneClientStubTests.testSearchIncludesCollectionsAndPeople | unit | xfail (R-PM34) |
| `channels` paging | PhoneClientStubTests | unit | pass |
| `checkOnline` | ClientStubTests (shared) | unit | pass |
| `AppModel.push/pop`, `AppSection.id` | PhoneNavigationTests | unit | pass |
| `PlayerModel.secondsRemaining/upNextIsDue` | PhonePlayerArithmeticTests | unit | pass |
| `CloudSync.syncedKeys`, `Preferences.keysNotOfferedHere`, picture clamps, `SavedSession` | PhoneSettingsRulesTests | unit | pass |
| `M3UParser.parse` | PhoneM3UTests | unit | pass |
| `IPTVModels.parseEpisodeNumber` | XMLTVEpisodeNumberTests (shared) | unit | pass |
| `GuideSchedule.resolved` | GuideScheduleTests (shared) | unit | pass |
| `DownloadAudioList`, `DownloadSegments`, `DownloadItemInfo`, `DownloadSubtitles.local`, `DownloadArtwork.key` | PhoneDownloadFilesTests, PhoneDownloadSegmentsTests | unit | pass |
| `NowPlayingSnapshot.position/fraction/link`, `ListeningActivityAttributes.ContentState` decoding | PhoneWidgetTests | unit | pass |
| `HomeRows.*` (next up target, last watched, first episode, new starts first, expired, played date) | NextUpTargetTests, NextUpRemovalTests (shared) | unit | pass |
| `DevicePose.resolve`, `usesFrontDisplay` | DevicePoseTests (shared) | unit | pass |
| `EnginePolicy.choose` | EnginePolicyTests (shared) | unit | pass |
| `AdaptiveQuality` | AdaptiveQualityTests (shared) | unit | pass |
| `SpeedCheck` | SpeedCheckTests (shared) | unit | pass |
| `StreamPlan` / direct play decisions | StreamPlanTests (shared) | unit | pass |
| `StreamSeams`, `DownloadRepair` | StreamSeamsTests (shared) | unit | pass |
| `SubtitleCues.parse/text` | SubtitleCuesTests (shared) | unit | pass |
| `TrackPreference` | TrackPreferenceTests (shared) | unit | pass |
| `ServerDiscovery.accepts` | ServerDiscoveryTests (shared) | unit | pass |
| `StationBuilder/StationEngine` ranking and re-deal | — | none | not unit-tested: needs a live pool; covered by UI station tests |
| `DownloadManager` state machine (requeue, ghosts, stalls, judgeIdle) | — | manual | needs real background sessions (MANUAL.md) |
| `OrientationLock` | — | manual | needs the hinge and real rotation (MANUAL.md) |
| `ImageLoader`, `BlurHash` | — | none | drawing only; seen in every UI screenshot |
| App Intents / Shortcuts / Spotlight | — | none | no headless driver for Siri/Shortcuts on the simulator |

## Sign-in and accounts (PhoneSignInTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Connect to a server, banner (name, security) | testPasswordSignInReachesHome | UI | see run |
| Password sign-in | testPasswordSignInReachesHome | UI | see run |
| Wrong password | testWrongPasswordSaysSo | UI | see run |
| Disabled account (fx-disabled) | testDisabledAccountIsRefused | UI | see run |
| Public users, passwordless user (fx-guest, fx-public) | testPublicUsersAreListedAndAPasswordlessOneSignsIn | UI | see run |
| Limited libraries (fx-limited) | testLimitedAccountSeesOnlyItsLibraries | UI | see run |
| Parental rating (fx-kid) | testKidAccountHidesRatedTitles, PhoneDetailTests.testBlockedTitleForTheKidAccountShowsAnError | UI | see run |
| Quick Connect sign-in | testQuickConnectSignsInOnceApproved | UI | see run |
| Quick Connect ↔ password switch | testQuickConnectAndBackToPassword | UI | see run |
| Unreachable server | testUnreachableServerSaysSo | UI | see run |
| Use a different server | testDifferentServerGoesBackToTheAddress | UI | see run |
| Name kept after a different server | testUsernameClearedAfterDifferentServer | UI | see run (R-Duo-user) |
| Sign out | testSignOutReturnsToTheSignInScreen | UI | see run |
| Sign-out question names the account | testSignOutQuestionNamesTheAccount | UI | see run (R-TV30) |
| Add account, switch account | testAddSecondAccountAndSwitchBack | UI | see run |
| Form clear of the keyboard (all sizes) | testSignInFieldsClearOfTheKeyboard | UI, layout | see run (R-SE-signin) |
| Form fits (all sizes) | testSignInScreenFitsTheScreen | UI, layout | see run |
| Server discovery on the LAN | — | manual | AutoDiscovery is off on the QA server (FIXTURES.md) |
| Revoked account row | — | none | needs a token revoked under a saved account; open on main (R-W-revoked) |

## Home (PhoneHomeTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Rows: My Media, Continue Watching, On Now, Next Up, Latest per library | testHomeShowsTheBaselineRows | UI, layout | see run |
| Bar (Search, Refresh) and hero fit | testHomeBarAndHeroFitTheScreen | UI, layout | see run |
| Hero Details, hero paging | testHeroDetailsOpensTheTitle, testHeroSwipesToTheNextPage | UI | see run |
| Refresh | testRefreshKeepsHome | UI | see run |
| Continue Watching card → title with progress | testContinueWatchingCardOpensTheTitle | UI | see run |
| See all → library; library tile; On Now → Live TV | testSeeAllOpensTheLibrary, testLibraryTileOpensTheLibrary, testOnNowRowOpensLiveTV | UI | see run |
| Episode card names the show once | testContinueWatchingEpisodeCardNamesTheShowOnce | UI | see run (R-PM29) |
| Search and back, no empty bar | testSearchFromHomeAndBackLeavesNoEmptyBar | UI | see run (R-b7ce99a) |
| Hero Play | PhoneContextMenuTests / PhonePlayerTests (play paths) | UI | indirect |
| Saved Home drawn offline at launch | — | manual | needs the server cut mid-run (MANUAL.md) |

## Libraries, Favorites, Collections, Search, Photos (PhoneBrowseTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Libraries list | testLibrariesListShowsEveryFixtureLibrary | UI, layout | see run |
| Library grid | testFilmsGridListsFixtures | UI, layout | see run |
| Sort (every option) | testEverySortOptionLoads, testSortByNameThenByDateAdded | UI | see run |
| Unwatched and Favorites filters | testUnwatchedAndFavouritesFilters | UI | see run |
| Genre filter | testGenreFilter | UI | see run |
| Paging to the end | testGridPagesToTheEnd | UI | see run (R-dbd3662a) |
| A–Z strip | testLetterIndexJumps | UI, layout | see run |
| Shows library lists series | testShowsLibraryListsSeriesNotEpisodes | UI | see run |
| Photo album opens | testPhotoAlbumOpensItsContents | UI | see run (R-PM4) |
| Home video in Photos plays | testHomeClipInPhotosLibraryPlays | UI | see run |
| Favorites page and kinds | testFavoritesListsTheBaselineAndFiltersByKind | UI | see run |
| Favourite from a title reaches Favorites | testFavouriteFromTitleAppearsInFavorites | UI | see run (R-2c20fe6) |
| Collections | testCollectionsListAndOpen | UI | see run (R-56a1825) |
| Search: films, shows, music, unicode, empty, recents, clear | PhoneSearchTests | UI, layout | see run |
| Search replaces the old term | testTypingAfterReturningReplacesTheOldTerm | UI | see run (R-PM35) |
| Search finds collections | testSearchFindsTheCollection | UI | see run (R-PM34) |
| Photo viewer (full-screen photo) | — | none | the app has no photo viewer on iPhone (nonVideoTypes are filtered) |

## Title pages, context menus, Next Up (PhoneDetailTests, PhoneContextMenuTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Film page facts and actions fit | testFilmPageShowsItsFacts | UI, layout | see run |
| Action row one line | testActionRowIsOneLine | UI, layout | see run (R-2c20fe6-row) |
| Favourite, Mark watched (server) | testFavouriteButtonReachesTheServer, testMarkWatchedFromTheMoreMenu | UI | see run |
| More menu anchored to its button | testMoreMenuOpensBesideItsButton | UI, layout | see run (R-5c15003) |
| Play at a set quality | testPlayAtASetQualityMenu | UI | see run |
| Trailer | testTrailerPlays | UI | see run |
| Versions | testVersionsCanBeChosen | UI | see run (R-PM6) |
| Cast → person page | testCastOpensThePersonPage | UI | see run |
| More Like This | testMoreLikeThisShelf | UI | see run |
| Show page: seasons, Up next line | testShowPageListsSeasonsAndEpisodes | UI, layout | see run |
| Show Play resumes the in-progress episode | testShowPlayResumesTheInProgressEpisode | UI | see run (R-1ccddf1) |
| Season page, specials, double episode, episode play glyph | testSeasonPageListsItsEpisodes, testSpecialsSeasonOpens, testShortShowListsTheDoubleEpisodeOnce, testEpisodePlayGlyphPlaysThatEpisode | UI | see run |
| Episode → show crumb | testEpisodePageShowsItsShowAndSeason | UI | see run |
| Episode rows fit (small phone) | testEpisodeRowsShowTheirTitles | UI, layout | see run (R-SE-rows) |
| Card menu: Play, from beginning, Details, Favourite, Watched, Download submenu, Go to show/season | PhoneContextMenuTests | UI, layout | see run |
| Remove from Next Up | testRemoveFromNextUp | UI | see run (R-a9528ef) |
| Add to Next Up (last watched, first episode, cancel) | testAddToNextUpFromLastWatched, testAddToNextUpFromTheFirstEpisode, testAddToNextUpCancel | UI | see run (memory jellyfin-next-up-rules) |

## Player (PhonePlayerTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Play, server hears it, DirectPlay reported | testPlayOpensAndTheServerHearsIt | UI | see run |
| Resume and save the point | testResumeStartsAtTheSavedPointAndSavesTheNewOne | UI | see run |
| Play from the beginning | testPlayFromBeginningIgnoresTheResumePoint | UI | see run |
| Back closes | testBackClosesThePlayerToTheTitle | UI | see run |
| Pause/play (server) | testPauseAndPlayReachTheServer | UI | see run |
| Skip ±10, scrub, remaining/total, fill | testSkipForwardAndBack, testScrubMovesThePosition, testRemainingTimeFlipsToTotal, testFillPillToggles | UI | see run |
| Controls hide and come back | testControlsHideByThemselvesAndComeBackOnATap | UI | see run |
| Controls take touches while fading | testControlsTakeTouchesWhileFading | UI | see run (R-58f77cf) |
| Audio card, choice reaches the server | testAudioCardListsEveryTrack, testChosenAudioTrackReachesTheServer | UI, layout | see run (R-ca154f3) |
| Subtitles: every kind, choice reaches the server, Off | testSubtitlesCardListsEveryKind, testChosenSubtitleReachesTheServer | UI, layout | see run |
| Forced subtitles | testForcedSubtitleOnForeignAudio | UI | see run |
| Sidecar and image subtitles | testSidecarSubtitlesAreOffered, testImageSubtitlesAreOffered | UI | see run |
| No phantom CC row | testNoPhantomCaptionRow | UI | see run (R-5a0e2d7-cc) |
| Quality card, pick a rung, stays paused | testQualityCardOffersAutoOriginalAndEveryRung, testPickingARungTranscodesAndStaysPaused | UI, layout | see run (R-B2) |
| A reopen counts no play | testQualityChangeDoesNotCountAPlay | UI | see run (R-013ead9) |
| Speed | testSpeedChoices | UI | see run |
| Sleep timer; shown in the title row | testSleepTimerStartsAndCancels, testSleepTimerShownInTitleRow | UI | see run (R-120c435) |
| After this (stop after) | testStopAfterThisNotOfferedOnAFilm, testStopAfterThisOfferedOnAnEpisode | UI | see run (R-d5792c6) |
| Info panel | testInfoPanelDescribesTheStream, testInfoNamesTheAudioTrack | UI, layout | see run |
| AirPlay button | testAirPlayButtonIsThere | UI | see run; the route picker is manual |
| Picture in Picture | testPictureInPictureButtonFollowsSupport | UI | skip on the iPhone simulator (PiP unsupported); manual |
| Skip Intro, Skip Credits | testSkipIntro, testSkipCreditsAppearsAtTheOutro | UI, layout | see run (R-B3) |
| Up Next pill, card, Play, Not now | testUpNextPillListsTheNextEpisode, testUpNextCardPlaysTheNextEpisode, testUpNextCancelKeepsTheEpisode | UI, layout | see run |
| Close over the Up Next card | testClosingWithTheUpNextCardUpDoesNotCrash | UI | see run (R-7132133) |
| Up Next with autoplay off | testUpNextCardWithAutoplayOff | UI | see run (R-5a0e2d7-B5) |
| Double-tap skip; hold for 2× | testDoubleTapRightSkipsForward, testHoldPlaysAtDoubleSpeed | UI | see run |
| Pinch to fill, edge brightness/volume swipes | — | manual | XCUITest's pinch does not reach the player (memory player-qa-probe-driver) |
| Error card (refused transcode) | testRefusedTranscodeShowsTheErrorCard | UI | see run |
| Codec matrix; transcode-only fixtures; video-only | testCodecMatrixPlays, testTranscodedFixturesPlay, testVideoOnlyFileSaysThereIsNoSound | UI | see run |
| mpv engine | testMPVEngineCanPlay | UI | see run |
| Portrait controls fit; landscape cards | testPortraitControlsFitTheScreen, testLandscapeCardsSitBetweenTitleAndPills | UI, layout | see run (R-74e72e9) |
| Chapters | — | none | no chapter list on the phone's More card; chapters show in the fold panel (Duo, manual) and Info |
| SharePlay | — | manual | needs a FaceTime call |

## Music and audiobooks (PhoneMusicTests, PhoneAudiobookTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Discover shelves, stations shelf, search field visible | testDiscoverShowsTheShelves | UI, layout | see run (R-b4d8347) |
| Library doors (artists, albums, songs, genres, playlists, favorites) | testLibraryDoorsOpenEveryList | UI | see run |
| Sort | testSongsSortMenu | UI | see run |
| Album with two discs | testAlbumGroupsItsDiscs | UI, layout | see run |
| Play a song, mini player, server hears it, Next label | testPlayingASongShowsTheMiniPlayerAndReportsIt | UI, layout | see run (R-db310b3-a11y) |
| Mini player play/pause | testMiniPlayerPlayPause | UI | see run |
| Now Playing controls, next, shuffle, repeat, close | testNowPlayingControls | UI, layout | see run |
| Queue | testQueueListsWhatComesNext | UI | see run |
| Next on the last song | testNextOnTheLastSongStops | UI | see run (R-f72bd13a) |
| Lyrics (synced) | testSyncedLyrics | UI, layout | see run |
| Favourite from Now Playing | testFavouriteFromNowPlayingReachesTheServer | UI | see run |
| Instant Mix, station, leanings, Shuffle All | testInstantMixFromNowPlaying, testStationFromDiscover, testShuffleAll | UI | see run |
| Song menu, Song Info | testSongMenuOffersItsActions | UI | see run |
| Artist page order | testArtistPageShowsTopSongsThenAlbums | UI | see run |
| Playlists | testPlaylistsListTheAccountsOwn | UI | see run |
| Smart playlist editor, save, delete | testSmartPlaylistEditorSavesAndDeletes | UI | see run |
| Music search | testMusicSearchFindsArtistsAlbumsSongs | UI, layout | see run |
| Mini player clear of the list's end | testMiniPlayerDoesNotCoverTheEndOfAList | UI, layout | see run (R-f41df90) |
| Audiobooks tab, Continue Listening | testAudiobooksTabShowsContinueListening | UI, layout | see run |
| Book page, chapters, resume, chapter row, speed | testBookPageListsChaptersAndResumes, testChapterRowPlaysFromThere, testAudiobookSpeedMenu | UI | see run |
| Multi-file book | testMultiFileBookPartsAreListed | UI | see run |
| Offline music pages, offline mix | — | manual | needs the server cut (MANUAL.md) |
| Volume slider, AirPlay from Now Playing | — | manual | system controls |

## Downloads (PhoneDownloadsTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Empty page | testEmptyDownloadsPage | UI, layout | see run |
| Download menu with sizes | testDownloadMenuOffersEveryQualityWithSizes | UI, layout | see run |
| File download, play it (Downloaded quality), delete | testFileDownloadPlaysAndIsRemoved | UI | see run (R-89c1c6c) |
| Stream (transcoded) download | testStreamDownloadCompletes | UI | see run |
| Queue, cancel, clear queue | testQueueAndCancel | UI | see run |
| Pause/resume all | testPauseAndResumeAllDownloads | UI | see run |
| No-download account | testDownloadRefusedForAccountWithoutPermission | UI | see run |
| Music door | testMusicAndAudiobookDoors | UI | see run |
| Offline playback with progress synced later | — | manual | needs the server cut mid-run (MANUAL.md) |
| Swipe-away, background, demotion | — | manual | MANUAL.md |

## Live TV (PhoneLiveTVTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Guide, channels, programmes | testGuideShowsBothChannelsAndProgrammes | UI, layout | see run |
| Tune a channel, live timeline, info | testTuningAChannelPlaysLive | UI, layout | see run |
| Channel up/down | testChannelUpAndDownInThePlayer | UI | see run |
| No speed on live | testSpeedIsUnavailableOnLive | UI | see run |
| Back from More; back clear of the heading | testLiveTVFromMoreHasBack | UI, layout | see run (R-2c20fe6-lt, R-PM15) |
| Custom M3U/XMLTV source | PhoneM3UTests (parser); Settings row in PhoneSettingsTests | unit, UI | see run |

## Settings (PhoneSettingsTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Every page and its rows; pinned rows absent | testEveryPageOpensWithItsRows | UI, layout | see run |
| Apple Watch page | testAppleWatchPageOpens | UI | see run |
| Account facts | testAccountPageNamesTheAccountAndServer | UI | see run |
| Approve Quick Connect | testApproveAQuickConnectCode | UI | see run |
| Theme | testDarkThemeTurnsTheAppDark | UI | see run |
| Hide Continue Watching | testHideContinueWatchingTakesTheRowOffHome | UI | see run |
| Tab Bar page | testTabBarSettingsReorderAndReset | UI | see run (R-0c2a8e9) |
| App Icon page | testAppIconPageListsIcons | UI | see run |
| Default quality | testDefaultQualityChoices | UI | see run |
| Autoplay next | PhonePlayerTests.testUpNextCardWithAutoplayOff | UI | see run |
| About | testAboutShowsTheVersion | UI | see run |
| Library copy delete asks | testLibraryCopyDeleteAsksFirst | UI | see run (R-074a461) |
| Live TV source | testLiveTVSourceOffersCustomPlaylist | UI | see run |
| Station mix page | testMusicStationMixPage | UI | see run |
| Pages fit | testSettingsPagesFitTheScreen | UI, layout | see run |
| Measure Apple TV sync (camera) | — | manual | needs a camera and an Apple TV |
| Tab bar drag to reorder | — | none | drag handles carry no identifiers (TESTING.md known gaps) |

## iPhone Duo and layout (DuoPoseTests, PhoneLayoutTests)

| Function | Test | Kind | Status |
|---|---|---|---|
| Front screen: Home bar clear of the dead strip | DuoPoseTests.testFrontScreenHomeBarClearsTheStatusStrip | UI (Duo) | see run |
| Front screen: back clear of the strip | testFrontScreenBackButtonClearsTheStrip | UI (Duo) | see run |
| Front screen: player title row and card close clear | testFrontScreenPlayerTitleRowClearsTheStrip | UI (Duo) | see run |
| Tent cover, tent player | testTentShowsTheIdleCover, testTentPlayerUsesTheFrontScreenLayout | UI (Duo, override) | see run |
| Half-folded player and title page | testHalfFoldedPlayerShowsTheFoldPanel, testHalfFoldedTitlePageSplits | UI (Duo, override) | skip without the inner screen |
| Music search drawn | testMusicSearchFieldIsDrawn | UI (Duo) | see run |
| Up Next card clear of the transport | testFrontScreenUpNextCardClearsTheTransport | UI (Duo) | see run (R-PM14) |
| Tab bar, More list, long title, landscape | PhoneLayoutTests | UI, layout (all) | see run |
| Skip Intro steps aside for cards | PhoneLayoutTests.testSkipIntroStepsAsideForCards | UI, layout | see run (R-SE-skip) |
| Inner screen, book pose, real fold, rotation on the inner screen, camera clearance | — | manual | MANUAL.md |

## Not automated, and why

See MANUAL.md for the steps. In short: CarPlay (no XCUITest driver for
CPTemplates), the Duo hinge and inner screen (Device Hub only), AirPlay
and the route picker (system UI), Picture in Picture (unsupported on the
iPhone simulator), real network loss and offline mode (the runner cannot
cut the server; the throttle proxy hangs below 2.6 Mbps), background
downloads after swipe-away and demotion (the simulator never demotes),
thermal state, lock screen and Live Activity buttons, pinch and edge
gestures (XCUITest's pinch does not reach the player), SharePlay, Siri and
Shortcuts, the Measure Apple TV sync camera page.

## Flaky

See the run notes below.

## Last run

(filled in below after the run)
