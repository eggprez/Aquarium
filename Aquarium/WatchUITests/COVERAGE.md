# Watch test coverage

Every function in the watch app (`Watch/*.swift`, `Watch/Views/`), its widget
extension (`WatchWidgets/`), the shared watch types (`Shared/WatchSyncTypes.swift`,
`Shared/WatchWidgetSnapshot.swift`) and the phone's side of the relay
(`Aquarium/Core/WatchLink.swift`, `WatchRemote.swift`), with the tests that reach it.

Generated from the sources and the last test results; a function counts as reached
when a test calls it by name (or a test's helper does). **Kind**: unit
(`WatchTests/`, `AquariumTests/Shared/Watch*`), UI (`WatchUITests/`), manual
(`WatchUITests/MANUAL.md`). **Status**: pass, expected failure (a known bug kept
with `XCTExpectFailure`), skip, not run, or manual. A View's private helpers are
reached through its screen; the view table lists the UI tests that open it.

Regenerate after a run:

```
xcrun xcresulttool get test-results tests --path <run>.xcresult > results.json
python3 -I Aquarium/WatchUITests/coverage.py Aquarium Aquarium/WatchUITests/COVERAGE.md results-unit.json results-ui.json results-phone.json
```

## Watch/WatchApp.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `AquariumWatchApp.init` | 30 | runs at every host launch (unit and UI) | unit | covered |
| `WatchDelegate.handle` | 78 | WKRefreshBackgroundTask can't be made in a test; MANUAL.md §7 (background wakes) | manual | manual |
| `WatchDelegate.scheduleRefresh` | 122 | WKApplication.scheduleBackgroundRefresh has no observable result in a test; MANUAL.md §6, §7 | manual | manual |
| `WatchActions.handle` | 138 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testOtherLinksAreIgnored`, `WatchLinkTests.testDeleteMessagesGoByGroup` (+6 more) | unit | pass |
| `WatchActions.resumeBook` | 155 | `WatchActionsTests.testResumeCarriesOnAPausedBook`, `WatchActionsTests.testResumeTakesTheServersBookInProgress`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testResumeWithNoBookSaysThereIsNone` | unit | pass |
| `WatchActions.play` | 175 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchActionsTests.testPlayingAnUnknownIdDoesNothing`, `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach` (+3 more) | unit | pass |
| `WatchActions.songs` | 194 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `WatchActions.refreshBookPositions` | 224 | `WatchBookPlaceTests.testRefreshAsksForTheBooksOnTheWatchAndAppliesThem`, `WatchBookPlaceTests.testRefreshAsksNothingOfflineSignedOutOrWithNoBooks`, `WatchBookPlaceTests.testRefreshWithATimeoutReturnsWhatCameInTime`, `WatchBookPlaceTests.testRefreshKeepsAnEarlyPlace` | unit | pass |

## Watch/WatchClient.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `JellyfinClient.makeSession` | 93 | through `JellyfinClient.useTestProtocols` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `JellyfinClient.useTestProtocols` | 109 | `WatchClientTests.testAPositionInTheLastFiveMinutesOfAFinishedBookLeavesItFinished` | unit | pass |
| `JellyfinClient.load` | 118 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `JellyfinClient.init` | 125 | the singleton, made at host launch; its device id: WatchClientTests.testTheWatchIsItsOwnDeviceToTheServer | unit | covered |
| `JellyfinClient.install` | 142 | `WatchClientTests.testTheSameAccountAgainOnlyRefreshesTheToken`, `WatchLinkTests.testDeleteMessagesGoByGroup`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchLinkTests.testACancelOnThePhoneIsACancelHere` | unit | pass |
| `JellyfinClient.signOut` | 157 | `WatchBookPlaceTests.testRefreshAsksNothingOfflineSignedOutOrWithNoBooks`, `WatchClientTests.testSignOutForgetsAccountAndToken`, `WatchClientTests.testNothingIsAskedSignedOut`, `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce` (+1 more) | unit | pass |
| `JellyfinClient.keychainAccount` | 165 | through `JellyfinClient.install`, `JellyfinClient.signOut` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `JellyfinClient.pathId` | 176 | `WatchClientTests.testPathIdsAreEscapedOnlyWhenTheyNeedIt` | unit | pass |
| `JellyfinClient.encode` | 182 | `WatchWidgetSnapshotTests.testTheSnapshotRoundTrips`, `WatchClientTests.testQueriesEscapeThePlusSign`, `WatchDownloadsTests.testTheInventoryIsCutToFitAMessage`, `WatchSyncTypesTests.testFileContentsRoundTrip` | unit | pass |
| `JellyfinClient.authorizationHeader` | 188 | through `JellyfinClient.authHeaders`, `JellyfinClient.request` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `JellyfinClient.authHeaders` | 200 | through `JellyfinClient.stream`, `JellyfinClient.downloadRequest` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `JellyfinClient.authorized` | 217 | `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce` | unit | pass |
| `JellyfinClient.request` | 229 | `WatchClientTests.testNothingIsAskedSignedOut`, `WatchSyncTypesTests.testFileContentsRoundTrip` | unit | pass |
| `JellyfinClient.get` | 272 | through `JellyfinClient.items`, `JellyfinClient.item`, `JellyfinClient.resumeAudio` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `JellyfinClient.decode` | 283 | `WatchWidgetSnapshotTests.testTheSnapshotRoundTrips`, `WatchDownloadsTests.testTheRecordIsWrittenBesideItsFile`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads`, `WatchLinkTests.testTheContextCarriesThePlanToTheDownloads` (+10 more) | unit | pass |
| `JellyfinClient.checkOnline` | 289 | `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch` (+10 more) | unit | pass |
| `JellyfinClient.items` | 321 | `WatchClientTests.testATransportFailureIsOfflineAndAnAnswerIsBackOnline`, `WatchClientTests.testA401IsAnExpiredSignInNotAnOutage`, `WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused`, `WatchClientTests.testOtherErrorsCarryTheirStatus` (+9 more) | unit | pass |
| `JellyfinClient.item` | 346 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchClientTests.testUnreadableAnswersSaySo`, `WatchClientTests.testOneItemWithEverythingAPageNeeds` (+2 more) | unit | pass |
| `JellyfinClient.items` | 352 | `WatchClientTests.testATransportFailureIsOfflineAndAnAnswerIsBackOnline`, `WatchClientTests.testA401IsAnExpiredSignInNotAnOutage`, `WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused`, `WatchClientTests.testOtherErrorsCarryTheirStatus` (+9 more) | unit | pass |
| `JellyfinClient.resumeAudio` | 364 | `WatchClientTests.testResumeAudioAsksForAudioInProgress` | unit | pass |
| `JellyfinClient.recentlyPlayedSongs` | 377 | `WatchClientTests.testRecentlyPlayedSongs` | unit | pass |
| `JellyfinClient.albums` | 383 | `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testListsThePagesRead`, `WatchNavigatorTests.testRoutesCompareByWhatTheyShow` | unit | pass |
| `JellyfinClient.albumTracks` | 387 | `WatchClientTests.testAlbumTracksComeInSleeveOrder`, `WatchDownloadsTests.testListsThePagesRead` | unit | pass |
| `JellyfinClient.albumArtists` | 395 | `WatchClientTests.testAlbumsArtistsGenresAndSongs` | unit | pass |
| `JellyfinClient.albums` | 411 | `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testListsThePagesRead`, `WatchNavigatorTests.testRoutesCompareByWhatTheyShow` | unit | pass |
| `JellyfinClient.songs` | 417 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `JellyfinClient.genres` | 423 | `WatchClientTests.testAlbumsArtistsGenresAndSongs` | unit | pass |
| `JellyfinClient.songs` | 436 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `JellyfinClient.songs` | 442 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `JellyfinClient.randomSongs` | 448 | `WatchClientTests.testAlbumsArtistsGenresAndSongs` | unit | pass |
| `JellyfinClient.playlists` | 452 | `WatchClientTests.testPlaylistsLeaveOutOnlyWhatPlainlyIsntMusic`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testRemovingAPlaylistTellsThePhoneUnlessThePhoneAsked` (+8 more) | UI + unit | pass |
| `JellyfinClient.playlistItems` | 461 | `WatchClientTests.testPlaylistItemsInTheirOwnOrderWithTheWebFallback`, `WatchClientStubURLProtocolTests.testAPlaylistsSongsDecode` | unit | pass |
| `JellyfinClient.audiobooks` | 487 | `WatchClientTests.testAlbumsArtistsGenresAndSongs` | unit | pass |
| `JellyfinClient.search` | 501 | `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered` | unit | pass |
| `JellyfinClient.query` | 502 | `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce`, `WatchClientTests.testItemsQueryCarriesEverythingAsked`, `WatchClientTests.testOneItemWithEverythingAPageNeeds`, `WatchClientTests.testItemsByIdGoFiftyAtATime` (+10 more) | unit | pass |
| `JellyfinClient.imageURL` | 523 | `WatchClientTests.testNothingIsAskedSignedOut`, `WatchClientTests.testImageAddressesFallBackFromItemToAlbum` | unit | pass |
| `JellyfinClient.ladder` | 538 | through `JellyfinClient.imageURL` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `JellyfinClient.stream` | 578 | `WatchClientTests.testADirectStreamIsLetInByItsHeader`, `WatchClientTests.testATranscodeCarriesTheTokenInItsAddress`, `WatchClientTests.testAStreamTheClientCantUseIsAnError` | unit | pass |
| `JellyfinClient.stopTranscode` | 620 | `WatchClientTests.testStoppingATranscodeNamesThisDeviceAndSession` | unit | pass |
| `JellyfinClient.downloadRequest` | 636 | `WatchClientTests.testNothingIsAskedSignedOut`, `WatchClientTests.testADownloadIsAnAACEncodeWithTheTokenInAHeader`, `WatchClientTests.testADownloadTheWatchCanPlayIsTheServersOwnFile` | unit | pass |
| `JellyfinClient.estimatedBytes` | 663 | `WatchClientTests.testTheSizeOfADownloadComesFromItsLength`, `WatchDownloadsTests.testPhoneProgressMovesTheBarAndStartsItsPatienceAgain`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchOnWatchGroupsTests.testTheQueueShowsWhatMovesThenWhatWaitsInTheOrderItWillStart` (+1 more) | unit | pass |
| `JellyfinClient.reportStopped` | 684 | `WatchClientTests.testAPositionIsAStoppedReport` | unit | pass |
| `JellyfinClient.reportPlaying` | 705 | `WatchClientTests.testBestEffortRequestsDontChangeTheState`, `WatchClientTests.testLiveReportsNameStartAndProgress` | unit | pass |
| `JellyfinClient.markPlayed` | 716 | `WatchClientTests.testAPlayIsCountedWithItsDate` | unit | pass |
| `JellyfinClient.markUnplayed` | 722 | `WatchClientTests.testAPlayIsCountedWithItsDate` | unit | pass |
| `JellyfinClient.send` | 736 | `WatchClientTests.testAPlayIsCountedWithItsDate`, `WatchClientTests.testASongHeardOffTheWatchIsCountedAsAPlay`, `WatchClientTests.testAStreamedPlayIsAStoppedReportNotASecondPlay`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped` (+3 more) | unit | pass |
| `AnyEncodable.init` | 764 | every POST body (WatchClientTests reports, PlaybackInfo) | unit | covered |
| `AnyEncodable.encode` | 765 | `WatchWidgetSnapshotTests.testTheSnapshotRoundTrips`, `WatchClientTests.testQueriesEscapeThePlusSign`, `WatchDownloadsTests.testTheInventoryIsCutToFitAMessage`, `WatchSyncTypesTests.testFileContentsRoundTrip` | unit | pass |
| `WatchKeychain.query` | 775 | `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce`, `WatchClientTests.testItemsQueryCarriesEverythingAsked`, `WatchClientTests.testOneItemWithEverythingAPageNeeds`, `WatchClientTests.testItemsByIdGoFiftyAtATime` (+10 more) | unit | pass |
| `WatchKeychain.store` | 783 | `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` | unit | pass |
| `WatchKeychain.token` | 795 | `WatchClientTests.testInstallSignsInAndKeepsTheTokenOutOfTheAccount`, `WatchClientTests.testTheSameAccountAgainOnlyRefreshesTheToken`, `WatchClientTests.testSignOutForgetsAccountAndToken`, `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce` (+5 more) | unit | pass |
| `WatchKeychain.delete` | 809 | `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testAPlaylistThePhoneSwitchedOffIsNotToldBack`, `WatchDownloadsTests.testADeleteFromThePhoneGoesByGroup`, `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` (+1 more) | unit | pass |

## Watch/WatchDownloads.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchRecord.init` | 86 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads` | unit | pass |
| `WatchRecord.init` | 111 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads` | unit | pass |
| `WatchDownloads.init` | 302 | the singleton, made at host launch (loads records, plan, wants) | unit | covered |
| `WatchDownloads.folder` | 368 | `WatchDownloadsTests.testTheRecordIsWrittenBesideItsFile`, `WatchDownloadsTests.testWhatIsAlreadyComingTakesItsRoomFirst`, `WatchDownloadsTests.testAWholeFileIsBelieved`, `WatchDownloadsTests.testAFileWithinThreePercentIsWhole` (+21 more) | unit | pass |
| `WatchDownloads.artFile` | 372 | `WatchImagesTests.testTheCoverBesideADownloadIsUsedFirst`, `WatchImagesTests.testAFileCoverLoadsAndIsCached`, `WatchImagesTests.testARecordWithACoverOnDiskSaysSo` | unit | pass |
| `WatchDownloads.loadRecords` | 376 | read once in init; a relaunch keeping state is WatchPlaybackTests.testPausingABookKeepsItsPlaceOnTheServer | manual | manual |
| `WatchDownloads.loadWants` | 399 | read once in init (wants.json is checked written: WatchWantsTests.testTheWantsListSurvivesOnDisk) | manual | manual |
| `WatchDownloads.saveWants` | 406 | through `WatchDownloads.dropWant`, `WatchDownloads.checkWants`, `WatchDownloads.keep` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.loadPlaylists` | 412 | read once in init | manual | manual |
| `WatchDownloads.reindex` | 417 | through `WatchDownloads.save`, `WatchDownloads.enqueue`, `WatchDownloads.deleteEverything` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.save` | 422 | through `WatchDownloads.retry`, `WatchDownloads.withdraw`, `WatchDownloads.deleteAlbum` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.savePlaylists` | 440 | through `WatchDownloads.delete`, `WatchDownloads.deletePlaylist`, `WatchDownloads.deleteEverything` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.persistTasks` | 445 | through `WatchDownloads.deleteEverything`, `WatchDownloads.finishActive` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.changed` | 449 | through `WatchDownloads.save`, `WatchDownloads.savePlaylists`, `WatchDownloads.enqueue` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.record` | 456 | `WatchBookPlaceTests.testNotingAPlaceMarksItForTheServer`, `WatchBookPlaceTests.testUnderFiveMinutesLeftIsFinished`, `WatchBookPlaceTests.testStartingAFinishedBookAgainIsNotFinished`, `WatchBookPlaceTests.testASongPast98PercentIsHeard` (+67 more) | unit | pass |
| `WatchDownloads.isComplete` | 460 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason` | unit | pass |
| `WatchDownloads.isStarting` | 463 | through WatchDownloads.queue (WatchOnWatchGroupsTests) | unit | covered |
| `WatchDownloads.isQueuedOrRunning` | 465 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason` | unit | pass |
| `WatchDownloads.mediaURL` | 470 | `WatchDownloadsTests.testAWholeFileIsBelieved`, `WatchDownloadsTests.testAMissingFileIsNoMediaURL` | unit | pass |
| `WatchDownloads.fraction` | 477 | `WatchWidgetSnapshotTests.testHowFarIn`, `WatchDownloadsTests.testPhoneProgressMovesTheBarAndStartsItsPatienceAgain`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord` | unit | pass |
| `WatchDownloads.albumTracks` | 504 | `WatchClientTests.testAlbumTracksComeInSleeveOrder`, `WatchDownloadsTests.testListsThePagesRead` | unit | pass |
| `WatchDownloads.playlistSongs` | 508 | WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch | unit | covered |
| `WatchDownloads.freeBytes` | 512 | `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes` | unit | pass |
| `WatchDownloads.enqueue` | 525 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch` (+91 more) | unit | pass |
| `WatchDownloads.writeMeta` | 566 | through `WatchDownloads.enqueue` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.retry` | 586 | `WatchDownloadsTests.testRetryQueuesAFailureAgainFromNothing`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` | unit | pass |
| `WatchDownloads.retryAllFailed` | 596 | `WatchDownloadsTests.testRetryQueuesAFailureAgainFromNothing` | unit | pass |
| `WatchDownloads.cancel` | 601 | `WatchDownloadsTests.testCancelForgetsAQueuedItem`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchDownloadsTests.testCancellingWhatThePhoneIsFetchingTellsThePhone`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` (+4 more) | unit | pass |
| `WatchDownloads.persistDeclined` | 616 | through `WatchDownloads.cancel`, `WatchDownloads.dropWant`, `WatchDownloads.deleteEverything` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.delete` | 622 | `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testAPlaylistThePhoneSwitchedOffIsNotToldBack`, `WatchDownloadsTests.testADeleteFromThePhoneGoesByGroup`, `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` (+1 more) | unit | pass |
| `WatchDownloads.withdraw` | 634 | through `WatchDownloads.deletePlaylist`, `WatchDownloads.syncPlaylist` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.deleteBook` | 648 | through `WatchDownloads.delete` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.deleteAlbum` | 653 | `WatchDownloadsTests.testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds`, `WatchWantsTests.testRemovingAnAlbumOfAnArtistLetsTheArtistWantGoButKeepsItsOtherAlbums`, `WatchWantsTests.testAWantTakenOffHereIsntPutBackByAPlanThatStillNamesIt`, `WatchWantsTests.testAPlanThatNoLongerNamesADroppedWantEndsTheGrace` | unit | pass |
| `WatchDownloads.deletePlaylist` | 679 | `WatchDownloadsTests.testRemovingAPlaylistTellsThePhoneUnlessThePhoneAsked`, `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan` | unit | pass |
| `WatchDownloads.dropped` | 692 | through `WatchDownloads.deletePlaylist`, `WatchDownloads.deleteEverything` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.persistDropped` | 702 | through `WatchDownloads.dropped`, `WatchDownloads.dropWant`, `WatchDownloads.deleteEverything` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.dropWant` | 716 | through `WatchDownloads.cancel`, `WatchDownloads.deleteBook`, `WatchDownloads.deleteAlbum` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.forgetWants` | 751 | `WatchWantsTests.testAGroupCancelledByHandForgetsItsWantButKeepsWhatArrived` | unit | pass |
| `WatchDownloads.forgetWants` | 763 | `WatchWantsTests.testAGroupCancelledByHandForgetsItsWantButKeepsWhatArrived` | unit | pass |
| `WatchDownloads.deleteWant` | 774 | `WatchSyncTypesTests.testEveryMessageRoundTrips`, `WatchWantsTests.testAWantTakenOffOnThePhoneLetsGoWithoutAWordBack`, `WatchWantsTests.testAWantsItemsKeptForSomethingElseStay` | unit | pass |
| `WatchDownloads.isDroppedWant` | 779 | through `WatchDownloads.checkWants` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.lookUp` | 784 | through `WatchDownloads.checkWants`, `WatchDownloads.download` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.checkWants` | 807 | through `WatchDownloads.mirror` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.wantStates` | 845 | `WatchWantsTests.testAWantWithNoContentsIsLookedUpOnTheServer`, `WatchWantsTests.testAWantThatCantBeLookedUpAsksThePhoneToSendItAgain`, `WatchWantsTests.testOfflineTheServerIsNotAsked`, `WatchWantsTests.testWantStatesReportHowFarEachHasGot` | unit | pass |
| `WatchDownloads.deleteLooseSongs` | 869 | `WatchDownloadsTests.testRemovingLooseSongsLeavesAlbums` | unit | pass |
| `WatchDownloads.deleteEverything` | 878 | `WatchDownloadsTests.testRemovingEverythingLetsTheWantsAndPlaylistsGoOnBothSides` | unit | pass |
| `WatchDownloads.removeFolder` | 900 | through `WatchDownloads.cancel`, `WatchDownloads.delete`, `WatchDownloads.withdraw` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.noteProgress` | 922 | `WatchBookPlaceTests.testNotingAPlaceMarksItForTheServer`, `WatchBookPlaceTests.testUnderFiveMinutesLeftIsFinished`, `WatchBookPlaceTests.testStartingAFinishedBookAgainIsNotFinished`, `WatchBookPlaceTests.testASongPast98PercentIsHeard` (+15 more) | unit | pass |
| `WatchDownloads.markSynced` | 944 | `WatchBookPlaceTests.testMarkSyncedOnlyCoversWhatTheServerHeard` | unit | pass |
| `WatchDownloads.unsentBookEvents` | 954 | `WatchBookPlaceTests.testABookNotedButNeverQueuedGoesFromItsRecord`, `WatchBookPlaceTests.testTheBookPlayingNowIsLeftToThePlayer` | unit | pass |
| `WatchDownloads.applyServerState` | 972 | `WatchBookPlaceTests.testASyncedBookTakesTheServersPlace`, `WatchBookPlaceTests.testListeningNotYetToldWinsOverAnOlderServer`, `WatchBookPlaceTests.testANewerPlayElsewhereWinsOverListeningNotYetTold`, `WatchBookPlaceTests.testAnEventStillQueuedKeepsTheWatchsPlace` (+5 more) | unit | pass |
| `WatchDownloads.pump` | 1035 | `WatchDownloadsTests.testAskedForThingsGoBeforeTheMirrors`, `WatchDownloadsTests.testAQuietPhoneInReachIsAskedAgainLessOftenEachTime`, `WatchDownloadsTests.testAPhoneAwayIsAskedAgainOnlyOnceItsPatienceRunsOut`, `WatchDownloadsTests.testWithThePathMonitorDownTheWatchNeverTakesItBack` (+3 more) | unit | pass |
| `WatchDownloads.phoneGaveUpOn` | 1059 | local to pump: testThePhoneGivingUpWithANetworkLetsTheWatchTry | unit | covered |
| `WatchDownloads.syncNow` | 1107 | `WatchDownloadsTests.testSyncNowAsksThePhoneAgainForEverythingAwaiting` | unit | pass |
| `WatchDownloads.reaskPhone` | 1127 | `WatchDownloadsTests.testAPhoneAwayIsAskedAgainOnlyOnceItsPatienceRunsOut` | unit | pass |
| `WatchDownloads.handOffToPhone` | 1156 | on the way to the background (scene phase); it is one call to pump, which is unit-tested | manual | manual |
| `WatchDownloads.makeRoom` | 1168 | through `WatchDownloads.pump` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.notePhoneProgress` | 1203 | `WatchDownloadsTests.testPhoneProgressMovesTheBarAndStartsItsPatienceAgain`, `WatchOnWatchGroupsTests.testTheQueueShowsWhatMovesThenWhatWaitsInTheOrderItWillStart` | unit | pass |
| `WatchDownloads.phoneStillAtIt` | 1212 | through `WatchDownloads.notePhoneProgress` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.phoneFailed` | 1224 | `WatchDownloadsTests.testThePhoneGivingUpWithNoNetworkSaysWhy`, `WatchDownloadsTests.testThePhoneGivingUpWithANetworkLetsTheWatchTry`, `WatchDownloadsTests.testAPhoneFailureForSomethingNotAskedIsIgnored` | unit | pass |
| `WatchDownloads.receivedFromPhone` | 1245 | `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchDownloadsTests.testASecondDeliveryLeavesTheFileThatIsThere`, `WatchDownloadsTests.testAFileFromThePhoneForNothingIsRemoved`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed` (+2 more) | unit | pass |
| `WatchDownloads.start` | 1275 | the watch's own transfer: WatchDownloadUITests (straight from the server) | UI | via screen |
| `WatchDownloads.cancelActiveTask` | 1312 | through `WatchDownloads.cancel`, `WatchDownloads.delete`, `WatchDownloads.withdraw` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.taskItem` | 1321 | through `WatchDownloads.cancelActiveTask` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.rejoin` | 1327 | runs once at launch against the background session; relaunch mid-download, MANUAL.md §1.5 | manual | manual |
| `WatchDownloads.handleBackgroundEvents` | 1353 | background session wake; MANUAL.md §7 | manual | manual |
| `WatchDownloads.releaseBackgroundWake` | 1358 | background session wake; MANUAL.md §7 | manual | manual |
| `WatchDownloads.landed` | 1375 | `WatchDownloadsTests.testWhatIsAlreadyComingTakesItsRoomFirst`, `WatchDownloadsTests.testAWholeFileIsBelieved`, `WatchDownloadsTests.testAFileWithinThreePercentIsWhole`, `WatchDownloadsTests.testAShortFileIsThrownAwayAndAskedForAgainThreeTimes` (+6 more) | unit | pass |
| `WatchDownloads.failed` | 1421 | `WatchDownloadsTests.testThePhoneGivingUpWithNoNetworkSaysWhy`, `WatchDownloadsTests.testAFailedTransferIsTriedThreeTimes`, `WatchDownloadsTests.testAFailureWithNoWayToTryAgainIsFailedAtOnce`, `WatchDownloadsTests.testAFailureHereGoesToThePhoneNext` (+1 more) | unit | pass |
| `WatchDownloads.finishActive` | 1440 | through `WatchDownloads.landed`, `WatchDownloads.failed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.cacheArt` | 1450 | through `WatchDownloads.landed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.apply` | 1467 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+17 more) | unit | pass |
| `WatchDownloads.mirror` | 1505 | `WatchSyncTypesTests.testRepliesRoundTrip`, `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchWantsTests.testAnItemHereForSomethingElseIsClaimedForTheWantToo`, `WatchWantsTests.testAFailedItemIsRetriedOnceAnHourNotOnEveryPass` (+3 more) | unit | pass |
| `WatchDownloads.mirrorSettled` | 1541 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+13 more) | unit | pass |
| `WatchDownloads.syncPlaylist` | 1554 | through `WatchDownloads.mirror` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchDownloads.receivedFromPhone` | 1604 | `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchDownloadsTests.testASecondDeliveryLeavesTheFileThatIsThere`, `WatchDownloadsTests.testAFileFromThePhoneForNothingIsRemoved`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed` (+2 more) | unit | pass |
| `WatchDownloads.receivedFromPhone` | 1615 | `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchDownloadsTests.testASecondDeliveryLeavesTheFileThatIsThere`, `WatchDownloadsTests.testAFileFromThePhoneForNothingIsRemoved`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed` (+2 more) | unit | pass |
| `WatchDownloads.keep` | 1624 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer`, `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds` (+26 more) | unit | pass |
| `WatchDownloads.inventory` | 1643 | `WatchDownloadsTests.testTheInventoryCountsEachByteOnce`, `WatchDownloadsTests.testTheInventoryIsCutToFitAMessage`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes` | unit | pass |
| `WatchDownloads.delete` | 1697 | `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testAPlaylistThePhoneSwitchedOffIsNotToldBack`, `WatchDownloadsTests.testADeleteFromThePhoneGoesByGroup`, `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` (+1 more) | unit | pass |
| `WatchDownloads.download` | 1707 | `WatchSyncTypesTests.testEveryMessageRoundTrips`, `WatchWantsTests.testADownloadMessageLooksItUpAndKeepsIt`, `WatchWantsTests.testADownloadThatCantBeLookedUpIsLeft` | unit | pass |
| `WatchDownloads.keep` | 1716 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer`, `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds` (+26 more) | unit | pass |
| `WatchDownloads.testSetNetwork` | 1749 | `WatchDownloadsTests.testAPhoneAwayPastItsPatienceHandsTheItemToTheWatch`, `WatchDownloadsTests.testThePathMonitorsWordAloneNeverTakesBackFromThePhone`, `WatchDownloadsTests.testThePhoneGivingUpWithANetworkLetsTheWatchTry`, `WatchDownloadsTests.testAFailedTransferIsTriedThreeTimes` (+7 more) | unit | pass |
| `WatchDownloads.testUpdate` | 1758 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch` (+55 more) | unit | pass |
| `WatchDownloads.testSetWantRetried` | 1765 | `WatchWantsTests.testAFailedItemIsRetriedOnceAnHourNotOnEveryPass`, `WatchWantsTests.testAnItemTurnedAwayForRoomIsLeftToThePump` | unit | pass |
| `WatchDownloads.testSetDroppedWant` | 1768 | `WatchWantsTests.testAWantTakenOffHereIsntPutBackByAPlanThatStillNamesIt` | unit | pass |
| `WatchDownloads.testReset` | 1779 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchPlayerTests.testPlayLeavesOutWhatIsntAudioAndShuffleKeepsTheChosenFirst` (+1 more) | unit | pass |
| `WatchDownloads.urlSession` | 1819 | background URLSession delegate: the watch's own transfers, exercised by WatchDownloadUITests on the simulator; real wakes MANUAL.md §7 | manual | manual |
| `WatchDownloads.urlSession` | 1847 | background URLSession delegate: the watch's own transfers, exercised by WatchDownloadUITests on the simulator; real wakes MANUAL.md §7 | manual | manual |
| `WatchDownloads.urlSession` | 1874 | background URLSession delegate: the watch's own transfers, exercised by WatchDownloadUITests on the simulator; real wakes MANUAL.md §7 | manual | manual |
| `WatchDownloads.urlSessionDidFinishEvents` | 1885 | background session wake; MANUAL.md §7 | manual | manual |

## Watch/WatchLink.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchSyncQueue.init` | 32 | the singleton, made at host launch | unit | covered |
| `WatchSyncQueue.persist` | 39 | through `WatchSyncQueue.add`, `WatchSyncQueue.flush`, `WatchSyncQueue.testReset` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchSyncQueue.add` | 45 | `WatchBookPlaceTests.testAnEventStillQueuedKeepsTheWatchsPlace`, `WatchSyncQueueTests.testAPositionReplacesTheOneWaitingButAPlayIsKept`, `WatchSyncQueueTests.testEventsAreMarkedWithWhoHeardThem`, `WatchSyncQueueTests.testTheQueueSurvivesARelaunch` (+9 more) | unit | pass |
| `WatchSyncQueue.hasPending` | 55 | `WatchSyncQueueTests.testAPositionReplacesTheOneWaitingButAPlayIsKept` | unit | pass |
| `WatchSyncQueue.stamped` | 62 | through `WatchSyncQueue.add` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchSyncQueue.flush` | 69 | `WatchSyncQueueTests.testNothingGoesWithNoPhoneAndNoNetwork`, `WatchSyncQueueTests.testAnEventRefusedForTheSignInIsKept`, `WatchSyncQueueTests.testAServerHiccupStopsTheRestForNow`, `WatchSyncQueueTests.testAnotherAccountsEventWaits` (+1 more) | unit | pass |
| `WatchSyncQueue.flushOnce` | 90 | through `WatchSyncQueue.flush` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchSyncQueue.testReset` | 132 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchPlayerTests.testPlayLeavesOutWhatIsntAudioAndShuffleKeepsTheChosenFirst` (+1 more) | unit | pass |
| `WatchSyncQueue.settle` | 141 | `WatchActionsTests.testOtherLinksAreIgnored`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchSyncQueueTests.testAnEventRefusedForTheSignInIsKept`, `WatchSyncQueueTests.testAServerHiccupStopsTheRestForNow` (+1 more) | unit | pass |
| `WatchLink.init` | 203 | the singleton, made at host launch | unit | covered |
| `WatchLink.start` | 207 | every launch; WatchConnectivity activation needs a pair (MANUAL.md §1) | UI | via screen |
| `WatchLink.apply` | 217 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+17 more) | unit | pass |
| `WatchLink.requestContext` | 225 | `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `WatchLink.apply` | 235 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+17 more) | unit | pass |
| `WatchLink.handle` | 258 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testOtherLinksAreIgnored`, `WatchLinkTests.testDeleteMessagesGoByGroup` (+6 more) | unit | pass |
| `WatchLink.take` | 290 | `WatchLinkTests.testWhatThePhoneIsPlayingIsKeptWithoutItsCover`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchLinkTests.testChoosingTheiPhoneSourceAsksForItsPlayback`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward` (+2 more) | unit | pass |
| `WatchLink.requestPlayback` | 311 | `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `WatchLink.remote` | 343 | `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward`, `WatchLinkTests.testEachRemoteCommandIsDrawnAtOnce` (+1 more) | unit | pass |
| `WatchLink.sendLogs` | 401 | through `WatchLink.handle` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.sendLogsInline` | 418 | through `WatchLink.sendLogs` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.finish` | 429 | local to send(events:) and sendLogsInline: WatchConnectivity's reply or timeout (unit tests answer through testEventReply) | manual | manual |
| `WatchLink.send` | 452 | `WatchClientTests.testAPlayIsCountedWithItsDate`, `WatchClientTests.testASongHeardOffTheWatchIsCountedAsAPlay`, `WatchClientTests.testAStreamedPlayIsAStoppedReportNotASecondPlay`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped` (+3 more) | unit | pass |
| `WatchLink.publishInventory` | 472 | through `WatchLink.apply`, `WatchLink.handle`, `WatchLink.session` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.send` | 498 | `WatchClientTests.testAPlayIsCountedWithItsDate`, `WatchClientTests.testASongHeardOffTheWatchIsCountedAsAPlay`, `WatchClientTests.testAStreamedPlayIsAStoppedReportNotASecondPlay`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped` (+3 more) | unit | pass |
| `WatchLink.finish` | 506 | local to send(events:) and sendLogsInline: WatchConnectivity's reply or timeout (unit tests answer through testEventReply) | manual | manual |
| `WatchLink.testSetPhone` | 537 | `WatchDownloadsTests.testWithAPhoneAppEverythingIsAskedOfThePhone`, `WatchDownloadsTests.testALongListGoesInMessagesOfTwoHundred`, `WatchDownloadsTests.testAskedForThingsGoBeforeTheMirrors`, `WatchDownloadsTests.testSignedOutNothingMoves` (+23 more) | unit | pass |
| `WatchLink.session` | 545 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.sessionCompanionAppInstalledDidChange` | 561 | WatchConnectivity; MANUAL.md §1 | manual | manual |
| `WatchLink.session` | 572 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.takePiece` | 646 | `WatchLinkTests.testPiecesJoinInOrderWhicheverOrderTheyArrive`, `WatchLinkTests.testAHalfWrittenPieceIsTrimmedAndWrittenAgain`, `WatchLinkTests.testAPieceWithoutItsPlaceIsRefused`, `WatchLinkTests.testASendLeftBehindGoesAfterAnHour` | unit | pass |
| `WatchLink.removeIncoming` | 711 | `WatchLinkTests.testPiecesJoinInOrderWhicheverOrderTheyArrive` | unit | pass |
| `WatchLink.sessionReachabilityDidChange` | 718 | WatchConnectivity; MANUAL.md §2 | manual | manual |
| `WatchLink.session` | 733 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 737 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 742 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 747 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |

## Watch/WatchPlayer.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `Entry.init` | 33 | the singleton and each queue entry: every WatchPlayerTests test | unit | covered |
| `Entry.hash` | 35 | queue entries: WatchPlayerTests | unit | covered |
| `WatchPlayer.init` | 107 | the singleton and each queue entry: every WatchPlayerTests test | unit | covered |
| `WatchPlayer.play` | 123 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchActionsTests.testPlayingAnUnknownIdDoesNothing`, `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach` (+3 more) | unit | pass |
| `WatchPlayer.playLater` | 144 | `WatchPlayerTests.testPlayLaterAddsToAQueueThatIsUp` | unit | pass |
| `WatchPlayer.skip` | 151 | no screen offers it (queue list not built on the watch); unused | UI | via screen |
| `WatchPlayer.togglePlayPause` | 160 | `WatchLinkTests.testEachRemoteCommandIsDrawnAtOnce`, `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `WatchPlayer.pause` | 164 | `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward`, `WatchPlayerTests.testPausingABookNotesItsPlaceAndQueuesItForTheServer`, `WatchPlayerTests.testAPauseBeforeTheSeekLandsWritesNothing`, `WatchPlayerTests.testAStreamedBookSaysSo` (+4 more) | unit | pass |
| `WatchPlayer.resume` | 173 | through `WatchPlayer.togglePlayPause` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.seek` | 184 | `WatchPlayerTests.testSeekStaysInsideTheItem`, `WatchPlayerTests.testChapterSkipsAndTheCurrentChapter` | unit | pass |
| `WatchPlayer.seek` | 191 | `WatchPlayerTests.testSeekStaysInsideTheItem`, `WatchPlayerTests.testChapterSkipsAndTheCurrentChapter` | unit | pass |
| `WatchPlayer.skipNext` | 193 | `WatchPlayerTests.testNextOnTheLastSongStops` | unit | pass |
| `WatchPlayer.skipPrevious` | 205 | `WatchPlayerTests.testPreviousPartWayInGoesToTheTop` | unit | pass |
| `WatchPlayer.skipChapter` | 216 | `WatchPlayerTests.testChapterSkipsAndTheCurrentChapter`, `WatchPlayerTests.testWithNoChaptersTheSkipsAreThirtyAndFifteen` | unit | pass |
| `WatchPlayer.stepSpeed` | 234 | `WatchPlayerTests.testTheSpeedStepsUpAndDown`, `WatchPlayerTests.testTheSpeedGoesRoundFromTheTop` | unit | pass |
| `WatchPlayer.stop` | 241 | `WatchPlayerTests.testStopClearsEverything` | unit | pass |
| `WatchPlayer.startCurrent` | 262 | through `WatchPlayer.play`, `WatchPlayer.skipNext`, `WatchPlayer.skipPrevious` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.resumePoint` | 348 | `WatchPlayerTests.testWhereABookOpens` | unit | pass |
| `WatchPlayer.install` | 360 | `WatchClientTests.testTheSameAccountAgainOnlyRefreshesTheToken`, `WatchLinkTests.testDeleteMessagesGoByGroup`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchLinkTests.testACancelOnThePhoneIsACancelHere` | unit | pass |
| `WatchPlayer.begin` | 381 | through `WatchPlayer.install` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.failedToOpen` | 389 | through `WatchPlayer.startCurrent`, `WatchPlayer.installItemObservers` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.installItemObservers` | 399 | through `WatchPlayer.install` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.teardownItemObservers` | 423 | through `WatchPlayer.stop`, `WatchPlayer.startCurrent` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.timeControlChanged` | 437 | WatchPlaybackTests (play/pause) | UI | via screen |
| `WatchPlayer.tick` | 457 | `WatchPlayerTests.testTheClockNotesABooksPlaceAsItPlays`, `WatchPlayerTests.testTheClockIgnoresTicksBeforeTheSeekLands` | unit | pass |
| `WatchPlayer.itemEnded` | 478 | not waited for (30 s songs); MANUAL.md | UI | via screen |
| `WatchPlayer.closeCurrent` | 493 | through `WatchPlayer.play`, `WatchPlayer.skipNext`, `WatchPlayer.skipPrevious` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.checkpoint` | 507 | `WatchPlayerTests.testCheckpointNotesAPlayingBookOnTheWayToTheBackground` | unit | pass |
| `WatchPlayer.note` | 523 | `WatchPlayerTests.testTheMinuteNoteNearTheEndIsOnlyAPosition`, `WatchPlayerTests.testABookPausedInItsLastMinutesThenFinishedCountsOnce`, `WatchPlayerTests.testASongIsHeardPastNinetyPercentAndCountedOnce`, `WatchLogTests.testNotesGoToTheFileAndTheExportCarriesThem` (+1 more) | unit | pass |
| `WatchPlayer.reportLive` | 555 | through `WatchPlayer.pause`, `WatchPlayer.begin`, `WatchPlayer.tick` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.activateSession` | 568 | through `WatchPlayer.resume`, `WatchPlayer.startCurrent` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.observeInterruptions` | 579 | calls and Siri: MANUAL.md §4 | manual | manual |
| `WatchPlayer.wireRemoteCommands` | 603 | lock-screen and crown transport: MANUAL.md §4 | manual | manual |
| `WatchPlayer.refreshCommands` | 630 | through `WatchPlayer.updateNowPlaying` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.updateNowPlaying` | 640 | through `WatchPlayer.pause`, `WatchPlayer.resume`, `WatchPlayer.seek` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.updateNowPlayingRate` | 676 | Now Playing card: MANUAL.md §4 | manual | manual |
| `WatchPlayer.loadArtwork` | 687 | through `WatchPlayer.updateNowPlaying` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.clearNowPlaying` | 699 | through `WatchPlayer.stop` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchPlayer.writeSnapshot` | 710 | `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft` | unit | pass |
| `WatchPlayer.worthRedrawing` | 747 | `WatchPlayerTests.testTheCardRedrawsOnlyWhenItChanges` | unit | pass |
| `WatchPlayer.testLoad` | 766 | `WatchActionsTests.testResumeCarriesOnAPausedBook`, `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchBookPlaceTests.testTheBookPlayingNowIsLeftToThePlayer`, `WatchPlayerTests.testTheSpeedStepsUpAndDown` (+20 more) | unit | pass |
| `WatchPlayer.testReset` | 791 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchPlayerTests.testPlayLeavesOutWhatIsntAudioAndShuffleKeepsTheChosenFirst` (+1 more) | unit | pass |

