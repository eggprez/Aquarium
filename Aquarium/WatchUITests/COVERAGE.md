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
| `WatchDelegate.handle` | 78 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testOtherLinksAreIgnored`, `WatchLinkTests.testDeleteMessagesGoByGroup` (+6 more) | unit | pass |
| `WatchDelegate.scheduleRefresh` | 122 | through `WatchDelegate.handle` | unit (indirect) | pass (through its callers) |
| `WatchActions.handle` | 138 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testOtherLinksAreIgnored`, `WatchLinkTests.testDeleteMessagesGoByGroup` (+6 more) | unit | pass |
| `WatchActions.resumeBook` | 155 | `WatchActionsTests.testResumeCarriesOnAPausedBook`, `WatchActionsTests.testResumeTakesTheServersBookInProgress`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testResumeWithNoBookSaysThereIsNone` | unit | pass |
| `WatchActions.play` | 175 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchActionsTests.testPlayingAnUnknownIdDoesNothing`, `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach` (+3 more) | unit | pass |
| `WatchActions.songs` | 194 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `WatchActions.refreshBookPositions` | 224 | `WatchBookPlaceTests.testRefreshAsksForTheBooksOnTheWatchAndAppliesThem`, `WatchBookPlaceTests.testRefreshAsksNothingOfflineSignedOutOrWithNoBooks`, `WatchBookPlaceTests.testRefreshWithATimeoutReturnsWhatCameInTime`, `WatchBookPlaceTests.testRefreshKeepsAnEarlyPlace` | unit | expected failure / pass |

