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

## The floating bar's blur (added 2026-11-20)

| Function | Test | Kind | Status |
|---|---|---|---|
| Untinted variable blur under the bar (filter found, no tint, no mask) | PadHeroBarBlurTests.testVariableBlurUsesTheUntintedFilter, …testMaskIsOpaqueAtTheTopAndClearAtTheBottom | unit | pass |
| Bar keeps its place and answers once the page scrolls under the blur | PadHomeTests.testBarStaysUsableOnceThePageScrollsUnderIt | UI | pass |
| What the blur looks like over artwork and over the page | MANUAL.md, "The floating bar's blur" | manual | manual |

## Shell and navigation

| Function | Test | Kind | Status |
|---|---|---|---|
| Sidebar shell at regular width (no tab bar) | PadSidebarTests.testSidebarIsTheShellNotATabBar | UI | pass |
| Header: account initial, name, server host | PadSidebarTests.testHeaderNamesTheAccountAndServer | UI | pass |
| Grouped rows: Browse / Libraries / Live / You, every library, no Settings or More rows | PadSidebarTests.testRowsAreGroupedHomeFirstAndEveryLibraryListed; PadSidebarGroupTests (8) | UI + unit | pass |
| Each section opens from its row, row lit | PadSidebarTests.testEverySectionOpensFromItsRow | UI | pass |
| Re-tapping the lit row pops to the section's top | PadSidebarTests.testSelectedRowGoesBackToTheTopOfItsSection | UI | pass |
| Search row pushes Search over Home | PadSidebarTests.testSearchRowPushesSearch; PadShellSelectionTests.testShowSearchOnAnIPadOpensItOverHome | UI + unit | pass |
| Settings gear in the footer | PadSidebarTests.testSettingsGearSelectsSettings | UI | pass |
| Footer status (Synced / downloads running / Offline) | PadSidebarTests.testFooterSaysSynced; PadDownloadsTests.testDownloadPlayAndDeleteAFilm | UI | pass |
| Downloads badge on the row | PadDownloadsTests.testDownloadPlayAndDeleteAFilm (transient) | UI | partial: the badge is up only while a transfer runs, too brief on the local server to assert |
| Collapse the sidebar; bring it back from Home's bar | PadSidebarTests.testCollapseAndBringBackTheSidebarInLandscape | UI | pass |
| Bring it back from a title page's bar | PadSidebarTests.testCollapsedSidebarComesBackFromATitlePage | UI | pass (fixed 2026-11-13) |
| Sidebar in portrait and landscape | PadSidebarTests.testSidebarInPortraitAndLandscape | UI | pass |
| Long library name not cut in the sidebar ("Home Videos & Phot…"): wraps to two lines | PadRegressionTests.testLongLibraryNameIsNotCutInTheSidebar | UI | pass (fixed 2026-11-13) |
| Sidebar width 190–280 (narrower sidebar, 6344432) | PadSidebarTests.testSidebarIsNarrow | UI | pass |
| Now Playing card at the foot of the sidebar | PadMusicTests.testPlayingASongPutsTheNowPlayingCardInTheSidebar, …SidebarCardPlayPauseAndOpensNowPlaying; PadBooksTests | UI | pass |
| No card when idle | PadSidebarTests.testDownloadsBadgeAndNowPlayingAbsentWhenIdle | UI | pass |
| Shell follows the size class: section with no tab goes into More, comes back on widening (a98b494) | PadShellSelectionTests (9) | unit | pass |
| Sidebar comes back after a phone-width window | PadWindowSizeTests.testSidebarComesBackAfterAPhoneWidthWindow | UI | skip (simulator shows apps full screen); open bug, MANUAL.md |
| Stage Manager / Split View / external display | — | manual | manual |

## Home