## Watch/WatchIntents.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchBookEntity.init` | 21 | `WatchIntentsTests.testABookEntityNamesTheBookAndItsAuthor`, `WatchIntentsTests.testACollectionEntitySaysWhatItIs` | unit | pass |
| `WatchBookQuery.entities` | 30 | `WatchIntentsTests.testBooksAreFoundOnTheWatchThenTheServer`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer` | unit | pass |
| `WatchBookQuery.entities` | 43 | `WatchIntentsTests.testBooksAreFoundOnTheWatchThenTheServer`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer` | unit | pass |
| `WatchBookQuery.suggestedEntities` | 58 | `WatchIntentsTests.testSuggestedBooksAreTheOnesInProgress`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer` | unit | pass |
| `WatchCollectionEntity.init` | 75 | `WatchIntentsTests.testABookEntityNamesTheBookAndItsAuthor`, `WatchIntentsTests.testACollectionEntitySaysWhatItIs` | unit | pass |
| `WatchCollectionQuery.entities` | 84 | `WatchIntentsTests.testBooksAreFoundOnTheWatchThenTheServer`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer` | unit | pass |
| `WatchCollectionQuery.entities` | 105 | `WatchIntentsTests.testBooksAreFoundOnTheWatchThenTheServer`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer` | unit | pass |
| `WatchCollectionQuery.suggestedEntities` | 127 | `WatchIntentsTests.testSuggestedBooksAreTheOnesInProgress`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer` | unit | pass |
| `ResumeAudiobookIntent.perform` | 144 | `WatchIntentsTests.testResumeAudiobookIntentWithNothingToResume`, `WatchIntentsTests.testPlayAudiobookIntentPlaysTheBook`, `WatchIntentsTests.testPlayMusicIntentPlaysTheCollection`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch` (+1 more) | unit | pass |
| `PlayAudiobookIntent.perform` | 161 | `WatchIntentsTests.testResumeAudiobookIntentWithNothingToResume`, `WatchIntentsTests.testPlayAudiobookIntentPlaysTheBook`, `WatchIntentsTests.testPlayMusicIntentPlaysTheCollection`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch` (+1 more) | unit | pass |
| `PlayMusicIntent.perform` | 178 | `WatchIntentsTests.testResumeAudiobookIntentWithNothingToResume`, `WatchIntentsTests.testPlayAudiobookIntentPlaysTheBook`, `WatchIntentsTests.testPlayMusicIntentPlaysTheCollection`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch` (+1 more) | unit | pass |
| `ShuffleMusicIntent.perform` | 190 | `WatchIntentsTests.testResumeAudiobookIntentWithNothingToResume`, `WatchIntentsTests.testPlayAudiobookIntentPlaysTheBook`, `WatchIntentsTests.testPlayMusicIntentPlaysTheCollection`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch` (+1 more) | unit | pass |

