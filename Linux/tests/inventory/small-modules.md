| Function | Source | Test file | Kind | Status |
|---|---|---|---|---|
| decode83 | src/blurhash.ts:26 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| toLinear | src/blurhash.ts:38 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| toSrgb | src/blurhash.ts:43 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| signPow | src/blurhash.ts:49 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| blurhashUrl | src/blurhash.ts:57 | tests/unit/blurhash.test.ts | unit | tested |
| render | src/blurhash.ts:69 | tests/unit/blurhash.test.ts | unit | tested via blurhashUrl |
| openDb | src/cache.ts:50 | tests/unit/cache.test.ts | unit | tested via hydrateCache |
| promisify | src/cache.ts:80 | tests/unit/cache.test.ts | unit | tested via hydrateCache |
| enqueue | src/cache.ts:91 | tests/unit/cache.test.ts | unit | tested via setCached |
| persist | src/cache.ts:104 | tests/unit/cache.test.ts | unit | tested via setCached |
| unpersist | src/cache.ts:117 | tests/unit/cache.test.ts | unit | tested via invalidateCache |
| getCached | src/cache.ts:126 | tests/unit/cache.test.ts | unit | tested |
| setCached | src/cache.ts:130 | tests/unit/cache.test.ts | unit | tested |
| invalidateCache | src/cache.ts:135 | tests/unit/cache.test.ts | unit | tested |
| clearCache | src/cache.ts:140 | tests/unit/cache.test.ts | unit | tested |
| hydrateCache | src/cache.ts:157 | tests/unit/cache.test.ts | unit | tested |
| itemSignature | src/cache.ts:192 | tests/unit/cache.test.ts | unit | tested |
| channelLabel | src/channels-panel.ts:23 | tests/dom/channels-panel.test.ts | dom | tested via liveTitleLines |
| logo | src/channels-panel.ts:26 | tests/dom/channels-panel.test.ts | dom | tested via fillChannelsPanel |
| liveTitleLines | src/channels-panel.ts:46 | tests/dom/channels-panel.test.ts | dom | tested |
| switchChannel | src/channels-panel.ts:77 | tests/dom/channels-panel.test.ts | dom | tested |
| switchChannel redraw | src/channels-panel.ts:84 | tests/dom/channels-panel.test.ts | dom | tested via switchChannel |
| stepChannel | src/channels-panel.ts:97 | tests/dom/channels-panel.test.ts | dom | tested |
| fillChannelsPanel | src/channels-panel.ts:112 | tests/dom/channels-panel.test.ts | dom | tested |
| draw | src/channels-panel.ts:137 | tests/dom/channels-panel.test.ts | dom | tested via fillChannelsPanel |
| lineupKey | src/lineup.ts:17 | tests/unit/lineup.test.ts | unit | tested |
| cachedLineup | src/lineup.ts:22 | tests/unit/lineup.test.ts | unit | tested |
| isChannel | src/lineup.ts:27 | tests/unit/lineup.test.ts | unit | tested |
| loadLineup | src/lineup.ts:38 | tests/unit/lineup.test.ts | unit | tested |
| readSchedule | src/lineup.ts:74 | tests/unit/lineup.test.ts | unit | tested via nearSchedule |
| scheduleStale | src/lineup.ts:93 | tests/unit/lineup.test.ts | unit | tested via nearSchedule |
| nearSchedule | src/lineup.ts:99 | tests/unit/lineup.test.ts | unit | tested |
| nowNextSync | src/lineup.ts:121 | tests/unit/lineup.test.ts | unit | tested |
| pickNowNext | src/lineup.ts:127 | tests/unit/lineup.test.ts | unit | tested via nowNext |
| nowNext | src/lineup.ts:148 | tests/unit/lineup.test.ts | unit | tested |
| onNow | src/lineup.ts:158 | tests/unit/lineup.test.ts | unit | tested |
| progressOf | src/lineup.ts:171 | tests/unit/lineup.test.ts | unit | tested |
| fmtClock | src/lineup.ts:177 | tests/unit/lineup.test.ts | unit | tested |
| playChannel | src/lineup.ts:188 | tests/unit/lineup.test.ts | unit | tested |
| preloadLineup | src/lineup.ts:211 | tests/unit/lineup.test.ts | unit | tested |
| refreshNow | src/lineup.ts:230 | tests/unit/lineup.test.ts | unit | tested |
| reducedMotion | src/scroll.ts:32 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| deltaPixels | src/scroll.ts:37 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| overNestedScroller | src/scroll.ts:67 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| wireSmoothScroll | src/scroll.ts:79 | tests/unit/scroll.test.ts | unit | tested |
| maxScroll | src/scroll.ts:88 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| stop | src/scroll.ts:90 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| frame | src/scroll.ts:100 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| onWheel | src/scroll.ts:136 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| onScroll | src/scroll.ts:167 | tests/unit/scroll.test.ts | unit | tested via wireSmoothScroll |
| blankSmartPlaylist | src/smartPlaylists.ts:27 | tests/unit/smartPlaylists.test.ts | unit | tested |
| getSmartPlaylists | src/smartPlaylists.ts:44 | tests/unit/smartPlaylists.test.ts | unit | tested |
| saveSmartPlaylist | src/smartPlaylists.ts:52 | tests/unit/smartPlaylists.test.ts | unit | tested |
| deleteSmartPlaylist | src/smartPlaylists.ts:60 | tests/unit/smartPlaylists.test.ts | unit | tested |
| asItem | src/smartPlaylists.ts:65 | tests/unit/smartPlaylists.test.ts | unit | tested |
| describe | src/smartPlaylists.ts:70 | tests/unit/smartPlaylists.test.ts | unit | tested |
| smartPlaylistSongs | src/smartPlaylists.ts:86 | tests/unit/smartPlaylists.test.ts | unit | tested |
| boxOf | src/spatial.ts:28 | tests/unit/spatial.test.ts | unit | tested via wireSpatialNav |
| pick | src/spatial.ts:49 | tests/unit/spatial.test.ts | unit | tested via wireSpatialNav |
| move | src/spatial.ts:91 | tests/unit/spatial.test.ts | unit | tested via wireSpatialNav |
| wireSpatialNav | src/spatial.ts:121 | tests/unit/spatial.test.ts | unit | tested |
| DIALS | src/stations.ts:18 | tests/unit/stations.test.ts | unit | tested |
| DIAL_INFO | src/stations.ts:22 | tests/unit/stations.test.ts | unit | tested |
| BUDGET | src/stations.ts:44 | tests/unit/stations.test.ts | unit | tested via remaining |
| points | src/stations.ts:46 | tests/unit/stations.test.ts | unit | tested |
| PRESETS | src/stations.ts:59 | tests/unit/stations.test.ts | unit | tested |
| remaining | src/stations.ts:65 | tests/unit/stations.test.ts | unit | tested |
| presetName | src/stations.ts:69 | tests/unit/stations.test.ts | unit | tested |
| getMixPoints | src/stations.ts:73 | tests/unit/stations.test.ts | unit | tested |
| saveMixPoints | src/stations.ts:78 | tests/unit/stations.test.ts | unit | tested |
| withDial | src/stations.ts:83 | tests/unit/stations.test.ts | unit | tested |
| weight | src/stations.ts:89 | tests/unit/stations.test.ts | unit | tested via likeness |
| genreKey | src/stations.ts:100 | tests/unit/stations.test.ts | unit | tested |
| words | src/stations.ts:114 | tests/unit/stations.test.ts | unit | tested via likeness |
| artistKeys | src/stations.ts:118 | tests/unit/stations.test.ts | unit | tested via profileOf |
| artistKeys add | src/stations.ts:120 | tests/unit/stations.test.ts | unit | tested via profileOf |
| lead | src/stations.ts:130 | tests/unit/stations.test.ts | unit | tested via score |
| genresOf | src/stations.ts:136 | tests/unit/stations.test.ts | unit | tested via profileOf |
| emptyProfile | src/stations.ts:153 | tests/unit/stations.test.ts | unit | tested via profileOf |
| addGenres | src/stations.ts:157 | tests/unit/stations.test.ts | unit | tested via profileOf |
| profileOf | src/stations.ts:164 | tests/unit/stations.test.ts | unit | tested |
| genreAffinity | src/stations.ts:198 | tests/unit/stations.test.ts | unit | tested via likeness |
| likeness | src/stations.ts:213 | tests/unit/stations.test.ts | unit | tested |
| sameAct | src/stations.ts:238 | tests/unit/stations.test.ts | unit | tested |
| actGrouper | src/stations.ts:244 | tests/unit/stations.test.ts | unit | tested via sequence |
| score | src/stations.ts:259 | tests/unit/stations.test.ts | unit | tested |
| sequence | src/stations.ts:282 | tests/unit/stations.test.ts | unit | tested |
| safe | src/stations.ts:344 | tests/unit/stations.test.ts | unit | tested via buildStation |
| similarArtistSongs | src/stations.ts:352 | tests/unit/stations.test.ts | unit | tested via buildStation |
| gather | src/stations.ts:359 | tests/unit/stations.test.ts | unit | tested via buildStation |
| dedupe | src/stations.ts:398 | tests/unit/stations.test.ts | unit | tested via buildStation |
| Station.more | src/stations.ts:409 | tests/unit/stations.test.ts | unit | tested via buildStation |
| Station.first | src/stations.ts:415 | tests/unit/stations.test.ts | unit | tested via buildStation |
| buildStation | src/stations.ts:424 | tests/unit/stations.test.ts | unit | tested |
| getMixSource | src/stations.ts:438 | tests/unit/stations.test.ts | unit | tested |
| buildInstantMix | src/stations.ts:443 | tests/unit/stations.test.ts | unit | tested |
| buildOfflineMix | src/stations.ts:451 | tests/unit/stations.test.ts | unit | tested |
| _internal | src/stations.ts:465 | tests/unit/stations.test.ts | unit | tested |
| normalizePref | src/theme.ts:26 | tests/unit/theme.test.ts | unit | tested |
| fromMediaQuery | src/theme.ts:30 | tests/unit/theme.test.ts | unit | tested via initTheme |
| resolved | src/theme.ts:36 | tests/unit/theme.test.ts | unit | tested via initTheme |
| apply | src/theme.ts:41 | tests/unit/theme.test.ts | unit | tested via initTheme |
| setSystem | src/theme.ts:51 | tests/unit/theme.test.ts | unit | tested via initTheme |
| getThemePref | src/theme.ts:55 | tests/unit/theme.test.ts | unit | tested |
| setThemePref | src/theme.ts:60 | tests/unit/theme.test.ts | unit | tested |
| initTheme | src/theme.ts:66 | tests/unit/theme.test.ts | unit | tested |
| legacy fellyjin localStorage carry-over | public/theme-boot.js:10 | tests/unit/theme.test.ts | unit | tested |
| pre-paint theme apply | public/theme-boot.js:21 | tests/unit/theme.test.ts | unit | tested |
| MUSIC_FIELDS | src/musicApi.ts:14 | tests/unit/musicApi.test.ts | unit | tested |
| MUSIC_DETAIL_FIELDS | src/musicApi.ts:18 | tests/unit/musicApi.test.ts | unit | tested |
| SORTS | src/musicApi.ts:27 | tests/unit/musicApi.test.ts | unit | tested |
| sess | src/musicApi.ts:57 | tests/unit/musicApi.test.ts | unit | tested via music |
| music | src/musicApi.ts:64 | tests/unit/musicApi.test.ts | unit | tested |
| artists | src/musicApi.ts:98 | tests/unit/musicApi.test.ts | unit | tested |
| musicItem | src/musicApi.ts:119 | tests/unit/musicApi.test.ts | unit | tested |
| sortedByTrack | src/musicApi.ts:125 | tests/unit/musicApi.test.ts | unit | tested |
| albumTracks | src/musicApi.ts:135 | tests/unit/musicApi.test.ts | unit | tested |
| topSongs | src/musicApi.ts:140 | tests/unit/musicApi.test.ts | unit | tested |
| allSongs | src/musicApi.ts:144 | tests/unit/musicApi.test.ts | unit | tested |
| albumsBy | src/musicApi.ts:148 | tests/unit/musicApi.test.ts | unit | tested |
| appearsOn | src/musicApi.ts:153 | tests/unit/musicApi.test.ts | unit | tested |
| genreSongs | src/musicApi.ts:158 | tests/unit/musicApi.test.ts | unit | tested |
| musicGenres | src/musicApi.ts:162 | tests/unit/musicApi.test.ts | unit | tested |
| audioPlaylists | src/musicApi.ts:179 | tests/unit/musicApi.test.ts | unit | tested |
| playlistItems | src/musicApi.ts:190 | tests/unit/musicApi.test.ts | unit | tested |
| createPlaylist | src/musicApi.ts:208 | tests/unit/musicApi.test.ts | unit | tested |
| renamePlaylist | src/musicApi.ts:218 | tests/unit/musicApi.test.ts | unit | tested |
| deletePlaylist | src/musicApi.ts:222 | tests/unit/musicApi.test.ts | unit | tested |
| addToPlaylist | src/musicApi.ts:226 | tests/unit/musicApi.test.ts | unit | tested |
| removeFromPlaylist | src/musicApi.ts:235 | tests/unit/musicApi.test.ts | unit | tested |
| movePlaylistEntry | src/musicApi.ts:240 | tests/unit/musicApi.test.ts | unit | tested |
| instantMix | src/musicApi.ts:246 | tests/unit/musicApi.test.ts | unit | tested |
| similarArtists | src/musicApi.ts:254 | tests/unit/musicApi.test.ts | unit | tested |
| recentlyPlayedSongs | src/musicApi.ts:260 | tests/unit/musicApi.test.ts | unit | tested |
| mostPlayedSongs | src/musicApi.ts:264 | tests/unit/musicApi.test.ts | unit | tested |
| resumeBooks | src/musicApi.ts:269 | tests/unit/musicApi.test.ts | unit | tested |
| lyrics | src/musicApi.ts:287 | tests/unit/musicApi.test.ts | unit | tested |
| searchMusic | src/musicApi.ts:302 | tests/unit/musicApi.test.ts | unit | tested |
| artistLine | src/musicApi.ts:320 | tests/unit/musicApi.test.ts | unit | tested |
| coverUrl | src/musicApi.ts:331 | tests/unit/musicApi.test.ts | unit | tested |
| albumsInOrder | src/musicApi.ts:343 | tests/unit/musicApi.test.ts | unit | tested |
| streamUrl | src/musicApi.ts:364 | tests/unit/musicApi.test.ts | unit | tested |
| secondsOf | src/musicApi.ts:369 | tests/unit/musicApi.test.ts | unit | tested |
| clock | src/musicApi.ts:373 | tests/unit/musicApi.test.ts | unit | tested |
| longDuration | src/musicApi.ts:382 | tests/unit/musicApi.test.ts | unit | tested |
| iconSvg | src/icons.ts:55 | tests/unit/icons.test.ts | unit | tested |
| iconSvg per-icon stroke widths | src/icons.ts:16 | tests/unit/icons.test.ts | unit | expected failure (bug) |
| icon | src/icons.ts:64 | tests/unit/icons.test.ts | unit | tested |
| readNumber | src/audio.ts:67 | tests/unit/audio.test.ts | unit | tested via bookSpeed |
| writeValue | src/audio.ts:75 | tests/unit/audio.test.ts | unit | tested via setSpeed |
| onChange | src/audio.ts:92 | tests/unit/audio.test.ts | unit | tested |
| changed | src/audio.ts:97 | tests/unit/audio.test.ts | unit | tested via onChange |
| getStatus | src/audio.ts:107 | tests/unit/audio.test.ts | unit | tested |
| isActive | src/audio.ts:111 | tests/unit/audio.test.ts | unit | tested |
| current | src/audio.ts:115 | tests/unit/audio.test.ts | unit | tested |
| queueState | src/audio.ts:119 | tests/unit/audio.test.ts | unit | tested |
| upNext | src/audio.ts:124 | tests/unit/audio.test.ts | unit | tested |
| isShuffled | src/audio.ts:128 | tests/unit/audio.test.ts | unit | tested |
| currentChapter | src/audio.ts:133 | tests/unit/audio.test.ts | unit | tested |
| trackOf | src/audio.ts:149 | tests/unit/audio.test.ts | unit | tested via play |
| followingIndex | src/audio.ts:165 | tests/unit/audio.test.ts | unit | tested via play |
| soundCheck | src/audio.ts:171 | tests/unit/audio.test.ts | unit | tested via setSoundCheck |
| publishQueue | src/audio.ts:175 | tests/unit/audio.test.ts | unit | tested via play |
| startAt | src/audio.ts:189 | tests/unit/audio.test.ts | unit | tested via play |
| handDownNext | src/audio.ts:224 | tests/unit/audio.test.ts | unit | tested via play |
| topUp | src/audio.ts:234 | tests/unit/audio.test.ts | unit | tested via play |
| attachLocal | src/audio.ts:260 | tests/unit/audio.test.ts | unit | tested via play |
| play | src/audio.ts:283 | tests/unit/audio.test.ts | unit | tested |
| replaceUpNext | src/audio.ts:308 | tests/unit/audio.test.ts | unit | tested |
| playNext | src/audio.ts:324 | tests/unit/audio.test.ts | unit | tested |
| playLater | src/audio.ts:335 | tests/unit/audio.test.ts | unit | tested |
| next | src/audio.ts:345 | tests/unit/audio.test.ts | unit | tested |
| previous | src/audio.ts:357 | tests/unit/audio.test.ts | unit | tested |
| jump | src/audio.ts:365 | tests/unit/audio.test.ts | unit | tested |
| stop | src/audio.ts:369 | tests/unit/audio.test.ts | unit | tested |
| removeAt | src/audio.ts:385 | tests/unit/audio.test.ts | unit | tested |
| move | src/audio.ts:398 | tests/unit/audio.test.ts | unit | tested |
| clearUpNext | src/audio.ts:407 | tests/unit/audio.test.ts | unit | tested |
| shuffled | src/audio.ts:417 | tests/unit/audio.test.ts | unit | tested via setShuffle |
| setShuffle | src/audio.ts:426 | tests/unit/audio.test.ts | unit | tested |
| cycleRepeat | src/audio.ts:444 | tests/unit/audio.test.ts | unit | tested |
| togglePause | src/audio.ts:456 | tests/unit/audio.test.ts | unit | tested |
| seek | src/audio.ts:461 | tests/unit/audio.test.ts | unit | tested |
| skip | src/audio.ts:468 | tests/unit/audio.test.ts | unit | tested |
| setVolume | src/audio.ts:472 | tests/unit/audio.test.ts | unit | tested |
| setMute | src/audio.ts:479 | tests/unit/audio.test.ts | unit | tested |
| BOOK_SPEEDS | src/audio.ts:483 | tests/unit/audio.test.ts | unit | tested |
| bookSpeed | src/audio.ts:485 | tests/unit/audio.test.ts | unit | tested |
| setSpeed | src/audio.ts:489 | tests/unit/audio.test.ts | unit | tested |
| setSoundCheck | src/audio.ts:494 | tests/unit/audio.test.ts | unit | tested |
| soundCheckOn | src/audio.ts:499 | tests/unit/audio.test.ts | unit | tested |
| sleepState | src/audio.ts:509 | tests/unit/audio.test.ts | unit | tested |
| cancelSleep | src/audio.ts:513 | tests/unit/audio.test.ts | unit | tested via setSleep |
| setSleep | src/audio.ts:521 | tests/unit/audio.test.ts | unit | tested |
| pauseForSleep | src/audio.ts:542 | tests/unit/audio.test.ts | unit | tested via setSleep |
| wireAudio | src/audio.ts:553 | tests/unit/audio.test.ts | unit | tested |
| isCustom | src/iptv.ts:38 | tests/unit/iptv.test.ts | unit | tested |
| sourceUrls | src/iptv.ts:42 | tests/unit/iptv.test.ts | unit | tested |
| DEFAULT_USER_AGENT | src/iptv.ts:57 | tests/unit/iptv.test.ts | unit | tested |
| iptvUserAgent | src/iptv.ts:60 | tests/unit/iptv.test.ts | unit | tested |
| DEFAULT_REFRESH_MIN | src/iptv.ts:66 | tests/unit/iptv.test.ts | unit | tested |
| refreshMinutes | src/iptv.ts:68 | tests/unit/iptv.test.ts | unit | tested |
| attrs | src/iptv.ts:78 | tests/unit/iptv.test.ts | unit | tested via parseM3u |
| parseM3u | src/iptv.ts:100 | tests/unit/iptv.test.ts | unit | tested |
| xmltvTime | src/iptv.ts:152 | tests/unit/iptv.test.ts | unit | tested |
| textOf | src/iptv.ts:166 | tests/unit/iptv.test.ts | unit | tested via parseXmltv |
| parseXmltv | src/iptv.ts:175 | tests/unit/iptv.test.ts | unit | tested |
| aged | src/iptv.ts:236 | tests/unit/iptv.test.ts | unit | tested via isDue |
| norm | src/iptv.ts:241 | tests/unit/iptv.test.ts | unit | tested via load |
| join | src/iptv.ts:243 | tests/unit/iptv.test.ts | unit | tested via load |
| fetchText | src/iptv.ts:276 | tests/unit/iptv.test.ts | unit | tested via load |
| loadFresh | src/iptv.ts:280 | tests/unit/iptv.test.ts | unit | tested via load |
| load | src/iptv.ts:305 | tests/unit/iptv.test.ts | unit | tested |
| invalidate | src/iptv.ts:326 | tests/unit/iptv.test.ts | unit | tested |
| isDue | src/iptv.ts:331 | tests/unit/iptv.test.ts | unit | tested |
| lastRead | src/iptv.ts:339 | tests/unit/iptv.test.ts | unit | tested |
| getChannels | src/iptv.ts:358 | tests/unit/iptv.test.ts | unit | tested |
| getPrograms | src/iptv.ts:364 | tests/unit/iptv.test.ts | unit | tested |
| describe | src/iptv.ts:378 | tests/unit/iptv.test.ts | unit | tested |