| Function | Test | Kind | Status |
|---|---|---|---|
| Hero with Play and Details | PadHomeTests.testHeroShowsWithPlayAndDetails | UI | pass |
| Hero edge to edge, under the sidebar, 2.4:1 band | PadHomeTests.testHeroIsEdgeToEdgeAtTwoPointFourToOne; PadHeroGeometryTests (5) | UI + unit | pass |
| Thumbnails on its side (width ≥ 900), dots upright | PadHomeTests.testThumbnailsInLandscapeDotsInPortrait | UI | pass |
| A thumbnail turns the hero | PadHomeTests.testThumbnailTurnsTheHeroToItsPage | UI | pass |
| Swipe turns the hero | PadHomeTests.testSwipingTheHeroTurnsThePage | UI | pass |
| Hero Details / Play | PadHomeTests.testHeroDetailsOpensTheTitle, testHeroPlayStartsThePlayer | UI | pass |
| Hero first page aligned with the rest (6344432) | PadRegressionTests.testHeroFirstPageSitsWhereTheOthersDo | UI | pass |
| Hero pages take their real width (d5792c6) | PadRegressionTests.testHeroPagesTakeTheirRealWidth | UI | pass |
| Hero timer stops behind a pushed title (30cbbc2) | PadRegressionTests.testHeroDoesNotTurnBehindAPushedTitle | UI | skip (Home's hero leaves the tree under a pushed page, so it can't be read) |
| Saved hero backdrops for offline; crop focus near the top (c643527) | — | manual | manual (visual / offline) |
| Continue Watching, Next Up shelves (baseline) | PadHomeTests.testContinueWatchingAndNextUpShelves | UI | pass |
| Latest per library | PadHomeTests.testLatestShelfPerLibrary | UI | pass |
| On Now shelf | PadHomeTests.testOnNowShelfOnHome | UI | pass |
| Recently Played / New Music shelves | PadHomeTests.testMusicShelvesOnHome | UI | pass |
| Library chip strip (instead of My Media tiles) | PadHomeTests.testLibraryChipsOpenALibrary | UI | pass |
| See all | PadHomeTests.testShelfSeeAllOpensTheWholeRow | UI | pass |
| Floating bar: Refresh, Search | PadHomeTests.testRefreshAndSearchInTheFloatingBar; PadSearchTests.testHomeBarSearchOpensTheSameSearch | UI | pass |
| Card opens its title | PadHomeTests.testCardOpensItsTitle | UI | pass |
| Both orientations | PadHomeTests.testHomeInBothOrientations | UI | pass |
| Deep Water metrics (gutter 28, shelf 32, row 16, grid 14, radius 14, poster 156, still 300) | PadMetricsTests (6) | unit | pass |

## Libraries, collections, photos, favourites