## Watch/WatchImages.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchImages.init` | 16 | WatchImagesTests | unit | covered |
| `WatchImages.url` | 21 | `WatchClientTests.testADirectStreamIsLetInByItsHeader`, `WatchClientTests.testATranscodeCarriesTheTokenInItsAddress`, `WatchClientTests.testADownloadIsAnAACEncodeWithTheTokenInAHeader`, `WatchClientTests.testADownloadTheWatchCanPlayIsTheServersOwnFile` (+4 more) | unit | pass |
| `WatchImages.cached` | 32 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `WatchImages.load` | 34 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `WatchImages.forget` | 57 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `Color.init` | 96 | WatchShimsTests.testTheThemeColours | unit | covered |

## Watch/WatchLog.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchLog.rotated` | 39 | through `WatchLog.rotate`, `WatchLog.writeExport` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLog.note` | 44 | `WatchPlayerTests.testTheMinuteNoteNearTheEndIsOnlyAPosition`, `WatchPlayerTests.testABookPausedInItsLastMinutesThenFinishedCountsOnce`, `WatchPlayerTests.testASongIsHeardPastNinetyPercentAndCountedOnce`, `WatchLogTests.testNotesGoToTheFileAndTheExportCarriesThem` (+1 more) | unit | pass |
| `WatchLog.error` | 49 | `WatchDownloadsTests.testEnqueueAgainAddsAReasonAndQueuesAFailureAgain`, `WatchDownloadsTests.testThePhoneGivingUpWithNoNetworkSaysWhy`, `WatchDownloadsTests.testAFailedTransferIsTriedThreeTimes`, `WatchDownloadsTests.testAFailureWithNoWayToTryAgainIsFailedAtOnce` (+11 more) | unit | pass |
| `WatchLog.logger` | 54 | through `WatchLog.note`, `WatchLog.error` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLog.write` | 62 | `WatchWidgetSnapshotTests.testWrittenAndReadThroughTheAppGroup`, `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchLinkTests.testTheRemotesSpeedGoesRound`, `WatchLinkTests.testPiecesJoinInOrderWhicheverOrderTheyArrive` (+6 more) | unit | pass |
| `WatchLog.append` | 69 | `WatchLinkTests.testTheRemotesSpeedGoesRound`, `WatchNavigatorTests.testThePlayerIsPushedOnceAndForgottenOnlyWhenPopped` | unit | pass |
| `WatchLog.rotate` | 87 | through `WatchLog.append` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLog.snapshotSystemLog` | 117 | through `WatchLog.backgrounded`, `WatchLog.export` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLog.beginSnapshot` | 143 | through `WatchLog.snapshotSystemLog` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLog.appendSnapshot` | 151 | through `WatchLog.snapshotSystemLog` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLog.launched` | 162 | `WatchLogTests.testALaunchAfterNoGoodbyeIsNotedAsACrash` | unit | pass |
| `WatchLog.backgrounded` | 177 | `WatchLogTests.testALaunchAfterNoGoodbyeIsNotedAsACrash` | unit | pass |
| `WatchLog.foregrounded` | 183 | `WatchLogTests.testALaunchAfterNoGoodbyeIsNotedAsACrash` | unit | pass |
| `WatchLog.export` | 191 | `WatchLogTests.testNotesGoToTheFileAndTheExportCarriesThem` | unit | pass |
| `WatchLog.writeExport` | 197 | through `WatchLog.export` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLog.fileStamp` | 215 | WatchLogTests | unit | covered |