## Watch/WatchClient.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `JellyfinClient.makeSession` | 89 | through `JellyfinClient.useTestProtocols` | unit (indirect) | pass (through its callers) |
| `JellyfinClient.useTestProtocols` | 105 | `WatchClientTests.testAPositionInTheLastFiveMinutesOfAFinishedBookLeavesItFinished` | unit | pass |
| `JellyfinClient.load` | 114 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `JellyfinClient.init` | 121 | the singleton, made at host launch; its device id: WatchClientTests.testTheWatchIsItsOwnDeviceToTheServer | unit | covered |
| `JellyfinClient.install` | 138 | `WatchClientTests.testTheSameAccountAgainOnlyRefreshesTheToken`, `WatchLinkTests.testDeleteMessagesGoByGroup`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchLinkTests.testACancelOnThePhoneIsACancelHere` (+2 more) | unit | not run / pass |
| `JellyfinClient.signOut` | 152 | `WatchBookPlaceTests.testRefreshAsksNothingOfflineSignedOutOrWithNoBooks`, `WatchClientTests.testSignOutForgetsAccountAndToken`, `WatchClientTests.testNothingIsAskedSignedOut`, `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce` (+1 more) | unit | pass |
| `JellyfinClient.keychainAccount` | 159 | through `JellyfinClient.install`, `JellyfinClient.signOut` | unit (indirect) | pass (through its callers) |
| `JellyfinClient.pathId` | 170 | `WatchClientTests.testPathIdsAreEscapedOnlyWhenTheyNeedIt` | unit | pass |
| `JellyfinClient.encode` | 176 | `WatchWidgetSnapshotTests.testTheSnapshotRoundTrips`, `WatchClientTests.testQueriesEscapeThePlusSign`, `WatchDownloadsTests.testTheInventoryIsCutToFitAMessage`, `WatchSyncTypesTests.testFileContentsRoundTrip` | unit | pass |
| `JellyfinClient.authorizationHeader` | 182 | through `JellyfinClient.authHeaders`, `JellyfinClient.request` | unit (indirect) | pass (through its callers) |
| `JellyfinClient.authHeaders` | 194 | through `JellyfinClient.stream`, `JellyfinClient.downloadRequest` | unit (indirect) | pass (through its callers) |
| `JellyfinClient.authorized` | 211 | `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce` | unit | pass |
| `JellyfinClient.request` | 223 | `WatchClientTests.testNothingIsAskedSignedOut`, `WatchSyncTypesTests.testFileContentsRoundTrip` | unit | pass |
| `JellyfinClient.get` | 262 | through `JellyfinClient.items`, `JellyfinClient.item`, `JellyfinClient.resumeAudio` | unit (indirect) | pass (through its callers) |
| `JellyfinClient.decode` | 273 | `WatchWidgetSnapshotTests.testTheSnapshotRoundTrips`, `WatchDownloadsTests.testTheRecordIsWrittenBesideItsFile`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads`, `WatchLinkTests.testTheContextCarriesThePlanToTheDownloads` (+11 more) | unit | not run / pass |
| `JellyfinClient.checkOnline` | 279 | `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch` (+10 more) | unit | pass |
| `JellyfinClient.items` | 311 | `WatchClientTests.testATransportFailureIsOfflineAndAnAnswerIsBackOnline`, `WatchClientTests.testA401IsAnExpiredSignInNotAnOutage`, `WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused`, `WatchClientTests.testOtherErrorsCarryTheirStatus` (+9 more) | unit | expected failure / pass |
| `JellyfinClient.item` | 336 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchClientTests.testUnreadableAnswersSaySo`, `WatchClientTests.testOneItemWithEverythingAPageNeeds` (+2 more) | unit | pass |
| `JellyfinClient.items` | 342 | `WatchClientTests.testATransportFailureIsOfflineAndAnAnswerIsBackOnline`, `WatchClientTests.testA401IsAnExpiredSignInNotAnOutage`, `WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused`, `WatchClientTests.testOtherErrorsCarryTheirStatus` (+9 more) | unit | expected failure / pass |
| `JellyfinClient.resumeAudio` | 354 | `WatchClientTests.testResumeAudioAsksForAudioInProgress` | unit | pass |
| `JellyfinClient.recentlyPlayedSongs` | 367 | `WatchClientTests.testRecentlyPlayedSongs` | unit | pass |
| `JellyfinClient.albums` | 373 | `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testListsThePagesRead`, `WatchNavigatorTests.testRoutesCompareByWhatTheyShow` | unit | pass |
| `JellyfinClient.albumTracks` | 377 | `WatchClientTests.testAlbumTracksComeInSleeveOrder`, `WatchDownloadsTests.testListsThePagesRead` | unit | pass |
| `JellyfinClient.albumArtists` | 381 | `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchLibraryTests.testArtistsAreTheMusicLibrarysNotTheAudiobooksAuthors` | UI + unit | not run / pass |
| `JellyfinClient.albums` | 396 | `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testListsThePagesRead`, `WatchNavigatorTests.testRoutesCompareByWhatTheyShow` | unit | pass |
| `JellyfinClient.songs` | 402 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `JellyfinClient.genres` | 408 | `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchLibraryTests.testAGenresPage` | UI + unit | not run / pass |
| `JellyfinClient.songs` | 421 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `JellyfinClient.songs` | 427 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchClientTests.testAlbumsArtistsGenresAndSongs`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testAWholeFileIsBelieved` (+6 more) | unit | pass |
| `JellyfinClient.randomSongs` | 433 | `WatchClientTests.testAlbumsArtistsGenresAndSongs` | unit | pass |
| `JellyfinClient.playlists` | 437 | `WatchClientTests.testPlaylistsLeaveOutOnlyWhatPlainlyIsntMusic`, `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered`, `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testRemovingAPlaylistTellsThePhoneUnlessThePhoneAsked` (+8 more) | UI + unit | not run / pass |
| `JellyfinClient.playlistItems` | 446 | `WatchClientTests.testPlaylistItemsInTheirOwnOrderWithTheWebFallback`, `WatchClientStubURLProtocolTests.testAPlaylistsSongsDecode` | unit | pass |
| `JellyfinClient.audiobooks` | 472 | `WatchClientTests.testAlbumsArtistsGenresAndSongs` | unit | pass |
| `JellyfinClient.search` | 486 | `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered` | unit | pass |
| `JellyfinClient.query` | 487 | `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce`, `WatchClientTests.testItemsQueryCarriesEverythingAsked`, `WatchClientTests.testOneItemWithEverythingAPageNeeds`, `WatchClientTests.testItemsByIdGoFiftyAtATime` (+11 more) | unit | not run / pass |
| `JellyfinClient.imageURL` | 508 | `WatchClientTests.testNothingIsAskedSignedOut`, `WatchClientTests.testImageAddressesFallBackFromItemToAlbum` | unit | pass |
| `JellyfinClient.ladder` | 523 | through `JellyfinClient.imageURL` | unit (indirect) | pass (through its callers) |
| `JellyfinClient.stream` | 563 | `WatchClientTests.testADirectStreamIsLetInByItsHeader`, `WatchClientTests.testATranscodeCarriesTheTokenInItsAddress`, `WatchClientTests.testAStreamTheClientCantUseIsAnError` | unit | pass |
| `JellyfinClient.stopTranscode` | 605 | `WatchClientTests.testStoppingATranscodeNamesThisDeviceAndSession` | unit | pass |
| `JellyfinClient.downloadRequest` | 621 | `WatchClientTests.testNothingIsAskedSignedOut`, `WatchClientTests.testADownloadIsAnAACEncodeWithTheTokenInAHeader`, `WatchClientTests.testADownloadTheWatchCanPlayIsTheServersOwnFile` | unit | pass |
| `JellyfinClient.estimatedBytes` | 648 | `WatchClientTests.testTheSizeOfADownloadComesFromItsLength`, `WatchDownloadsTests.testPhoneProgressMovesTheBarAndStartsItsPatienceAgain`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchOnWatchGroupsTests.testTheQueueShowsWhatMovesThenWhatWaitsInTheOrderItWillStart` (+1 more) | unit | pass |
| `JellyfinClient.reportStopped` | 669 | `WatchClientTests.testAPositionIsAStoppedReport` | unit | pass |
| `JellyfinClient.reportPlaying` | 690 | `WatchClientTests.testBestEffortRequestsDontChangeTheState`, `WatchClientTests.testLiveReportsNameStartAndProgress` | unit | pass |
| `JellyfinClient.markPlayed` | 701 | `WatchClientTests.testAPlayIsCountedWithItsDate` | unit | pass |
| `JellyfinClient.markUnplayed` | 707 | `WatchClientTests.testAPlayIsCountedWithItsDate` | unit | pass |
| `JellyfinClient.send` | 721 | `WatchClientTests.testAPlayIsCountedWithItsDate`, `WatchClientTests.testASongHeardOffTheWatchIsCountedAsAPlay`, `WatchClientTests.testAStreamedPlayIsAStoppedReportNotASecondPlay`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped` (+3 more) | unit | pass |
| `AnyEncodable.init` | 749 | every POST body (WatchClientTests reports, PlaybackInfo) | unit | covered |
| `AnyEncodable.encode` | 750 | `WatchWidgetSnapshotTests.testTheSnapshotRoundTrips`, `WatchClientTests.testQueriesEscapeThePlusSign`, `WatchDownloadsTests.testTheInventoryIsCutToFitAMessage`, `WatchSyncTypesTests.testFileContentsRoundTrip` | unit | pass |
| `WatchKeychain.query` | 760 | `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce`, `WatchClientTests.testItemsQueryCarriesEverythingAsked`, `WatchClientTests.testOneItemWithEverythingAPageNeeds`, `WatchClientTests.testItemsByIdGoFiftyAtATime` (+11 more) | unit | not run / pass |
| `WatchKeychain.store` | 768 | `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` | unit | pass |
| `WatchKeychain.token` | 780 | `WatchClientTests.testInstallSignsInAndKeepsTheTokenOutOfTheAccount`, `WatchClientTests.testTheSameAccountAgainOnlyRefreshesTheToken`, `WatchClientTests.testSignOutForgetsAccountAndToken`, `WatchClientTests.testTheTokenRidesInATranscodeAddressOnce` (+5 more) | unit | pass |
| `WatchKeychain.delete` | 794 | `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testAPlaylistThePhoneSwitchedOffIsNotToldBack`, `WatchDownloadsTests.testADeleteFromThePhoneGoesByGroup`, `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` (+1 more) | unit | pass |

## Watch/WatchDownloads.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchRecord.init` | 82 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads` | unit | pass |
| `WatchRecord.init` | 106 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads` | unit | pass |
| `WatchDownloads.init` | 289 | the singleton, made at host launch (loads records, plan, wants) | unit | covered |
| `WatchDownloads.folder` | 355 | `WatchDownloadsTests.testTheRecordIsWrittenBesideItsFile`, `WatchDownloadsTests.testWhatIsAlreadyComingTakesItsRoomFirst`, `WatchDownloadsTests.testAWholeFileIsBelieved`, `WatchDownloadsTests.testAFileWithinThreePercentIsWhole` (+21 more) | unit | expected failure / pass |
| `WatchDownloads.artFile` | 359 | `WatchImagesTests.testTheCoverBesideADownloadIsUsedFirst`, `WatchImagesTests.testAFileCoverLoadsAndIsCached`, `WatchImagesTests.testARecordWithACoverOnDiskSaysSo` | unit | pass |
| `WatchDownloads.loadRecords` | 363 | read once in init; a relaunch keeping state is WatchPlaybackTests.testPausingABookKeepsItsPlaceOnTheServer | manual | manual |
| `WatchDownloads.loadWants` | 386 | read once in init (wants.json is checked written: WatchWantsTests.testTheWantsListSurvivesOnDisk) | manual | manual |
| `WatchDownloads.saveWants` | 393 | through `WatchDownloads.dropWant`, `WatchDownloads.checkWants`, `WatchDownloads.keep` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.loadPlaylists` | 399 | read once in init | manual | manual |
| `WatchDownloads.reindex` | 404 | through `WatchDownloads.save`, `WatchDownloads.enqueue`, `WatchDownloads.deleteEverything` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.save` | 409 | through `WatchDownloads.retry`, `WatchDownloads.withdraw`, `WatchDownloads.deleteAlbum` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.savePlaylists` | 424 | through `WatchDownloads.delete`, `WatchDownloads.deletePlaylist`, `WatchDownloads.deleteEverything` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.persistTasks` | 429 | through `WatchDownloads.deleteEverything`, `WatchDownloads.finishActive` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.changed` | 433 | through `WatchDownloads.save`, `WatchDownloads.savePlaylists`, `WatchDownloads.enqueue` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.record` | 440 | `WatchBookPlaceTests.testNotingAPlaceMarksItForTheServer`, `WatchBookPlaceTests.testUnderFiveMinutesLeftIsFinished`, `WatchBookPlaceTests.testStartingAFinishedBookAgainIsNotFinished`, `WatchBookPlaceTests.testASongPast98PercentIsHeard` (+67 more) | unit | expected failure / pass |
| `WatchDownloads.isComplete` | 444 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason` | unit | pass |
| `WatchDownloads.isStarting` | 447 | through WatchDownloads.queue (WatchOnWatchGroupsTests) | unit | covered |
| `WatchDownloads.isQueuedOrRunning` | 449 | `WatchDownloadsTests.testEnqueueKeepsAudioOnceWithItsReason` | unit | pass |
| `WatchDownloads.mediaURL` | 454 | `WatchDownloadsTests.testAWholeFileIsBelieved`, `WatchDownloadsTests.testAMissingFileIsNoMediaURL` | unit | pass |
| `WatchDownloads.fraction` | 461 | `WatchWidgetSnapshotTests.testHowFarIn`, `WatchDownloadsTests.testPhoneProgressMovesTheBarAndStartsItsPatienceAgain`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord` | unit | pass |
| `WatchDownloads.albumTracks` | 488 | `WatchClientTests.testAlbumTracksComeInSleeveOrder`, `WatchDownloadsTests.testListsThePagesRead` | unit | pass |
| `WatchDownloads.playlistSongs` | 492 | WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch | unit | covered |
| `WatchDownloads.freeBytes` | 496 | `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes` | unit | pass |
| `WatchDownloads.enqueue` | 509 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch` (+91 more) | unit | expected failure / pass |
| `WatchDownloads.writeMeta` | 548 | `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch` | unit | expected failure |
| `WatchDownloads.retry` | 559 | `WatchDownloadsTests.testRetryQueuesAFailureAgainFromNothing`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` | unit | pass |
| `WatchDownloads.retryAllFailed` | 569 | `WatchDownloadsTests.testRetryQueuesAFailureAgainFromNothing` | unit | pass |
| `WatchDownloads.cancel` | 574 | `WatchDownloadsTests.testCancelForgetsAQueuedItem`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchDownloadsTests.testCancellingWhatThePhoneIsFetchingTellsThePhone`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` (+4 more) | unit | expected failure / pass |
| `WatchDownloads.persistDeclined` | 589 | through `WatchDownloads.cancel`, `WatchDownloads.dropWant`, `WatchDownloads.deleteEverything` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.delete` | 595 | `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testAPlaylistThePhoneSwitchedOffIsNotToldBack`, `WatchDownloadsTests.testADeleteFromThePhoneGoesByGroup`, `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` (+1 more) | unit | pass |
| `WatchDownloads.withdraw` | 607 | through `WatchDownloads.deletePlaylist`, `WatchDownloads.syncPlaylist` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.deleteBook` | 621 | through `WatchDownloads.delete` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.deleteAlbum` | 626 | `WatchDownloadsTests.testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds`, `WatchWantsTests.testRemovingAnAlbumOfAnArtistLetsTheArtistWantGoButKeepsItsOtherAlbums`, `WatchWantsTests.testAWantTakenOffHereIsntPutBackByAPlanThatStillNamesIt`, `WatchWantsTests.testAPlanThatNoLongerNamesADroppedWantEndsTheGrace` | unit | pass |
| `WatchDownloads.deletePlaylist` | 652 | `WatchDownloadsTests.testRemovingAPlaylistTellsThePhoneUnlessThePhoneAsked`, `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan` | unit | pass |
| `WatchDownloads.dropped` | 665 | through `WatchDownloads.deletePlaylist`, `WatchDownloads.deleteEverything` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.persistDropped` | 675 | through `WatchDownloads.dropped`, `WatchDownloads.dropWant`, `WatchDownloads.deleteEverything` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.dropWant` | 689 | through `WatchDownloads.cancel`, `WatchDownloads.deleteBook`, `WatchDownloads.deleteAlbum` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.forgetWants` | 724 | `WatchWantsTests.testAGroupCancelledByHandForgetsItsWantButKeepsWhatArrived` | unit | pass |
| `WatchDownloads.forgetWants` | 736 | `WatchWantsTests.testAGroupCancelledByHandForgetsItsWantButKeepsWhatArrived` | unit | pass |
| `WatchDownloads.deleteWant` | 747 | `WatchSyncTypesTests.testEveryMessageRoundTrips`, `WatchWantsTests.testAWantTakenOffOnThePhoneLetsGoWithoutAWordBack`, `WatchWantsTests.testAWantsItemsKeptForSomethingElseStay` | unit | pass |
| `WatchDownloads.isDroppedWant` | 752 | through `WatchDownloads.checkWants` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.lookUp` | 757 | through `WatchDownloads.checkWants`, `WatchDownloads.download` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.checkWants` | 780 | through `WatchDownloads.mirror` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.wantStates` | 818 | `WatchWantsTests.testAWantWithNoContentsIsLookedUpOnTheServer`, `WatchWantsTests.testAWantThatCantBeLookedUpAsksThePhoneToSendItAgain`, `WatchWantsTests.testOfflineTheServerIsNotAsked`, `WatchWantsTests.testWantStatesReportHowFarEachHasGot` (+1 more) | unit | not run / pass |
| `WatchDownloads.deleteLooseSongs` | 842 | `WatchDownloadsTests.testRemovingLooseSongsLeavesAlbums` | unit | pass |
| `WatchDownloads.deleteEverything` | 851 | `WatchDownloadsTests.testRemovingEverythingLetsTheWantsAndPlaylistsGoOnBothSides` | unit | pass |
| `WatchDownloads.removeFolder` | 873 | through `WatchDownloads.cancel`, `WatchDownloads.delete`, `WatchDownloads.withdraw` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.noteProgress` | 891 | `WatchBookPlaceTests.testNotingAPlaceMarksItForTheServer`, `WatchBookPlaceTests.testUnderFiveMinutesLeftIsFinished`, `WatchBookPlaceTests.testStartingAFinishedBookAgainIsNotFinished`, `WatchBookPlaceTests.testASongPast98PercentIsHeard` (+15 more) | unit | expected failure / pass |
| `WatchDownloads.markSynced` | 913 | `WatchBookPlaceTests.testMarkSyncedOnlyCoversWhatTheServerHeard` | unit | pass |
| `WatchDownloads.unsentBookEvents` | 923 | `WatchBookPlaceTests.testABookNotedButNeverQueuedGoesFromItsRecord`, `WatchBookPlaceTests.testTheBookPlayingNowIsLeftToThePlayer` | unit | pass |
| `WatchDownloads.applyServerState` | 938 | `WatchBookPlaceTests.testASyncedBookTakesTheServersPlace`, `WatchBookPlaceTests.testListeningNotYetToldWinsOverAnOlderServer`, `WatchBookPlaceTests.testANewerPlayElsewhereWinsOverListeningNotYetTold`, `WatchBookPlaceTests.testAnEventStillQueuedKeepsTheWatchsPlace` (+6 more) | unit | expected failure / pass |
| `WatchDownloads.pump` | 983 | `WatchDownloadsTests.testAskedForThingsGoBeforeTheMirrors`, `WatchDownloadsTests.testAQuietPhoneInReachIsAskedAgainLessOftenEachTime`, `WatchDownloadsTests.testAPhoneAwayIsAskedAgainOnlyOnceItsPatienceRunsOut`, `WatchDownloadsTests.testWithThePathMonitorDownTheWatchNeverTakesItBack` (+3 more) | unit | pass |
| `WatchDownloads.phoneGaveUpOn` | 1007 | local to pump: testThePhoneGivingUpWithANetworkLetsTheWatchTry | unit | covered |
| `WatchDownloads.syncNow` | 1055 | `WatchDownloadsTests.testSyncNowAsksThePhoneAgainForEverythingAwaiting` | unit | pass |
| `WatchDownloads.reaskPhone` | 1075 | `WatchDownloadsTests.testAPhoneAwayIsAskedAgainOnlyOnceItsPatienceRunsOut` | unit | pass |
| `WatchDownloads.handOffToPhone` | 1104 | on the way to the background (scene phase); it is one call to pump, which is unit-tested | manual | manual |
| `WatchDownloads.makeRoom` | 1116 | through `WatchDownloads.pump` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.notePhoneProgress` | 1151 | `WatchDownloadsTests.testPhoneProgressMovesTheBarAndStartsItsPatienceAgain`, `WatchOnWatchGroupsTests.testTheQueueShowsWhatMovesThenWhatWaitsInTheOrderItWillStart` | unit | pass |
| `WatchDownloads.phoneStillAtIt` | 1160 | through `WatchDownloads.notePhoneProgress` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.phoneFailed` | 1172 | `WatchDownloadsTests.testThePhoneGivingUpWithNoNetworkSaysWhy`, `WatchDownloadsTests.testThePhoneGivingUpWithANetworkLetsTheWatchTry`, `WatchDownloadsTests.testAPhoneFailureForSomethingNotAskedIsIgnored` | unit | pass |
| `WatchDownloads.receivedFromPhone` | 1193 | `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchDownloadsTests.testASecondDeliveryLeavesTheFileThatIsThere`, `WatchDownloadsTests.testAFileFromThePhoneForNothingIsRemoved`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed` (+2 more) | unit | pass |
| `WatchDownloads.start` | 1223 | the watch's own transfer: WatchDownloadUITests (straight from the server) | UI | via screen |
| `WatchDownloads.cancelActiveTask` | 1260 | through `WatchDownloads.cancel`, `WatchDownloads.delete`, `WatchDownloads.withdraw` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.taskItem` | 1269 | through `WatchDownloads.cancelActiveTask` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.rejoin` | 1275 | runs once at launch against the background session; relaunch mid-download, MANUAL.md §1.5 | manual | manual |
| `WatchDownloads.handleBackgroundEvents` | 1301 | background session wake; MANUAL.md §7 | manual | manual |
| `WatchDownloads.releaseBackgroundWake` | 1306 | background session wake; MANUAL.md §7 | manual | manual |
| `WatchDownloads.landed` | 1323 | `WatchDownloadsTests.testWhatIsAlreadyComingTakesItsRoomFirst`, `WatchDownloadsTests.testAWholeFileIsBelieved`, `WatchDownloadsTests.testAFileWithinThreePercentIsWhole`, `WatchDownloadsTests.testAShortFileIsThrownAwayAndAskedForAgainThreeTimes` (+6 more) | unit | pass |
| `WatchDownloads.failed` | 1369 | `WatchDownloadsTests.testThePhoneGivingUpWithNoNetworkSaysWhy`, `WatchDownloadsTests.testAFailedTransferIsTriedThreeTimes`, `WatchDownloadsTests.testAFailureWithNoWayToTryAgainIsFailedAtOnce`, `WatchDownloadsTests.testAFailureHereGoesToThePhoneNext` (+2 more) | unit | not run / pass |
| `WatchDownloads.finishActive` | 1388 | through `WatchDownloads.landed`, `WatchDownloads.failed` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.cacheArt` | 1398 | through `WatchDownloads.landed` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.apply` | 1415 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+20 more) | unit | not run / pass |
| `WatchDownloads.mirror` | 1453 | `WatchSyncTypesTests.testRepliesRoundTrip`, `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchWantsTests.testAnItemHereForSomethingElseIsClaimedForTheWantToo`, `WatchWantsTests.testAFailedItemIsRetriedOnceAnHourNotOnEveryPass` (+4 more) | unit | not run / pass |
| `WatchDownloads.mirrorSettled` | 1489 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+13 more) | unit | pass |
| `WatchDownloads.syncPlaylist` | 1502 | through `WatchDownloads.mirror` | unit (indirect) | pass (through its callers) |
| `WatchDownloads.receivedFromPhone` | 1552 | `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchDownloadsTests.testASecondDeliveryLeavesTheFileThatIsThere`, `WatchDownloadsTests.testAFileFromThePhoneForNothingIsRemoved`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed` (+2 more) | unit | pass |
| `WatchDownloads.receivedFromPhone` | 1563 | `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchDownloadsTests.testASecondDeliveryLeavesTheFileThatIsThere`, `WatchDownloadsTests.testAFileFromThePhoneForNothingIsRemoved`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed` (+2 more) | unit | pass |
| `WatchDownloads.keep` | 1572 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer`, `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds` (+26 more) | unit | pass |
| `WatchDownloads.inventory` | 1591 | `WatchDownloadsTests.testTheInventoryCountsEachByteOnce`, `WatchDownloadsTests.testTheInventoryIsCutToFitAMessage`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchPhoneLinkTests.testTheWatchsContextBecomesWhatSettingsShows` | unit | not run / pass |
| `WatchDownloads.delete` | 1645 | `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testAPlaylistThePhoneSwitchedOffIsNotToldBack`, `WatchDownloadsTests.testADeleteFromThePhoneGoesByGroup`, `WatchTestModeTests.testTokensStayOutOfTheKeychainInTestMode` (+1 more) | unit | pass |
| `WatchDownloads.download` | 1655 | `WatchSyncTypesTests.testEveryMessageRoundTrips`, `WatchWantsTests.testADownloadMessageLooksItUpAndKeepsIt`, `WatchWantsTests.testADownloadThatCantBeLookedUpIsLeft` | unit | pass |
| `WatchDownloads.keep` | 1664 | `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch`, `WatchIntentsTests.testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer`, `WatchDownloadsTests.testDeleteRemovesTheFileAndItsPlaceInPlaylists`, `WatchDownloadsTests.testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds` (+26 more) | unit | pass |
| `WatchDownloads.testSetNetwork` | 1697 | `WatchDownloadsTests.testAPhoneAwayPastItsPatienceHandsTheItemToTheWatch`, `WatchDownloadsTests.testThePathMonitorsWordAloneNeverTakesBackFromThePhone`, `WatchDownloadsTests.testThePhoneGivingUpWithANetworkLetsTheWatchTry`, `WatchDownloadsTests.testAFailedTransferIsTriedThreeTimes` (+7 more) | unit | pass |
| `WatchDownloads.testUpdate` | 1706 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch` (+55 more) | unit | expected failure / pass |
| `WatchDownloads.testSetWantRetried` | 1713 | `WatchWantsTests.testAFailedItemIsRetriedOnceAnHourNotOnEveryPass`, `WatchWantsTests.testAnItemTurnedAwayForRoomIsLeftToThePump` | unit | pass |
| `WatchDownloads.testSetDroppedWant` | 1716 | `WatchWantsTests.testAWantTakenOffHereIsntPutBackByAPlanThatStillNamesIt` | unit | pass |
| `WatchDownloads.testReset` | 1727 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchPlayerTests.testPlayLeavesOutWhatIsntAudioAndShuffleKeepsTheChosenFirst` (+1 more) | unit | pass |
| `WatchDownloads.urlSession` | 1767 | background URLSession delegate: the watch's own transfers, exercised by WatchDownloadUITests on the simulator; real wakes MANUAL.md §7 | manual | manual |
| `WatchDownloads.urlSession` | 1795 | background URLSession delegate: the watch's own transfers, exercised by WatchDownloadUITests on the simulator; real wakes MANUAL.md §7 | manual | manual |
| `WatchDownloads.urlSession` | 1822 | background URLSession delegate: the watch's own transfers, exercised by WatchDownloadUITests on the simulator; real wakes MANUAL.md §7 | manual | manual |
| `WatchDownloads.urlSessionDidFinishEvents` | 1833 | background session wake; MANUAL.md §7 | manual | manual |

## Watch/WatchLink.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchSyncQueue.init` | 32 | the singleton, made at host launch | unit | covered |
| `WatchSyncQueue.persist` | 39 | through `WatchSyncQueue.add`, `WatchSyncQueue.flush`, `WatchSyncQueue.testReset` | unit (indirect) | pass (through its callers) |
| `WatchSyncQueue.add` | 45 | `WatchBookPlaceTests.testAnEventStillQueuedKeepsTheWatchsPlace`, `WatchSyncQueueTests.testAPositionReplacesTheOneWaitingButAPlayIsKept`, `WatchSyncQueueTests.testEventsAreMarkedWithWhoHeardThem`, `WatchSyncQueueTests.testTheQueueSurvivesARelaunch` (+9 more) | unit | pass |
| `WatchSyncQueue.hasPending` | 55 | `WatchSyncQueueTests.testAPositionReplacesTheOneWaitingButAPlayIsKept` | unit | pass |
| `WatchSyncQueue.stamped` | 62 | through `WatchSyncQueue.add` | unit (indirect) | pass (through its callers) |
| `WatchSyncQueue.flush` | 69 | `WatchSyncQueueTests.testNothingGoesWithNoPhoneAndNoNetwork`, `WatchSyncQueueTests.testAnEventRefusedForTheSignInIsKept`, `WatchSyncQueueTests.testAServerHiccupStopsTheRestForNow`, `WatchSyncQueueTests.testAnotherAccountsEventWaits` (+1 more) | unit | pass |
| `WatchSyncQueue.flushOnce` | 90 | through `WatchSyncQueue.flush` | unit (indirect) | pass (through its callers) |
| `WatchSyncQueue.testReset` | 132 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchPlayerTests.testPlayLeavesOutWhatIsntAudioAndShuffleKeepsTheChosenFirst` (+1 more) | unit | pass |
| `WatchSyncQueue.settle` | 141 | `WatchActionsTests.testOtherLinksAreIgnored`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchSyncQueueTests.testAnEventRefusedForTheSignInIsKept`, `WatchSyncQueueTests.testAServerHiccupStopsTheRestForNow` (+1 more) | unit | expected failure / pass |
| `WatchLink.init` | 203 | the singleton, made at host launch | unit | covered |
| `WatchLink.start` | 207 | every launch; WatchConnectivity activation needs a pair (MANUAL.md §1) | UI | via screen |
| `WatchLink.apply` | 217 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+20 more) | unit | not run / pass |
| `WatchLink.requestContext` | 225 | `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `WatchLink.apply` | 235 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+20 more) | unit | not run / pass |
| `WatchLink.handle` | 258 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testOtherLinksAreIgnored`, `WatchLinkTests.testDeleteMessagesGoByGroup` (+6 more) | unit | pass |
| `WatchLink.take` | 290 | `WatchLinkTests.testWhatThePhoneIsPlayingIsKeptWithoutItsCover`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchLinkTests.testChoosingTheiPhoneSourceAsksForItsPlayback`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward` (+8 more) | unit | not run / pass |
| `WatchLink.requestPlayback` | 311 | `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `WatchLink.remote` | 343 | `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward`, `WatchLinkTests.testEachRemoteCommandIsDrawnAtOnce` (+1 more) | unit | pass |
| `WatchLink.sendLogs` | 401 | through `WatchLink.handle` | unit (indirect) | pass (through its callers) |
| `WatchLink.sendLogsInline` | 418 | through `WatchLink.sendLogs` | unit (indirect) | pass (through its callers) |
| `WatchLink.finish` | 429 | local to send(events:) and sendLogsInline: WatchConnectivity's reply or timeout (unit tests answer through testEventReply) | manual | manual |
| `WatchLink.send` | 452 | `WatchClientTests.testAPlayIsCountedWithItsDate`, `WatchClientTests.testASongHeardOffTheWatchIsCountedAsAPlay`, `WatchClientTests.testAStreamedPlayIsAStoppedReportNotASecondPlay`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped` (+3 more) | unit | pass |
| `WatchLink.publishInventory` | 472 | through `WatchLink.apply`, `WatchLink.handle`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
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
| `WatchPlayer.resume` | 173 | through `WatchPlayer.togglePlayPause` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.seek` | 184 | `WatchPlayerTests.testSeekStaysInsideTheItem`, `WatchPlayerTests.testChapterSkipsAndTheCurrentChapter` | unit | pass |
| `WatchPlayer.seek` | 191 | `WatchPlayerTests.testSeekStaysInsideTheItem`, `WatchPlayerTests.testChapterSkipsAndTheCurrentChapter` | unit | pass |
| `WatchPlayer.skipNext` | 193 | `WatchPlayerTests.testNextOnTheLastSongStops` | unit | pass |
| `WatchPlayer.skipPrevious` | 205 | `WatchPlayerTests.testPreviousPartWayInGoesToTheTop` | unit | pass |
| `WatchPlayer.skipChapter` | 216 | `WatchPlayerTests.testChapterSkipsAndTheCurrentChapter`, `WatchPlayerTests.testWithNoChaptersTheSkipsAreThirtyAndFifteen` | unit | pass |
| `WatchPlayer.stepSpeed` | 232 | `WatchPlayerTests.testTheSpeedStepsUpAndDown`, `WatchPlayerTests.testTheSpeedGoesRoundFromTheTop`, `WatchPlaybackTests.testTheSpeedButtonStepsThroughEverySpeed` | UI + unit | expected failure / not run / pass |
| `WatchPlayer.stop` | 238 | `WatchPlayerTests.testStopClearsEverything` | unit | pass |
| `WatchPlayer.startCurrent` | 259 | through `WatchPlayer.play`, `WatchPlayer.skipNext`, `WatchPlayer.skipPrevious` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.resumePoint` | 345 | `WatchPlayerTests.testWhereABookOpens` | unit | pass |
| `WatchPlayer.install` | 357 | `WatchClientTests.testTheSameAccountAgainOnlyRefreshesTheToken`, `WatchLinkTests.testDeleteMessagesGoByGroup`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchLinkTests.testACancelOnThePhoneIsACancelHere` (+2 more) | unit | not run / pass |
| `WatchPlayer.begin` | 378 | through `WatchPlayer.install` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.failedToOpen` | 386 | through `WatchPlayer.startCurrent`, `WatchPlayer.installItemObservers` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.installItemObservers` | 396 | through `WatchPlayer.install` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.teardownItemObservers` | 420 | through `WatchPlayer.stop`, `WatchPlayer.startCurrent` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.timeControlChanged` | 434 | WatchPlaybackTests (play/pause) | UI | via screen |
| `WatchPlayer.tick` | 454 | `WatchPlayerTests.testTheClockNotesABooksPlaceAsItPlays`, `WatchPlayerTests.testTheClockIgnoresTicksBeforeTheSeekLands` | unit | pass |
| `WatchPlayer.itemEnded` | 475 | not waited for (30 s songs); MANUAL.md | UI | via screen |
| `WatchPlayer.closeCurrent` | 490 | through `WatchPlayer.play`, `WatchPlayer.skipNext`, `WatchPlayer.skipPrevious` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.checkpoint` | 504 | `WatchPlayerTests.testCheckpointNotesAPlayingBookOnTheWayToTheBackground` | unit | pass |
| `WatchPlayer.note` | 520 | `WatchPlayerTests.testTheMinuteNoteNearTheEndIsOnlyAPosition`, `WatchPlayerTests.testABookPausedInItsLastMinutesThenFinishedCountsOnce`, `WatchPlayerTests.testASongIsHeardPastNinetyPercentAndCountedOnce`, `WatchLogTests.testNotesGoToTheFileAndTheExportCarriesThem` (+1 more) | unit | pass |
| `WatchPlayer.reportLive` | 552 | through `WatchPlayer.pause`, `WatchPlayer.begin`, `WatchPlayer.tick` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.activateSession` | 565 | through `WatchPlayer.resume`, `WatchPlayer.startCurrent` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.observeInterruptions` | 576 | calls and Siri: MANUAL.md §4 | manual | manual |
| `WatchPlayer.wireRemoteCommands` | 600 | lock-screen and crown transport: MANUAL.md §4 | manual | manual |
| `WatchPlayer.refreshCommands` | 627 | through `WatchPlayer.updateNowPlaying` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.updateNowPlaying` | 637 | through `WatchPlayer.pause`, `WatchPlayer.resume`, `WatchPlayer.seek` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.updateNowPlayingRate` | 673 | Now Playing card: MANUAL.md §4 | manual | manual |
| `WatchPlayer.loadArtwork` | 684 | through `WatchPlayer.updateNowPlaying` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.clearNowPlaying` | 696 | through `WatchPlayer.stop` | unit (indirect) | pass (through its callers) |
| `WatchPlayer.writeSnapshot` | 707 | `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft` | unit | pass |
| `WatchPlayer.worthRedrawing` | 744 | `WatchPlayerTests.testTheCardRedrawsOnlyWhenItChanges` | unit | pass |
| `WatchPlayer.testLoad` | 763 | `WatchActionsTests.testResumeCarriesOnAPausedBook`, `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchBookPlaceTests.testTheBookPlayingNowIsLeftToThePlayer`, `WatchPlayerTests.testTheSpeedStepsUpAndDown` (+20 more) | unit | expected failure / pass |
| `WatchPlayer.testReset` | 788 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchPlayerTests.testPlayLeavesOutWhatIsntAudioAndShuffleKeepsTheChosenFirst` (+1 more) | unit | pass |

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
| `WatchImages.url` | 21 | `WatchClientTests.testADirectStreamIsLetInByItsHeader`, `WatchClientTests.testATranscodeCarriesTheTokenInItsAddress`, `WatchClientTests.testADownloadIsAnAACEncodeWithTheTokenInAHeader`, `WatchClientTests.testADownloadTheWatchCanPlayIsTheServersOwnFile` (+6 more) | unit | not run / pass |
| `WatchImages.cached` | 32 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `WatchImages.load` | 34 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `WatchImages.forget` | 57 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `Color.init` | 96 | WatchShimsTests.testTheThemeColours | unit | covered |

