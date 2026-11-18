# Apple TV: what is tested, and how

Every Apple TV screen, control and tvOS-only code path, with the test that
covers it. Kinds: **unit** (`AquariumTests/TV/`, run by `TestPlans/Unit`),
**UI** (`AquariumUITests/TV/`, `Tools/run-tests.sh tv`, against the QA server
as `suite-tv`), **manual** (`MANUAL.md`, hardware only).

Status: **pass**, **xfail** (kept with `XCTExpectFailure("bug: …")`, a real
bug), **fail** (fails, not yet understood), **manual**, **untested** (with why).
Status is from the run of 2026-11-13 (see the end of this file).

Regression tests are named after their bug and cite the source in a comment.

## Shell and focus

| Function | Test | Kind | Status |
|---|---|---|---|
| Tab strip: Home, Library, Search, Live TV, Settings, in order; no Music, Books, Downloads, More | `TVShellFocusTests.testTheStripHasFiveTabsInOrder`, `TVShellTests.testStripIsHomeLibrariesSearchLiveTVSettings` | UI, unit | pass |
| Every tab can be entered from the strip and left back to it (focus never lost or trapped) | `TVShellFocusTests.testEveryTabCanBeEnteredAndLeft` | UI | pass |
| Home: Down from the strip reaches the media bar's Play (f3ea7ed; master-fix-list "Down … lands on Refresh") | `TVShellFocusTests.testDownFromTheStripOnHomeReachesThePlayButton` | UI | pass |
| Library opens as its own screen; Menu goes back, not out (AppModel.push) | `TVShellFocusTests.testOpeningALibraryKeepsFocusAndMenuGoesBackNotOut`, `TVShellTests.testALibraryOpensTheSameWay_regressionBackQuitTheApp` | UI, unit | pass |
| Title screen over everything (`detailRoot`), its own stack, Menu pops it | `TVShellTests.testATitleOpensAsItsOwnScreenNotUnderTheStrip`, `testMenuPoppingThePathTrimsTheRoutes`, `testCloseDetailEmptiesEverything`; `TVShellFocusTests.testMenuFromATitlePageReturnsToWhereItCameFrom` | unit, UI | pass |
| Never an offline shell on a TV | `TVShellTests.testNeverAnOfflineShell` | unit | pass |
| Deep links `aquarium://item|play/<id>` (the Top Shelf's way in) | every `launchDetail` / `launchPlaying` test (through `AppModel.handle`) | UI | pass (exercised by 40+ UI tests) |

## Sign-in

| Function | Test | Kind | Status |
|---|---|---|---|
| Server address, connect, password sign-in | `TVSignInTests.testPasswordSignInLandsOnHome` | UI | pass |
| Wrong password message, stays on screen | `TVSignInTests.testAWrongPasswordSaysSoAndStaysPut` | UI | xfail |
| Disabled account refused in plain words | `TVSignInTests.testADisabledAccountIsRefusedInPlainWords` | UI | xfail |
| Public users offered; passwordless user signs straight in, sees only its library, no Live TV | `TVSignInTests.testTheServersPublicUsersAreOffered`, `testAPasswordlessUserSignsStraightInAndSeesOnlyTheirLibrary` | UI | pass |
| Quick Connect: code shown, approved from another device, signs in | `TVSignInTests.testQuickConnectSignsInOnceApprovedElsewhere` | UI | pass |
| "Who's watching?" household of the Apple TV's users (`Keychain.Household`) | `TVDeviceTests.testTheHouseholdOffersOnlyOtherUsersAccounts`, `testTestModeKeepsTheHouseholdOutOfTheSharedKeychain`; second tvOS user in `MANUAL.md` §5 | unit, manual | pass |
| Device name sent to the server | `TVDeviceTests.testTheServerSeesAnAppleTV` | unit | pass |
| Sign out (dialog, back to sign-in) | `TVSettingsTests.testSignOutReturnsToTheSignInScreen`, `testSignOutDialogNamesTheAccount` | UI | xfail (1), pass (1) |

## Home

| Function | Test | Kind | Status |
|---|---|---|---|
| Rows: Continue Watching, Next Up, My Media, Latest per library, no music rows | `TVHomeTests.testRowsMatchTheBaseline` | UI | pass |
| Media bar: Play and Details on every page | `TVHomeTests.testTheMediaBarHasPlayAndDetailsForTheTitleShown` | UI | pass |
| Media bar Details opens the title; Play plays | `TVHomeTests.testDetailsOpensTheTitleOnTheBar`, `testPlayOnTheBarPlaysThatTitle` | UI | pass |
| Continue Watching resumes at the server's position | `TVHomeTests.testContinueWatchingResumesWhereItStopped` | UI | pass |
| Card press-and-hold menu; Mark Watched reaches the server | `TVHomeTests.testHoldingACardOpensItsMenu`, `testMarkWatchedFromTheCardMenuReachesTheServer` | UI | pass |
| Next Up card opens the season on its episode | `TVHomeTests.testNextUpCardOpensTheSeasonOnItsEpisode`, `TVShellTests.testNextUpOpensTheShowWithTheSeasonOnTopAndTheEpisodePicked` | UI, unit | pass |
| Refresh | `TVHomeTests.testRefreshKeepsFocusAndRows` | UI | pass |
| Hide Continue Watching | `TVSettingsTests.testHideContinueWatchingTakesTheRowOffHome` | UI | pass |

## Libraries, collections, search

| Function | Test | Kind | Status |
|---|---|---|---|
| Library tab lists the video libraries, no Music or Books | `TVBrowseTests.testLibraryTabListsTheVideoLibrariesOnly` | UI | pass |
| A library's grid opens a title; Menu returns focus to the card | `TVBrowseTests.testAFilmLibraryGridOpensATitle` | UI | pass |
| The grid loads every page (17206fe, stalled at 60) | `TVBrowseTests.testTheGridKeepsPagingPastTheFirstPage` | UI | pass |
| Collections | `TVBrowseTests.testCollectionsOpenAndListTheirTitles` | UI | xfail |
| Photo folders (master-fix-list "Folder tiles open an empty page") | `TVBrowseTests.testFolderOfPhotosOpensItsContents` | UI | xfail |
| Search: field, keyboard, results, Unicode, nothing found | `TVBrowseTests.testSearchFindsTheLongFixtures`, `testSearchFindsAUnicodeTitle`, `testSearchWithNoMatchSaysSo` | UI | pass |
| Search offers no music on a TV | `TVBrowseTests.testSearchOffersNoMusicOnTheTV` | UI | pass |

## Requests through Seerr (TVRequestsTests)

Against the stand-in Seerr server (TESTING.md). Run 2026-11-16: 4 pass.

| Function | Test | Kind | Status |
|---|---|---|---|
| No Requests tab without Seerr | TVRequestsTests.testNoRequestsTabWithoutSeerr | UI | pass |
| Requests tab: a request's row reachable with the remote, opens its page with focus | TVRequestsTests.testTheRequestsTabListsRequestsAndThingsToAskFor | UI | pass |
| A film asked for with the remote from a browse row | TVRequestsTests.testAFilmIsAskedForWithTheRemote | UI | pass |
| Search offers what the library lacks, reachable with the remote | TVRequestsTests.testSearchOffersWhatTheLibraryLacks | UI | pass |
| Connecting in Settings (the full-screen form and the on-screen keyboard) | — | manual | MANUAL.md |

Seen, not fixed: after Request is pressed the button goes and focus moves up to
the tab strip rather than to Cancel Request.

## Title pages

| Function | Test | Kind | Status |
|---|---|---|---|
| Film page: title, overview, facts, Play first, cast reachable and back up (faa8a89) | `TVBrowseTests.testAFilmPageHasEverythingAndFocusStartsOnPlay` | UI | pass |
| Quality dialog: rungs, Cancel, plays at the rung | `TVBrowseTests.testQualityDialogListsTheRungsAndCancels`, `testQualityDialogPlaysAtTheChosenRung` | UI | pass |
| Favourite and Watched reach the server | `TVBrowseTests.testFavoriteAndWatchedReachTheServer` | UI | pass |
| Versions (master-fix-list "Multiple versions not selectable") | `TVBrowseTests.testVersionsCanBeChosen` | UI | xfail |
| Local trailer plays | `TVBrowseTests.testTrailerButtonOnAFilmWithLocalTrailersPlaysOne` | UI | pass |
| YouTube scheme declared; YouTube-only trailer hidden without the app (master-fix-list "Trailer button … tvOS cannot open") | `TVShellTests.testTheYouTubeSchemeIsDeclared`, `testAYouTubeOnlyTrailerIsHiddenWithoutTheYouTubeApp`, `testYouTubeIdsAreReadFromEveryShape`, `testOnlyWebAddressesCountAsRemoteTrailers`, `testALocalTrailerAlwaysShowsTheButton` | unit | xfail (2), pass (3) |
| Show page opens on Play; Down starts the seasons at the first (e565adf, a2aa13b); season page; back | `TVBrowseTests.testAShowOpensOnPlayAndDownStartsTheSeasonsAtTheFirst` | UI | pass |
| Play on a show plays its next episode | `TVBrowseTests.testPlayOnAShowStartsItsNextEpisode` | UI | pass |
| Episode page and breadcrumbs; double episode | `TVBrowseTests.testAnEpisodePage`, `testDoubleEpisodeAndAMissingNumberAreShownAsTheyAre` | UI | pass |
| Person page from the cast | `TVBrowseTests.testCastLeadsToAPersonPage` | UI | xfail |
| Blocked title in plain words (fix-status "Blocked title raw error") | `TVBrowseTests.testABlockedTitleSaysSoInPlainWords` | UI | xfail |

## The player (mpv)

| Function | Test | Kind | Status |
|---|---|---|---|
| Remote press → event mapping (`RemoteInputView`); Menu passed up | `TVRemoteInputTests` (22 tests) | unit | pass |
| Driver decisions: Menu's steps, centre click, Down, swipes, scrub rate and clamp, return point, Sync tab over the clip (`RemoteRules`) | `TVRemoteInputTests` | unit | pass |
| Engine is mpv whatever is asked; DirectPlay of an MP4 | `TVPlayerTests.testTheTVPlaysThroughMPVEvenWhenAppleIsAsked`, `TVQualityEngineTests.testEverythingIsMPVWhateverIsAsked`, `testTheModelChoosesMPVForAFilmEvenWithTheAppleSetting`, `testThisBuildIsTheAppleTVAndHasMPV`, `testFullQualityRenderingOnMains` | UI, unit | pass |
| mpv device profile (direct play everything, rung caps, surround, keyframe segments) | `TVQualityEngineTests.testMPVProfile*` | unit | pass |
| Play/pause button and centre click | `TVPlayerTests.testPlayPauseButtonAndCentreClick` | UI | pass |
| Edge clicks skip, running total | `TVPlayerTests.testEdgeClicksSkipAndCountUp` | UI | pass |
| Paused swipe scrub, click jumps, Menu returns | `TVPlayerTests.testPausedSwipeScrubsAndMenuGoesBackToTheReturnPoint` | UI | pass |
| A swipe while playing moves nothing (17206fe) | `TVPlayerTests.testASwipeWhilePlayingMovesNothing` | UI | pass |
| Down over a waiting scrub doesn't open the panel (f6b43c9) | `TVPlayerTests.testDownWhileScrubbingDoesNotOpenThePanel` | UI | pass |
| Menu: panel, then bar, then out | `TVPlayerTests.testMenuStepsBackPanelThenBarThenOut` | UI | pass |
| Swipe-down panel: tabs for a film, focus along tabs and into cards, Menu from card to tab | `TVPlayerTests.testSwipeDownOpensInfoWithAFilmsTabs` | UI | pass |
| Swipe up from the tabs closes the panel | `TVPlayerTests.testSwipeUpFromTheTabsPutsThePanelAway` | UI | pass |
| Info tab: title, stream line (engine), chapter | `TVPlayerTests.testInfoNamesTheFileTheChapterAndHDRRange` | UI | pass |
| Audio tracks: every one listed, choosing one reaches the server (jellyfin-track-index-needs-source-id.md) | `TVPlayerTests.testEveryAudioTrackIsListedAndOneCanBeChosen` | UI | pass |
| Every subtitle kind listed; none claims a server burn-in on direct play (master-fix-list) | `TVPlayerTests.testEverySubtitleKindIsListedAndNoneClaimsTheServerDrawsIt` | UI | pass |
| PGS stays DirectPlay on mpv; ASS, WebVTT, VobSub each shown | `TVPlayerTests.testAPictureSubtitleStaysDirectPlayOnMPV`, `testAnASSAndAWebVTTAndAVobSubTrackCanEachBeShown` | UI | pass |
| Sidecar subtitles | `TVPlayerTests.testSidecarSubtitlesAreListed` | UI | pass |
| Forced subtitles on by themselves for foreign audio (hls-subtitle-timing.md) | `TVPlayerTests.testForcedSubtitlesComeOnByThemselvesForForeignAudio` | UI | pass |
| Quality tab: no Auto, a rung transcodes, same place kept (f6b43c9) | `TVPlayerTests.testQualityTabHasNoAutoAndPickingARungTranscodes` | UI | pass |
| Quality change while paused stays paused (qa-2026-11-11 B2) | `TVPlayerTests.testAQualityChangeWhilePausedStaysPaused` | UI | pass |
| Reopens don't add plays (master-fix-list "Every stream reopen adds to PlayCount") | `TVPlayerTests.testAReopenDoesNotAddToThePlayCount` | UI | xfail |
| Speed tab | `TVPlayerTests.testSpeedTabChangesTheRate` | UI | pass |
| Picture tab steps and reset | `TVPlayerTests.testPictureTabStepsAndResets` | UI | pass |
| Skip Intro | `TVPlayerTests.testSkipIntroAppearsAndSkipsTheIntro` | UI | pass |
| Skip Credits (qa-2026-11-11 B3) | `TVPlayerTests.testSkipCreditsAppearsAtTheOutro` | UI | pass |
| Up Next card plays the next episode; Menu stops autoplay | `TVPlayerTests.testUpNextCardPlaysTheNextEpisode`, `testMenuOnTheUpNextCardStopsAutoplay` | UI | pass |
| Resume position reported to the server (qa-server-short-title-resume.md) | `TVPlayerTests.testResumeIsReportedToTheServer` | UI | pass |
| Match Frame Rate asks nothing when off | `TVDeviceTests.testFrameRateMatchingAsksNothingWhereTheSettingIsOff`; real switching `MANUAL.md` §2 | unit, manual | pass |
| Screensaver held off while playing (bffc9e7) | `MANUAL.md` §2 | manual | manual |
| Siri Remote touch surface feel, edge vs swipe, 1st/2nd-gen remotes | `MANUAL.md` §1 | manual | manual |
| HDR10, HLG, Dolby Vision, AV1 on hardware | `MANUAL.md` §2 | manual | manual |
| HDMI audio formats, downmix | `MANUAL.md` §3 | manual | manual |

## Auto quality on the TV

| Function | Test | Kind | Status |
|---|---|---|---|
| Auto never steers the TV (5095d5e) | `TVQualityEngineTests.testAutoNeverSteersTheTVsStreams_regression5095d5e` | unit | pass |
| Opening quality is the TV's Settings row whatever Auto says | `TVQualityEngineTests.testOpeningQualityIsTheTVsOwnRowWhateverAutoSays` | unit | pass |
| The quality is this device's, not synced | `TVQualityEngineTests.testTheQualityIsThisDevicesNotSynced` | unit | pass |
| No speed check, no power cap, never on battery | `TVQualityEngineTests.testSpeedCheckNeverRunsOnTheTV`, `testTheTVIsNeverOnABattery` | unit | pass |
| Choosing in the player stores the rung | `TVQualityEngineTests.testChoosingAutoInThePlayerStoresTheChoiceButStillDoesNotSteer` | unit | pass |
| No Auto in Settings or in the panel | `TVSettingsTests.testDefaultQualityListsEveryRungAndKeepsTheChoice`, `TVPlayerTests.testQualityTabHasNoAutoAndPickingARungTranscodes` | UI | pass |

## Sync code and audio delay

| Function | Test | Kind | Status |
|---|---|---|---|
| `SyncCode` payload, round trip, rejects junk; QR drawn as the overlay draws it reads back | `TVSyncCodeTests` | unit | pass |
| Delay rates, NTSC rounding, clips ship in the bundle, per-rate delays kept locally | `TVSyncCodeTests` | unit | pass |
| Flashing-images warning before the clip (17206fe) | `TVSettingsTests.testTheSyncClipWarnsBeforeFlashing` | UI | pass |
| Clip shows a readable code for its rate (24, 60) | `TVSyncCodeUITests.testTheClipCarriesAReadableCodeForItsRate`, `testEachPresetRateHasItsOwnClip` | UI | pass |
| Swipe down opens Sync; a step redraws the code (bffc9e7) | `TVSyncCodeUITests.testSwipeDownOpensSyncAndAStepRedrawsTheCode` | UI | pass |
| Menu leaves the clip back to Settings | `TVSyncCodeUITests.testMenuLeavesTheClipBackToSettings` | UI | pass |
| Read by an iPhone across a room | `MANUAL.md` §3 | manual | manual |

## Live TV and the guide

| Function | Test | Kind | Status |
|---|---|---|---|
| XMLTV parse: names, icons, every zone shape, open-ended, broken entries, no external entities | `TVGuideTests` | unit | pass |
| M3U playlist | `TVGuideTests.testPlaylistEntries` | unit | pass |
| Overlaps resolved into one line (`GuideSchedule`) | `TVGuideTests.testAFeedsOverlapsComeOutAsOneLineOfProgrammes` | unit | pass |
| Guide lists channels, programmes, ruler | `TVLiveTVTests.testTheGuideListsEveryChannelWithProgrammes` | UI | pass |
| Guide moves later and back, Up reaches the strip | `TVLiveTVTests.testTheGuideScrollsLaterAndComesBack`, `testUpFromTheGuideReachesTheStrip` | UI | pass |
| Tune a channel; top edge changes channel; live timeline, no scrubber | `TVLiveTVTests.testTuningAChannelAndChangingItWithTheEdges` | UI | pass |
| Channels tab; no Quality on a channel | `TVLiveTVTests.testTheChannelsTabListsTheLineUp` | UI | pass |
| Menu back to the guide | `TVLiveTVTests.testMenuLeavesAChannelBackToTheGuide` | UI | pass |
| Live TV source choice in Settings | `TVSettingsTests.testLiveTVSourceChoices` | UI | pass |

## Settings

| Function | Test | Kind | Status |
|---|---|---|---|
| Every page opens and Menu comes back; Up reaches the strip | `TVSettingsTests.testEveryPageOpensAndMenuComesBack` | UI | pass |
| Side panel describes the focused row | `TVSettingsTests.testThePanelDescribesTheFocusedRow` | UI | pass |
| Default quality list | `TVSettingsTests.testDefaultQualityListsEveryRungAndKeepsTheChoice` | UI | pass |
| No engine, battery, adaptive or speed-check rows; picture rows present (c964e31) | `TVSettingsTests.testNoEngineBatteryOrAdaptiveRows` | UI | pass |
| No Night mode where mpv can't do it (master-fix-list round 2) | `TVSettingsTests.testNightModeIsNotOfferedWhereItCannotWork` | UI | xfail |
| Picture adjustment and Reset | `TVSettingsTests.testPictureAdjustmentEnablesReset` | UI | pass |
| Audio: a delay row per clip rate, downmix | `TVSettingsTests.testAudioHasADelayRowPerClipRate` | UI | pass |
| Subtitles rows and language list | `TVSettingsTests.testSubtitlePageRows` | UI | pass |
| Account page | `TVSettingsTests.testAccountPageSaysWhoAndWhere` | UI | pass |
| About says mpv | `TVSettingsTests.testAboutSaysMPV` | UI | pass |
| No Music, Downloads or Watch pages | `TVSettingsTests.testNoMusicPageOnTheTV` | UI | pass |

## Music, downloads

The Apple TV has no music UI and keeps no downloads (FEATURE-LIST.md;
`AppModel.sections`; `TestID+Music.swift`). Tested as absences: no tab
(`TVShellTests`, `TVShellFocusTests`), no music libraries
(`TVBrowseTests.testLibraryTabListsTheVideoLibrariesOnly`), no music in Search
(`testSearchOffersNoMusicOnTheTV`), no music rows on Home
(`TVHomeTests.testRowsMatchTheBaseline`), no Music/Downloads pages in Settings
(`TVSettingsTests.testNoMusicPageOnTheTV`).

## Top Shelf

| Function | Test | Kind | Status |
|---|---|---|---|
| Publish: series posters, manifest, progress, ten at most, failures left out, no re-fetch, prune, ids can't escape the folder, nothing signed out, clear, refresh from Next Up | `TVTopShelfTests` | unit | pass (15) |
| Snapshot keys the extension decodes; links; URL scheme declared; extension embedded with the right extension point | `TVTopShelfTests` | unit | pass |
| The shelf is written under the group container's Library/Caches (the only place a real Apple TV allows writes; the root worked only in the simulator, so hardware showed the static image), and the old folder is swept | `TVTopShelfTests.testTheShelfLivesUnderLibraryCachesWhereTVOSAllowsWrites`, `testAPublishSweepsTheOldFolder` | unit | new 2026-11-18 |
| The extension drawing the shelf on a home screen; Play from a cell | `MANUAL.md` §4 | manual | manual |

## tvOS-only branches elsewhere, and why some are not tested here

| Code path | Covered by | Status |
|---|---|---|
| `PlayerModel.adaptsQuality` / `Preferences.openingBitrate` tvOS branches | `TVQualityEngineTests` | covered |
| `PowerSource.onBattery` tvOS branch | `TVQualityEngineTests.testTheTVIsNeverOnABattery` | covered |
| `PlaybackEngineKind.platformDefault`, `EnginePolicy.Platform.current` | `TVQualityEngineTests` | covered |
| `engineLoad` → `setDisplayRefreshRate(DisplayMatch.matchedRate)` | `TVDeviceTests` (nil on the simulator), MANUAL §2 | partial: only hardware switches modes |
| `MPVEngine` tvOS audio session; TLS roots (mpv-tls-verification.md) | every UI player test plays on mpv over http; HTTPS through mpv untested (the QA server is plain http) | untested: no HTTPS QA server |
| `RemoteDebugHook` (DEBUG) | used by the UI tests to swipe; not itself under test | n/a |
| `AppIntents`/`PlayerIntents` tvOS branches (Siri) | MANUAL §5 | manual: Siri can't be driven in the simulator |
| Downloads, OfflineProgress, SharePlay, Watch link (`#if !os(tvOS)`) | absent on tvOS by compilation | n/a |
| Focus styles and sizes in `Components.swift`, `HomeView`, `ItemDetailView` (layout) | screenshots attached by the UI tests; MANUAL §5 for the sofa | visual only |
| Dropout taken as end of episode (master-fix-list "Top priority") | not automated: needs the QA proxy killed mid-stream; MANUAL §5 | untested |
| Starved direct play notice | not automated: needs the 8098 throttle, which can hang below 2.6 Mbps (qa-rproxy-low-rate-hang.md) | untested |

## The run behind the statuses (2026-11-13)

- Unit: `AquariumTests` TV classes on "Aquarium Test Apple TV" (tvOS 27.0):
  83 tests, 81 pass, 2 expected failures, 0 unexpected
  (`TestResults/unit-tv-102433.xcresult`).
- UI: `Tools/run-tests.sh tv -- -collect-test-diagnostics never`: 95 tests,
  84 pass, 11 expected failures, 0 unexpected, 0 skipped, 28.8 min
  (`TestResults/20261113-102531-tv/`).

Every expected failure is a bug seen on this branch; its `XCTExpectFailure`
says what and where. Several are conditional (they only expect a failure
when the bug shows), so a fix turns them into plain passes.