## Watch/WatchTestMode.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchTestMode.prepare` | 33 | `WatchTestModeTests.testTheUnitHostRunsInTestMode` | unit | pass |
| `WatchTestMode.signIn` | 59 | `WatchHomeTests.testTheBookInProgressIsOfferedToContinue`, `WatchLibraryTests.testAudiobooksAndABooksPage`, `WatchPlaybackTests.testASongPlaysAndTheServerSeesIt`, `WatchPlaybackTests.testPausingABookKeepsItsPlaceOnTheServer` | UI | pass |

## Watch/Shims.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `Languages.name` | 16 | `WatchDownloadsTests.testTheRecordIsWrittenBesideItsFile`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone` (+8 more) | UI + unit | pass |
| `Array.sortedByTrack` | 23 | `WatchShimsTests.testTracksInSleeveOrder` | unit | pass |
| `Array.albumsInOrder` | 34 | `WatchShimsTests.testAlbumsOfSongsOnceEachInOrder` | unit | pass |

## Watch/Views/RootView.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchNavigator.showPlayer` | 50 | `WatchNavigatorTests.testThePlayerIsPushedOnceAndForgottenOnlyWhenPopped` | unit | pass |
| `WatchNavigator.playerLeft` | 58 | `WatchNavigatorTests.testThePlayerIsPushedOnceAndForgottenOnlyWhenPopped` | unit | pass |
| `WatchNavigator.popToRoot` | 62 | `WatchNavigatorTests.testThePlayerIsPushedOnceAndForgottenOnlyWhenPopped` | unit | pass |
| `LibraryHome.load` | 228 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `Door.init` | 287 | drawn on its screen in the UI tests | UI | via screen |
| `WatchDownloads.progress` | 415 | `WatchDownloadsTests.testProgressOfASet`, `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `DownloadButton.act` | 464 | drawn on its screen in the UI tests | UI | via screen |
| `DownloadControl.keep` | 650 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer`, `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds` (+26 more) | unit | pass |
| `DownloadControl.cancel` | 655 | `WatchDownloadsTests.testCancelForgetsAQueuedItem`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchDownloadsTests.testCancellingWhatThePhoneIsFetchingTellsThePhone`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` (+4 more) | unit | pass |
| `DownloadControl.remove` | 659 | `WatchOnWatchGroupsTests.testRemoveByGroup` | unit | pass |