## Watch/WatchLog.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchLog.rotated` | 39 | through `WatchLog.rotate`, `WatchLog.writeExport` | unit (indirect) | pass (through its callers) |
| `WatchLog.note` | 44 | `WatchPlayerTests.testTheMinuteNoteNearTheEndIsOnlyAPosition`, `WatchPlayerTests.testABookPausedInItsLastMinutesThenFinishedCountsOnce`, `WatchPlayerTests.testASongIsHeardPastNinetyPercentAndCountedOnce`, `WatchLogTests.testNotesGoToTheFileAndTheExportCarriesThem` (+1 more) | unit | pass |
| `WatchLog.error` | 49 | `WatchDownloadsTests.testEnqueueAgainAddsAReasonAndQueuesAFailureAgain`, `WatchDownloadsTests.testThePhoneGivingUpWithNoNetworkSaysWhy`, `WatchDownloadsTests.testAFailedTransferIsTriedThreeTimes`, `WatchDownloadsTests.testAFailureWithNoWayToTryAgainIsFailedAtOnce` (+11 more) | unit | pass |
| `WatchLog.logger` | 54 | through `WatchLog.note`, `WatchLog.error` | unit (indirect) | pass (through its callers) |
| `WatchLog.write` | 62 | `WatchWidgetSnapshotTests.testWrittenAndReadThroughTheAppGroup`, `WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`, `WatchLinkTests.testTheRemotesSpeedGoesRound`, `WatchLinkTests.testPiecesJoinInOrderWhicheverOrderTheyArrive` (+6 more) | unit | pass |
| `WatchLog.append` | 69 | `WatchLinkTests.testTheRemotesSpeedGoesRound`, `WatchNavigatorTests.testThePlayerIsPushedOnceAndForgottenOnlyWhenPopped` | unit | pass |
| `WatchLog.rotate` | 87 | through `WatchLog.append` | unit (indirect) | pass (through its callers) |
| `WatchLog.snapshotSystemLog` | 117 | through `WatchLog.backgrounded`, `WatchLog.export` | unit (indirect) | pass (through its callers) |
| `WatchLog.beginSnapshot` | 143 | through `WatchLog.snapshotSystemLog` | unit (indirect) | pass (through its callers) |
| `WatchLog.appendSnapshot` | 151 | through `WatchLog.snapshotSystemLog` | unit (indirect) | pass (through its callers) |
| `WatchLog.launched` | 162 | `WatchLogTests.testALaunchAfterNoGoodbyeIsNotedAsACrash` | unit | pass |
| `WatchLog.backgrounded` | 177 | `WatchLogTests.testALaunchAfterNoGoodbyeIsNotedAsACrash` | unit | pass |
| `WatchLog.foregrounded` | 183 | `WatchLogTests.testALaunchAfterNoGoodbyeIsNotedAsACrash` | unit | pass |
| `WatchLog.export` | 191 | `WatchLogTests.testNotesGoToTheFileAndTheExportCarriesThem` | unit | pass |
| `WatchLog.writeExport` | 197 | through `WatchLog.export` | unit (indirect) | pass (through its callers) |
| `WatchLog.fileStamp` | 215 | WatchLogTests | unit | covered |

