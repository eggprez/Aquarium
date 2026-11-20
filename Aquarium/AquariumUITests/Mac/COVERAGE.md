# Mac coverage inventory

Function → test → kind → status. Unit tests are in `AquariumTests/Mac/`, UI tests in
`AquariumUITests/Mac/`, manual checks in `MANUAL.md` here. Shared logic also has the
`AquariumTests/Shared/` tests (engine policy, stream plan, seams, track preference,
guide schedule, Next Up…), which run on the Mac as part of the Unit plan.

Status key: **built** = compiles for the Mac plan, not run yet (see "Run state" at the
end); **pass** / **fail** / **xfail** (kept with `XCTExpectFailure("bug: …")`) once run;
**manual** = MANUAL.md.

Test names in `Class.test…` form; `Bug…` names are regressions, each citing its source
in a comment.

## App and Dock — `MacAppDelegate.swift`

| Function | Test | Kind | Status |
|---|---|---|---|
| Return-to-app refresh, once per 5 min, signed in only | `MacAppShellTests.testBecomingActiveSoonAfterLaunchDoesNotRefresh`, `testReturnAfterFiveMinutesRefreshesOnceWhenSignedIn`, `testReturnUnderFiveMinutesDoesNothing`; MANUAL S5 | unit, manual | built |
| Dock menu: Continue Watching + Search | `MacAppShellTests.testDockMenuWithNothingToContinueIsJustSearch`, `testDockMenuListsContinueWatchingThenSearch`; MANUAL K1 | unit, manual | built |
| Dock menu play / search actions | MANUAL K1 (the menu items' @objc targets need a Dock click) | manual | manual |
| Dock reopen brings the main window back | `MacAppShellTests.testBugDockClickIgnoredWithOtherWindowsOpen`; MANUAL K2 | unit, manual | built |
| Player window opened when playback starts anywhere | `MacPlayerUITests.testBugPlayerWasTinySheet`, `MacMenuCommandUITests.testCommandReturnPlays` | UI | built |
| NSAlert when no window can show an alert | MANUAL K5 | manual | manual |
| Dock badge = transfers to finish | `MacAppShellTests.testBugDockBadgeMatchesTransfersToFinish`; MANUAL K3 | unit, manual | built |

## Menu bar — `MacCommands.swift`

| Function | Test | Kind | Status |
|---|---|---|---|
| Window ▸ Aquarium (⌥⌘1) | `MacMenuCommandUITests.testBugMainWindowUnreachableOnceClosed` | UI | built |
| Aquarium ▸ About (version, build, engine) | `MacMenuCommandUITests.testAboutPanelShowsVersionAndEngine`, `MacAppShellTests.testAboutPanelHasAVersionAndAnEngine` | UI, unit | built |
| No File ▸ New Window | `MacMenuCommandUITests.testNoNewWindowCommand` | UI | built |
| View ▸ Bigger / Smaller / Actual Size (⌘= ⌘- ⌘0), enable states | `MacViewOptionsTests.*` (10), `MacMenuCommandUITests.testBugCommandEqualsZoomedNothing`, `testActualSizeIsDisabledAtActualSize` | unit, UI | built |
| View ▸ sections on ⌘1…⌘9 in sidebar order | `MacSidebarTests.testBugCmdNumberOutOfSidebarOrder`, `testSidebarOrderLeavesSearchOut`, `MacMenuCommandUITests.testCommandNumbersFollowTheSidebar`, `testViewMenuListsTheSections` | unit, UI | built |
| View ▸ Refresh (⌘R), only the page in front | `MacNavigationTests.testCommandRequestsAreCounters`, `MacMenuCommandUITests.testRefreshKeepsThePage`, `MacNavigationTests.testBugAlertsToastsRefreshHitEveryWindow` | unit, UI | built |
| Go ▸ Back (⌘[), enable state, title windows | `MacNavigationTests.testBackIsDisabledAtTheTopOfASection`, `testBackPopsOnePageOfTheShownSection`, `testBackInATitleWindowGoesBackThroughItsOwnPages`, `MacMenuCommandUITests.testGoBackAndHome`, `testBackIsDisabledAtTheTop`, `MacWindowsUITests.testTitleWindowHasItsOwnPages` | unit, UI | built |
| Go ▸ Home (⇧⌘H) / show at top | `MacNavigationTests.testBugGoHomeDoesNothingFromPushedPage`, `testShowAtTopKeepsOtherSectionsPages`, `MacMenuCommandUITests.testGoBackAndHome` | unit, UI | built |
| Go ▸ Search (⌘F) | `MacMenuCommandUITests.testCommandFPutsTheCursorInSearch` | UI | built |
| Go ▸ Live TV (⇧⌘L), Downloads (⌥⌘J) | `MacMenuCommandUITests.testGoDownloadsAndLiveTV` | UI | built |
| Go ▸ Show Downloads in Finder (⌥⌘R) | `MacMenuCommandUITests.testShowDownloadsInFinderIsThere` (enabled only); MANUAL K4 | UI, manual | built |
| Go ▸ Earlier / Later / Now gate | `MacNavigationTests.testGuideCommandsOnlyWhileTheGuideIsInFront`, `testBugGuideKeysYieldToThePlayerWindow`, `testGuideCommandsOffWithAPageOverTheGuide`, `testGuideCommandsOffWithATitleWindowInFront`, `testGuideCommandsOffElsewhere`, `MacMenuCommandUITests.testGuideCommandsOnlyLiveOnTheGuide` | unit, UI | built |
| Go ▸ Earlier / Later / Now actions (⌘← ⌘→ ⌘T) | `MacSectionsUITests.testGuideEarlierLaterNow` | UI | built |
| Item ▸ Play (⌘↩) | `MacMenuCommandUITests.testCommandReturnPlays`, `testBugItemMenuGreyedForGridSelection` | UI | built |
| Item ▸ Favorites (⌘D), Watched (⇧⌘U), titles | `MacMenuCommandUITests.testItemMenuOnATitlePage`, `testItemMenuDisabledWithNoTitleInFront`, `testBugItemMenuActsOnCoveredLibrarySelection`; `MacNavigationTests.testItemMenuActionsCallThrough` | UI, unit | built |
| Item ▸ Open in New Window (⌥⌘O) | `MacMenuCommandUITests.testOptionCommandOOpensTheTitleInANewWindow`, `MacWindowsUITests.testSameTitleTwiceIsOneWindow` | UI | built |
| `FocusSearchOnRequest`, `onMacRefresh` | through the ⌘F and ⌘R UI tests above | UI | built |
| `MacMainWindow` (find, show, open) | `MacNavigationTests.testMainWindowIsFoundByItsSceneId`, ⌥⌘1 UI test | unit, UI | built |

## Player — `PlayerWindow.swift`, `PlayerMacMenus.swift`

| Function | Test | Kind | Status |
|---|---|---|---|
| Player window: own window, ≥ 480×270, titled | `MacPlayerUITests.testBugPlayerWasTinySheet` | UI | built |
| Window takes the picture's shape | `MacPlayerTests.testWindowTakesThePicturesShapeKeepingWidthAndTop`, `testWindowShrinksBothWaysRatherThanRunOffTheScreen`, `testWindowAlreadyTheRightShapeIsLeftAlone`, `testNoPictureSizeNoChange` | unit | built |
| Closing the window stops; Escape stops / leaves full screen | `MacPlayerUITests.testClosingThePlayerWindowStopsPlayback`, `testEscapeStopsWhenNotFullScreen`, `testBugFullScreenIsThePlayersAndEscapeLeavesIt`; MANUAL A4 | UI, manual | pass (Escape fixed ee0982e; close-window: see Run state) |
| Restored window with nothing to play dismisses itself | `MacWindowsUITests.testBugRestoredPlayerWindowBlack` | UI | pass (fixed 406fd71) |
| No Window ▸ Player | `MacPlayerUITests.testBugWindowMenuPlayerOpensBlackWindow` | UI | built |
| Stream Info inspector (⌘I) | `MacPlayerUITests.testSpeedFromTheMenuAndBrackets`, `MacPlayerTests.testStreamInfoAndPanelRequests` | UI, unit | built |
| Playback menu items exist / disabled when idle | `MacPlayerUITests.testPlaybackMenuHasEverything`, `testPlaybackMenuIsDisabledWithNothingPlaying` | UI | built |
| Key gating (bare keys only in the player window, yielded to inspector/error card) | `MacPlayerTests.testKeysAreBoundWhileThePlayerWindowIsInFront`, `testBugSpaceBarPausesWhileTypingSearch`, `testBugCmdArrowSkipsInTextFieldsAndGuide`, `testBugBareKeysStealInspectorAndErrorCard`; `MacPlayerUITests.testBugTypingASpaceInSearchDoesNotPause` | unit, UI | built |
| Space, ⌘← ⌘→ (Go ▸ Earlier / Later give the keys up away from the guide) | `MacPlayerUITests.testSpaceAndArrowKeysWhileThePlayerIsInFront`, `MacSectionsUITests.testGuideEarlierLaterNow` | UI | pass (⌘→ fixed 949c8fe) |
| [ / ] speed, Speed menu | `MacPlayerTests.testSpeedSteps`, `testSpeedNames`, `MacPlayerUITests.testSpeedFromTheMenuAndBrackets` | unit, UI | built |
| ↑ / ↓ volume, M mute | `MacPlayerTests.testVolumeStepsFivePercentAndClamps`, `testVolumeUpUnmutesButDownDoesNot`, `testVolumeIsRemembered`, `MacPlayerUITests.testMuteAndVolumeKeys` | unit, UI | built |
| C toggle subtitles | `MacPlayerTests.testCTurnsOnTheTrackThatWasOnLast` … `testCKeyTogglesOffAndBackToTheSameTrack` (6), `MacPlayerUITests.testCTogglesSubtitles` | unit, UI | built |
| Audio / Subtitles rows ("(Forced)", "(reopens the stream)") | `MacPlayerTests.testForcedTrackSaysSo`, `testTrackNeedingANewStreamSaysSoWhenStreaming`, `testPlainTrack`, `testTrackIdentifiersUseTheServerIndex` | unit | built |
| Audio track choice reaches the server | `MacPlayerUITests.testBugAudioTrackChoiceReachesTheServer`, `MacClientTests.testBugTrackChoiceIgnoredWithoutMediaSourceId`, `testEmptyMediaSourceIdIsNotSent` | UI, unit | built |
| Forced subtitles | `MacPlayerUITests.testForcedSubtitlesAreMarkedAndShown`, `MacPlaybackCoreTests.testBugHLSSubtitlesTenSecondsLate`, `testHEVCOrNoSubtitlesKeepFMP4` | UI, unit | built |
| Quality menu, change while paused | `MacPlayerUITests.testQualityMenuListsAutoAndTheRungs`, `testBugQualityChangeWhilePausedStaysPaused` | UI | built |
| Chapters (timeline ticks, scrub preview name) | `MacPlayerTests.testChapterNameAtATime` | unit | built |
| Skip Intro / Credits (S), segments query | `MacPlayerUITests.testSkipIntroWithS`, `testBugSkipCreditsShows`, `MacClientTests.testBugSkipCreditsNeverShows`, `testSegmentsNotAvailableIsNoSegments` | UI, unit | built |
| Up Next card and menu, Stop after this | `MacPlayerUITests.testUpNextCardPlaysTheNextEpisode`, `testUpNextMenuListsTheNextEpisodes`, `testBugStopAfterNotOfferedOnAFilm`, `MacPlayerTests.testBugStopAfterOfferedOnFilm`, `testStopAfterWordingFollowsTheItem`, `testDisplayTitleForAnEpisodeNamesTheShow` | UI, unit | built |
| Sleep timer | `MacPlayerUITests.testSleepTimerSetAndCancel` | UI | built |
| Fill Screen toggle | `MacPlaybackCoreTests.testFillScreenPreferenceRoundTrips`; menu item in `testPlaybackMenuHasEverything` | unit, UI | built |
| Full screen (F) on the player window only; not while PiP has it | `MacPlayerTests.testBugFullScreenMenuFullScreensMainWindow`, `testBugHiddenForPictureInPictureIsDetected`, `testNoWindowIsNotHiddenForPictureInPicture`, `MacPlayerUITests.testBugFullScreenIsThePlayersAndEscapeLeavesIt` (now checks the window really grows: it passed with no full screen before); MANUAL D6 | unit, UI, manual | pass (fixed cdca18b) |
| Picture in Picture (P), mpv hand-over | `MacPlayerTests.testPictureInPictureMenuIsOffWithNoController`; MANUAL N3 | unit, manual | built |
| SharePlay start / leave | MANUAL N5 | manual | manual |
| SharePlay "Start from whose progress?" in the player window, as a sheet (a Mac alert shows three buttons and dropped Keep Watching Here, found 2026-11-19); the pick moves playback (made-up friends via AQUARIUM_TEST_SHAREPLAY_PROGRESS) | MacSharePlayUITests.testWhoseProgressIsAskedAndThePickIsWherePlayGoes | UI | pass 2026-11-19 |
| Show Panel (⌘K) | `MacPlayerUITests.testShowPanelOpensInfo` | UI | built |
| Stop (⌘.) from any window | `MacPlayerUITests.testStopFromAnyWindow` | UI | built |
| Picture's right-click menu | `MacPlayerUITests.testRightClickOnThePicture` | UI | built |
| Controls follow the pointer, hide after the setting | `MacPlayerTests.testPointerLeavingHidesTheControls`, `testControlsHideAfterTheSettingsInterval`, `testMacHidesControlsSoonerThanATouchScreen`, `MacPlayerUITests.testControlsAppearUnderThePointerAndHideAfterwards`, `testBugControlsTakeAClickAsTheyAppear` | unit, UI | built |
| Transport buttons reach the server | `MacPlayerUITests.testPlayPauseButtonReachesTheServer`, `testSkipButtonsMoveTenSeconds` | UI | built |
| Resume reported / honoured | `MacPlayerUITests.testResumePositionReportedOnStop`, `testResumeStartsWhereTheServerSays` | UI | built |
| Engine on the Mac (policy, mpv when asked, DTS → mpv) | `MacPlaybackCoreTests` (8 engine tests), `MacPlayerUITests.testPlaybackRunsOnMPVWhenAsked`, `testDTSFilmPlaysThroughMPVAutomatically` | unit, UI | built |
| mpv TLS (tls-verify, bundled roots) | `MacPlaybackCoreTests.testBugMpvAcceptsAnyCertificate`, `testTLSRootsShipInTheMacApp`, `testMPVOptionsTheMacKeepsShared`; MANUAL T1–T2 | unit, manual | built |
| Sidebar Now Playing strip | `MacPlayerUITests.testMainWindowStaysUsableWhilePlaying`, `testSidebarNowPlayingPauses` | UI | built |
| HDR, display moves, hwdec, power profile | MANUAL D1–D7, S3 | manual | manual |
| Media keys, Now Playing | MANUAL N1–N2 | manual | manual |

## Windows — `ItemWindow.swift`

| Function | Test | Kind | Status |
|---|---|---|---|
| `ItemWindowNavigator` push / back / navigate / binding | `MacNavigationTests.testNavigator…` (5) | unit | built |
| `isWorkingWindow`, `keyNavigator` routing of push / navigate | `MacNavigationTests.testBugAlertsToastsRefreshHitEveryWindow`, `testPushWithATitleWindowInFrontOpensInThatWindow`, `testNavigateWithATitleWindowInFrontUsesThatWindow` | unit | built |
| `Route` coding for window restoration | `MacNavigationTests.testRoutesSurviveEncodingForWindowRestoration` | unit | built |
| Title window, library window, one per title | `MacWindowsUITests.testTitleWindowHasItsOwnPages`, `testSameTitleTwiceIsOneWindow`, `testLibraryWindowFromTheSidebar` | UI | built |
| Window closes when the account changes | `MacWindowsUITests.testTitleWindowClosesOnSignOut` | UI | built |
| Alerts on the window being worked in | `MacWindowsUITests.testBugAlertShowsOnTheWindowBeingWorkedIn` | UI | built |
| Main window minimum size; pages don't grow it | `MacWindowsUITests.testBugMainWindowNoMinimumSize`, `testBugPushedPageGrowsMainWindow` | UI | built |

## Sidebar — `MacSidebar.swift`

| Function | Test | Kind | Status |
|---|---|---|---|
| Groups (top / Libraries / Live / You) | `MacSidebarTests.testGroups…` (4), `MacDeepWaterTests.testSidebarGroupHeadingsAreDeepWaters`, `MacBrowseUITests.testSidebarHasHomeLibrariesLiveTVFavoritesDownloads` | unit, UI | built |
| Re-click goes to the top; the selecting click doesn't | `MacSidebarTests.testClickThatMovedTheSelectionIsNotAReclick`, `testBugSidebarSlowClickResetsSection`, `testTapLongAfterAnArrowKeyMoveIsAReclick`, `testSecondTapOnSelectedRowIsAReclick`, `testBugTapBeforeSelectionStillPairs`, `testSelectionMovedElsewhereDoesNotSwallowAReclick`, `testStaleTapDoesNotPairWithALaterArrowKeyMove` (`SidebarClickRule`), `MacBrowseUITests.testReclickingTheSelectedRowGoesToTheTop` (strict); MANUAL A3 | unit, UI, manual | pass (fixed c528230) |
| Row menu: Open in New Window, Refresh | `MacSidebarTests.testOpenInNewWindowOnlyForLibrariesFavoritesCollections`, `MacBrowseUITests.testSidebarRowMenuRefreshAndOpenInNewWindow` | unit, UI | built |
| Downloads badge | `MacSidebarTests.testDownloadsBadgeIsTheTransferCount` | unit | built |
| Footer account menu: add, settings, sign out (confirm / cancel) | `MacSignInUITests.testAccountMenuOffersAddSettingsAndSignOut` (chooses by type-select: the items aren't in XCUITest's tree), `testSignOutAsksFirstAndCancelKeepsYouIn`, `testSignOutReturnsToSignIn`, `testAddAccountOpensTheSignInSheet`; MANUAL A1 | UI, manual | pass |
| Switch account | not automated: the suite has one Mac account signed in; needs a second saved account (`suite-spare1`) — see "No automated test" | — | — |
| Mac section symbols, no Settings / Search / Music rows | `MacSidebarTests.testMacSymbols`, `testMacSidebarHasNoSettingsOrSearchRow`, `MacSectionsUITests.testNoMusicSectionOnTheMac` | unit, UI | built |

## Mac views — `*+Mac.swift`, `MacStyles.swift`, `MacViewOptions.swift`

| Function | Test | Kind | Status |
|---|---|---|---|
| `HeroCarousel` height, turning, chevrons, dots, arrows | `MacViewLogicTests.testHeroIsA2point4To1BandHeldBetween280And520`, `testHeroTurnsWrapAtBothEnds`, `MacBrowseUITests.testMediaBarPagesWithChevronsAndArrowKeys`, `testMediaBarDotsJumpToAPage` | unit, UI | built |
| `MacHeroButtonStyle` (white Play, glass Details) | `MacDeepWaterUITests.testBugHeroPlayVanishesWhenWindowNotKey`; MANUAL D9–D10 | UI, manual | built |
| `ShelfLayout.fit`, shelf paging | `MacViewLogicTests.testShelf…` (3) | unit | built |
| `MacHoverFill`, `PosterHover`, `macMenuAsLabel`, `macSelectable` | MANUAL D8 (hover is visual only) | manual | manual |
| `macOpensOnReturn` | `MacBrowseUITests.testBugReturnOnEpisodesPlaysTheEarliest` (Return on rows) | UI | built |
| `macWindowSizedPage` | `MacWindowsUITests.testBugPushedPageGrowsMainWindow` | UI | built |
| `spaceAlert` (not enough disk) | MANUAL "Things the UI runner can't do" | manual | manual |
| `MacEpisodeList` play choice, height, anchors, selection menu | `MacViewLogicTests.testBugReturnOnEpisodesPlaysRandomOne`, `testBugEpisodeListClipsLastRow`, `testEpisodeRowAnchors`, `MacBrowseUITests.testBugEpisodeListShowsTheLastEpisode`, `testBugReturnOnEpisodesPlaysTheEarliest` | unit, UI | built |
| `LibraryFilters` per library | `MacViewLogicTests.testBugLibraryFiltersForgottenBetweenLibraries`, `testDefaultFiltersLeaveNothingBehind`, `testCorruptFiltersLoadAsDefaults`, `MacBrowseUITests.testBugFiltersRememberedPerLibrary` | unit, UI | built |
| `LibrarySelectionMenu` offers and actions | `MacViewLogicTests.testSelectionMenuOffersOnlyWhatChangesSomething`, `MacBrowseUITests.testLibrarySelectionMenuMarksWatched` | unit, UI | built |
| `LibraryNoResults` | `MacViewLogicTests.testBugEmptyLibraryBlamesFilters`, `testNoResultsWording`, `MacBrowseUITests.testLibrarySearchFieldNarrowsAndNoResultsClears` | unit, UI | built |
| Library search request (`/Items?userId=`) | `MacClientTests.testBugMacLibrarySearchOnOldUsersRoute` | unit | built |
| Library table layout, sort, filters, paging tiebreak | `MacBrowseUITests.testLibraryTableLayout`, `testLibraryGridSortAndFilters`, `MacViewLogicTests.testBugLibraryPagingStopsShort` | UI, unit | built |
| `MacViewOptions` | `MacViewOptionsTests.*` | unit | built |
| Guide: type-select, day label, selection, double-click interval, ruler keys | `MacViewLogicTests.testTypeSelect…` (3), `testGuideDayLabel`, `testGuideSelectionIsAValue`, `testDoubleClickIntervalIsTheSystems`, `testGuidePreferenceKeysTakeTheLatest` | unit | built |
| Guide: ruler position, popover, context menu, play a channel | `MacSectionsUITests.testGuideShowsTheQAChannels`, `testBugGuideRulerRuns90MinAhead`, `testProgrammePopoverAndContextMenu`, `testPlayAChannel`, `testTypeToSelectAChannel` | UI | built |
| Guide ▸ Copy Title (`GuidePasteboard`) | MANUAL (clipboard is shared with the person at the Mac) | manual | manual |
| Downloads page (`MacDownloadsView`, rows, tiles, menus, delete confirm) | `MacSectionsUITests.testDownloadsPageWhenEmpty`, `testDownloadPlayAndDelete`, `testDownloadsManageMenu` | UI | built |
| Downloads: Show in Finder (`DownloadManager.reveal`, `revealInFinder`) | MANUAL K4 | manual | manual |
| Download folders on the Mac, test-mode isolation | `MacPlaybackCoreTests.testDownloadsLiveInTestModesOwnFolder`, `testDownloadFolderPerItemIsDirectlyUnderTheRoot`, `testRootIsMadeWhenAskedFor` | unit | built |

## Shell, Home, browsing (shared views as the Mac draws them)

| Function | Test | Kind | Status |
|---|---|---|---|
| Sign-in (password, wrong password, disabled account), Quick Connect, relaunch | `MacSignInUITests.*`; MANUAL A5 (VoiceOver on the Quick Connect code) | UI, manual | pass (Quick Connect crash fixed cb59aa6) |
| Authorization header ASCII on a Mac | `MacClientTests.testAuthorizationHeaderIsASCIIOnAMac` | unit | built |
| Avatar URL (`/UserImage`) | `MacClientTests.testBugAvatarOnOldUsersRoute` | unit | built |
| Home: Continue Watching, Next Up, toolbar, See all | `MacBrowseUITests.testHomeShowsContinueWatchingAndNextUp`, `testToolbarSearchRefreshAndPlayFeatured`, `testShelfHeadingOpensSeeAll` | UI | built |
| Dock menu items from Home's rows | `MacAppShellTests.testDockMenuItemsDedupeAndStopAtFive`, `testDockMenuEpisodeTitleIsTheShowAndSubtitleTheEpisode`, `testClearDockMenu` | unit | built |
| Search (sidebar field, results, recents, Unicode) | `MacBrowseUITests.testSidebarSearchFindsTheFXLongTitles`, `testSearchRemembersRecentTerms`, `testUnicodeTitleOpens`, `MacNavigationTests.testSidebarFieldReturnShowsSearch`, `testSearchStaysTheSelectionOnAMac`; MANUAL A2 | UI, unit, manual | pass (Return fixed ea316c7) |
| Favorites | `MacBrowseUITests.testFavoritesListsTheBaselineFavourites` | UI | built |
| Title page (actions, favourite, watched), series, person | `MacBrowseUITests.testFilmPageHasPlayFavoriteWatchedDownload`, `testFavoriteButtonReachesTheServer`, `testBugFavoriteThenWatchedLosesOne`, `testSeriesPageListsSeasonsAndEpisodes`, `testPersonPageFromCast`, `MacClientTests.testFavoriteAndWatchedRequests` | UI, unit | built |
| Show's Play picks the episode in progress | `MacClientTests.testBugShowPlayOffersS1E1`, `testShowWithNothingInProgressFallsBackToNextUp` | unit | built |
| Context menus on posters | `MacBrowseUITests.testPosterContextMenuMarksWatchedAndFavorite` | UI | built |
| Toasts → alerts / silence on a Mac | `MacAppShellTests.testErrorToastBecomesAnAlert`, `testAlertTitles`, `testFooterMessagesAreNotSaid`, `testSignOutFailureIsStillSaid`, `testInfoToastStaysAToast`, `testPresentAlertOnAMacIsAnAlert`, `testASecondAlertReplacesTheFirst` | unit | built |
| Direct play / Dolby Vision on the Mac | `MacPlaybackCoreTests.testMP4PlaysAsAFileAndMKVDoesNot`, `testBugDolbyVisionGreenPurple` | unit | built |
| Music | `MacSectionsUITests.testNoMusicSectionOnTheMac` (the Mac has none yet) | UI | built |
| Live TV row / guide | see Guide above | UI | built |

## Settings — `MacSettingsWindow`

| Function | Test | Kind | Status |
|---|---|---|---|
| ⌘, opens; every pane | `MacSectionsUITests.testSettingsWindowOpensWithCommandComma`, `testEverySettingsPaneOpens` | UI | built |
| Video ▸ engine → About shows it | `MacSectionsUITests.testVideoSettingsChangeTheEngine`, `MacPlaybackCoreTests.testEngineDescriptionFollowsTheSetting` | UI, unit | built |
| Account ▸ Sign Out asks; ▸ + opens the sheet in front | `MacSectionsUITests.testSettingsSignOutAsks`, `testBugAddAccountSheetOpensBehindSettings` | UI | built |
| Video ▸ no Night mode row (neither engine on a Mac can compress the sound) | `MacSectionsUITests.testBugNightModeToggleDoesNothing` | UI | pass (fixed c6eae9a) |
| Theme | `MacDeepWaterUITests.testScreensInLightAndDark` | UI | built |
| Preferences kept apart in test mode | `MacViewOptionsTests.testWritesGoToTheTestSuiteNotTheRealDefaults`, `MacPlaybackCoreTests.testTestModeIsOnAndStateIsApart` | unit | built |

## Requests through Seerr — `Views/Seerr/`

Against the stand-in Seerr server (TESTING.md). Run 2026-11-16 (the class alone; the Mac screen suite as a whole is still switched off): 3 pass.

| Function | Test | Kind | Status |
|---|---|---|---|
| Sidebar gains Requests (under You); no window of its own | MacRequestsUITests.testTheSidebarGainsRequests, MacSidebarTests.testRequestsSitsWithWhatIsYours | UI, unit | pass |
| Sidebar search offers a title, its page requests it | MacRequestsUITests.testSearchOffersARequestAndThePageMakesIt | UI | pass |
| Settings → Account: connect by address (http warning, no password typed) | MacRequestsUITests.testConnectingInSettings | UI | pass |
| The Seerr page: each browse row a placeholder until it lands, the foot credits Seerr and TMDB | MacRequestsUITests.testRowsShowTheyAreLoadingAndThePageCreditsSeerrAndTMDB | UI | pass 2026-11-19 |

## Deep Water

| Function | Test | Kind | Status |
|---|---|---|---|
| Tokens (radius 14, Mac metrics, accent/link) | `MacDeepWaterTests.*` (5) | unit | built |
| Hero bleed, white Play, title page two columns, pinned library header, chips | `MacDeepWaterUITests.*` (6) | UI | built |
| How it looks, light and dark | screenshots from `MacDeepWaterUITests.testScreensInLightAndDark`; MANUAL D8 | UI, manual | built |

## No automated test, and why

- **Switch account** from the sidebar menu: needs two accounts saved in the test session; the launcher signs in one. Could be added with a second `launch(reset:false)` signing in `suite-spare1` — left out because the spare accounts are shared with the iPhone and iPad agents.
- **Dock click / Dock menu actions, Finder reveal, clipboard, NSAlert fallback**: outside the app window XCUITest drives, or touch state shared with the person at the Mac. MANUAL K1–K5.
- **PiP, AirPlay, SharePlay, Handoff, Spotlight, media keys, HDR, sleep/wake, power source**: system UI or hardware. MANUAL.
- **Hover fills, the selection ring**: visual only. MANUAL D8.
- **Not enough disk space alert**: needs a nearly full volume. MANUAL.
- **Offline shell on the Mac (`[.downloads]` only)**: needs the server unreachable mid-run; the Mac suite shares the QA server with the other agents, and stopping it is not allowed. Could be done with a private proxy (memory note qa-offline-via-private-proxy.md) in a later pass.
- **mpv dropout counted as the end of the title** (open bug, MANUAL T4): needs a network cut during playback.

## Run state (2026-11-13, `claude/fix-mac`)

- **Unit** (`TestPlans/Unit`, Mac): 285 tests, all pass (166 Mac, 3 of them new for
  `SidebarClickRule`; the rest shared).
- **UI** (`TestPlans/Mac`, `-collect-test-diagnostics never`, `TEST_RUNNER_AQUARIUM_QA_DIR`
  set), 122 tests, `suite-reset.py suite-mac` before each run:
  - first run after the fixes: 118 pass, 1 skip, 3 failures (Add Account under AutoFill; close-window
    stop and quality-while-paused watching a session an earlier test left), fixed in fa17510,
    af73c54 and c97090a;
  - run 2 (automation mode without authentication): 120 pass, 1 skip, 1 failure — the downloaded
    film's tile "not hittable" to a right-click, fixed in 815fe75;
  - run 3: **121 pass, 0 failures, 1 skip**.
  The skip is `MacBrowseUITests.testShelfHeadingOpensSeeAll`: the shelf it looks at has no See all
  with the baseline fixtures.
- No expected failures left: the four bugs (restored black player window, Escape, sidebar
  re-click, Night mode row) are fixed and their tests strict.

### What XCUITest can't do on this Mac (found 2026-11-13)

- `press(forDuration:)` reaches nothing in the app: tests click with
  `click(forDuration:thenDragTo:)` or `click()`.
- Menus popped up from a SwiftUI `Menu` in a window (Download, Quality on a title page, the
  account row) are not in the element tree; context menus and the menu bar are.
  `chooseInOpenMenu` picks from them by type-select; MANUAL lists looking at them.
- The sidebar search field's recent-terms list is a pop-up outside the tree (↓ Return picks
  from it).
- Mac episode rows are never "hittable" and their own `click()` tries to scroll the list
  rather than the page: `scrollIntoView` + `clickCentre`.
- Alert buttons lose their SwiftUI identifiers ("action-button-1"): by title.
- `app.screenshot()` fails with the window on a second display; the base class attaches every
  display's screenshot on a Mac.
- The QA server keeps sessions earlier tests left "playing", with their position and activity
  moving on: `macSessions` leaves out the sessions there before the launch.
- Menu-bar items and pop-up/context menu items do **not** carry their `TestID` identifiers on a Mac
  (they read `menuAction:`); tests fall back to titles.
- The UI runner is sandboxed: `QA.folder` resolves inside its container unless
  `AQUARIUM_QA_DIR` is passed (`TEST_RUNNER_AQUARIUM_QA_DIR=…`).
- Shared `JellyfinAPI.sessions()` sees nothing (`ControllableByUserId`); the Mac tests use
  `macSessions()` in `MacUISupport.swift`.