## Watch/Views/LibraryViews.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `BooksView.load` | 66 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `AlbumsView.load` | 328 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `Array.localArtists` | 385 | `WatchShimsTests.testArtistsOfSongsOnceEach` | unit | pass |
| `ArtistDetail.play` | 446 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchActionsTests.testPlayingAnUnknownIdDoesNothing`, `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach` (+3 more) | unit | pass |
| `SongsView.load` | 500 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `SearchView.search` | 688 | `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered` | unit | pass |

## Watch/Views/NowPlayingScreen.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `NowPlayingScreen.claimCrown` | 45 | drawn on its screen in the UI tests | UI | via screen |
| `NowPlayingScreen.content` | 66 | drawn on its screen in the UI tests | UI | via screen |
| `NowPlayingScreen.playing` | 87 | drawn on its screen in the UI tests | UI | via screen |
| `NowPlayingScreen.speedLabel` | 204 | `WatchPlayerTests.testWholeSpeedsReadAsWholeNumbers`, `WatchPlayerTests.testOnePointTwoFiveAndOnePointSevenFiveReadRight` | unit | pass |
| `NowPlayingScreen.subtitle` | 208 | `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchPlayerTests.testTheCardRedrawsOnlyWhenItChanges`, `WatchOnWatchGroupsTests.testGroupsAreWhatWasAskedForEachSongOnce` | unit | pass |
| `VolumePopup.show` | 285 | through `NowPlayingScreen.subtitle` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `CrownVolume.makeWKInterfaceObject` | 303 | drawn on its screen in the UI tests | UI | via screen |
| `CrownVolume.updateWKInterfaceObject` | 309 | drawn on its screen in the UI tests | UI | via screen |
| `CrownVolume.makeCoordinator` | 316 | drawn on its screen in the UI tests | UI | via screen |

## Watch/Views/OnWatchViews.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchDownloads.groups` | 25 | `WatchDownloadsTests.testTheInventoryCountsEachByteOnce`, `WatchOnWatchGroupsTests.testGroupsAreWhatWasAskedForEachSongOnce`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup`, `WatchOnWatchGroupsTests.testCancellingAPlaylistAskedForByHandWithNothingHereTakesItAway` (+2 more) | unit | pass |
| `WatchDownloads.remove` | 65 | `WatchOnWatchGroupsTests.testRemoveByGroup` | unit | pass |
| `WatchDownloads.cancel` | 74 | `WatchDownloadsTests.testCancelForgetsAQueuedItem`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchDownloadsTests.testCancellingWhatThePhoneIsFetchingTellsThePhone`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` (+4 more) | unit | pass |
| `WatchDownloads.retry` | 84 | `WatchDownloadsTests.testRetryQueuesAFailureAgainFromNothing`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` | unit | pass |
| `WatchDownloads.cancelAll` | 91 | `WatchOnWatchGroupsTests.testCancelAllStopsEverythingArriving` | unit | pass |
| `WatchDownloads.queue` | 99 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchPlayerTests.testNextOnTheLastSongStops`, `WatchPlayerTests.testPlayLaterAddsToAQueueThatIsUp` (+2 more) | unit | pass |
| `WatchDownloads.playlistName` | 116 | `WatchOnWatchGroupsTests.testGroupsAreWhatWasAskedForEachSongOnce` | unit | pass |
| `Shelves.p` | 132 | drawn on its screen in the UI tests | UI | via screen |
| `OnWatchView.failedNote` | 225 | drawn on its screen in the UI tests | UI | via screen |
| `OnWatchView.hereNote` | 230 | drawn on its screen in the UI tests | UI | via screen |
| `DownloadQueueView.cancelButton` | 351 | drawn on its screen in the UI tests | UI | via screen |
| `DownloadQueueView.waitingNote` | 357 | drawn on its screen in the UI tests | UI | via screen |
| `WatchSettingsView.serverStatus` | 456 | `WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused`, `WatchClientTests.testSettingsServerLine` | unit | pass |

## Watch/Views/PhoneRemoteViews.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchMode.init` | 45 | drawn on its screen in the UI tests | UI | via screen |
| `PhonePlayerScreen.content` | 222 | drawn on its screen in the UI tests | UI | via screen |
| `PhonePlayerScreen.playing` | 241 | drawn on its screen in the UI tests | UI | via screen |
| `PhonePlayerScreen.nextSpeed` | 357 | `WatchLinkTests.testTheRemotesSpeedGoesRound` | unit | pass |
| `PhonePlayerScreen.speedLabel` | 363 | `WatchPlayerTests.testWholeSpeedsReadAsWholeNumbers`, `WatchPlayerTests.testOnePointTwoFiveAndOnePointSevenFiveReadRight` | unit | pass |
| `PhonePlayerScreen.subtitle` | 367 | `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchPlayerTests.testTheCardRedrawsOnlyWhenItChanges`, `WatchOnWatchGroupsTests.testGroupsAreWhatWasAskedForEachSongOnce` | unit | pass |
| `CompanionCrownVolume.makeWKInterfaceObject` | 423 | drawn on its screen in the UI tests | UI | via screen |
| `CompanionCrownVolume.updateWKInterfaceObject` | 429 | drawn on its screen in the UI tests | UI | via screen |
| `CompanionCrownVolume.makeCoordinator` | 435 | drawn on its screen in the UI tests | UI | via screen |