## Watch/WatchTestMode.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchTestMode.prepare` | 18 | `WatchTestModeTests.testTheUnitHostRunsInTestMode` | unit | pass |
| `WatchTestMode.signIn` | 44 | `WatchPlaybackTests.testASongPlaysAndTheServerSeesIt`, `WatchPlaybackTests.testPausingABookKeepsItsPlaceOnTheServer` | UI | not run |

## Watch/Shims.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `Languages.name` | 16 | `WatchDownloadsTests.testTheRecordIsWrittenBesideItsFile`, `WatchDownloadsTests.testARecordFromAnOlderBuildStillReads`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone` (+8 more) | UI + unit | not run / pass |
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
| `DownloadControl.cancel` | 655 | `WatchDownloadsTests.testCancelForgetsAQueuedItem`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchDownloadsTests.testCancellingWhatThePhoneIsFetchingTellsThePhone`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` (+4 more) | unit | expected failure / pass |
| `DownloadControl.remove` | 659 | `WatchOnWatchGroupsTests.testRemoveByGroup`, `WatchPhoneLinkTests.testAStalePlaceIsDroppedNotSent`, `WatchPhoneLinkTests.testASongHeardOnTheWatchIsCountedAsAPlay` | unit | not run / pass |

## Watch/Views/LibraryViews.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `BooksView.load` | 61 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `AlbumsView.load` | 323 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `Array.localArtists` | 380 | `WatchShimsTests.testArtistsOfSongsOnceEach` | unit | pass |
| `ArtistDetail.play` | 441 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchActionsTests.testPlayingAnUnknownIdDoesNothing`, `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach` (+3 more) | unit | pass |
| `SongsView.load` | 495 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `SearchView.search` | 683 | `WatchClientTests.testSearchAsksFourWaysAndKeepsWhatAnswered` | unit | pass |

## Watch/Views/NowPlayingScreen.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `NowPlayingScreen.claimCrown` | 45 | drawn on its screen in the UI tests | UI | via screen |
| `NowPlayingScreen.content` | 66 | drawn on its screen in the UI tests | UI | via screen |
| `NowPlayingScreen.playing` | 87 | drawn on its screen in the UI tests | UI | via screen |
| `NowPlayingScreen.speedLabel` | 204 | `WatchPlayerTests.testWholeSpeedsReadAsWholeNumbers`, `WatchPlayerTests.testOnePointTwoFiveAndOnePointSevenFiveReadRight`, `WatchPlaybackTests.testTheSpeedButtonStepsThroughEverySpeed` | UI + unit | expected failure / not run / pass |
| `NowPlayingScreen.subtitle` | 208 | `WatchWidgetSnapshotTests.testThePlayerWritesWhatIsPlaying`, `WatchPlayerTests.testTheCardRedrawsOnlyWhenItChanges`, `WatchOnWatchGroupsTests.testGroupsAreWhatWasAskedForEachSongOnce` | unit | pass |
| `VolumePopup.show` | 285 | through `NowPlayingScreen.subtitle` | unit (indirect) | pass (through its callers) |
| `CrownVolume.makeWKInterfaceObject` | 303 | drawn on its screen in the UI tests | UI | via screen |
| `CrownVolume.updateWKInterfaceObject` | 309 | drawn on its screen in the UI tests | UI | via screen |
| `CrownVolume.makeCoordinator` | 316 | drawn on its screen in the UI tests | UI | via screen |

## Watch/Views/OnWatchViews.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchDownloads.groups` | 25 | `WatchDownloadsTests.testTheInventoryCountsEachByteOnce`, `WatchOnWatchGroupsTests.testGroupsAreWhatWasAskedForEachSongOnce`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup`, `WatchOnWatchGroupsTests.testCancellingAPlaylistAskedForByHandWithNothingHereTakesItAway` (+3 more) | unit | not run / pass |
| `WatchDownloads.remove` | 65 | `WatchOnWatchGroupsTests.testRemoveByGroup`, `WatchPhoneLinkTests.testAStalePlaceIsDroppedNotSent`, `WatchPhoneLinkTests.testASongHeardOnTheWatchIsCountedAsAPlay` | unit | not run / pass |
| `WatchDownloads.cancel` | 74 | `WatchDownloadsTests.testCancelForgetsAQueuedItem`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchDownloadsTests.testCancellingWhatThePhoneIsFetchingTellsThePhone`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` (+4 more) | unit | expected failure / pass |
| `WatchDownloads.retry` | 84 | `WatchDownloadsTests.testRetryQueuesAFailureAgainFromNothing`, `WatchOnWatchGroupsTests.testRemoveCancelAndRetryByGroup` | unit | pass |
| `WatchDownloads.cancelAll` | 91 | `WatchOnWatchGroupsTests.testCancelAllStopsEverythingArriving` | unit | pass |
| `WatchDownloads.queue` | 99 | `WatchActionsTests.testPlayingAnAlbumOrPlaylistById`, `WatchIntentsTests.testShuffleMusicIntentUsesTheServerThenTheWatch`, `WatchPlayerTests.testNextOnTheLastSongStops`, `WatchPlayerTests.testPlayLaterAddsToAQueueThatIsUp` (+2 more) | unit | pass |
| `WatchDownloads.playlistName` | 116 | `WatchOnWatchGroupsTests.testGroupsAreWhatWasAskedForEachSongOnce` | unit | pass |
| `Shelves.p` | 132 | drawn on its screen in the UI tests | UI | via screen |
| `OnWatchView.failedNote` | 225 | drawn on its screen in the UI tests | UI | via screen |
| `OnWatchView.hereNote` | 230 | drawn on its screen in the UI tests | UI | via screen |
| `DownloadQueueView.cancelButton` | 351 | drawn on its screen in the UI tests | UI | via screen |
| `DownloadQueueView.waitingNote` | 357 | drawn on its screen in the UI tests | UI | via screen |
| `WatchSettingsView.serverStatus` | 455 | `WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused`, `WatchClientTests.testSettingsServerLine` | unit | expected failure / pass |

## Watch/Views/PhoneRemoteViews.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchMode.init` | 45 | drawn on its screen in the UI tests | UI | via screen |
| `PhonePlayerScreen.content` | 222 | drawn on its screen in the UI tests | UI | via screen |
| `PhonePlayerScreen.playing` | 241 | drawn on its screen in the UI tests | UI | via screen |
| `PhonePlayerScreen.nextSpeed` | 357 | `WatchLinkTests.testTheRemotesSpeedGoesRound` | unit | pass |
| `PhonePlayerScreen.speedLabel` | 363 | `WatchPlayerTests.testWholeSpeedsReadAsWholeNumbers`, `WatchPlayerTests.testOnePointTwoFiveAndOnePointSevenFiveReadRight`, `WatchPlaybackTests.testTheSpeedButtonStepsThroughEverySpeed` | UI + unit | expected failure / not run / pass |
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
| `WatchSync.pack` | 30 | `WatchLinkTests.testAContextFromThePhoneAsADictionaryDecodes`, `WatchSyncTypesTests.testPackPutsOneJSONPayloadUnderTheOneKey`, `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead`, `WatchPhoneLinkTests.testTheWatchsContextBecomesWhatSettingsShows` (+1 more) | unit | not run / pass |
| `WatchSync.unpack` | 35 | `WatchLinkTests.testAContextFromThePhoneAsADictionaryDecodes`, `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK`, `WatchSyncTypesTests.testUnpackIgnoresAnythingElse`, `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead` | unit | not run / pass |
| `WatchMirrorPlan.init` | 72 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `PhoneContext.init` | 95 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `WatchInventory.init` | 157 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `WatchContext.init` | 208 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `WatchProgressEvent.belongs` | 295 | `WatchSyncTypesTests.testEventsGoOnlyUnderTheirOwnAccount` | unit | pass |
| `PhonePlaybackState.init` | 394 | `WatchSyncTypesTests.testPhoneContextFromAnOlderPhoneStillDecodes`, `WatchSyncTypesTests.testWatchContextFromAnOlderWatchDecodes`, `WatchSyncTypesTests.testPhonePlaybackStateFromAnOlderPhoneDecodes` | unit | pass |
| `PhonePlaybackState.position` | 416 | `WatchWidgetSnapshotTests.testHowFarIn`, `WatchWidgetSnapshotTests.testIdleTheCardShowsTheBookMostRecentlyLeft`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward`, `WatchLinkTests.testEachRemoteCommandIsDrawnAtOnce` (+9 more) | unit | pass |
| `WatchDownloadSource.originalExtension` | 463 | `WatchSyncTypesTests.testTheServersOwnFileWhenTheWatchCanPlayIt`, `WatchSyncTypesTests.testAnEncodeWhenTheWatchCantPlayItOrItIsMuchBigger` | unit | pass |
| `WatchDownloadSource.originalQuery` | 473 | `WatchSyncTypesTests.testTheOriginalsQuery` | unit | pass |
| `VideoProgress.isFinished` | 584 | `WatchBookPlaceTests.testFinishedMeansUnderFiveMinutesLeft`, `WatchBookPlaceTests.testVideoProgressFinishedPast90Percent`, `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | not run / pass |
| `BookProgress.isFinished` | 601 | `WatchBookPlaceTests.testFinishedMeansUnderFiveMinutesLeft`, `WatchBookPlaceTests.testVideoProgressFinishedPast90Percent`, `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | not run / pass |
| `BookProgress.isFinished` | 605 | `WatchBookPlaceTests.testFinishedMeansUnderFiveMinutesLeft`, `WatchBookPlaceTests.testVideoProgressFinishedPast90Percent`, `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | not run / pass |
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
| `WatchLink.isLong` | 164 | through `WatchLink.pumpFetches` | unit (indirect) | pass (through its callers) |
| `WatchLink.init` | 174 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.start` | 200 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.handleFetchEvents` | 220 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.releaseFetchWake` | 229 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.resumeFetches` | 242 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.checkWatch` | 251 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sendContext` | 268 | through `WatchLink.syncNow`, `WatchLink.download`, `WatchLink.forgetWant` | unit (indirect) | pass (through its callers) |
| `WatchLink.pushContext` | 277 | through `WatchLink.sendContext` | unit (indirect) | pass (through its callers) |
| `WatchLink.sendPlaylists` | 299 | through `WatchLink.pushContext` | unit (indirect) | pass (through its callers) |
| `WatchLink.sendBooks` | 326 | through `WatchLink.pushContext` | unit (indirect) | pass (through its callers) |
| `WatchLink.handOver` | 343 | through `WatchLink.sendPlaylists`, `WatchLink.sendDownload`, `WatchLink.enqueueFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.syncNow` | 367 | `WatchDownloadsTests.testSyncNowAsksThePhoneAgainForEverythingAwaiting` | unit | pass |
| `WatchLink.buildContext` | 391 | through `WatchLink.pushContext`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.send` | 432 | `WatchClientTests.testAPlayIsCountedWithItsDate`, `WatchClientTests.testASongHeardOffTheWatchIsCountedAsAPlay`, `WatchClientTests.testAStreamedPlayIsAStoppedReportNotASecondPlay`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped` (+3 more) | unit | pass |
| `WatchLink.sendLive` | 447 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.deleteFromWatch` | 454 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.deleteEverythingOnWatch` | 472 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.download` | 496 | `WatchSyncTypesTests.testEveryMessageRoundTrips`, `WatchWantsTests.testADownloadMessageLooksItUpAndKeepsIt`, `WatchWantsTests.testADownloadThatCantBeLookedUpIsLeft` | unit | pass |
| `WatchLink.removeWant` | 521 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.forgetWant` | 528 | through `WatchLink.handle` | unit (indirect) | pass (through its callers) |
| `WatchLink.persistWants` | 537 | through `WatchLink.syncNow`, `WatchLink.download`, `WatchLink.forgetWant` | unit (indirect) | pass (through its callers) |
| `WatchLink.reconcileWants` | 551 | through `WatchLink.apply` | unit (indirect) | pass (through its callers) |
| `WatchLink.sendDownload` | 573 | through `WatchLink.syncNow`, `WatchLink.download`, `WatchLink.reconcileWants` | unit (indirect) | pass (through its callers) |
| `WatchLink.requestInventory` | 598 | `WatchSyncTypesTests.testPackPutsOneJSONPayloadUnderTheOneKey`, `WatchSyncTypesTests.testEveryMessageRoundTrips`, `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead` | unit | not run / pass |
| `WatchLink.requestWatchLogs` | 614 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.reloadWatchLogs` | 619 | through `WatchLink.deleteWatchLog`, `WatchLink.take`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.deleteWatchLog` | 630 | `WatchPhoneLinkTests.testTheWatchsLogArrivesInPiecesAndIsKept` | unit | not run |
| `WatchLink.exportPhoneLog` | 638 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.apply` | 665 | `WatchDownloadsTests.testAPlaylistTakenOffHereIsntPutBackByAnOldPlan`, `WatchDownloadsTests.testAPlaylistFromThePhoneIsKeptAndFollowed`, `WatchDownloadsTests.testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone`, `WatchDownloadsTests.testBooksInProgressFromThePhoneAreQueuedForTheWatch` (+20 more) | unit | not run / pass |
| `WatchLink.keepsOnWatch` | 687 | `WatchPhoneLinkTests.testTheWatchsContextBecomesWhatSettingsShows` | unit | not run |
| `WatchLink.setKeepsOnWatch` | 694 | through `WatchLink.download` | unit (indirect) | pass (through its callers) |
| `WatchLink.playlistRemovedOnWatch` | 711 | through `WatchLink.handle` | unit (indirect) | pass (through its callers) |
| `WatchLink.keepOnly` | 725 | through `WatchLink.apply` | unit (indirect) | pass (through its callers) |
| `WatchLink.handle` | 739 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testOtherLinksAreIgnored`, `WatchLinkTests.testDeleteMessagesGoByGroup` (+6 more) | unit | pass |
| `WatchLink.take` | 758 | `WatchLinkTests.testWhatThePhoneIsPlayingIsKeptWithoutItsCover`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchLinkTests.testChoosingTheiPhoneSourceAsksForItsPlayback`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward` (+8 more) | unit | not run / pass |
| `WatchLink.relayFile` | 790 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.resumeFile` | 796 | through `WatchLink.saveResumeData`, `WatchLink.takeResumeData` | unit (indirect) | pass (through its callers) |
| `WatchLink.saveResumeData` | 802 | through `WatchLink.stopFetching` | unit (indirect) | pass (through its callers) |
| `WatchLink.takeResumeData` | 807 | through `WatchLink.cancelFetch`, `WatchLink.startFetch`, `WatchLink.fetchFailed` | unit (indirect) | pass (through its callers) |
| `WatchLink.taskInfo` | 815 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.existingRelayFile` | 821 | through `WatchLink.enqueueFetch`, `WatchLink.cancelFetch`, `WatchLink.handOver` | unit (indirect) | pass (through its callers) |
| `WatchLink.persistFetches` | 827 | through `WatchLink.syncNow`, `WatchLink.handle`, `WatchLink.enqueueFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.enqueueFetch` | 832 | through `WatchLink.syncNow`, `WatchLink.handle`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.cancelFetch` | 867 | `WatchLinkTests.testWhatOnlyThePhoneHearsIsIgnoredHere`, `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `WatchLink.stopFetching` | 897 | through `WatchLink.cancelFetch`, `WatchLink.restartFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.restartFetch` | 924 | through `WatchLink.enqueueFetch`, `WatchLink.watchForStall` | unit (indirect) | pass (through its callers) |
| `WatchLink.watchForStall` | 948 | through `WatchLink.startFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.describe` | 977 | `WatchSyncTypesTests.testEveryMessageRoundTrips` | unit | pass |
| `WatchLink.rejoinFetches` | 989 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.lookUpEstimate` | 1040 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.updateRelay` | 1052 | through `WatchLink.enqueueFetch`, `WatchLink.startFetch`, `WatchLink.watchTransfers` | unit (indirect) | pass (through its callers) |
| `WatchLink.persistRelay` | 1063 | through `WatchLink.cancelFetch`, `WatchLink.updateRelay`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.nameRelayItem` | 1068 | through `WatchLink.enqueueFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.cancelRelay` | 1088 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.cancelAllRelays` | 1099 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.debugSeedRelayRows` | 1114 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.clearFinishedRelayItems` | 1139 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.pumpFetches` | 1148 | through `WatchLink.syncNow`, `WatchLink.handle`, `WatchLink.enqueueFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.startFetch` | 1162 | through `WatchLink.pumpFetches` | unit (indirect) | pass (through its callers) |
| `WatchLink.fetchRequest` | 1219 | through `WatchLink.startFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.estimatedBytes` | 1247 | `WatchClientTests.testTheSizeOfADownloadComesFromItsLength`, `WatchDownloadsTests.testPhoneProgressMovesTheBarAndStartsItsPatienceAgain`, `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchOnWatchGroupsTests.testTheQueueShowsWhatMovesThenWhatWaitsInTheOrderItWillStart` (+1 more) | unit | pass |
| `WatchLink.reportProgress` | 1254 | through `WatchLink.watchTransfers` | unit (indirect) | pass (through its callers) |
| `WatchLink.watchTransfers` | 1262 | through `WatchLink.handOver`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.taskItem` | 1279 | through `WatchLink.watchForStall` | unit (indirect) | pass (through its callers) |
| `WatchLink.fetchFailed` | 1283 | `WatchLinkTests.testPhoneProgressAndFailureReachTheRecord`, `WatchSyncTypesTests.testEveryMessageRoundTrips`, `WatchPhoneWireTests.testWhatThePhoneSendsTheWatchCanRead` | unit | not run / pass |
| `WatchLink.fetched` | 1302 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.forget` | 1331 | `WatchImagesTests.testAFileCoverLoadsAndIsCached` | unit | pass |
| `WatchLink.handOver` | 1339 | through `WatchLink.sendPlaylists`, `WatchLink.sendDownload`, `WatchLink.enqueueFetch` | unit (indirect) | pass (through its callers) |
| `WatchLink.piecesFolder` | 1414 | through `WatchLink.handOver` | unit (indirect) | pass (through its callers) |
| `WatchLink.removePieces` | 1420 | through `WatchLink.cancelFetch`, `WatchLink.sendFailed`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.cut` | 1428 | through `WatchLink.handOver` | unit (indirect) | pass (through its callers) |
| `WatchLink.sentFractions` | 1460 | through `WatchLink.watchTransfers`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.sendFailed` | 1483 | through `WatchLink.handOver`, `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.take` | 1501 | `WatchLinkTests.testWhatThePhoneIsPlayingIsKeptWithoutItsCover`, `WatchLinkTests.testTheRemoteSaysWhenThePhoneIsOutOfReach`, `WatchLinkTests.testChoosingTheiPhoneSourceAsksForItsPlayback`, `WatchLinkTests.testTheRemotesGuessCarriesTheClockForward` (+8 more) | unit | not run / pass |
| `WatchLink.takeAndAnswer` | 1523 | through `WatchLink.session` | unit (indirect) | pass (through its callers) |
| `WatchLink.persistPending` | 1534 | through `WatchLink.take`, `WatchLink.settle` | unit (indirect) | pass (through its callers) |
| `WatchLink.settle` | 1538 | `WatchActionsTests.testOtherLinksAreIgnored`, `WatchDownloadsTests.testACancelRightAfterQueueingLeavesNothingForTheNextLaunch`, `WatchSyncQueueTests.testAnEventRefusedForTheSignInIsKept`, `WatchSyncQueueTests.testAServerHiccupStopsTheRestForNow` (+1 more) | unit | expected failure / pass |
| `WatchLink.forward` | 1550 | through `WatchLink.syncNow`, `WatchLink.take`, `WatchLink.retryForward` | unit (indirect) | pass (through its callers) |
| `WatchLink.retryForward` | 1590 | through `WatchLink.forward` | unit (indirect) | pass (through its callers) |
| `WatchLink.deliver` | 1611 | through `WatchLink.forward` | unit (indirect) | pass (through its callers) |
| `WatchLink.session` | 1660 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.sessionDidBecomeInactive` | 1703 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sessionDidDeactivate` | 1705 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sessionWatchStateDidChange` | 1710 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.sessionReachabilityDidChange` | 1720 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchLink.session` | 1727 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 1743 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 1747 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 1777 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 1782 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.session` | 1796 | `WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK` | unit | pass |
| `WatchLink.urlSession` | 1838 | the relay's background URLSession: MANUAL.md §1 | manual | manual |
| `WatchLink.urlSession` | 1862 | the relay's background URLSession: MANUAL.md §1 | manual | manual |
| `WatchLink.urlSession` | 1888 | the relay's background URLSession: MANUAL.md §1 | manual | manual |
| `WatchLink.urlSessionDidFinishEvents` | 1938 | the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1 | manual | manual |
| `WatchWant.status` | 1955 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testResumeOfflineTakesTheWatchsBook`, `WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch` (+71 more) | unit | expected failure / not run / pass |
| `RelayItem.isStuck` | 1996 | `WatchPhoneLinkTests.testASendThatStopsMovingIsCalledStuck` | unit | not run |

