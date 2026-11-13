# iPad coverage

Every function an iPad reaches, and every iPad-only logic path, with the test
that exercises it. Kinds: **unit** (`AquariumTests/iPad`, run with the Unit
plan on the iPad simulator), **UI** (`AquariumUITests/iPad`, the iPad plan,
against the QA server as `suite-ipad`), **manual** (`MANUAL.md`).
Flows the iPhone shares in logic (track preference rules, stream planning,
download queues, Next Up arithmetic) have their deep unit tests with the
iPhone and shared suites; here each such function is still *exercised* on the
iPad's layout by a UI test.

Status is from the run recorded at the bottom: **pass**, **xfail** (an open
bug, wrapped in `XCTExpectFailure("bug: …")`), **skip** (with the reason),
**manual**, **fail** (see the report).

How to run:

```
Tools/run-tests.sh ipad                                   # UI, iPad Air 11
xcodebuild test -scheme Aquarium -testPlan Unit -destination 'id=<iPad sim>' \
  -only-testing:AquariumTests/PadMetricsTests … CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

## Shell and navigation

| Function | Test | Kind | Status |
|---|---|---|---|
| Sidebar shell at regular width (no tab bar) | PadSidebarTests.testSidebarIsTheShellNotATabBar | UI | STATUS |
| Header: account initial, name, server host | PadSidebarTests.testHeaderNamesTheAccountAndServer | UI | STATUS |
| Grouped rows: Browse / Libraries / Live / You, every library, no Settings or More rows | PadSidebarTests.testRowsAreGroupedHomeFirstAndEveryLibraryListed; PadSidebarGroupTests (8) | UI + unit | STATUS |
| Each section opens from its row, row lit | PadSidebarTests.testEverySectionOpensFromItsRow | UI | STATUS |
| Re-tapping the lit row pops to the section's top | PadSidebarTests.testSelectedRowGoesBackToTheTopOfItsSection | UI | STATUS |
| Search row pushes Search over Home | PadSidebarTests.testSearchRowPushesSearch; PadShellSelectionTests.testShowSearchOnAnIPadOpensItOverHome | UI + unit | STATUS |
| Settings gear in the footer | PadSidebarTests.testSettingsGearSelectsSettings | UI | STATUS |
| Footer status (Synced / downloads running / Offline) | PadSidebarTests.testFooterSaysSynced; PadDownloadsTests.testDownloadPlayAndDeleteAFilm | UI | STATUS |
| Downloads badge on the row | PadDownloadsTests.testDownloadPlayAndDeleteAFilm (transient) | UI | partial: the badge is up only while a transfer runs, too brief on the local server to assert |
| Collapse the sidebar; bring it back from Home's bar | PadSidebarTests.testCollapseAndBringBackTheSidebarInLandscape | UI | STATUS |
| Bring it back from a title page's bar | PadSidebarTests.testCollapsedSidebarComesBackFromATitlePage | UI | STATUS |
| Sidebar in portrait and landscape | PadSidebarTests.testSidebarInPortraitAndLandscape | UI | STATUS |
| Sidebar width 190–280 (narrower sidebar, 6344432) | PadSidebarTests.testSidebarIsNarrow | UI | STATUS |
| Now Playing card at the foot of the sidebar | PadMusicTests.testPlayingASongPutsTheNowPlayingCardInTheSidebar, …SidebarCardPlayPauseAndOpensNowPlaying; PadBooksTests | UI | STATUS |
| No card when idle | PadSidebarTests.testDownloadsBadgeAndNowPlayingAbsentWhenIdle | UI | STATUS |
| Shell follows the size class: section with no tab goes into More, comes back on widening (a98b494) | PadShellSelectionTests (9) | unit | pass |
| Sidebar comes back after a phone-width window | PadWindowSizeTests.testSidebarComesBackAfterAPhoneWidthWindow | UI | skip (simulator shows apps full screen); open bug, MANUAL.md |
| Stage Manager / Split View / external display | — | manual | manual |

## Home

| Function | Test | Kind | Status |
|---|---|---|---|
| Hero with Play and Details | PadHomeTests.testHeroShowsWithPlayAndDetails | UI | STATUS |
| Hero edge to edge, under the sidebar, 2.4:1 band | PadHomeTests.testHeroIsEdgeToEdgeAtTwoPointFourToOne; PadHeroGeometryTests (5) | UI + unit | STATUS |
| Thumbnails on its side (width ≥ 900), dots upright | PadHomeTests.testThumbnailsInLandscapeDotsInPortrait | UI | STATUS |
| A thumbnail turns the hero | PadHomeTests.testThumbnailTurnsTheHeroToItsPage | UI | STATUS |
| Swipe turns the hero | PadHomeTests.testSwipingTheHeroTurnsThePage | UI | STATUS |
| Hero Details / Play | PadHomeTests.testHeroDetailsOpensTheTitle, testHeroPlayStartsThePlayer | UI | STATUS |
| Hero first page aligned with the rest (6344432) | PadRegressionTests.testHeroFirstPageSitsWhereTheOthersDo | UI | STATUS |
| Hero pages take their real width (d5792c6) | PadRegressionTests.testHeroPagesTakeTheirRealWidth | UI | STATUS |
| Hero timer stops behind a pushed title (30cbbc2) | PadRegressionTests.testHeroDoesNotTurnBehindAPushedTitle | UI | STATUS |
| Saved hero backdrops for offline; crop focus near the top (c643527) | — | manual | manual (visual / offline) |
| Continue Watching, Next Up shelves (baseline) | PadHomeTests.testContinueWatchingAndNextUpShelves | UI | STATUS |
| Latest per library | PadHomeTests.testLatestShelfPerLibrary | UI | STATUS |
| On Now and music shelves | PadHomeTests.testLiveTVAndMusicShelvesOnHome | UI | STATUS |
| Library chip strip (instead of My Media tiles) | PadHomeTests.testLibraryChipsOpenALibrary | UI | STATUS |
| See all | PadHomeTests.testShelfSeeAllOpensTheWholeRow | UI | STATUS |
| Floating bar: Refresh, Search | PadHomeTests.testRefreshAndSearchInTheFloatingBar; PadSearchTests.testHomeBarSearchOpensTheSameSearch | UI | STATUS |
| Card opens its title | PadHomeTests.testCardOpensItsTitle | UI | STATUS |
| Both orientations | PadHomeTests.testHomeInBothOrientations | UI | STATUS |
| Deep Water metrics (gutter 28, shelf 32, row 16, grid 14, radius 14, poster 156, still 300) | PadMetricsTests (6) | unit | pass |

## Libraries, collections, photos, favourites

| Function | Test | Kind | Status |
|---|---|---|---|
| Grid with the count in the pinned header | PadLibraryTests.testGridAndCountInTheHeader | UI | STATUS |
| More columns on its side | PadLibraryTests.testGridHasMoreColumnsInLandscape | UI | STATUS |
| iPad name search in the header, Clear | PadLibraryTests.testSearchFieldFiltersByName | UI | STATUS |
| Unwatched, Favourites, Genre filters | PadLibraryTests.testUnwatchedFilterHidesPlayedFilms, testFavoritesFilter, testGenreMenuFilters | UI | STATUS |
| Sort menu and reverse | PadLibraryTests.testSortMenuAndReverse | UI | STATUS |
| Card → title → Back to the grid | PadLibraryTests.testCardOpensTitleAndBackReturnsToTheGrid | UI | STATUS |
| Shows library → series | PadLibraryTests.testShowsLibraryOpensASeries | UI | STATUS |
| Collections section (56a1825) and a collection's titles | PadLibraryTests.testCollectionsSectionListsFXCollection | UI | STATUS |
| Photo album opens as a grid of photos | PadPhotosTests.testPhotoAlbumOpensAsAGridOfPhotos | UI | STATUS |
| Favourites: baseline, kind chips | PadFavoritesTests.testFavoritesShowsTheBaselineAndFiltersByKind | UI | STATUS |
| Favourite added elsewhere appears (ItemMutations) | PadFavoritesTests.testFavoriteAddedOnATitleAppearsHere | UI | STATUS |

## Title pages

| Function | Test | Kind | Status |
|---|---|---|---|
| Two-column header (poster beside facts) on its side | PadDetailTests.testTwoColumnHeaderInLandscape | UI | STATUS |
| Header upright | PadDetailTests.testHeaderInPortrait | UI | STATUS |
| Facts, genres, overview tap-to-unfold | PadDetailTests.testFactsAndOverview | UI | STATUS |
| Resume label and time left | PadDetailTests.testResumeLabelAndRemainingOnAFilmInProgress | UI | STATUS |
| Favourite disc → server | PadDetailTests.testFavoriteDiscReachesTheServer | UI | STATUS |
| Watched disc → server | PadDetailTests.testWatchedDiscReachesTheServer | UI | STATUS |
| Quality menu (ladder) and play at a rung | PadDetailTests.testQualityMenuListsTheLadder, testQualityMenuPlaysAtTheRungChosen | UI | STATUS |
| Download menu | PadDetailTests.testDownloadMenuOffersQualities | UI | STATUS |
| Versions (three media sources) | PadDetailTests.testVersionsAreOfferedOnATitleWithThreeFiles | UI | STATUS |
| Season switch, episodes two across, switching seasons | PadDetailTests.testSeriesPageHasSeasonSwitchAndEpisodesTwoAcrossInLandscape | UI | STATUS |
| Episode summary, play glyph | PadDetailTests.testEpisodeSummaryAndPlayGlyph | UI | STATUS |
| Episode page and its Show › Season trail | PadDetailTests.testEpisodeRowOpensTheEpisodesPageWithItsTrail | UI | STATUS |
| Add to Next Up asks (popover on iPad) | PadDetailTests.testAddToNextUpOnASeriesAsks | UI | STATUS |
| Cast → person page | PadDetailTests.testCastOpensAPersonsPage | UI | STATUS |
| More Like This | PadDetailTests.testMoreLikeThis | UI | STATUS |
| Back from the page's own bar | PadDetailTests.testBackReturnsToTheSectionsPage | UI | STATUS |
| Trailer disc (local trailers) | PadDetailTests.testTrailerOnATitleWithLocalTrailers | UI | STATUS |
| Quality not alone on its row upright | PadRegressionTests.testQualityDoesNotWrapAloneBesideThePosterInPortrait | UI | STATUS |
| Blocked title's error (fx-kid) | PadRegressionTests.testBlockedTitleSaysSoInPlainWords | UI | STATUS |
| Header switches to the compact stack under 720 pt of column | — | manual | manual (needs a window narrower than the simulator allows) |

## Search and context menus

| Function | Test | Kind | Status |
|---|---|---|---|
| "FX Long" finds the four | PadSearchTests.testFindsTheFXLongTitles | UI | STATUS |
| Results beside the sidebar | PadSearchTests.testResultsSitInTheDetailColumnBesideTheSidebar | UI | STATUS |
| Unicode title | PadSearchTests.testUnicodeTitleIsFound | UI | STATUS |
| Music results above "Films & TV" | PadSearchTests.testMusicResultsAboveFilmsAndTV | UI | STATUS |
| No matches | PadSearchTests.testNoMatchesSaysSo | UI | STATUS |
| Result opens its title | PadSearchTests.testResultOpensItsTitle | UI | STATUS |
| Recent terms, Clear | PadSearchTests.testRecentTermsAreKeptAndCleared | UI | STATUS |
| Card menu: play, details, favourite, watched, from the beginning, download; no Mac-only items | PadContextMenuTests.testFilmMenuHasThePlayAndLibraryActions | UI | STATUS |
| Details / Favourite / Play from Beginning from the menu | PadContextMenuTests.testDetailsFromTheMenuOpensTheTitle, testFavoriteFromTheMenuReachesTheServer, testPlayFromBeginningStartsAtZero | UI | STATUS |
| Episode menu: Go to Show / Season, Next Up | PadContextMenuTests.testEpisodeMenuGoesToShowAndSeason | UI | STATUS |
| Season chip menu → season page | PadContextMenuTests.testSeasonChipMenuOpensTheSeasonsPage | UI | STATUS |
| Download submenu | PadContextMenuTests.testDownloadSubmenuListsQualities | UI | STATUS |
| Grid card menu | PadContextMenuTests.testLibraryGridCardHasTheMenuToo | UI | STATUS |
| Secondary click with a pointer | — | manual | manual |

## Player

| Function | Test | Kind | Status |
|---|---|---|---|
| iPad chrome: every control, worded pills, PiP button, both orientations | PadPlayerChromeTests.testIPadChromeHasEveryControl | UI | STATUS |
| Regular (non-compact) chrome metrics; window-controls inset | PadPlayerMetricsTests (4) | unit | pass |
| Resume where the server says | PadPlayerChromeTests.testResumesWhereTheServerSays | UI | STATUS |
| Pause / play; controls held while paused | PadPlayerChromeTests.testPauseAndPlay | UI | STATUS |
| Skip ±10 | PadPlayerChromeTests.testSkipForwardAndBack | UI | STATUS |
| Scrub | PadPlayerChromeTests.testScrubbingMovesThePosition | UI | STATUS |
| Remaining ↔ total | PadPlayerChromeTests.testRemainingTimeTogglesToTotal | UI | STATUS |
| Fill pill | PadPlayerChromeTests.testFillPillTurnsOnAndOff | UI | STATUS |
| Controls hide while playing, tap brings them back | PadPlayerChromeTests.testControlsHideWhilePlayingAndComeBackWithATap | UI | STATUS |
| Back closes to the title page | PadPlayerChromeTests.testBackClosesThePlayerToTheTitlePage | UI | STATUS |
| Info as a popover: engine, position, delivery | PadPlayerInfoTests.testInfoIsAPopoverWithEngineAndPosition | UI | STATUS |
| Engine pinned to AVFoundation on iPad | PadPlayerInfoTests.testMpvPreferenceIsPinnedToTheAppleEngineOnIPad | UI | STATUS |
| Chapters (Info's chapter row follows the position) | PadPlayerInfoTests.testChapterNameFollowsThePosition | UI | STATUS |
| Speed and sleep timer (More card) | PadPlayerInfoTests.testSpeedAndSleepFromTheMoreCardShowInInfo | UI | STATUS |
| "Normal" speed chip whole | PadPlayerInfoTests.testNormalSpeedChipIsWhole | UI | STATUS |
| Audio card, switch track (6 tracks) | PadPlayerTracksTests.testAudioCardListsEveryTrackAndSwitches | UI | STATUS |
| Forced subtitles offered and chosen; Off | PadPlayerTracksTests.testForcedSubtitleTrackIsOfferedAndCanBeChosen | UI | STATUS |
| Sidecar subtitles listed / chosen | PadPlayerTracksTests.testSidecarSubtitleIsOffered; PadRegressionTests.testChosenSidecarSubtitleStaysChosen | UI | STATUS |
| Quality card: rung chosen, transcoding | PadPlayerTracksTests.testQualityCardChoosesARung | UI | STATUS |
| Quality change while paused stays paused (B2) | PadPlayerTracksTests.testQualityChangeWhilePausedStaysPaused | UI | STATUS |
| Skip intro | PadPlayerMomentsTests.testSkipIntroAppearsInTheIntroAndSkipsIt | UI | STATUS |
| Skip credits (B3) | PadPlayerMomentsTests.testSkipCreditsAppearsInTheOutro | UI | STATUS |
| Up Next pill and card, jump to an episode | PadPlayerMomentsTests.testUpNextPillAndCardOnAnEpisode | UI | STATUS |
| Up Next card at the end, Play now | PadPlayerMomentsTests.testUpNextCardAtTheEndPlaysTheNextEpisode | UI | STATUS |
| Close with the Up Next card up: no crash | PadPlayerMomentsTests.testClosingWithTheUpNextCardUpDoesNotCrash | UI | STATUS |
| Stop after this (episode only) | PadPlayerMomentsTests.testStopAfterThisEpisodeIsOfferedOnAnEpisodeNotAFilm; PadRegressionTests.testStopAfterThisSurvivesAQualityChange | UI | STATUS |
| Picture in Picture from the button | PadPictureInPictureTests.testPictureInPictureStartsAndStops | UI | STATUS |
| Background → PiP, playback continues, player kept | PadPictureInPictureTests.testBackgroundingStartsPictureInPictureAndPlaybackContinues | UI | STATUS |
| Resume point and pause reported to the server | PadPlaybackReportingTests (2) | UI | STATUS |
| Player messages (toasts) over the player (B4) | PadRegressionTests.testPlayerMessagesShowOverThePlayer | UI | STATUS |
| Pills take taps while up (fade fix 58f77cf) | PadRegressionTests.testPillTakesATapWhileTheControlsAreUp | UI | STATUS; the timed edge-of-fade tap is manual |
| mpv, AirPlay, SharePlay, pinch, hold 2×, PiP placement | — | manual | manual |

## Music, books

| Function | Test | Kind | Status |
|---|---|---|---|
| Music from the sidebar; Discover / Library; library doors | PadMusicTests.testMusicDiscoverAndLibraryPages | UI | STATUS |
| Album with two discs | PadMusicTests.testAlbumPageGroupsDiscs | UI | STATUS |
| Song plays → sidebar card; no phone mini player | PadMusicTests.testPlayingASongPutsTheNowPlayingCardInTheSidebar | UI | STATUS |
| Card play/pause; opens Now Playing in a centred column (1a32226) | PadMusicTests.testSidebarCardPlayPauseAndOpensNowPlaying | UI | STATUS |
| Queue and synced lyrics | PadMusicTests.testNowPlayingQueueAndLyrics | UI | STATUS |
| Songs A–Z by title (6344432) | PadMusicTests.testSongsAToZJumpsToTheLetter | UI | STATUS |
| Artist page | PadMusicTests.testArtistPageFromTheAlbum | UI | STATUS |
| Song menu, Song Info | PadMusicTests.testSongMenuOffersQueueActions | UI | STATUS |
| Playlists (own, public), smart playlists heading | PadMusicPagesTests.testPlaylistsListTheSuitesOwnAndThePublicOnes | UI | STATUS |
| Artists, Genres | PadMusicPagesTests.testArtistsAndGenresDoors | UI | STATUS |
| Music search field | PadMusicPagesTests.testMusicSearchFieldFindsAnAlbum | UI | STATUS |
| Discover: Shuffle all, stations | PadMusicPagesTests.testDiscoverHasStationsAndShuffle | UI | STATUS |
| Audiobooks: Continue Listening | PadBooksTests.testAudiobooksSectionShowsContinueListening | UI | STATUS |
| Book page, chapters, play a chapter → sidebar card names it | PadBooksTests.testBookPageListsChaptersAndPlaysFromOne | UI | STATUS |

## Live TV

| Function | Test | Kind | Status |
|---|---|---|---|
| Guide: channels and programmes, both orientations | PadLiveTVTests.testGuideListsTheChannelsWithProgrammes | UI | STATUS |
| No back button at full width | PadLiveTVTests.testFullWidthLiveTVHasNoBackButton | UI | STATUS |
| Tune a channel: channel buttons, Channels pill, line-up popover, change channel | PadLiveTVTests.testTuningAChannelPlaysItWithChannelButtonsAndPill | UI | STATUS |
| Next channel wraps | PadLiveTVTests.testNextChannelWraps | UI | STATUS |
| Programme cell tunes | PadLiveTVTests.testProgrammeCellTunesItsChannel | UI | STATUS |
| Guide density on iPad (5.5 pt/min, 172 pt column) | PadMetricsTests.testGuideKeepsTheIPadDensity | unit | pass |

## Downloads

| Function | Test | Kind | Status |
|---|---|---|---|
| Empty page | PadDownloadsTests.testEmptyDownloadsPage | UI | STATUS |
| Download from a title, appears, plays from the copy, delete with confirmation | PadDownloadsTests.testDownloadPlayAndDeleteAFilm | UI | STATUS |
| Manage menu | PadDownloadsTests.testDownloadSettingsOnThePage | UI | STATUS |
| Series downloads, music/audiobook doors, offline shell | — | — | not covered: see the report (needs longer encodes or an offline server) |

## Settings

| Function | Test | Kind | Status |
|---|---|---|---|
| Two columns at ≥ 720 pt (landscape); the phone's list below (portrait) | PadSettingsTests.testTwoColumnsInLandscape, testOneColumnInPortrait; PadSettingsSplitTests | UI + unit | STATUS |
| Every page from the split list | PadSettingsTests.testEveryPageOpensFromTheSplitList | UI | STATUS |
| Rotation switches split ↔ list | PadSettingsTests.testRotatingSwitchesBetweenSplitAndList | UI | STATUS |
| "Sidebar" order page (not "Tab Bar") | PadSettingsTests.testAppearanceNamesTheSidebarNotTheTabBar | UI | STATUS |
| Theme | PadSettingsTests.testThemeChoice | UI | STATUS |
| Sub-page leaves with Settings (346bc31) | PadSettingsTests.testLeavingASettingsSubPageByTheSidebarLeavesIt | UI | STATUS |
| Account facts; Quick Connect approval field | PadSettingsTests.testAccountPageAndQuickConnectApproval | UI | STATUS |
| About | PadSettingsTests.testAboutNamesTheVersionAndEngine | UI | STATUS |
| No engine choice on iPad | PadSettingsTests.testVideoPageHasNoEngineChoiceOnIPad | UI | STATUS |
| Sign out | PadSettingsTests.testSignOutGoesToTheSignInScreen | UI | STATUS |
| Reordering the sidebar by drag | — | manual | manual (drag handles have no identifiers) |

## Sign-in and keyboard

| Function | Test | Kind | Status |
|---|---|---|---|
| Sign-in card centred | PadSignInTests.testSignInCardIsCentredOnTheWideScreen | UI | STATUS |
| Return connects; server banner | PadSignInTests.testReturnInTheServerFieldConnects | UI | STATUS |
| Public users listed | PadSignInTests.testPublicUsersAreListed | UI | STATUS |
| Password sign-in by Return → sidebar shell | PadSignInTests.testPasswordSignInByKeyboardLandsOnTheSidebarShell | UI | STATUS |
| Wrong password | PadSignInTests.testWrongPasswordSaysSo | UI | STATUS |
| Quick Connect code approved by the server | PadSignInTests.testQuickConnectShowsACodeTheServerCanApprove | UI | STATUS |
| Hardware Return / Tab / Escape | PadKeyboardTests (4) | UI | STATUS |
| Pointer hover, Pencil, ⌘ overlay | — | manual | manual |

## Results

RESULTS