## WatchWidgets/WatchWidgets.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `ListeningProvider.placeholder` | 23 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual | manual |
| `ListeningProvider.getSnapshot` | 30 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual | manual |
| `ListeningProvider.getTimeline` | 34 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual | manual |

## Shared/WatchSyncTypes.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchSync.pack` | 30 | `WatchLinkTests.testAContextFromThePhoneAsADictionaryDecodes`, `WatchSyncTypesTests.testPackPutsOneJSONPayloadUnderTheOneKey`, `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead`, `WatchPhoneLinkTests.testTheWatchsContextBecomesWhatSettingsShows` (+1 more) | unit | pass |
| `WatchSync.unpack` | 35 | `WatchLinkTests.testAContextFromThePhoneAsADictionaryDecodes`, `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK`, `WatchSyncTypesTests.testUnpackIgnoresAnythingElse`, `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead` | unit | pass |
| `WatchMirrorPlan.init` | 72 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `PhoneContext.init` | 95 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `WatchInventory.init` | 157 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `WatchContext.init` | 208 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `WatchProgressEvent.belongs` | 295 | `WatchSyncTypesTests.testEventsGoOnlyUnderTheirOwnAccount` | unit | pass |
| `PhonePlaybackState.init` | 394 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `PhonePlaybackState.position` | 416 | `WatchWidgetSnapshotTests.testHowFarIn`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward`, `WatchLinkTests.testEachRemoteCommandIsDrawnAtOnce` (+9 more) | unit | pass |
| `WatchDownloadSource.originalExtension` | 463 | `WatchSyncTypesTests.testTheServersOwnFileWhenTheWatchCanPlayIt`, `WatchSyncTypesTests.testAnEncodeWhenTheWatchCantPlayItOrItIsMuchBigger` | unit | pass |
| `WatchDownloadSource.originalQuery` | 473 | `WatchSyncTypesTests.testTheOriginalsQuery` | unit | pass |
| `VideoProgress.isFinished` | 584 | `WatchBookPlaceTests.testFinishedMeansUnderFiveMinutesLeft`, `WatchBookPlaceTests.testVideoProgressFinishedPast90Percent`, `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | pass |
| `BookProgress.isFinished` | 601 | `WatchBookPlaceTests.testFinishedMeansUnderFiveMinutesLeft`, `WatchBookPlaceTests.testVideoProgressFinishedPast90Percent`, `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | pass |
| `BookProgress.isFinished` | 605 | `WatchBookPlaceTests.testFinishedMeansUnderFiveMinutesLeft`, `WatchBookPlaceTests.testVideoProgressFinishedPast90Percent`, `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | pass |
| `BookProgress.isStale` | 611 | `WatchBookPlaceTests.testStaleMeansStartedElsewhereSince` | unit | pass |
| `BookProgress.takesServer` | 619 | `WatchBookPlaceTests.testTakesServer` | unit | pass |
| `BookProgress.date` | 629 | `WatchBookPlaceTests.testTheServersDatesRead` | unit | pass |

## Shared/WatchWidgetSnapshot.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `ListeningSnapshot.read` | 33 | `WatchWidgetSnapshotTests.testWrittenAndReadThroughTheAppGroup`, `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft` | unit | pass |
| `ListeningSnapshot.write` | 38 | `WatchWidgetSnapshotTests.testWrittenAndReadThroughTheAppGroup`, `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchLinkTests.testTheRemotesSpeedGoesRound`, `WatchLinkTests.testPiecesJoinInOrderWhicheverOrderTheyArrive` (+6 more) | unit | pass |