## Aquarium/Core/WatchRemote.swift

| Function | Line | Test(s) | Kind | Status |
|---|---|---|---|---|
| `WatchRemote.init` | 46 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.start` | 48 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.watch` | 73 | `WatchLinkTests.testChoosingTheiPhoneSourceAsksForItsPlayback` | unit | pass |
| `WatchRemote.observeState` | 87 | through `WatchRemote.watch` | unit (indirect) | pass (through its callers) |
| `WatchRemote.watchClock` | 112 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.clockMoved` | 128 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.changed` | 148 | through `WatchRemote.handle` | unit (indirect) | pass (through its callers) |
| `WatchRemote.snapshot` | 161 | through `WatchRemote.send` | unit (indirect) | pass (through its callers) |
| `WatchRemote.state` | 206 | the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote) | manual | manual |
| `WatchRemote.send` | 232 | `WatchClientTests.testAPlayIsCountedWithItsDate`, `WatchClientTests.testASongHeardOffTheWatchIsCountedAsAPlay`, `WatchClientTests.testAStreamedPlayIsAStoppedReportNotASecondPlay`, `WatchClientTests.testABookPositionOlderThanTheServersLastPlayIsDropped` (+3 more) | unit | pass |
| `WatchRemote.differs` | 256 | through `WatchRemote.send` | unit (indirect) | pass (through its callers) |
| `WatchRemote.fetchArtwork` | 274 | through `WatchRemote.send` | unit (indirect) | pass (through its callers) |
| `WatchRemote.loadArtwork` | 288 | through `WatchRemote.fetchArtwork` | unit (indirect) | pass (through its callers) |
| `WatchRemote.artworkURL` | 303 | through `WatchRemote.loadArtwork` | unit (indirect) | pass (through its callers) |
| `WatchRemote.handle` | 313 | `WatchActionsTests.testTheWidgetsPlayLinkPlaysThatItem`, `WatchActionsTests.testTheWidgetsResumeLinkResumesTheBook`, `WatchActionsTests.testOtherLinksAreIgnored`, `WatchLinkTests.testDeleteMessagesGoByGroup` (+6 more) | unit | pass |