| Function | Test | Kind | Status |
|---|---|---|---|
| Grid with the count in the pinned header | PadLibraryTests.testGridAndCountInTheHeader | UI | pass |
| More columns on its side | PadLibraryTests.testGridHasMoreColumnsInLandscape | UI | pass |
| iPad name search in the header, Clear | PadLibraryTests.testSearchFieldFiltersByName | UI | pass |
| Unwatched, Favourites, Genre filters | PadLibraryTests.testUnwatchedFilterHidesPlayedFilms, testFavoritesFilter, testGenreMenuFilters | UI | pass |
| Sort menu (Reverse Order is the Mac's alone) | PadLibraryTests.testSortMenu | UI | pass |
| Every filter chip reachable upright (the name field overlaps the strip) | PadLibraryTests.testEveryFilterChipCanBeReachedUpright | UI | pass |
| Card → title → Back to the grid | PadLibraryTests.testCardOpensTitleAndBackReturnsToTheGrid | UI | pass |
| Shows library → series | PadLibraryTests.testShowsLibraryOpensASeries | UI | pass |
| Collections section (56a1825) and a collection's titles | PadLibraryTests.testCollectionsSectionListsFXCollection | UI | pass |
| Photo album opens as a grid of photos | PadPhotosTests.testPhotoAlbumOpensAsAGridOfPhotos | UI | pass (claude/fix-tv) |
| Photo folder named properly, not by its folder on disk | PadPhotosTests.testPhotoFolderIsNotShownByItsRawFolderName | UI | pass (claude/fix-tv) |
| Favourites: baseline, kind chips | PadFavoritesTests.testFavoritesShowsTheBaselineAndFiltersByKind | UI | pass |
| Favourite added elsewhere appears (ItemMutations) | PadFavoritesTests.testFavoriteAddedOnATitleAppearsHere | UI | pass |

## Title pages

| Function | Test | Kind | Status |
|---|---|---|---|
| Two-column header (poster beside facts) on its side | PadDetailTests.testTwoColumnHeaderInLandscape | UI | pass |
| Header upright | PadDetailTests.testHeaderInPortrait | UI | pass |
| Facts, genres, overview tap-to-unfold | PadDetailTests.testFactsAndOverview | UI | pass |
| Resume label and time left | PadDetailTests.testResumeLabelAndRemainingOnAFilmInProgress | UI | pass |
| Favourite disc → server | PadDetailTests.testFavoriteDiscReachesTheServer | UI | pass |
| Watched disc → server | PadDetailTests.testWatchedDiscReachesTheServer | UI | pass |
| Quality menu (ladder) and play at a rung, held for the sitting | PadDetailTests.testQualityMenuListsTheLadder, testQualityMenuPlaysAtTheRungChosen; PadQualityPinTests (3) | UI + unit | pass (rung fixed 2026-11-13) |
| Download menu | PadDetailTests.testDownloadMenuOffersQualities | UI | pass |
| Versions (three media sources), in the quality menu's Version section | PadDetailTests.testVersionsAreOfferedOnATitleWithThreeFiles | UI | pass (claude/fix-tv) |
| Season switch, episodes two across, switching seasons | PadDetailTests.testSeriesPageHasSeasonSwitchAndEpisodesTwoAcrossInLandscape | UI | pass |
| Episode summary, play glyph | PadDetailTests.testEpisodeSummaryAndPlayGlyph | UI | pass |
| Episode page and its Show › Season trail | PadDetailTests.testEpisodeRowOpensTheEpisodesPageWithItsTrail | UI | pass |
| Add to Next Up asks (popover on iPad) | PadDetailTests.testAddToNextUpOnASeriesAsks | UI | pass |
| Cast → person page | PadDetailTests.testCastOpensAPersonsPage | UI | pass |
| More Like This | PadDetailTests.testMoreLikeThis | UI | pass |
| Back from the page's own bar | PadDetailTests.testBackReturnsToTheSectionsPage | UI | pass |
| Trailer disc (local trailers) | PadDetailTests.testTrailerOnATitleWithLocalTrailers | UI | pass |
| Quality not alone on its row upright | PadRegressionTests.testQualityDoesNotWrapAloneBesideThePosterInPortrait | UI | pass |
| Blocked title's error (fx-kid): plain words, no Try again | PadRegressionTests.testBlockedTitleSaysSoInPlainWords | UI | pass (words: claude/fix-tv; no Try again: 2026-11-13) |
| Header switches to the compact stack under 720 pt of column | — | manual | manual (needs a window narrower than the simulator allows) |
| A person's page from the cast: header, name in the bar, Films shelf, a film opens; no facts or biography where the server has none | PadPersonTests.testPersonPageShowsTheirFilmsAndOpensOne | UI | pass |
| Favorites: layout, sort and reverse pickers | — | — | the Mac's toolbar: an iPad has the kind chips only (PadFavoritesTests) |

## Search and context menus

| Function | Test | Kind | Status |
|---|---|---|---|
| "FX Long" finds the four | PadSearchTests.testFindsTheFXLongTitles | UI | pass |
| Results beside the sidebar | PadSearchTests.testResultsSitInTheDetailColumnBesideTheSidebar | UI | pass |
| Unicode title | PadSearchTests.testUnicodeTitleIsFound | UI | pass |
| Music results above "Films & TV" | PadSearchTests.testMusicResultsAboveFilmsAndTV | UI | pass |
| No matches | PadSearchTests.testNoMatchesSaysSo | UI | pass |
| Result opens its title | PadSearchTests.testResultOpensItsTitle | UI | pass |
| Recent terms, Clear | PadSearchTests.testRecentTermsAreKeptAndCleared | UI | pass |
| Card menu: play, details, favourite, watched, from the beginning, download; no Mac-only items | PadContextMenuTests.testFilmMenuHasThePlayAndLibraryActions | UI | pass |
| Play / Favourite / Play from Beginning from the menu (cards have no Details: a tap opens them) | PadContextMenuTests.testPlayFromTheMenuStartsThePlayer, testFavoriteFromTheMenuReachesTheServer, testPlayFromBeginningStartsAtZero | UI | pass |
| Episode menu: Go to Show / Season, Next Up | PadContextMenuTests.testEpisodeMenuGoesToShowAndSeason | UI | pass |
| Season chip menu → season page | PadContextMenuTests.testSeasonChipMenuOpensTheSeasonsPage | UI | pass |
| Download submenu | PadContextMenuTests.testDownloadSubmenuListsQualities | UI | pass |
| Grid card menu | PadContextMenuTests.testLibraryGridCardHasTheMenuToo; MANUAL.md | UI + manual | xfail (XCUITest only: a real long press gives the menu) |
| Secondary click with a pointer | — | manual | manual |

## Requests through Seerr (PadRequestsTests)

Against the stand-in Seerr server (TESTING.md). The logic rows are in the
iPhone file (the same shared unit tests run here). Run 2026-11-16: 4 pass.

| Function | Test | Kind | Status |
|---|---|---|---|
| Sidebar gains Requests (under You) only while connected; its page beside the sidebar | PadRequestsTests.testTheSidebarGainsRequestsOnlyWhenConnected, PadShellTests.testRequestsSitsWithWhatIsYours | UI, unit | pass |
| Search offers a title, its page requests it, Requests lists it by name | PadRequestsTests.testSearchOffersARequestAndThePageMakesIt | UI | pass |
| A show partly in the library is not offered as missing | PadRequestsTests.testLibraryResultsStillLeadAndSeerrFollows | UI | pass |
| A show's missing-seasons banner; a person's "Not in Your Library" row | PadRequestsTests.testAPersonsPageShowsTheRestOfTheirWork | UI | pass |
| The Seerr page: each browse row a placeholder until it lands, the foot credits Seerr and TMDB | PadRequestsTests.testRowsShowTheyAreLoadingAndThePageCreditsSeerrAndTMDB | UI | pass 2026-11-19 |

## Player

| Function | Test | Kind | Status |
|---|---|---|---|
| iPad chrome: every control, worded pills, PiP button, both orientations | PadPlayerChromeTests.testIPadChromeHasEveryControl | UI | pass |
| Regular (non-compact) chrome metrics; window-controls inset | PadPlayerMetricsTests (4) | unit | pass |
| Resume where the server says | PadPlayerChromeTests.testResumesWhereTheServerSays | UI | pass |
| Pause / play; controls held while paused | PadPlayerChromeTests.testPauseAndPlay | UI | pass |
| Skip ±10 | PadPlayerChromeTests.testSkipForwardAndBack | UI | pass |
| Scrub | PadPlayerChromeTests.testScrubbingMovesThePosition | UI | pass |
| Remaining ↔ total | PadPlayerChromeTests.testRemainingTimeTogglesToTotal | UI | pass |
| Fill pill | PadPlayerChromeTests.testFillPillTurnsOnAndOff | UI | pass |
| Controls hide while playing, tap brings them back | PadPlayerChromeTests.testControlsHideWhilePlayingAndComeBackWithATap | UI | pass |
| Back closes to the title page | PadPlayerChromeTests.testBackClosesThePlayerToTheTitlePage | UI | pass |
| Info as a popover: engine, position, delivery | PadPlayerInfoTests.testInfoIsAPopoverWithEngineAndPosition | UI | pass |
| Engine pinned to AVFoundation on iPad | PadPlayerInfoTests.testMpvPreferenceIsPinnedToTheAppleEngineOnIPad | UI | pass |
| Chapters (Info's chapter row follows the position) | PadPlayerInfoTests.testChapterNameFollowsThePosition | UI | pass |
| Speed and sleep timer (More card) | PadPlayerInfoTests.testSpeedAndSleepFromTheMoreCardShowInInfo | UI | pass |
| "Normal" speed chip whole | PadPlayerInfoTests.testNormalSpeedChipIsWhole | UI | pass |
| Audio card, switch track (6 tracks) | PadPlayerTracksTests.testAudioCardListsEveryTrackAndSwitches | UI | skip (the QA server's encoder fails for this file; the player ends on its error card after three tries, about 1 min 45 s, checked by hand 2026-11-13) |
| Forced subtitles offered and chosen; Off | PadPlayerTracksTests.testForcedSubtitleTrackIsOfferedAndCanBeChosen | UI | pass |
| Sidecar subtitles listed / chosen | PadPlayerTracksTests.testSidecarSubtitleIsOffered; PadRegressionTests.testChosenSidecarSubtitleStaysChosen | UI | pass |
| Quality card: rung chosen, transcoding | PadPlayerTracksTests.testQualityCardChoosesARung | UI | pass |
| Quality change while paused stays paused (B2) | PadPlayerTracksTests.testQualityChangeWhilePausedStaysPaused | UI | pass |
| Skip intro | PadPlayerMomentsTests.testSkipIntroAppearsInTheIntroAndSkipsIt | UI | pass |
| Skip credits (B3) | PadPlayerMomentsTests.testSkipCreditsAppearsInTheOutro | UI | pass |
| Up Next pill and card, jump to an episode | PadPlayerMomentsTests.testUpNextPillAndCardOnAnEpisode | UI | pass |
| Up Next card at the end, Play now | PadPlayerMomentsTests.testUpNextCardAtTheEndPlaysTheNextEpisode | UI | pass |
| Close with the Up Next card up: no crash | PadPlayerMomentsTests.testClosingWithTheUpNextCardUpDoesNotCrash | UI | pass |
| Stop after this (episode only) | PadPlayerMomentsTests.testStopAfterThisEpisodeIsOfferedOnAnEpisodeNotAFilm; PadRegressionTests.testStopAfterThisSurvivesAQualityChange | UI | pass |
| Picture in Picture from the button | PadPictureInPictureTests.testPictureInPictureStartsAndStops | UI | xfail (system: iPadOS places the PiP window over the player's Leave PiP button; MANUAL.md) |
| Background → PiP, playback continues, player kept | PadPictureInPictureTests.testBackgroundingStartsPictureInPictureAndPlaybackContinues | UI | pass |
| Resume point and pause reported to the server | PadPlaybackReportingTests (2) | UI | pass |
| Player messages (toasts) over the player (B4) | PadRegressionTests.testPlayerMessagesShowOverThePlayer | UI | pass |
| Pills take taps while up (fade fix 58f77cf) | PadRegressionTests.testPillTakesATapWhileTheControlsAreUp | UI | pass; the timed edge-of-fade tap is manual |
| mpv, AirPlay, SharePlay, pinch, hold 2×, PiP placement | — | manual | manual |
| SharePlay "Start from whose progress?" on the player: you, then others with a spot, then the beginning; the pick moves playback (made-up friends via AQUARIUM_TEST_SHAREPLAY_PROGRESS) | PadSharePlayTests.testWhoseProgressIsAskedAndThePickIsWherePlayGoes | UI | pass 2026-11-19 |
| "Keep Watching Here" leaves playback where it was | PadSharePlayTests.testKeepWatchingHereStaysPut | UI | pass 2026-11-19 |
| SyncPlay (shared with the iPhone: same card, same code) | PhoneSyncPlayTests on the iPhone; iPhone MANUAL for two devices | UI (iPhone) | not run on the iPad |

## Music, books

| Function | Test | Kind | Status |
|---|---|---|---|
| Music from the sidebar; Discover / Library; library doors | PadMusicTests.testMusicDiscoverAndLibraryPages | UI | pass |
| Album with two discs | PadMusicTests.testAlbumPageGroupsDiscs | UI | pass |
| Song plays → sidebar card; no phone mini player | PadMusicTests.testPlayingASongPutsTheNowPlayingCardInTheSidebar | UI | pass |
| Card play/pause; opens Now Playing in a centred column (1a32226) | PadMusicTests.testSidebarCardPlayPauseAndOpensNowPlaying | UI | pass |
| Queue and synced lyrics | PadMusicTests.testNowPlayingQueueAndLyrics | UI | pass |
| Songs A–Z by title (6344432) | PadMusicTests.testSongsAToZJumpsToTheLetter | UI | pass |
| Artist page | PadMusicTests.testArtistPageFromTheAlbum | UI | pass |
| Song menu, Song Info | PadMusicTests.testSongMenuOffersQueueActions | UI | pass |
| Playlists (own, public), smart playlists heading | PadMusicPagesTests.testPlaylistsListTheSuitesOwnAndThePublicOnes | UI | pass |
| Artists, Genres | PadMusicPagesTests.testArtistsAndGenresDoors | UI | pass |
| Music search field | PadMusicPagesTests.testMusicSearchFieldFindsAnAlbum | UI | pass |
| Discover: Shuffle all, stations | PadMusicPagesTests.testDiscoverHasStationsAndShuffle | UI | pass |
| Audiobooks: Continue Listening | PadBooksTests.testAudiobooksSectionShowsContinueListening | UI | pass |
| Book page, chapters, play a chapter → sidebar card names it | PadBooksTests.testBookPageListsChaptersAndPlaysFromOne | UI | pass |

### Playlists (PadPlaylistTests, added 2026-11-14)

Each test makes its own playlists, named "suite-ipad …", and deletes them on the server afterwards. Verified 2026-11-14: each of the five new classes (Person, Playlists, Smart playlists, Settings accounts, Settings more) passed alone and again together (31 tests: 21 pass, 10 expected failures). The bugs behind those ten were fixed 2026-11-15 and the marks removed: 31 strict, 30 passed together and the Live TV settings test passed on its own rerun.

| Function | Test | Kind | Status |
|---|---|---|---|
| Playlists page: own and public playlists, song counts, the + | PadPlaylistTests.testPlaylistsPageListsTheAccountsAndThePublicOnes | UI | pass |
| + → New Playlist alert (Cancel makes nothing; Create), the new playlist's page, "Empty playlist", its row on the list | PadPlaylistTests.testCreatingWithThePlusOpensTheNewEmptyPlaylist | UI | pass |
| Rename from the row's menu (Cancel, Rename; server follows) | PadPlaylistTests.testRenameFromTheRowsMenu | UI | pass (fixed 2026-11-15) |
| Delete Playlist from the row's menu: the confirmation, Cancel keeps it, "Delete from the server" removes it | PadPlaylistTests.testDeleteAsksFirstAndCancelKeepsThePlaylist | UI | pass (fixed 2026-11-15) |
| Song "…" → Add to Playlist → New Playlist… (named for the album), the playlist made with the song | PadPlaylistTests.testASongsMenuMakesANewPlaylistWithTheSongInIt | UI | pass (fixed 2026-11-15) |
| Song "…" → Add to Playlist → an existing playlist; the list's count follows | PadPlaylistTests.testASongsMenuAddsToAnExistingPlaylist | UI | pass (fixed 2026-11-15) |
| A playlist's page: header, songs in the playlist's order, the "…" menu with Edit Songs | PadPlaylistTests.testPlaylistPageShowsItsSongsInTheirOrder | UI | pass |
| Remove from Playlist in a song's press-and-hold menu | PadPlaylistTests.testRemoveFromPlaylistInASongsMenu | UI | pass (fixed 2026-11-15) |
| Edit Songs: the editor, its status line, a row's red − and Delete, Done | PadPlaylistTests.testEditSongsRemovesASongAndDoneGoesBack | UI | pass |
| Edit Songs: drag a row by its handle; the server's order follows | PadPlaylistTests.testEditSongsReordersByDragging | UI | pass |
| Playlists' empty, loading and error states | — | — | not covered: every account sees the server's public playlists, so the list is never empty on the QA server; loading is a skeleton for a fraction of a second (MANUAL.md) |

### Smart playlists (PadSmartPlaylistTests, added 2026-11-14)

A smart playlist is kept in the app's settings, which every launch starts empty. The editor's tests make theirs through the editor; the tests of what a rule answers launch with the rule already saved (`-smart_playlists`). "Save as Playlist on Server" makes a real playlist, deleted afterwards, and a song made a favourite is put back.

| Function | Test | Kind | Status |
|---|---|---|---|
| "Smart Playlists" heading, "None yet", New; the editor's defaults; Save off without a name; Cancel makes nothing | PadSmartPlaylistTests.testListStartsEmptyAndCancelMakesNothing | UI | pass |
| Editor: the genre picker (filter, choose, take one back from Chosen), the Genres row and the sentence following | PadSmartPlaylistTests.testGenrePickerFiltersChoosesAndTakesBack | UI | pass |
| Editor: name, artist search / add / remove, year from / to, added within, played, minimum plays, favourites, sort, limit, each read back in the summary sentence; Save lists the rule with its sentence | PadSmartPlaylistTests.testEditorControlsWriteTheSummaryAndSaveListsTheRule | UI | pass |
| Genre + year rule answers with exactly the matching fixture songs, by title | PadSmartPlaylistTests.testGenreAndYearRulePicksExactlyTheMatchingSongs | UI | pass |
| Artist rule | PadSmartPlaylistTests.testArtistRulePicksThatArtistsSongs | UI | pass |
| Favourites-only rule | PadSmartPlaylistTests.testFavouritesOnlyRulePicksTheFavouriteSong | UI | pass |
| "Added in the last N days" (settled in the app against DateCreated) | PadSmartPlaylistTests.testAddedWithinRuleIsSettledAgainstTheDateAdded | UI | pass (fixed 2026-11-15) |
| A rule nothing matches: "Nothing matches", Play off, Save as Playlist on Server off | PadSmartPlaylistTests.testARuleNothingMatchesSaysSo | UI | pass |
| Row menu: Edit Rules (the editor opens on the rule, the row follows the edit), Delete | PadSmartPlaylistTests.testRowMenuEditsTheRuleAndDeletesIt | UI | pass |
| The rule's page menu: Edit Rules, Refresh, Save as Playlist on Server (a real playlist, opened), Delete → "Gone" | PadSmartPlaylistTests.testDetailMenuEditsRefreshesSavesToTheServerAndDeletes | UI | pass (fixed 2026-11-15) |
| Offline: answered from downloads, the shelf on the offline Discover page | — | — | not covered (needs downloaded music and the server out of reach) |

## Live TV

| Function | Test | Kind | Status |
|---|---|---|---|
| Guide: channels and programmes, both orientations | PadLiveTVTests.testGuideListsTheChannelsWithProgrammes | UI | pass |
| No back button at full width | PadLiveTVTests.testFullWidthLiveTVHasNoBackButton | UI | pass |
| Tune a channel: channel buttons, Channels pill, line-up popover, change channel | PadLiveTVTests.testTuningAChannelPlaysItWithChannelButtonsAndPill | UI | pass |
| Next channel wraps | PadLiveTVTests.testNextChannelWraps | UI | pass |
| Programme cell tunes | PadLiveTVTests.testProgrammeCellTunesItsChannel | UI | pass |
| Guide density on iPad (5.5 pt/min, 172 pt column) | PadMetricsTests.testGuideKeepsTheIPadDensity | unit | pass |
| Custom playlist source (M3U + XMLTV from the test's own HTTP server): channels in the guide | PadSettingsMoreTests.testCustomPlaylistFieldsArtworkCheckAndLastRead | UI | pass |
| Guide date picker, Earlier / Now / Later, programme Info popover, cell menu | — | — | the Mac's toolbar and popover: not on an iPad |

## Downloads

| Function | Test | Kind | Status |
|---|---|---|---|
| Empty page | PadDownloadsTests.testEmptyDownloadsPage | UI | pass |
| Download from a title, appears, plays from the copy, delete with confirmation | PadDownloadsTests.testDownloadPlayAndDeleteAFilm | UI | pass |
| Manage menu | PadDownloadsTests.testDownloadSettingsOnThePage | UI | pass |
| Series downloads, music/audiobook doors, offline shell | — | — | not covered: see the report (needs longer encodes or an offline server) |

## Settings

| Function | Test | Kind | Status |
|---|---|---|---|
| Two columns at ≥ 720 pt (landscape); the phone's list below (portrait) | PadSettingsTests.testTwoColumnsInLandscape, testOneColumnInPortrait; PadSettingsSplitTests | UI + unit | pass |
| Every page from the split list | PadSettingsTests.testEveryPageOpensFromTheSplitList | UI | pass |
| Rotation switches split ↔ list | PadSettingsTests.testRotatingSwitchesBetweenSplitAndList | UI | pass |
| "Sidebar" order page (not "Tab Bar") | PadSettingsTests.testAppearanceNamesTheSidebarNotTheTabBar | UI | pass |
| Theme | PadSettingsTests.testThemeChoice | UI | pass |
| Sub-page leaves with Settings (346bc31) | PadSettingsTests.testLeavingASettingsSubPageByTheSidebarLeavesIt | UI | pass |
| Sub-pages (Sidebar, App Icon, Station mix, …) open in the one-column layout | PadSettingsTests.testSubPagesOpenInTheOneColumnLayout | UI | pass (fixed 2026-11-13) |
| Account facts; Quick Connect approval field | PadSettingsTests.testAccountPageAndQuickConnectApproval | UI | pass |
| About | PadSettingsTests.testAboutNamesTheVersionAndEngine | UI | pass |
| No engine choice on iPad | PadSettingsTests.testVideoPageHasNoEngineChoiceOnIPad | UI | pass |
| Sign out | PadSettingsTests.testSignOutGoesToTheSignInScreen | UI | pass |
| Add Account… sheet starts on the server in use; Cancel | PadSettingsAccountsTests.testAddAccountSheetStartsOnThisServerAndCancels | UI | pass |
| Second account (suite-spare1) signed in; the tick on the one in use; tap to switch; swipe → Sign Out | PadSettingsAccountsTests.testSecondAccountSignsInSwitchesBackAndIsSwipedOut | UI | pass (fixed 2026-11-15) |
| Sign Out of This Device from an account's press-and-hold menu | PadSettingsAccountsTests.testAnAccountNotInUseIsSignedOutFromItsMenu | UI | pass (fixed 2026-11-15) |
| Removing an account asks first | — | — | the Mac's confirmation (`settings.accounts.removeConfirm`): an iPad signs the account out at once |
| Live TV: source switch, Custom playlist page (playlist, guide, user agent, refresh interval), artwork check (no channels yet; a line a channel), Refresh now, "Last read" line | PadSettingsMoreTests.testCustomPlaylistFieldsArtworkCheckAndLastRead | UI | pass (fixed 2026-11-15) |
| Subtitles: Forced only (a choice of the language row), kept across a relaunch | PadSettingsMoreTests.testSubtitlesForcedOnlyIsAChoiceOfTheLanguageRow | UI | pass |
| Audio: language; no audio delay or downmix on an iPad | PadSettingsMoreTests.testAudioPageHasALanguageAndNoDelayOnAnIPad | UI | pass |
| Station mix: preset, dials, the 20-point budget, Custom | PadSettingsMoreTests.testStationMixPresetAndDialsShareOneBudget | UI | pass |
| Station mix: the warning under a dial whose tag recent stations lacked | PadSettingsMoreTests.testStationMixDialWarnsWhenRecentStationsLackedItsTag | UI | pass (coverage handed in as a launch argument) |
| Library copy: the switch, Status and Saved rows, Sync now, Delete with its confirmation and Cancel | PadSettingsMoreTests.testLibraryCopyStatusRowsSyncAndDelete | UI | pass |
| About: the engine and the paragraph | PadSettingsMoreTests.testAboutSaysWhatTheAppIsAndItsEngine | UI | pass |
| Apple Watch page | — | — | not offered on an iPad (the row is the iPhone's: SettingsView.swift:1020) |
| Reordering the sidebar by drag | — | manual | manual (drag handles have no identifiers) |

## Sign-in and keyboard

| Function | Test | Kind | Status |
|---|---|---|---|
| Sign-in card centred | PadSignInTests.testSignInCardIsCentredOnTheWideScreen | UI | pass |
| Sign-in shows the one-word wordmark, read as "Aquarium" | PadSignInTests.testSignInShowsTheWordmark | UI | new, not yet run |
| Return connects; server banner | PadSignInTests.testReturnInTheServerFieldConnects | UI | pass |
| Public users listed | PadSignInTests.testPublicUsersAreListed | UI | pass |
| Password sign-in by Return → sidebar shell | PadSignInTests.testPasswordSignInByKeyboardLandsOnTheSidebarShell | UI | pass |
| Wrong password | PadSignInTests.testWrongPasswordSaysSo | UI | pass |
| Quick Connect code approved by the server | PadSignInTests.testQuickConnectShowsACodeTheServerCanApprove | UI | pass |
| Return submits search; Return through the sign-in form | PadKeyboardTests.testReturnSubmitsSearch, testReturnConnectsAndMovesThroughTheSignInForm | UI | pass |
| Tab from username to password | PadKeyboardTests.testTabMovesFromUsernameToPassword | UI | skip (Tab not delivered as a key by the simulator's on-screen keyboard; MANUAL.md) |
| Escape closes the Info popover and a context menu (hardware key) | PadKeyboardTests.testEscapeDismissesTheInfoPopover, testEscapeDismissesAContextMenu | UI | skip (hardware key presses don't reach the app on this simulator; MANUAL.md) |
| Pointer hover, Pencil, ⌘ overlay | — | manual | manual |

## Results

Final state, 2026-11-13 (fix pass on `claude/fix-ipad`, with `claude/fix-tv`
merged), "Aquarium Test iPad Air 11" (iOS 27.0), QA server 8196, `suite-ipad`
reset before each run: the full iPad plan once, then the two failures rerun
alone. The unit plan ran on a private iPhone 17 Pro simulator (iOS 27.0),
where the iPad-only unit tests skip; their last iPad run is the 33 below.

| | Count |
|---|---|
| Unit tests (AquariumTests/iPad) | 36: the earlier 33 (iPad only, last run on the iPad, all pass) and PadQualityPinTests (3, pass on iOS) |
| Unit plan, whole (iPhone simulator) | 155: 122 pass, 33 skip (iPad and TV only), 0 fail |
| UI tests (AquariumUITests/iPad), full plan | 165: 154 pass, 2 expected failures, 7 skipped, 2 failed |

The two failures:

- `PadRegressionTests.testHeroFirstPageSitsWhereTheOthersDo`: failed once in
  the full plan (first hero page measured 182 pt off in landscape) and passed
  rerun alone.
- `PadPlayerChromeTests.testIPadChromeHasEveryControl`: the pill row was not
  found after turning to landscape (2 of 3 runs before these fixes failed
  too). The controls come up with the player and hide 4 s later, about when
  the turn ends: `showControls()` found them up, returned, and they faded.
  Fixed in the test (it brings the controls back whenever they are gone until
  the row is seen); 10 of 10 with `-test-iterations 10`.

The two expected failures are no longer app bugs: the PiP window's position
is iPadOS's (MANUAL.md), and the grid card's missing menu is XCUITest's (a
real long press gives it; MANUAL.md). Skips are the simulator's limits
(hardware keys, Tab, full-screen windows), the hero under a pushed page, the
smoke test of the iPhone's that the plan carries (it skips on an iPad), and the multitrack film
whose encode the QA server can't open.