## Aquarium/Core/WatchLink.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchLink.isLong` | 164 | through `WatchLink.pumpFetches` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.init` | 174 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.start` | 200 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.handleFetchEvents` | 220 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.releaseFetchWake` | 229 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.resumeFetches` | 242 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.checkWatch` | 251 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sendContext` | 268 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.pushContext` | 277 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sendPlaylists` | 299 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sendBooks` | 326 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.handOver` | 343 | through `WatchLink.sendDownload` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.syncNow` | 367 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.buildContext` | 391 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.send` | 432 | through `WatchLink.sendDownload`, `WatchLink.fetchFailed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.sendLive` | 447 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.deleteFromWatch` | 454 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.deleteEverythingOnWatch` | 472 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.download` | 496 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.removeWant` | 521 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.forgetWant` | 528 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.persistWants` | 537 | through `WatchLink.reconcileWants`, `WatchLink.apply` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.reconcileWants` | 551 | through `WatchLink.apply` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.sendDownload` | 573 | through `WatchLink.reconcileWants` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.requestInventory` | 598 | `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead` | unit | pass |
| `WatchLink.requestWatchLogs` | 614 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.reloadWatchLogs` | 619 | through `WatchLink.deleteWatchLog`, `WatchLink.take` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.deleteWatchLog` | 630 | `WatchPhoneLinkTests.testTheWatchsLogArrivesInPiecesAndIsKept` | unit | pass |
| `WatchLink.exportPhoneLog` | 638 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.apply` | 665 | `WatchPhoneLinkTests.testTheWatchsContextBecomesWhatSettingsShows`, `WatchPhoneLinkTests.testAnOlderWatchsPlaylistsAreReadFromItsInventory`, `WatchPhoneLinkTests.testSomethingElseInTheContextIsIgnored` | unit | pass |
| `WatchLink.keepsOnWatch` | 687 | `WatchPhoneLinkTests.testTheWatchsContextBecomesWhatSettingsShows` | unit | pass |
| `WatchLink.setKeepsOnWatch` | 694 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.playlistRemovedOnWatch` | 711 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.keepOnly` | 725 | through `WatchLink.apply` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.handle` | 739 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.take` | 758 | `WatchPhoneLinkTests.testTheWatchsLogArrivesInPiecesAndIsKept`, `WatchPhoneLinkTests.testANewerPlaceReplacesAnOlderOneAndALateOldOneIsDropped`, `WatchPhoneLinkTests.testTheSameEventTwiceIsTakenOnce`, `WatchPhoneLinkTests.testPlacesForDifferentAccountsAreKeptApart` (+2 more) | unit | pass |
| `WatchLink.relayFile` | 790 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.resumeFile` | 796 | through `WatchLink.saveResumeData`, `WatchLink.takeResumeData` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.saveResumeData` | 802 | through `WatchLink.stopFetching` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.takeResumeData` | 807 | through `WatchLink.cancelFetch`, `WatchLink.startFetch`, `WatchLink.fetchFailed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.taskInfo` | 815 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.existingRelayFile` | 821 | through `WatchLink.cancelFetch`, `WatchLink.handOver` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.persistFetches` | 827 | through `WatchLink.cancelFetch`, `WatchLink.restartFetch`, `WatchLink.fetchFailed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.enqueueFetch` | 832 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.cancelFetch` | 867 | through `WatchLink.keepOnly` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.stopFetching` | 897 | through `WatchLink.cancelFetch`, `WatchLink.restartFetch` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.restartFetch` | 924 | through `WatchLink.watchForStall` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.watchForStall` | 948 | through `WatchLink.startFetch` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.describe` | 977 | through `WatchLink.watchForStall` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.rejoinFetches` | 989 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.lookUpEstimate` | 1040 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.updateRelay` | 1052 | through `WatchLink.startFetch`, `WatchLink.watchTransfers`, `WatchLink.fetchFailed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.persistRelay` | 1063 | through `WatchLink.cancelFetch`, `WatchLink.updateRelay` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.nameRelayItem` | 1068 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.cancelRelay` | 1088 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.cancelAllRelays` | 1099 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.debugSeedRelayRows` | 1114 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.clearFinishedRelayItems` | 1139 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.pumpFetches` | 1148 | through `WatchLink.cancelFetch`, `WatchLink.restartFetch`, `WatchLink.fetchFailed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.startFetch` | 1162 | through `WatchLink.pumpFetches` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.fetchRequest` | 1219 | through `WatchLink.startFetch` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.estimatedBytes` | 1247 | through `WatchLink.startFetch` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.reportProgress` | 1254 | through `WatchLink.watchTransfers` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.watchTransfers` | 1262 | through `WatchLink.handOver` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.taskItem` | 1279 | through `WatchLink.watchForStall` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.fetchFailed` | 1283 | `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead` | unit | pass |
| `WatchLink.fetched` | 1302 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.forget` | 1331 | through `WatchLink.fetchFailed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.handOver` | 1339 | through `WatchLink.sendDownload` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.piecesFolder` | 1414 | through `WatchLink.handOver` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.removePieces` | 1420 | through `WatchLink.cancelFetch`, `WatchLink.sendFailed` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.cut` | 1428 | through `WatchLink.handOver` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.sentFractions` | 1460 | through `WatchLink.watchTransfers` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.sendFailed` | 1483 | through `WatchLink.handOver` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.take` | 1501 | `WatchPhoneLinkTests.testTheWatchsLogArrivesInPiecesAndIsKept`, `WatchPhoneLinkTests.testANewerPlaceReplacesAnOlderOneAndALateOldOneIsDropped`, `WatchPhoneLinkTests.testTheSameEventTwiceIsTakenOnce`, `WatchPhoneLinkTests.testPlacesForDifferentAccountsAreKeptApart` (+2 more) | unit | pass |
| `WatchLink.takeAndAnswer` | 1523 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.persistPending` | 1534 | through `WatchLink.take`, `WatchLink.settle` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.settle` | 1538 | through `WatchLink.take`, `WatchLink.forward` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.forward` | 1550 | through `WatchLink.take`, `WatchLink.retryForward` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.retryForward` | 1590 | through `WatchLink.forward` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.deliver` | 1611 | through `WatchLink.forward` | unit (indirect) | caller tested (this line may sit behind a guard the test does not open) |
| `WatchLink.session` | 1660 | WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1) | manual | manual |
| `WatchLink.sessionDidBecomeInactive` | 1703 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sessionDidDeactivate` | 1705 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sessionWatchStateDidChange` | 1710 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sessionReachabilityDidChange` | 1720 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.session` | 1727 | WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1) | manual | manual |
| `WatchLink.session` | 1743 | WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1) | manual | manual |
| `WatchLink.session` | 1747 | WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1) | manual | manual |
| `WatchLink.session` | 1777 | WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1) | manual | manual |
| `WatchLink.session` | 1782 | WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1) | manual | manual |
| `WatchLink.session` | 1796 | WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1) | manual | manual |
| `WatchLink.urlSession` | 1838 | the relay's background URLSession: MANUAL.md §1 | manual | manual |
| `WatchLink.urlSession` | 1862 | the relay's background URLSession: MANUAL.md §1 | manual | manual |
| `WatchLink.urlSession` | 1888 | the relay's background URLSession: MANUAL.md §1 | manual | manual |
| `WatchLink.urlSessionDidFinishEvents` | 1938 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchWant.status` | 1955 | `WatchPhoneLinkTests.testAWantsStatusReadsFromTheWatchsReport` | unit | pass |
| `RelayItem.isStuck` | 1996 | `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | pass |

## Aquarium/Core/WatchRemote.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchRemote.init` | 46 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.start` | 48 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.watch` | 73 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.observeState` | 87 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.watchClock` | 112 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.clockMoved` | 128 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.changed` | 148 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.snapshot` | 161 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.state` | 206 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.send` | 232 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.differs` | 256 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.fetchArtwork` | 274 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.loadArtwork` | 288 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.artworkURL` | 303 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.handle` | 313 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |

## Screens and widget views

