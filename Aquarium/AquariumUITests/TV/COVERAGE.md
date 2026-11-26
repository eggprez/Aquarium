# Apple TV: what is tested, and how

Every Apple TV screen, control and tvOS-only code path, with the test that
covers it. Kinds: **unit** (`AquariumTests/TV/`, run by `TestPlans/Unit`),
**UI** (`AquariumUITests/TV/`, `Tools/run-tests.sh tv`, against the QA server
as `suite-tv`), **manual** (`MANUAL.md`, hardware only).

Status: **pass**, **xfail** (kept with `XCTExpectFailure("bug: …")`, a real
bug), **fail** (fails, not yet understood), **manual**, **untested** (with why).
Status is from the run of 2026-11-13 (see the end of this file), except rows
marked 2026-11-22, which are from that day's run: 153 UI tests, 149 pass, 4 fail (three real Seerr bugs, fixed the same day; then 152 of 153, the one failure an mpv crash in the simulator's Metal driver while playing, which passed on two reruns); 555 unit tests on the Apple TV simulator, all pass.

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
| A library screen opens with something focused (seen opening with nothing focused) | `TVBrowseTests.testALibraryScreenOpensWithFocus` | UI | see the run |
| Deep links `aquarium://item|play/<id>` (the Top Shelf's way in) | every `launchDetail` / `launchPlaying` test (through `AppModel.handle`) | UI | pass (exercised by 40+ UI tests) |

## Sign-in

| Function | Test | Kind | Status |
|---|---|---|---|
| Server address, connect, password sign-in | `TVSignInTests.testPasswordSignInLandsOnHome` | UI | pass |
| Sign-in shows the one-word wordmark, read as "Aquarium" | `TVSignInTests.testSignInShowsTheWordmark` | UI | pass 2026-11-22 |
| Wrong password message, stays on screen | `TVSignInTests.testAWrongPasswordSaysSoAndStaysPut` | UI | xfail |
| Disabled account refused in plain words | `TVSignInTests.testADisabledAccountIsRefusedInPlainWords` | UI | xfail |
| Public users offered; passwordless user signs straight in, sees only its library, no Live TV | `TVSignInTests.testTheServersPublicUsersAreOffered`, `testAPasswordlessUserSignsStraightInAndSeesOnlyTheirLibrary` | UI | pass |
| Quick Connect: code shown, approved from another device, signs in | `TVSignInTests.testQuickConnectSignsInOnceApprovedElsewhere` | UI | pass |
| "Who's watching?" household of the Apple TV's users (`Keychain.Household`) | `TVDeviceTests.testTheHouseholdOffersOnlyOtherUsersAccounts`, `testTestModeKeepsTheHouseholdOutOfTheSharedKeychain`; second tvOS user in `MANUAL.md` §5 | unit, manual | pass |
| Device name sent to the server | `TVDeviceTests.testTheServerSeesAnAppleTV` | unit | pass |
| A plain-http server is marked HTTP, with the warning and the server's version | `TVSignInServerTests.testAPlainHTTPServerIsMarkedAndWarnedAbout` | UI | pass 2026-11-22 |
| "Use a different server" goes back to the address | `TVSignInServerTests.testUseADifferentServerGoesBackToTheAddress` | UI | pass 2026-11-22 |
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
| Card menu: Add to Favorites reaches the server | `TVCardMenuTests.testAddToFavoritesFromTheCardMenuReachesTheServer` | UI | pass 2026-11-22 |
| Card menu: Play from Beginning ignores the resume point (offered only when started) | `TVCardMenuTests.testPlayFromBeginningIgnoresTheResumePoint` | UI | pass 2026-11-22 |
| Card menu: Go to Show, Go to Season, Episode Details on a Next Up card | `TVCardMenuTests.testGoToShowFromAnEpisodeCardOpensTheShow`, `testGoToSeasonFromAnEpisodeCardOpensTheSeason`, `testANextUpCardOffersTheEpisodesOwnPage` | UI | pass 2026-11-22 |
| Card menu: Add Show to Next Up asks first (Menu leaves the server alone); the Next Up row offers Remove, not Add | `TVCardMenuTests.testAddShowToNextUpAsksAndMenuLeavesItAlone`, `testTheNextUpRowsMenuOffersRemovalAndNotAdding` | UI | pass 2026-11-22 |
| Card menu: Remove from Next Up and the two Add answers carried out | not automated: each changes the suite's Next Up baseline that `TVHomeTests` reads; the shared logic is in `NextUpRemovalTests`/`NextUpTargetTests` (unit); `MANUAL.md` §6 | manual |

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
| Search for a person, by name | not written: no person fixture that Search is known to return on the TV (the cast path is `testCastLeadsToAPersonPage`, xfail) | untested |

## Requests through Seerr (TVRequestsTests)

Against the stand-in Seerr server (TESTING.md). Run 2026-11-16: 4 pass.

| Function | Test | Kind | Status |
|---|---|---|---|
| No Requests tab without Seerr | TVRequestsTests.testNoRequestsTabWithoutSeerr | UI | pass |
| Requests tab: a request's row reachable with the remote, opens its page with focus | TVRequestsTests.testTheRequestsTabListsRequestsAndThingsToAskFor | UI | pass |
| A film asked for with the remote from a browse row | TVRequestsTests.testAFilmIsAskedForWithTheRemote | UI | pass |
| Search offers what the library lacks, reachable with the remote | TVRequestsTests.testSearchOffersWhatTheLibraryLacks | UI | pass |
| The Seerr tab: each browse row a placeholder until it lands, the foot credits Seerr and TMDB, focus kept | TVRequestsTests.testRowsShowTheyAreLoadingAndThePageCreditsSeerrAndTMDB | UI | pass 2026-11-19 |
| Where each request stands on its row (Waiting for approval, On its way) | `TVRequestsMoreTests.testEachRequestsRowSaysWhereItStands` | UI | pass 2026-11-22 |
| A pending request taken back with the remote, through "Cancel this request?" | `TVRequestsMoreTests.testARequestIsTakenBackWithTheRemote` | UI | pass 2026-11-22 |
| A show's missing seasons offered on its page; the request page ticks them and asks for 3 and 4 | `TVRequestsMoreTests.testAShowsMissingSeasonsAreOfferedOnItsPageAndAskedFor` | UI | pass 2026-11-22, after the fix: the banner is a focus region, so Down from the seasons reaches Request… |
| "Like This, Not in Your Library" under a film, reachable, opens a request page | `TVRequestsMoreTests.testAFilmsPageOffersLikeThisFromSeerr` | UI | pass 2026-11-22, after the fix: the request page's first button takes focus when it arrives |
| Settings → Account: the Seerr rows while connected, Disconnect takes the tab away | `TVRequestsSettingsTests.testAConnectedSeerrShowsItsRowsAndDisconnectTakesTheTabAway` | UI | pass 2026-11-22, after the fix: Account is pushed by value and its Seerr row takes focus back after the strip rebuilds |
| The Connect form opens; Menu leaves it unconnected | `TVRequestsSettingsTests.testTheConnectFormOpensAndMenuLeavesItUnconnected` | UI | pass 2026-11-22 |
| Connecting in Settings with the on-screen keyboard, the plain-http warning, the tab appears | `TVRequestsSettingsTests.testConnectingFromSettingsWithTheKeyboardAddsTheSeerrTab` (stand-in server); a real Seerr in `MANUAL.md` | UI, manual | pass 2026-11-22, after the same fix |
| Posters off notice, an expired session renewed, Reconnect | not written for the TV (covered on the iPhone: `PhoneRequestsTests`; same `SeerrClient`) | untested here |

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
| A show's Add to Next Up asks first; no Mark watched on a show | `TVDetailMoreTests.testAShowsAddToNextUpAsksAndMenuLeavesItAlone` | UI | pass 2026-11-22 |
| More Like This reached with the remote, opens a title, Menu comes back | `TVDetailMoreTests.testMoreLikeThisIsReachedWithTheRemoteAndOpensATitle` | UI | pass 2026-11-22 |
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
| Info tab: runtime line of facts | `TVPanelFactsTests` (2) | unit | see the run |
| Info tab: no sleep timer (removed 2026-11-26) | `TVPlayerInfoTabTests.testInfoHasNoSleepTimer` | UI | pass 2026-11-26 |
| Info tab: Autoplay switch only on an episode with a next one; Off stops the next starting | `TVPlayerInfoTabTests.testAFilmHasNoAutoplaySwitch`, `testAutoplayOffInInfoStopsTheNextEpisodeStarting` | UI | pass 2026-11-22 |
| Audio tracks: every one listed, choosing one reaches the server (jellyfin-track-index-needs-source-id.md) | `TVPlayerTests.testEveryAudioTrackIsListedAndOneCanBeChosen` | UI | pass |
| Every subtitle kind listed; none claims a server burn-in on direct play (master-fix-list) | `TVPlayerTests.testEverySubtitleKindIsListedAndNoneClaimsTheServerDrawsIt` | UI | pass |
| PGS stays DirectPlay on mpv; ASS, WebVTT, VobSub each shown | `TVPlayerTests.testAPictureSubtitleStaysDirectPlayOnMPV`, `testAnASSAndAWebVTTAndAVobSubTrackCanEachBeShown` | UI | pass |
| Sidecar subtitles | `TVPlayerTests.testSidecarSubtitlesAreListed` | UI | pass |
| Forced subtitles on by themselves for foreign audio (hls-subtitle-timing.md) | `TVPlayerTests.testForcedSubtitlesComeOnByThemselvesForForeignAudio` | UI | pass |
| Quality tab: Auto first, a rung transcodes and is kept, same place kept (f6b43c9) | `TVPlayerTests.testQualityTabOpensOnAutoAndPickingARungTranscodesAndKeepsIt` | UI | pass 2026-11-26 |
| Quality change while paused stays paused (qa-2026-11-11 B2) | `TVPlayerTests.testAQualityChangeWhilePausedStaysPaused` | UI | pass |
| Reopens don't add plays (master-fix-list "Every stream reopen adds to PlayCount") | `TVPlayerTests.testAReopenDoesNotAddToThePlayCount` | UI | xfail |
| Speed tab | `TVPlayerTests.testSpeedTabChangesTheRate` | UI | pass |
| No Picture tab (removed 2026-11-26; the picture rows are in Settings) | `TVPlayerTests.testSwipeDownOpensInfoWithAFilmsTabs` | UI | pass 2026-11-26 |
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
| Auto steers the TV when it is the TV's choice, and a kept rung is never stepped | `TVQualityEngineTests.testAutoSteersTheTVsStreamsWhenItIsTheTVsChoice` | unit | pass 2026-11-26 |
| Auto is this device's, never synced (5095d5e) | `TVQualityEngineTests.testAutoIsThisDevicesAndNeverSynced_regression5095d5e`, `PhoneSettingsRulesTests.testDeviceSettingsStayOnTheDevice` | unit | pass 2026-11-26 |
| Opening quality: Original under Auto, the rung otherwise | `TVQualityEngineTests.testOpeningQualityIsOriginalUnderAutoAndTheRungOtherwise` | unit | pass 2026-11-26 |
| The quality is this device's, not synced | `TVQualityEngineTests.testTheQualityIsThisDevicesNotSynced` | unit | pass |
| Speed check always on under Auto, never for a kept rung; never on battery | `TVQualityEngineTests.testTheSpeedCheckIsAlwaysOnUnderAutoWithNoRowForIt`, `testTheTVIsNeverOnABattery` | unit | pass 2026-11-26 |
| Choosing in the player is kept and decides who steers | `TVQualityEngineTests.testChoosingInThePlayerIsKeptAndDecidesWhoSteers` | unit | pass 2026-11-26 |
| The Settings row is Auto or the kept rung | `TVQualityEngineTests.testTheSettingsRowIsAutoOrTheKeptRung` | unit | pass 2026-11-26 |
| A new Apple TV starts on Auto; one already set up keeps its rung; settled once | `TVQualityEngineTests.testANewAppleTVStartsOnAuto`, `testAnAppleTVAlreadySetUpKeepsItsRung`, `testTheChoiceIsSettledOnceAndAutoPickedLaterSticks` | unit | pass 2026-11-26 |
| Auto at the top of Settings' list and first in the panel, ticked on a new TV | `TVSettingsTests.testDefaultQualityListsEveryRungAndKeepsTheChoice`, `TVPlayerTests.testQualityTabOpensOnAutoAndPickingARungTranscodesAndKeepsIt` | UI | pass 2026-11-26 |
| Auto picked in the panel goes back to the original and is ticked | `TVPlayerTests.testChoosingAutoInThePlayerGoesBackToTheOriginal` | UI | pass 2026-11-26 |
| Auto stepping down on a slow line and climbing back | not automated: needs the 8098 throttle, which can hang below 2.6 Mbps; the policy is `AdaptiveQualityTests` (unit, shared); `MANUAL.md` §2 | manual |

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
| Info over a channel: the programme, up to three coming up, no Autoplay | `TVLiveTVMoreTests.testInfoOverAChannelNamesTheProgrammeAndWhatComesNext` | UI | pass 2026-11-22 |
| A custom playlist source with no playlist: "No channels" in place of a guide, focus not trapped | `TVLiveTVMoreTests.testACustomSourceWithNoPlaylistSaysThereAreNoChannels` | UI | pass 2026-11-22 |
| Guide error banner and Retry | not automated: needs the guide request to fail while the channel list loads; no hook for it; `MANUAL.md` §6 | manual |
| Live TV source choice in Settings | `TVSettingsTests.testLiveTVSourceChoices` | UI | pass |

## Settings

| Function | Test | Kind | Status |
|---|---|---|---|
| Every page opens and Menu comes back; Up reaches the strip | `TVSettingsTests.testEveryPageOpensAndMenuComesBack` | UI | pass |
| Side panel describes the focused row | `TVSettingsTests.testThePanelDescribesTheFocusedRow` | UI | pass |
| Default quality list: Auto, then every rung | `TVSettingsTests.testDefaultQualityListsEveryRungAndKeepsTheChoice` | UI | pass 2026-11-26 |
| No engine, battery, adaptive or speed-check rows; picture rows present (c964e31) | `TVSettingsTests.testNoEngineBatteryOrAdaptiveRows` | UI | pass |
| No Night mode where mpv can't do it (master-fix-list round 2) | `TVSettingsTests.testNightModeIsNotOfferedWhereItCannotWork` | UI | xfail |
| Picture adjustment and Reset | `TVSettingsTests.testPictureAdjustmentEnablesReset` | UI | pass |
| Audio: a delay row per clip rate, downmix | `TVSettingsTests.testAudioHasADelayRowPerClipRate` | UI | pass |
| Subtitles rows and language list | `TVSettingsTests.testSubtitlePageRows` | UI | pass |
| Account page | `TVSettingsTests.testAccountPageSaysWhoAndWhere` | UI | pass |
| About says mpv | `TVSettingsTests.testAboutSaysMPV` | UI | pass |
| No Music, Downloads or Watch pages | `TVSettingsTests.testNoMusicPageOnTheTV` | UI | pass |
| First page: General switches flip and are kept over a relaunch; Next Up window list; iCloud row a switch or Unavailable; each page's summary in grey | `TVSettingsRowsTests.testGeneralSwitchesFlipAndAreKeptOverARelaunch`, `testNextUpWindowListsItsChoicesAndKeepsOne`, `testTheICloudRowIsASwitchOrSaysUnavailable`, `testTheFirstPageSaysWhereEachPageStands` | UI | pass 2026-11-22 |
| The summaries as the tvOS build words them (Auto or the rung; the 60 fps delay and Stereo; Never; Custom playlist; the Next Up window in words) | `TVSettingsSummaryTests` (8) | unit | pass 2026-11-22 |
| Account: connection facts; this account listed and clicking it asks nothing; Add Account opens sign-in and Cancel comes back; SyncPlay… asks which group, Menu leaves it Off | `TVSettingsRowsTests.testAccountPageGivesTheConnectionFacts`, `testTheAccountsListHasThisAccountAndClickingItAsksNothing`, `testAddAccountOpensSignInAndCancelComesBack`, `testSyncPlayInSettingsAsksWhichGroupAndMenuLeavesItOff` | UI | pass 2026-11-22 |
| Two accounts: the other's row asks Switch / Sign Out of This Apple TV; Switch signs it in; Sign Out takes it off the list; signing out leaves it on "Who's watching?", a press signs it in | `TVSettingsAccountsTests` (4) | UI | pass 2026-11-22 |
| Video: framing on its row and the first page; Resume and Autoplay switches; audio language list; zoom and aspect with Reset | `TVSettingsRowsTests.testFramingChoiceShowsOnItsRowAndOnTheFirstPage`, `testResumeAndAutoplaySwitchesFlip`, `testAudioLanguageListStartsWithTheFilesOwnAndKeepsAChoice`, `testZoomAndAspectAreListedAndResetPutsThemBack` | UI | pass 2026-11-22 |
| Video's effect: the Settings quality is what a title opens at; Resume off starts from the top | `TVSettingsEffectTests.testTheQualityChosenInSettingsIsWhatATitleOpensAt`, `testWithResumeOffATitleStartsFromTheTop` | UI | pass 2026-11-22 |
| Audio: downmix on the first page; every delay row In step on a clean launch; a delay set over the 24 fps clip shows on its row and no other | `TVSettingsRowsTests.testStereoDownmixShowsOnTheFirstPage`, `testEveryDelayRowReadsInStepOnACleanLaunch`; `TVSettingsEffectTests.testADelaySetOverTheClipIsShownOnItsRowAndNoOther` | UI | pass 2026-11-22 |
| Subtitles: size, background, language and forced only; a choice list opens on the current choice | `TVSettingsRowsTests.testSubtitleSizeBackgroundLanguageAndForcedOnly`, `testAChoiceListOpensOnTheCurrentChoice` | UI | pass 2026-11-22 |
| Live TV: a custom source brings the playlist rows and Jellyfin takes them away; a text row's alert, Menu saves nothing; artwork check with no playlist; Refresh now | `TVSettingsRowsTests.testACustomSourceBringsThePlaylistRowsAndTheServerTakesThemAway`, `testCheckingArtworkWithNoPlaylistSaysThereAreNoChannels`, `testRefreshNowSaysItIsRefreshing` | UI | pass 2026-11-22 |
| Library copy: kept, synced, deleted, switched off | `TVSettingsRowsTests.testKeepingALibraryCopySyncsItAndDeleteEmptiesIt` | UI | pass 2026-11-22 |
| A playlist address typed and saved; the guide from a real M3U/XMLTV playlist | not automated: the QA folder serves no playlist over http for the app to read; parsing is `TVGuideTests` (unit) | untested |

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
| Downloads, OfflineProgress, Watch link (`#if !os(tvOS)`) | absent on tvOS by compilation | n/a |
| Watch Together tab in the panel, with SharePlay and SyncPlay | TVSyncPlayTests.testThePanelHasAWatchTogetherTabWithSharePlayAndSyncPlay | new 2026-11-18 |
| SyncPlay against the QA server: a group from the panel, the remote's play/pause is the group's, someone else's jump and play move mpv, leave | TVSyncPlayTests.testSyncPlayStartsAGroupAndFollowsIt | new 2026-11-18 |
| What mpv does with a group's order; SyncPlay's wire and clock | GroupOrderTests, SyncPlayWireTests, SyncPlayClockTests (unit) | new 2026-11-18 |
| SharePlay session on the Apple TV (`AVDelegatingPlaybackCoordinator`) | MANUAL: needs a FaceTime call; never run | manual, untested |
| Settings › Account › SyncPlay (join with nothing playing) | the question and Menu: `TVSettingsRowsTests.testSyncPlayInSettingsAsksWhichGroupAndMenuLeavesItOff`; joining a group with nothing playing: MANUAL | UI, manual |
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