## Screens and widget views

| View | File | UI tests that open it | Status |
|---|---|---|---|
| `AquariumWatchApp` | Watch/WatchApp.swift:14 | not reached by any test | via its parent screen |
| `Artwork` | Watch/WatchImages.swift:64 | not reached by any test | via its parent screen |
| `RootView` | Watch/Views/RootView.swift:69 | drawn on its screen in the UI tests | via its parent screen |
| `LibraryHome` | Watch/Views/RootView.swift:86 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+34 more) | not run |
| `NowPlayingRow` | Watch/Views/RootView.swift:238 | `WatchPlaybackTests.testTheHomeRowLeadsBackToThePlayer` | not run |
| `DownloadingRow` | Watch/Views/RootView.swift:262 | drawn on its screen in the UI tests | via its parent screen |
| `Door` | Watch/Views/RootView.swift:281 | drawn on its screen in the UI tests | via its parent screen |
| `BookRow` | Watch/Views/RootView.swift:311 | drawn on its screen in the UI tests | via its parent screen |
| `SongRow` | Watch/Views/RootView.swift:333 | drawn on its screen in the UI tests | via its parent screen |
| `CollectionRow` | Watch/Views/RootView.swift:363 | drawn on its screen in the UI tests | via its parent screen |
| `ProgressBar` | Watch/Views/RootView.swift:382 | drawn on its screen in the UI tests | via its parent screen |
| `DownloadButton` | Watch/Views/RootView.swift:436 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` | not run |
| `DownloadMark` | Watch/Views/RootView.swift:475 | drawn on its screen in the UI tests | via its parent screen |
| `DownloadControl` | Watch/Views/RootView.swift:515 | `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch`, `WatchDownloadUITests.testTheQueueOrOnWatchShowsWhatIsArriving` (+2 more) | not run |
| `PlayShuffleBar` | Watch/Views/RootView.swift:671 | `WatchLibraryTests.testAnAlbumsPageListsItsSongsInOrder`, `WatchLibraryTests.testAnArtistsPageListsTheirAlbums`, `WatchPlaybackTests.testPlayPauseNextAndPrevious` | not run |
| `StatusRow` | Watch/Views/RootView.swift:692 | `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` | not run |
| `BooksView` | Watch/Views/LibraryViews.swift:10 | `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch`, `WatchLibraryTests.testAudiobooksAndABooksPage`, `WatchLibraryTests.testTheAudiobooksSortStepsThroughItsOrders` (+8 more) | not run |
| `BookDetail` | Watch/Views/LibraryViews.swift:81 | `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch`, `WatchLibraryTests.testAudiobooksAndABooksPage`, `WatchPlaybackTests.testABookOpensWhereItWasLeftAndItsButtonsMoveIt` (+6 more) | not run |
| `MusicMenu` | Watch/Views/LibraryViews.swift:179 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+12 more) | not run |
| `PlaylistsView` | Watch/Views/LibraryViews.swift:218 | `WatchLibraryTests.testAPlaylistsPage` | not run |
| `AlbumsView` | Watch/Views/LibraryViews.swift:273 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+8 more) | not run |
| `ArtistsView` | Watch/Views/LibraryViews.swift:340 | `WatchLibraryTests.testAnArtistsPageListsTheirAlbums`, `WatchLibraryTests.testArtistsAreTheMusicLibrarysNotTheAudiobooksAuthors` | not run |
| `ArtistDetail` | Watch/Views/LibraryViews.swift:396 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+8 more) | not run |
| `SongsView` | Watch/Views/LibraryViews.swift:449 | `WatchLibraryTests.testAnAlbumsPageListsItsSongsInOrder`, `WatchLibraryTests.testSongsList`, `WatchLibraryTests.testAPlaylistsPage` (+2 more) | not run |
| `SongSwipe` | Watch/Views/LibraryViews.swift:510 | drawn on its screen in the UI tests | via its parent screen |
| `GenresView` | Watch/Views/LibraryViews.swift:529 | `WatchLibraryTests.testAGenresPage` | not run |
| `CollectionDetail` | Watch/Views/LibraryViews.swift:554 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+7 more) | not run |
| `SearchView` | Watch/Views/LibraryViews.swift:627 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testAnAlbumDownloadsWholeAndIsRemoved`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` (+18 more) | not run |
| `NowPlayingScreen` | Watch/Views/NowPlayingScreen.swift:15 | `WatchPlaybackTests.testASongPlaysAndTheServerSeesIt`, `WatchPlaybackTests.testPlayPauseNextAndPrevious`, `WatchPlaybackTests.testTheHomeRowLeadsBackToThePlayer` (+8 more) | not run |
| `VolumePopup` | Watch/Views/NowPlayingScreen.swift:243 | drawn on its screen in the UI tests | via its parent screen |
| `CrownVolume` | Watch/Views/NowPlayingScreen.swift:300 | drawn on its screen in the UI tests | via its parent screen |
| `OnWatchView` | Watch/Views/OnWatchViews.swift:121 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch` | not run |
| `GroupLink` | Watch/Views/OnWatchViews.swift:248 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchDownloadUITests.testRemoveEverythingEmptiesTheWatch`, `WatchDownloadUITests.testABookDownloadsAndPlaysFromTheWatch` | not run |
| `GroupRow` | Watch/Views/OnWatchViews.swift:264 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner` | not run |
| `DownloadQueueView` | Watch/Views/OnWatchViews.swift:298 | drawn on its screen in the UI tests | via its parent screen |
| `QueueRow` | Watch/Views/OnWatchViews.swift:369 | drawn on its screen in the UI tests | via its parent screen |
| `StorageLine` | Watch/Views/OnWatchViews.swift:405 | `WatchDownloadUITests.testASongDownloadsFromItsRowCorner`, `WatchHomeTests.testSettingsShowsTheAccountTheServerAndThePhone` | not run |
| `WatchSettingsView` | Watch/Views/OnWatchViews.swift:447 | `WatchHomeTests.testSettingsShowsTheAccountTheServerAndThePhone`, `WatchHomeTests.testSettingsSignedOut`, `WatchHomeTests.testSyncNowRunsWithNothingToSync` | not run |
| `SourceSwitch` | Watch/Views/PhoneRemoteViews.swift:53 | `WatchHomeTests.testTheSwitchShowsThePhonesSideAndBack`, `WatchHomeTests.testTheChoiceOfSideIsRemembered` | not run |
| `PhoneNowPlayingRow` | Watch/Views/PhoneRemoteViews.swift:88 | drawn on its screen in the UI tests | via its parent screen |
| `PhoneArtwork` | Watch/Views/PhoneRemoteViews.swift:112 | drawn on its screen in the UI tests | via its parent screen |
| `PhoneIdleRow` | Watch/Views/PhoneRemoteViews.swift:140 | `WatchHomeTests.testTheSwitchShowsThePhonesSideAndBack` | not run |
| `PhonePlayerScreen` | Watch/Views/PhoneRemoteViews.swift:181 | drawn on its screen in the UI tests | via its parent screen |
| `PhoneVolumePopup` | Watch/Views/PhoneRemoteViews.swift:375 | drawn on its screen in the UI tests | via its parent screen |
| `CompanionCrownVolume` | Watch/Views/PhoneRemoteViews.swift:420 | drawn on its screen in the UI tests | via its parent screen |
| `AquariumWatchWidgets` | WatchWidgets/WatchWidgets.swift:11 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |
| `ListeningProvider` | WatchWidgets/WatchWidgets.swift:22 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |
| `ListeningWidget` | WatchWidgets/WatchWidgets.swift:39 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |
| `ListeningWidgetView` | WatchWidgets/WatchWidgets.swift:51 | drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests) | manual |

## Totals

Functions listed: 450. Reached by a unit test: 370; by UI tests only: 25;
manual (real hardware or the system's UI): 55; reached by nothing: 0.
