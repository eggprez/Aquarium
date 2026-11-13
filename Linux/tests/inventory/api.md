| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| CLIENT_VERSION | src/api.ts:11 | tests/unit/api-media.test.ts | unit | tested |
| getSession | src/api.ts:35 | tests/unit/api-session.test.ts; tests/integration/smoke.test.ts | unit, integration (QA server) | tested |
| splitError | src/api.ts:47 | tests/unit/api-session.test.ts | unit | tested via api, probeServer, login |
| announceIdentityChange | src/api.ts:63 | tests/unit/api-session.test.ts | unit | tested via api, checkOnline |
| isOffline | src/api.ts:73 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| setOffline | src/api.ts:77 | tests/unit/api-session.test.ts | unit | tested via api, checkOnline |
| checkOnline | src/api.ts:84 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| confirmOffline | src/api.ts:112 | tests/unit/api-session.test.ts | unit | tested via api |
| getConfig | src/api.ts:122 | tests/unit/api-session.test.ts | unit | tested |
| loadConfig | src/api.ts:126 | tests/unit/api-session.test.ts; all integration suites (qaApi) | unit, integration (QA server) | tested |
| saveConfig | src/api.ts:144 | tests/unit/api-session.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| api | src/api.ts:152 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts (real 401 and 404) | unit, integration (QA server) | tested |
| probeServer | src/api.ts:196 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| login | src/api.ts:209 | tests/unit/api-session.test.ts | unit | tested (sign-in itself is server.rs, Rust suites) |
| logout | src/api.ts:237 | tests/unit/api-session.test.ts | unit | tested |
| discoverServers | src/api.ts:260 | tests/unit/api-session.test.ts | unit | tested (LAN discovery is off on the QA server) |
| publicCall | src/api.ts:268 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via publicUsers, quickConnect* |
| publicUsers | src/api.ts:287 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| quickConnectEnabled | src/api.ts:299 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| quickConnectInitiate | src/api.ts:319 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| quickConnectState | src/api.ts:334 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| loginWithQuickConnect | src/api.ts:342 | tests/unit/api-session.test.ts | unit | tested (the exchange is server.rs) |
| authorizeQuickConnect | src/api.ts:366 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| listAccounts | src/api.ts:396 | tests/unit/api-session.test.ts | unit | tested |
| knownServers | src/api.ts:405 | tests/unit/api-session.test.ts | unit | tested |
| switchAccount | src/api.ts:415 | tests/unit/api-session.test.ts | unit | tested |
| forgetAccount | src/api.ts:428 | tests/unit/api-session.test.ts | unit | tested |
| avatarUrl | src/api.ts:438 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| expireSession | src/api.ts:453 | tests/unit/api-session.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via api (401) |
| ITEM_FIELDS | src/api.ts:480 | tests/unit/api-browse.test.ts | unit | tested via every grid query |
| DETAIL_FIELDS | src/api.ts:485 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via getItem |
| VIDEO_COLLECTION_TYPES | src/api.ts:493 | tests/unit/api-browse.test.ts | unit | tested |
| NON_VIDEO_ITEM_TYPES | src/api.ts:498 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via isVideoItem, getLibraryItems |
| isVideoItem | src/api.ts:501 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getViews | src/api.ts:507 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getResume | src/api.ts:513 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| NEXT_UP_DAY_CHOICES | src/api.ts:532 | tests/unit/api-browse.test.ts | unit | tested |
| nextUpDaysLabel | src/api.ts:534 | tests/unit/api-browse.test.ts | unit | tested |
| nextUpDays | src/api.ts:545 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via getNextUp |
| nextUpInProgress | src/api.ts:551 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via getNextUp |
| nextUpRewatching | src/api.ts:555 | tests/unit/api-browse.test.ts | unit | tested via getNextUp |
| nextUpQuery | src/api.ts:559 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via getNextUp |
| NOT_PLAYED_DATE | src/api.ts:580 | tests/unit/api-browse.test.ts | unit | tested |
| hasPlayedDate | src/api.ts:583 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| newStartsFirst | src/api.ts:598 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| expiredFromNextUp | src/api.ts:611 | tests/unit/api-browse.test.ts | unit | tested |
| reportExpired | src/api.ts:624 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via getNextUp (day limit) |
| getNextUp | src/api.ts:640 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| seriesEpisodesWithUserData | src/api.ts:654 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested via removeFromNextUp, addToNextUp |
| walked | src/api.ts:662 | tests/unit/api-browse.test.ts | unit | tested via nextUpTarget, addToNextUp |
| nextUpTarget | src/api.ts:669 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| removeFromNextUp | src/api.ts:685 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| addToNextUp | src/api.ts:711 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested ("last"); expected failure (bug) for "first" on the QA server |
| homeSectionFor | src/api.ts:744 | tests/unit/api-browse.test.ts | unit | tested via getHomeSections |
| jellyfinDefaultSection | src/api.ts:767 | tests/unit/api-browse.test.ts | unit | tested via HOME_FALLBACK, getHomeSections |
| HOME_FALLBACK | src/api.ts:771 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getHomeSections | src/api.ts:781 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getSeriesNextUp | src/api.ts:807 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getLatest | src/api.ts:824 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| foldEpisodesIntoSeries | src/api.ts:834 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via getLatest |
| getLibraryItems | src/api.ts:875 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getFavorites | src/api.ts:903 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| getGenres | src/api.ts:924 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getItem | src/api.ts:933 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getSimilar | src/api.ts:942 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getSeasons | src/api.ts:950 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getEpisodes | src/api.ts:956 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getTrickplay | src/api.ts:994 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| trickplayTile | src/api.ts:1032 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested (jf_image forwarded by tests/helpers/api-qa.ts) |
| getMediaSegments | src/api.ts:1056 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested (Intro); expected failure (bug) for Outro |
| search | src/api.ts:1068 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getChannels | src/api.ts:1086 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getPrograms | src/api.ts:1103 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getItemsByIds | src/api.ts:1131 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| getUserDataByIds | src/api.ts:1145 | tests/unit/api-browse.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| markPlayed | src/api.ts:1151 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| setFavorite | src/api.ts:1158 | tests/unit/api-browse.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| resolveImage | src/api.ts:1173 | tests/unit/api-media.test.ts | unit | tested via imageUrl, imageHash |
| imageUrl | src/api.ts:1190 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| imageHash | src/api.ts:1211 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| logoUrl | src/api.ts:1229 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| seriesPosterUrl | src/api.ts:1247 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| seasonPosterUrl | src/api.ts:1258 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| probeBandwidth | src/api.ts:1278 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested (jf_bitrate_test forwarded by tests/helpers/api-qa.ts) |
| deviceProfile | src/api.ts:1298 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested via resolvePlayback; expected failure (bug): no External subtitle method, Embed-only subtitles burnt in on HLS |
| resolvePlayback | src/api.ts:1339 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested; expected failure (bug): transcode URL carries the access token |
| DOWNLOAD_QUALITIES | src/api.ts:1424 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested |
| audioRate | src/api.ts:1435 | tests/unit/api-media.test.ts | unit | tested via estimateDownloadSize, buildDownload |
| resolutionLabel | src/api.ts:1442 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via mediaSummary |
| channelLabel | src/api.ts:1454 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested via mediaSummary; expected failure (bug): server layout "stereo" not capitalised |
| mediaSummary | src/api.ts:1474 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
| estimateDownloadSize | src/api.ts:1497 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested |
| effectiveDownloadQuality | src/api.ts:1526 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested |
| buildDownload | src/api.ts:1542 | tests/unit/api-media.test.ts; tests/integration/api-playback.test.ts | unit, integration (QA server) | tested (the transcode download address is built, not fetched: it would start an encode) |
| ticksToText | src/api.ts:1576 | tests/unit/api-media.test.ts | unit | tested |
| remainingText | src/api.ts:1589 | tests/unit/api-media.test.ts; tests/integration/api-state.test.ts | unit, integration (QA server) | tested |
| secondsToClock | src/api.ts:1595 | tests/unit/api-media.test.ts | unit | tested |
| bytesToText | src/api.ts:1605 | tests/unit/api-media.test.ts; tests/integration/api-browse.test.ts | unit, integration (QA server) | tested |
