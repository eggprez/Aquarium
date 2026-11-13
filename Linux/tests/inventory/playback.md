| Function | Source | Test file | Kind | Status |
| --- | --- | --- | --- | --- |
| MAX_VOLUME | src/playback.ts:14 | tests/unit/playback-prefs.test.ts | unit | tested |
| loadVolume | src/playback.ts:16 | tests/unit/playback-prefs.test.ts | unit | tested via getVolume |
| getVolume | src/playback.ts:24 | tests/unit/playback-prefs.test.ts | unit | tested |
| rememberVolume | src/playback.ts:28 | tests/unit/playback-prefs.test.ts | unit | tested via playerCtl.setVolume, noteVolume |
| noteVolume | src/playback.ts:40 | tests/unit/playback-prefs.test.ts | unit | tested |
| isAutoplayPending | src/playback.ts:102 | tests/unit/playback-next.test.ts | unit | tested |
| cancelAutoplay | src/playback.ts:110 | tests/unit/playback-prefs.test.ts | unit | tested |
| isAutoplayCancelled | src/playback.ts:115 | tests/unit/playback-prefs.test.ts | unit | tested |
| resumeAutoplay | src/playback.ts:120 | tests/unit/playback-prefs.test.ts | unit | tested |
| SKIP_INTERVALS | src/playback.ts:130 | tests/unit/playback-prefs.test.ts | unit | tested |
| skipInterval | src/playback.ts:132 | tests/unit/playback-prefs.test.ts | unit | tested |
| HIDE_AFTER_CHOICES | src/playback.ts:138 | tests/unit/playback-prefs.test.ts | unit | tested |
| hideControlsAfter | src/playback.ts:140 | tests/unit/playback-prefs.test.ts | unit | tested |
| showsRemaining | src/playback.ts:146 | tests/unit/playback-prefs.test.ts | unit | tested |
| setShowsRemaining | src/playback.ts:150 | tests/unit/playback-prefs.test.ts | unit | tested |
| autoplayNextEnabled | src/playback.ts:156 | tests/unit/playback-prefs.test.ts | unit | tested |
| resumeEnabled | src/playback.ts:161 | tests/unit/playback-prefs.test.ts | unit | tested |
| getUserQueue | src/playback.ts:176 | tests/unit/playback-next.test.ts | unit | tested |
| queueChanged | src/playback.ts:180 | tests/unit/playback-next.test.ts | unit | tested via queueNext, removeFromQueue, clearQueue |
| queueable | src/playback.ts:186 | tests/unit/playback-next.test.ts | unit | tested via queueNext, queueLater |
| queueNext | src/playback.ts:198 | tests/unit/playback-next.test.ts | unit | tested |
| queueLater | src/playback.ts:207 | tests/unit/playback-next.test.ts | unit | tested |
| removeFromQueue | src/playback.ts:216 | tests/unit/playback-next.test.ts | unit | tested |
| clearQueue | src/playback.ts:221 | tests/unit/playback-next.test.ts | unit | tested |
| playQueued | src/playback.ts:228 | tests/unit/playback-next.test.ts | unit | tested |
| startQueueIfIdle | src/playback.ts:242 | tests/unit/playback-next.test.ts | unit | tested via queueNext |
| maybePrefetch | src/playback.ts:271 | tests/unit/playback-start.test.ts | unit | tested via registerPlayerBridge (player-status) |
| takePrefetched | src/playback.ts:304 | tests/unit/playback-start.test.ts | unit | tested via playItem |
| showPlaybackError | src/playback.ts:317 | tests/unit/playback-start.test.ts | unit | tested via registerPlayerBridge (player-status); playItem path is expected failure (bug) |
| smallerStream | src/playback.ts:351 | tests/unit/playback-start.test.ts | unit | tested via showPlaybackError |
| PICTURE_CONTROLS | src/playback.ts:373 | tests/unit/playback-prefs.test.ts | unit | tested |
| saveConfigSoon | src/playback.ts:388 | tests/unit/playback-prefs.test.ts | unit | tested |
| setLiveSetting | src/playback.ts:404 | tests/unit/playback-prefs.test.ts | unit | tested |
| sleepDeadline | src/playback.ts:422 | tests/unit/playback-prefs.test.ts | unit | tested |
| cancelSleepTimer | src/playback.ts:426 | tests/unit/playback-prefs.test.ts | unit | tested |
| setSleepTimer | src/playback.ts:434 | tests/unit/playback-prefs.test.ts | unit | tested |
| getTracks | src/playback.ts:476 | tests/unit/playback-next.test.ts | unit | tested |
| seriesTrackKey | src/playback.ts:480 | tests/unit/playback-next.test.ts | unit | tested via onTrackList |
| readTrackChoice | src/playback.ts:488 | tests/unit/playback-next.test.ts | unit | tested via onTrackList |
| writeTrackChoice | src/playback.ts:498 | tests/unit/playback-next.test.ts | unit | tested via onTrackList |
| onTrackList | src/playback.ts:512 | tests/unit/playback-next.test.ts | unit | tested via registerPlayerBridge (player-tracks) |
| getNowPlaying | src/playback.ts:557 | tests/unit/playback-start.test.ts | unit | tested |
| peekNextEpisode | src/playback.ts:572 | tests/unit/playback-next.test.ts | unit | tested |
| playNextNow | src/playback.ts:596 | tests/unit/playback-next.test.ts | unit | tested |
| itemTitle | src/playback.ts:607 | tests/unit/playback-prefs.test.ts | unit | tested |
| findDownload | src/playback.ts:617 | tests/unit/playback-start.test.ts | unit | tested via playItem, switchToDownload |
| pickStartingBitrate | src/playback.ts:647 | tests/unit/playback-start.test.ts | unit | expected failure (bug) |
| playItem | src/playback.ts:659 | tests/unit/playback-start.test.ts | unit | expected failure (bug) |
| playChannelUrl | src/playback.ts:769 | tests/unit/playback-start.test.ts | unit | tested |
| playLocal | src/playback.ts:824 | tests/unit/playback-start.test.ts | unit | tested |
| isLocalEpisode | src/playback.ts:891 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, maybeAutoplay |
| sameSeries | src/playback.ts:897 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode |
| fromStart | src/playback.ts:903 | tests/unit/playback-next.test.ts | unit | tested via autoplayNext, startLocalShuffle |
| findNextEpisode | src/playback.ts:910 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, autoplayNext |
| findNextLocalEpisode | src/playback.ts:923 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, autoplayNext |
| isShuffling | src/playback.ts:950 | tests/unit/playback-next.test.ts | unit | tested |
| startLocalShuffle | src/playback.ts:960 | tests/unit/playback-next.test.ts | unit | tested |
| nextShuffledEpisode | src/playback.ts:973 | tests/unit/playback-next.test.ts | unit | tested via autoplayNext |
| nextFromServer | src/playback.ts:1004 | tests/unit/playback-next.test.ts | unit | tested via peekNextEpisode, autoplayNext |
| autoplayNext | src/playback.ts:1010 | tests/unit/playback-next.test.ts | unit | tested via maybeAutoplay, playNextNow |
| maybeAutoplay | src/playback.ts:1052 | tests/unit/playback-next.test.ts | unit | tested via registerPlayerBridge (player-status) |
| SPACE_HEADROOM | src/playback.ts:1099 | tests/unit/playback-downloads.test.ts | unit | tested via resolveSpace |
| freeSpace | src/playback.ts:1102 | tests/unit/playback-downloads.test.ts | unit | tested via resolveSpace |
| estimateTotal | src/playback.ts:1109 | tests/unit/playback-downloads.test.ts | unit | tested via resolveSpace |
| resolveSpace | src/playback.ts:1131 | tests/unit/playback-downloads.test.ts | unit | tested via startDownload, downloadSeason |
| startDownload | src/playback.ts:1183 | tests/unit/playback-downloads.test.ts | unit | tested |
| beginDownload | src/playback.ts:1201 | tests/unit/playback-downloads.test.ts | unit | tested via pumpQueue |
| isRetry | src/playback.ts:1304 | tests/unit/playback-downloads.test.ts | unit | tested via getQueuedDownloads, pumpQueue |
| isTranscodeEntry | src/playback.ts:1309 | tests/unit/playback-downloads.test.ts | unit | tested via getQueuedDownloads, nextStartable |
| isTranscodeDownload | src/playback.ts:1314 | tests/unit/playback-downloads.test.ts | unit | tested |
| entryId | src/playback.ts:1320 | tests/unit/playback-downloads.test.ts | unit | tested via cancelQueuedDownload, startDownload |
| isDownloadsPaused | src/playback.ts:1338 | tests/unit/playback-downloads.test.ts | unit | tested |
| unmeteredOnly | src/playback.ts:1342 | tests/unit/playback-downloads.test.ts | unit | tested via downloadHoldReason |
| transcodeSerial | src/playback.ts:1346 | tests/unit/playback-downloads.test.ts | unit | tested via nextStartable, isWaitingForTranscode |
| downloadHoldReason | src/playback.ts:1354 | tests/unit/playback-downloads.test.ts | unit | tested |
| setAsideRunning | src/playback.ts:1365 | tests/unit/playback-downloads.test.ts | unit | tested via setDownloadsPaused, applyMeteredHold, restoreDownloadQueue |
| setDownloadsPaused | src/playback.ts:1388 | tests/unit/playback-downloads.test.ts | unit | tested |
| downloadPrefsChanged | src/playback.ts:1408 | tests/unit/playback-downloads.test.ts | unit | tested |
| applyMeteredHold | src/playback.ts:1415 | tests/unit/playback-downloads.test.ts | unit | tested via downloadPrefsChanged, network-metered event |
| MAX_DOWNLOAD_CONCURRENCY | src/playback.ts:1438 | tests/unit/playback-downloads.test.ts | unit | tested |
| dlConcurrency initialiser | src/playback.ts:1441 | tests/unit/playback-downloads.test.ts | unit | tested via getDownloadConcurrency |
| getDownloadConcurrency | src/playback.ts:1446 | tests/unit/playback-downloads.test.ts | unit | tested |
| setDownloadConcurrency | src/playback.ts:1452 | tests/unit/playback-downloads.test.ts | unit | tested |
| saveQueue | src/playback.ts:1462 | tests/unit/playback-downloads.test.ts | unit | tested via notifyQueueChanged |
| getQueuedDownloads | src/playback.ts:1495 | tests/unit/playback-downloads.test.ts | unit | tested |
| cancelQueuedDownload | src/playback.ts:1523 | tests/unit/playback-downloads.test.ts | unit | tested |
| queueRetriesFirst | src/playback.ts:1544 | tests/unit/playback-downloads.test.ts | unit | tested via retryDownload, retryFailedDownloads |
| retryDownload | src/playback.ts:1582 | tests/unit/playback-downloads.test.ts | unit | tested |
| retryFailedDownloads | src/playback.ts:1605 | tests/unit/playback-downloads.test.ts | unit | tested |
| clearDownloadQueue | src/playback.ts:1614 | tests/unit/playback-downloads.test.ts | unit | tested |
| notifyQueueChanged | src/playback.ts:1623 | tests/unit/playback-downloads.test.ts | unit | tested via startDownload, cancelQueuedDownload |
| ensureQueueBridge | src/playback.ts:1628 | tests/unit/playback-downloads.test.ts | unit | tested via download-progress, network-metered and aquarium-connectivity events |
| scheduleAutomaticRetry | src/playback.ts:1666 | tests/unit/playback-downloads.test.ts | unit | tested via download-progress event |
| armRetryWake | src/playback.ts:1687 | tests/unit/playback-downloads.test.ts | unit | tested via pumpQueue |
| nextStartable | src/playback.ts:1703 | tests/unit/playback-downloads.test.ts | unit | tested via pumpQueue |
| isWaitingForTranscode | src/playback.ts:1715 | tests/unit/playback-downloads.test.ts | unit | tested |
| pumpQueue | src/playback.ts:1719 | tests/unit/playback-downloads.test.ts | unit | tested via startDownload, downloadSeason, retries |
| downloadSeason | src/playback.ts:1764 | tests/unit/playback-downloads.test.ts | unit | tested |
| downloadSeries | src/playback.ts:1806 | tests/unit/playback-downloads.test.ts | unit | tested |
| restoreDownloadQueue | src/playback.ts:1828 | tests/unit/playback-downloads.test.ts | unit | tested |
| QUALITY_CHOICES | src/playback.ts:1911 | tests/unit/playback-start.test.ts | unit | tested |
| getQualityState | src/playback.ts:1921 | tests/unit/playback-start.test.ts | unit | tested |
| downloadedLabel | src/playback.ts:1947 | tests/unit/playback-prefs.test.ts | unit | tested |
| switchQuality | src/playback.ts:1956 | tests/unit/playback-start.test.ts | unit | tested |
| switchToDownload | src/playback.ts:1984 | tests/unit/playback-start.test.ts | unit | tested |
| isAdaptiveEnabled | src/playback.ts:2016 | tests/unit/playback-prefs.test.ts | unit | tested |
| setAdaptiveEnabled | src/playback.ts:2020 | tests/unit/playback-prefs.test.ts | unit | tested |
| mpvCommand | src/playback.ts:2029 | tests/unit/playback-prefs.test.ts | unit | tested via playerCtl.setProp |
| openUoscMenu | src/playback.ts:2033 | tests/unit/playback-next.test.ts | unit | tested via showQualityMenu, showEpisodeMenu |
| showQualityMenu | src/playback.ts:2037 | tests/unit/playback-next.test.ts | unit | tested |
| getEpisodeQueue | src/playback.ts:2079 | tests/unit/playback-next.test.ts | unit | tested |
| playQueuedEpisode | src/playback.ts:2095 | tests/unit/playback-next.test.ts | unit | tested |
| showEpisodeMenu | src/playback.ts:2107 | tests/unit/playback-next.test.ts | unit | tested |
| handlePlayerMessage | src/playback.ts:2128 | tests/unit/playback-next.test.ts | unit | tested via registerPlayerBridge (player-message) |
| registerPlayerBridge | src/playback.ts:2194 | tests/unit/playback-start.test.ts, tests/unit/playback-next.test.ts | unit | tested |
| SPEEDS | src/playback.ts:2246 | tests/unit/playback-prefs.test.ts | unit | tested |
| SUB_DELAY_STEP | src/playback.ts:2250 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.pauseToggle | src/playback.ts:2253 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setProp | src/playback.ts:2261 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.stop | src/playback.ts:2262 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.seek | src/playback.ts:2263 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setTrack | src/playback.ts:2264 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setVolume | src/playback.ts:2267 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setMute | src/playback.ts:2271 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setSpeed | src/playback.ts:2272 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setSubDelay | src/playback.ts:2274 | tests/unit/playback-prefs.test.ts | unit | tested |
| playerCtl.setAudioDelay | src/playback.ts:2279 | tests/unit/playback-prefs.test.ts | unit | tested |
| AUDIO_DELAY_STEP | src/playback.ts:2288 | tests/unit/playback-prefs.test.ts | unit | tested |
| getStreamSource | src/playback.ts:2291 | tests/unit/playback-start.test.ts | unit | expected failure (bug) |
| getNowPlayingFull | src/playback.ts:2295 | tests/unit/playback-start.test.ts | unit | tested |
| syncOfflineProgress | src/playback.ts:2300 | tests/unit/playback-prefs.test.ts | unit | tested |
| now | src/adaptive.ts:78 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| rungIndex | src/adaptive.ts:80 | tests/unit/adaptive.test.ts | unit | tested via currentRung, onStarted |
| resetStream | src/adaptive.ts:86 | tests/unit/adaptive.test.ts | unit | tested via onStarted, onStatus |
| currentRung | src/adaptive.ts:102 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| settling | src/adaptive.ts:110 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| nextRungDown | src/adaptive.ts:132 | tests/unit/adaptive.test.ts | unit | tested via stepDown |
| stepDown | src/adaptive.ts:145 | tests/unit/adaptive.test.ts | unit | tested via onStall, onStatus |
| stepUp | src/adaptive.ts:203 | tests/unit/adaptive.test.ts | unit | tested via onStatus |
| onStall | src/adaptive.ts:224 | tests/unit/adaptive.test.ts | unit | tested via player-stall event |
| onStatus | src/adaptive.ts:235 | tests/unit/adaptive.test.ts | unit | tested via player-status event |
| onStarted | src/adaptive.ts:297 | tests/unit/adaptive.test.ts | unit | tested via aquarium-player-started event |
| registerAdaptiveQuality | src/adaptive.ts:313 | tests/unit/adaptive.test.ts | unit | tested |
| schedule | src/prefetch.ts:18 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| cancel | src/prefetch.ts:32 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| cardElFrom | src/prefetch.ts:40 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| left | src/prefetch.ts:50 | tests/unit/prefetch.test.ts | unit | tested via wirePrefetch |
| wirePrefetch | src/prefetch.ts:54 | tests/unit/prefetch.test.ts | unit | tested |