| View | File | UI tests that open it | Status |
|---|---|---|---|
| `AquariumWatchApp` | Watch/WatchApp.swift:14 | not reached by any test | via its parent screen |
| `Artwork` | Watch/WatchImages.swift:64 | not reached by any test | via its parent screen |
| `RootView` | Watch/Views/RootView.swift:69 | drawn on its screen in the UI tests | via its parent screen |
| `LibraryHome` | Watch/Views/RootView.swift:86 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+34 more) | pass / skip |
| `NowPlayingRow` | Watch/Views/RootView.swift:238 | `WatchPlaybackTests.testTheHomeRowLeadsBackToThePlayer` | pass |
| `DownloadingRow` | Watch/Views/RootView.swift:262 | drawn on its screen in the UI tests | via its parent screen |
| `Door` | Watch/Views/RootView.swift:281 | drawn on its screen in the UI tests | via its parent screen |
| `BookRow` | Watch/Views/RootView.swift:311 | drawn on its screen in the UI tests | via its parent screen |
| `SongRow` | Watch/Views/RootView.swift:333 | drawn on its screen in the UI tests | via its parent screen |
| `CollectionRow` | Watch/Views/RootView.swift:363 | drawn on its screen in the UI tests | via its parent screen |
| `ProgressBar` | Watch/Views/RootView.swift:382 | drawn on its screen in the UI tests | via its parent screen |
| `DownloadButton` | Watch/Views/RootView.swift:436 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` | pass |
| `DownloadMark` | Watch/Views/RootView.swift:475 | drawn on its screen in the UI tests | via its parent screen |
| `DownloadControl` | Watch/Views/RootView.swift:515 | `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch`, `WatchDownloadUITests.testTheQueueOrOnWatchShowsWhatIsArriving` (+2 more) | pass |
| `PlayShuffleBar` | Watch/Views/RootView.swift:671 | `WatchLibraryTests.testAnAlbumsPageListsItsSongsInOrder`, `WatchLibraryTests.testAnArtistsPageListsTheirAlbums`, `WatchPlaybackTests.testPlayPauseNextAndPrevious` | pass |
| `StatusRow` | Watch/Views/RootView.swift:692 | `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch`, `WatchLibraryTests.testAGenresPage` | pass |
| `BooksView` | Watch/Views/LibraryViews.swift:10 | `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch`, `WatchLibraryTests.testAudiobooksAndABooksPage`, `WatchLibraryTests.testTheAudiobooksSortStepsThroughItsOrders` (+8 more) | pass |
| `BookDetail` | Watch/Views/LibraryViews.swift:86 | `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch`, `WatchLibraryTests.testAudiobooksAndABooksPage`, `WatchPlaybackTests.testABookOpensWhereItWasLeftAndItsButtonsMoveIt` (+6 more) | pass |
| `MusicMenu` | Watch/Views/LibraryViews.swift:184 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+12 more) | pass |
| `PlaylistsView` | Watch/Views/LibraryViews.swift:223 | `WatchLibraryTests.testAPlaylistsPage` | pass |
| `AlbumsView` | Watch/Views/LibraryViews.swift:278 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+8 more) | pass / skip |
| `ArtistsView` | Watch/Views/LibraryViews.swift:345 | `WatchLibraryTests.testAnArtistsPageListsTheirAlbums`, `WatchLibraryTests.testArtistsAreTheMusicLibrarysNotTheAudiobooksAuthors` | pass |
| `ArtistDetail` | Watch/Views/LibraryViews.swift:401 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+8 more) | pass / skip |
| `SongsView` | Watch/Views/LibraryViews.swift:454 | `WatchLibraryTests.testAnAlbumsPageListsItsSongsInOrder`, `WatchLibraryTests.testSongsList`, `WatchLibraryTests.testAPlaylistsPage` (+2 more) | pass |
| `SongSwipe` | Watch/Views/LibraryViews.swift:515 | drawn on its screen in the UI tests | via its parent screen |
| `GenresView` | Watch/Views/LibraryViews.swift:534 | `WatchLibraryTests.testAGenresPage` | pass |
| `CollectionDetail` | Watch/Views/LibraryViews.swift:559 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+7 more) | pass |
| `SearchView` | Watch/Views/LibraryViews.swift:632 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+18 more) | pass / skip |
| `NowPlayingScreen` | Watch/Views/NowPlayingScreen.swift:15 | `WatchPlaybackTests.testASongPlaysAndTheServerSeesIt`, `WatchPlaybackTests.testPlayPauseNextAndPrevious`, `WatchPlaybackTests.testTheHomeRowLeadsBackToThePlayer` (+8 more) | pass |
| `VolumePopup` | Watch/Views/NowPlayingScreen.swift:243 | drawn on its screen in the UI tests | via its parent screen |
| `CrownVolume` | Watch/Views/NowPlayingScreen.swift:300 | drawn on its screen in the UI tests | via its parent screen |
| `OnWatchView` | Watch/Views/OnWatchViews.swift:121 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` | pass |
| `GroupLink` | Watch/Views/OnWatchViews.swift:248 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch`, `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch` | pass |
| `GroupRow` | Watch/Views/OnWatchViews.swift:264 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner` | pass |
| `DownloadQueueView` | Watch/Views/OnWatchViews.swift:298 | drawn on its screen in the UI tests | via its parent screen |
| `QueueRow` | Watch/Views/OnWatchViews.swift:369 | drawn on its screen in the UI tests | via its parent screen |
| `StorageLine` | Watch/Views/OnWatchViews.swift:405 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchHomeTests.testSettingsShowsTheAccountTheServerAndThePhone` | pass |
| `WatchSettingsView` | Watch/Views/OnWatchViews.swift:447 | `WatchHomeTests.testSettingsShowsTheAccountTheServerAndThePhone`, `WatchHomeTests.testSettingsSignedOut`, `WatchHomeTests.testSyncNowRunsWithNothingToSync` | pass |
| `SourceSwitch` | Watch/Views/PhoneRemoteViews.swift:53 | `WatchHomeTests.testTheSwitchShowsThePhonesSideAndBack`, `WatchHomeTests.testTheChoiceOfSideIsRemembered` | pass |
| `PhoneNowPlayingRow` | Watch/Views/PhoneRemoteViews.swift:88 | drawn on its screen in the UI tests | via its parent screen |
| `PhoneArtwork` | Watch/Views/PhoneRemoteViews.swift:112 | drawn on its screen in the UI tests | via its parent screen |
| `PhoneIdleRow` | Watch/Views/PhoneRemoteViews.swift:140 | `WatchHomeTests.testTheSwitchShowsThePhonesSideAndBack` | pass |
| `PhonePlayerScreen` | Watch/Views/PhoneRemoteViews.swift:181 | drawn on its screen in the UI tests | via its parent screen |
| `PhoneVolumePopup` | Watch/Views/PhoneRemoteViews.swift:375 | drawn on its screen in the UI tests | via its parent screen |
| `CompanionCrownVolume` | Watch/Views/PhoneRemoteViews.swift:420 | drawn on its screen in the UI tests | via its parent screen |
| `AquariumWatchWidgets` | WatchWidgets/WatchWidgets.swift:11 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |
| `ListeningProvider` | WatchWidgets/WatchWidgets.swift:22 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |
| `ListeningWidget` | WatchWidgets/WatchWidgets.swift:39 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |
| `ListeningWidgetView` | WatchWidgets/WatchWidgets.swift:51 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |

## Totals

Functions listed: 450. Reached by a unit test: 337; by UI tests only: 25;
manual (real hardware or the system's UI): 88; reached by nothing: 0.

## Regression tests and known bugs

Each regression test names its source in a comment. The seven bugs the suite found
were fixed on `claude/fix-watch` (2026-11-13) and their `XCTExpectFailure` wrappers
removed; none is kept as an expected failure now.

| Test | Source | Result here |
|---|---|---|
| `WatchBookPlaceTests.testABooksEarlyPlaceSurvivesTheServersZero`, `…AnUndatedZero`, `testRefreshKeepsAnEarlyPlace` | master-fix-list top priority; fixed in `WatchDownloads.applyServerState` (`serverHasHeldPlace`) | pass |
| `WatchBookPlaceTests.testAZeroAfterTheServerHeldAPlaceIsAReset`, `testAZeroPastTheEarlyWindowIsAReset` | dec4915 (telling early 0 from a reset) | pass |
| `WatchPlayerTests.testTheSpeedGoesRoundFromTheTop`, `testOnePointTwoFiveAndOnePointSevenFiveReadRight`; `WatchPlaybackTests.testTheSpeedButtonStepsThroughEverySpeed` | master-fix-list; fixed in `WatchPlayer.stepSpeed` and the two `speedLabel`s (`%g`) | pass |
| `WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused` | master-fix-list "Connected while 401"; fixed: `JellyfinClient.signInRefused`, row reads "Sign-in expired" | pass |
| `WatchLibraryTests.testArtistsAreTheMusicLibrarysNotTheAudiobooksAuthors` | master-fix-list (Mary Shelley); fixed: `albumArtists` asks `IncludeItemTypes=Audio` | pass |
| `WatchLibraryTests.testTheAudiobooksSortControlCoversNoRow` | master-fix-list sort button; fixed: the sort is a row at the head of the list (strict now) | pass |
| `WatchLibraryTests.testTheAlbumsSortControlCoversNoRow` | master-fix-list sort button (Albums half); fixed: the sort is a row at the head of the list | pass |
| `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch` | found here: detached meta.json write vs cancel; fixed: `metaGeneration` orders writes and removals (strict now; 20/20 runs) | pass |
| `WatchDownloadsTests.testThePathMonitorsWordAloneNeverTakesBackFromThePhone`, `testWithThePathMonitorDownTheWatchNeverTakesItBack` | 05ce303 (1,418 cancels); watch-network-reality | pass |
| `WatchDownloadsTests.testAShortFileIsThrownAwayAndAskedForAgainThreeTimes` | WatchDownloads header; duo-device-download-forensics | pass |
| `WatchDownloadsTests.testAPlaylistThePhoneSwitchedOffIsNotToldBack` | c08deb9 | pass |
| `WatchWantsTests.testAnItemCancelledByHandStaysCancelled` | WatchDownloads.declined note; 49da046 | pass |
| `WatchSyncQueueTests.testThePhoneSettlesOnlyWhatItNames`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped`, `testAStreamedPlayIsAStoppedReportNotASecondPlay`, `testRestartingAFinishedBookMarksItUnplayedFirst`, `WatchPlayerTests.testAPauseBeforeTheSeekLandsWritesNothing`, `testTheMinuteNoteNearTheEndIsOnlyAPosition` | 1228f45 | pass |
| `WatchPlayerTests.testABookPausedInItsLastMinutesThenFinishedCountsOnce`, `testNextOnTheLastSongStops`; `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward` | f72bd13 | pass |
| `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes` | f66fe9c | pass |
| `WatchSyncTypesTests.testEventsGoOnlyUnderTheirOwnAccount`, `WatchSyncQueueTests.testAnotherAccountsEventWaits` | e929365 | pass |
| `WatchLinkTests.testACancelOnThePhoneIsACancelHere`, `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | 3a32a24 | pass |
| `WatchActionsTests.testResumeWithNoBookSaysThereIsNone` | master-fix-list "Resume Audiobook does nothing" (the action's half; the idle screen's note is MANUAL.md) | pass |
| `WatchPlaybackTests.testPausingABookKeepsItsPlaceOnTheServer` | qa-server-short-title-resume (resume tested past 5 min) | pass |
