| Function | Source | Test file | Kind | Status |
| --- | --- | --- | --- | --- |
| ICONS (sidebar glyphs) | src/main.ts:86 | tests/dom/main-shell.test.ts | dom | tested via paintNav |
| fsSetBar | src/main.ts:157 | tests/dom/main-fullscreen.test.ts | dom | tested via fsPokeControls/fsArmHide |
| userSubPos | src/main.ts:175 | tests/dom/main-fullscreen.test.ts | dom | tested via fsSetBar (sub_pos lift and restore, damaged value) |
| fsPokeControls | src/main.ts:182 | tests/dom/main-fullscreen.test.ts | dom | tested via document mousemove, player-mouse, notes, tap |
| fsArmHide | src/main.ts:194 | tests/dom/main-fullscreen.test.ts | dom | tested (hide after Settings interval, hover and open panel keep it up) |
| fsPointerMoved | src/main.ts:218 | tests/dom/main-fullscreen.test.ts | dom | tested (Linux/CLAUDE.md invariant: out-of-window and repeated mousemoves ignored) |
| setVideoFullscreen | src/main.ts:230 | tests/dom/main-fullscreen.test.ts | dom | tested via f, button, Escape, events, gestures |
| setVideoPip | src/main.ts:284 | tests/dom/main-fullscreen.test.ts | dom | tested via p, button, ctl pip, quit prompt |
| reflectCoverage | src/main.ts:309 | tests/dom/main-player.test.ts | dom | tested via updatePlayerBar and PiP (body.video-covered) |
| reflectPip | src/main.ts:313 | tests/dom/main-fullscreen.test.ts | dom | tested via setVideoPip and player-pip |
| hashOf | src/main.ts:338 | tests/dom/main-boot.test.ts | dom | tested via hashchange back trail |
| goBack | src/main.ts:349 | tests/dom/main-boot.test.ts | dom | tested via Back button, Alt+Left, mouse button 3 |
| atHome | src/main.ts:360 | tests/dom/main-boot.test.ts | dom | tested via back trail and next-up-changed |
| updateBackButton | src/main.ts:365 | tests/dom/main-boot.test.ts | dom | tested via back trail |
| SERVER_PAGES | src/main.ts:371 | tests/dom/main-boot.test.ts | dom | tested via route (offline pages) |
| renderOffline | src/main.ts:373 | tests/dom/main-boot.test.ts | dom | tested (Go to Downloads, Retry connection) |
| highlightNav | src/main.ts:407 | tests/dom/main-shell.test.ts | dom | tested (active entry, aria-current) |
| settleScroll | src/main.ts:425 | tests/dom/main-boot.test.ts | dom | tested via scroll memory |
| route | src/main.ts:438 | tests/dom/main-boot.test.ts | dom | tested |
| VIEWS_CACHE_KEY | src/main.ts:489 | tests/dom/main-shell.test.ts | dom | tested via buildNav (cache across launches) |
| viewsSignature | src/main.ts:493 | tests/dom/main-shell.test.ts | dom | tested via buildNav (redraw only on change) |
| buildNav | src/main.ts:497 | tests/dom/main-shell.test.ts | dom | tested (cached paint, failure, refresh) |
| paintNav | src/main.ts:526 | tests/dom/main-shell.test.ts | dom | tested (libraries, music, books, Collections, Live TV) |
| updateSidebarFooter | src/main.ts:594 | tests/dom/main-shell.test.ts | dom | tested |
| updateOfflinePill | src/main.ts:629 | tests/dom/main-shell.test.ts | dom | tested via aquarium-connectivity |
| cacheOwner | src/main.ts:635 | tests/dom/main-shell.test.ts | dom | tested via showShell/boot |
| showShell | src/main.ts:640 | tests/dom/main-boot.test.ts | dom | tested (boot; first sign-in in main-shell.test.ts) |
| showLogin | src/main.ts:671 | tests/dom/main-boot.test.ts | dom | tested (boot, Settings sign-out, auth expired, identity change) |
| showAddAccount | src/main.ts:686 | tests/dom/main-shell.test.ts | dom | tested (Cancel, sign-in) |
| enterAccount | src/main.ts:703 | tests/dom/main-shell.test.ts | dom | tested via switch and Add Account; player stop in main-fullscreen.test.ts |
| switchToAccount | src/main.ts:712 | tests/dom/main-shell.test.ts | dom | tested (success, failure) |
| PB_ICONS | src/main.ts:726 | tests/dom/main-player.test.ts | dom | tested via play/pause, volume and skip glyphs |
| skipIcon | src/main.ts:782 | tests/dom/main-player.test.ts | dom | tested via syncSkipButtons |
| syncSkipButtons | src/main.ts:789 | tests/dom/main-player.test.ts | dom | tested (interval from Settings, live change) |
| pbButton | src/main.ts:805 | tests/dom/main-player.test.ts | dom | tested (click and error logged to ui_log) |
| chapterNameAt | src/main.ts:843 | tests/dom/main-player.test.ts | dom | tested via scrubber readout |
| renderChapters | src/main.ts:854 | tests/dom/main-player.test.ts | dom | tested |
| closeBarPanel | src/main.ts:884 | tests/dom/main-panels.test.ts | dom | tested |
| toggleBarPanel | src/main.ts:888 | tests/dom/main-panels.test.ts | dom | tested |
| toggleQualityPicker | src/main.ts:911 | tests/dom/main-panels.test.ts | dom | tested |
| languageName | src/main.ts:976 | tests/dom/main-panels.test.ts | dom | tested via trackLabel |
| trackLabel | src/main.ts:989 | tests/dom/main-panels.test.ts | dom | tested |
| toggleAudioPanel | src/main.ts:996 | tests/dom/main-panels.test.ts | dom | tested |
| toggleSubtitlePanel | src/main.ts:1017 | tests/dom/main-panels.test.ts | dom | tested |
| togglePlaybackPanel | src/main.ts:1050 | tests/dom/main-panels.test.ts | dom | tested |
| togglePicturePanel | src/main.ts:1118 | tests/dom/main-panels.test.ts | dom | tested |
| toggleEpisodePanel | src/main.ts:1218 | tests/dom/main-panels.test.ts | dom | tested (its .catch at 1330 is unreachable: getEpisodeQueue never rejects) |
| toggleChannelsPanel | src/main.ts:1339 | tests/dom/main-panels.test.ts | dom | tested |
| toggleSleepPanel | src/main.ts:1343 | tests/dom/main-panels.test.ts | dom | tested |
| toggleChapterPanel | src/main.ts:1403 | tests/dom/main-panels.test.ts | dom | tested |
| mbps | src/main.ts:1445 | tests/dom/main-panels.test.ts | dom | tested via stream info Bitrate |
| deliveryLabel | src/main.ts:1451 | tests/dom/main-panels.test.ts | dom | expected failure (bug) — server-stream branches unreachable while playback.ts drops the source; local and live branches tested |
| toggleInfoPanel | src/main.ts:1469 | tests/dom/main-panels.test.ts | dom | tested |
| queueTiles | src/main.ts:1525 | tests/dom/main-panels.test.ts | dom | tested (play, right-click remove) |
| VOLUME_THROTTLE_MS | src/main.ts:1561 | tests/dom/main-controls.test.ts | dom | tested via buildVolume throttle |
| setRangeFill | src/main.ts:1568 | tests/dom/main-player.test.ts | dom | tested via scrubber, volume and picture sliders |
| volumeIcon | src/main.ts:1572 | tests/dom/main-controls.test.ts | dom | tested |
| buildVolume | src/main.ts:1577 | tests/dom/main-controls.test.ts | dom | tested (throttle, change, pointerup, unmute) |
| bumpVolume | src/main.ts:1626 | tests/dom/main-controls.test.ts | dom | tested via ArrowUp/ArrowDown |
| stepSpeed | src/main.ts:1643 | tests/dom/main-controls.test.ts | dom | tested via [ and ] |
| resetMediaExtras | src/main.ts:1668 | tests/dom/main-player.test.ts | dom | tested via new item (segments, trickplay, next available, stalls reset) |
| trickplayTile | src/main.ts:1700 | tests/dom/main-player.test.ts | dom | tested (fetched once, failure not retried) |
| showScrubPreview | src/main.ts:1718 | tests/dom/main-player.test.ts | dom | tested |
| hideScrubPreview | src/main.ts:1750 | tests/dom/main-player.test.ts | dom | tested |
| segmentAt | src/main.ts:1755 | tests/dom/main-player.test.ts | dom | tested via skip button |
| syncSkipButton | src/main.ts:1763 | tests/dom/main-player.test.ts | dom | tested |
| UPNEXT_LEAD | src/main.ts:1779 | tests/dom/main-controls.test.ts | dom | tested via syncUpNext |
| syncUpNext | src/main.ts:1781 | tests/dom/main-controls.test.ts | dom | tested |
| upNextKey | src/main.ts:1819 | tests/dom/main-controls.test.ts | dom | tested via thumbnail fetched once |
| upNextTitle | src/main.ts:1828 | tests/dom/main-controls.test.ts | dom | tested |
| dismissUpNext | src/main.ts:1840 | tests/dom/main-controls.test.ts | dom | tested (Not now) |
| upNextShowing | src/main.ts:1847 | tests/dom/main-controls.test.ts | dom | tested via Enter |
| startUpNext | src/main.ts:1851 | tests/dom/main-controls.test.ts | dom | tested (once, failure toast) |
| playerTitleLines | src/main.ts:1868 | tests/dom/main-player.test.ts | dom | tested (episode, film, download record, channel) |
| buildPlayerBar | src/main.ts:1894 | tests/dom/main-player.test.ts | dom | tested (every control; pointer handlers in main-fullscreen.test.ts) |
| barNoteShowing | src/main.ts:2102 | tests/dom/main-controls.test.ts | dom | tested |
| flashBarNote | src/main.ts:2106 | tests/dom/main-controls.test.ts | dom | tested |
| toggleSubtitles | src/main.ts:2117 | tests/dom/main-controls.test.ts | dom | tested |
| skipSegment | src/main.ts:2139 | tests/dom/main-player.test.ts | dom | tested via s and ctl skip |
| skipBy | src/main.ts:2147 | tests/dom/main-controls.test.ts | dom | tested (not on live) |
| nudgeAudioDelay | src/main.ts:2154 | tests/dom/main-controls.test.ts | dom | tested (keys, picture input, tune panel) |
| openInfo | src/main.ts:2165 | tests/dom/main-controls.test.ts | dom | tested |
| openPictureMenu | src/main.ts:2177 | tests/dom/main-controls.test.ts | dom | tested |
| onPlayerInput | src/main.ts:2239 | tests/dom/main-controls.test.ts | dom | tested (keys, ctl, gestures, context) |
| barOutOfSight | src/main.ts:2322 | tests/dom/main-fullscreen.test.ts | dom | tested |
| updatePlayerBar | src/main.ts:2326 | tests/dom/main-player.test.ts | dom | tested |
| syncAudioState | src/main.ts:2435 | tests/dom/main-controls.test.ts | dom | tested |
| SEARCH_DEBOUNCE_MS | src/main.ts:2468 | tests/dom/main-shell.test.ts | dom | tested via wireSearch |
| gotoSearch | src/main.ts:2475 | tests/dom/main-shell.test.ts | dom | tested (push once, then replace) |
| wireSearch | src/main.ts:2486 | tests/dom/main-shell.test.ts | dom | tested |
| isTyping | src/main.ts:2576 | tests/dom/main-shell.test.ts | dom | tested via /, ? and spatial nav |
| wireGlobalKeys | src/main.ts:2583 | tests/dom/main-shell.test.ts | dom | tested (? sheet; Alt+Left in main-boot.test.ts) |
| SHORTCUTS | src/main.ts:2607 | tests/dom/main-shell.test.ts | dom | tested via toggleShortcuts |
| toggleShortcuts | src/main.ts:2661 | tests/dom/main-shell.test.ts | dom | expected failure (bug) — reopening after its Close button; open/close/Escape tested |
| askBeforeQuit | src/main.ts:2707 | tests/dom/main-fullscreen.test.ts | dom | tested |
| LAST_ROUTE_KEY / RESUMABLE | src/main.ts:2748 | tests/dom/main-boot.test.ts | dom | tested via rememberRoute/lastRoute |
| rememberRoute | src/main.ts:2753 | tests/dom/main-boot.test.ts | dom | tested |
| lastRoute | src/main.ts:2764 | tests/dom/main-boot.test.ts | dom | tested |
| boot | src/main.ts:2775 | tests/dom/main-boot.test.ts | dom | tested (every listener exercised across the main-*.test.ts files) |
| stopServerRetry (in boot) | src/main.ts:2929 | tests/dom/main-shell.test.ts | dom | tested |
| scheduleServerRetry (in boot) | src/main.ts:2937 | tests/dom/main-shell.test.ts | dom | tested (15 s, doubling, 5 min cap, network and visibility cues) |
| row | src/views/settings.ts:21 | tests/dom/views-settings.test.ts | dom | tested via renderSettings |
| choice | src/views/settings.ts:32 | tests/dom/views-settings.test.ts | dom | tested (save, save failure, onPicked) |
| batteryRenderChoice | src/views/settings.ts:55 | tests/dom/views-settings.test.ts | dom | tested (old true/false configs) |
| toggle | src/views/settings.ts:67 | tests/dom/views-settings.test.ts | dom | tested |
| slider | src/views/settings.ts:92 | tests/dom/views-settings.test.ts | dom | tested (live apply, reset, scale) |
| LANGUAGES | src/views/settings.ts:142 | tests/dom/views-settings.test.ts | dom | tested |
| lastDecoder | src/views/settings.ts:172 | tests/dom/views-settings.test.ts | dom | tested (storage failure) |
| DECODER_NAMES | src/views/settings.ts:180 | tests/dom/views-settings.test.ts | dom | tested |
| downloadsBlock | src/views/settings.ts:192 | tests/dom/views-settings.test.ts | dom | tested |
| renderSettings | src/views/settings.ts:220 | tests/dom/views-settings.test.ts | dom | tested (every block; stale-page guards) |
| drawAccounts (in renderSettings) | src/views/settings.ts:336 | tests/dom/views-settings.test.ts | dom | tested |
| qcSay / qcConfirm (in renderSettings) | src/views/settings.ts:412 | tests/dom/views-settings.test.ts | dom | tested |
| syncLastRead (in renderSettings) | src/views/settings.ts:698 | tests/dom/views-settings.test.ts | dom | tested |
| refreshNow (in renderSettings) | src/views/settings.ts:721 | tests/dom/views-settings.test.ts | dom | tested |
| checkArtwork (in renderSettings) | src/views/settings.ts:741 | tests/dom/views-settings.test.ts | dom | tested |
| syncLiveRows (in renderSettings) | src/views/settings.ts:766 | tests/dom/views-settings.test.ts | dom | tested |
| checkSources (in renderSettings) | src/views/settings.ts:788 | tests/dom/views-settings.test.ts | dom | tested |
| probeArtwork | src/views/settings.ts:1127 | tests/dom/views-settings.test.ts | dom | tested via Check artwork (timeout, unnamed, failures) |
| el | src/ui.ts:9 | tests/dom/ui.test.ts | dom | tested |
| clear | src/ui.ts:30 | tests/dom/ui.test.ts | dom | tested |
| asButton | src/ui.ts:41 | tests/dom/ui.test.ts | dom | tested |
| spinner | src/ui.ts:54 | tests/dom/ui.test.ts | dom | tested |
| noart | src/ui.ts:61 | tests/dom/ui.test.ts | dom | tested |
| noartIcon | src/ui.ts:67 | tests/dom/ui.test.ts | dom | tested |
| art | src/ui.ts:79 | tests/dom/ui.test.ts | dom | tested |
| backdropLayer | src/ui.ts:127 | tests/dom/ui.test.ts | dom | tested |
| heroTitle | src/ui.ts:150 | tests/dom/ui.test.ts | dom | tested |
| liftTint | src/ui.ts:171 | tests/dom/ui.test.ts | dom | tested via ambientTint |
| dominantColor | src/ui.ts:189 | tests/dom/ui.test.ts | dom | tested via ambientTint (canvas stubbed: jsdom has no 2D context) |
| ambientTint | src/ui.ts:233 | tests/dom/ui.test.ts | dom | tested |
| times | src/ui.ts:249 | tests/dom/ui.test.ts | dom | tested via skeletons |
| skeletonCards | src/ui.ts:253 | tests/dom/ui.test.ts | dom | tested |
| skeletonRow | src/ui.ts:264 | tests/dom/ui.test.ts | dom | tested |
| skeletonGrid | src/ui.ts:269 | tests/dom/ui.test.ts | dom | tested |
| skeletonRows | src/ui.ts:277 | tests/dom/ui.test.ts | dom | tested |
| skeletonDetail | src/ui.ts:294 | tests/dom/ui.test.ts | dom | tested |
| emptyState | src/ui.ts:331 | tests/dom/ui.test.ts | dom | tested |
| errorState | src/ui.ts:344 | tests/dom/ui.test.ts | dom | tested |
| openDialog | src/ui.ts:374 | tests/dom/ui.test.ts | dom | tested |
| toast | src/ui.ts:456 | tests/dom/ui.test.ts | dom | tested |
| RECENT_KEY / RECENT_MAX | src/ui.ts:469 | tests/dom/ui.test.ts | dom | tested via recentSearches |
| recentSearches | src/ui.ts:472 | tests/dom/ui.test.ts | dom | tested |
| rememberSearch | src/ui.ts:483 | tests/dom/ui.test.ts | dom | tested |
| clearRecentSearches | src/ui.ts:495 | tests/dom/ui.test.ts | dom | tested |
| closeMenus | src/ui.ts:507 | tests/dom/ui.test.ts | dom | tested |
| rectOf | src/ui.ts:521 | tests/dom/ui.test.ts | dom | tested via openMenu |
| positionFixed | src/ui.ts:535 | tests/dom/ui.test.ts | dom | tested (clamp, flip, cap) |
| wireMenuKeys | src/ui.ts:557 | tests/dom/ui.test.ts | dom | tested |
| openMenu | src/ui.ts:596 | tests/dom/ui.test.ts | dom | tested |
| fillMenu | src/ui.ts:696 | tests/dom/ui.test.ts | dom | tested |
| openActionMenu | src/ui.ts:747 | tests/dom/ui.test.ts | dom | tested |
| attachContextMenu | src/ui.ts:762 | tests/dom/ui.test.ts | dom | tested |
| downloadLabel | src/ui.ts:783 | tests/dom/ui.test.ts | dom | tested |
| downloadAction | src/ui.ts:792 | tests/dom/ui.test.ts | dom | tested (regression 4fe2d31 season downloads) |
| queueActions | src/ui.ts:839 | tests/dom/ui.test.ts | dom | tested |
| showIdOf | src/ui.ts:866 | tests/dom/ui.test.ts | dom | tested via itemActions/askAddToNextUp |
| showNameOf | src/ui.ts:872 | tests/dom/ui.test.ts | dom | tested via askAddToNextUp |
| nextUpChanged | src/ui.ts:877 | tests/dom/ui.test.ts | dom | tested |
| askAddToNextUp | src/ui.ts:886 | tests/dom/ui.test.ts | dom | tested |
| removeShowFromNextUp | src/ui.ts:923 | tests/dom/ui.test.ts | dom | tested via itemActions nextUp |
| itemActions | src/ui.ts:934 | tests/dom/ui.test.ts | dom | tested (regression a963a95 Resume label) |
| progressPct | src/ui.ts:1036 | tests/dom/ui.test.ts | dom | tested via itemCard |
| itemCard | src/ui.ts:1042 | tests/dom/ui.test.ts | dom | tested (regression 56a1825 BoxSet opens a grid) |
| ROW_CHEVRON | src/ui.ts:1193 | tests/dom/ui.test.ts | dom | tested via scrollRow |
| scrollRow | src/ui.ts:1204 | tests/dom/ui.test.ts | dom | tested |
| cardRow | src/ui.ts:1237 | tests/dom/ui.test.ts | dom | tested |
| section | src/ui.ts:1244 | tests/dom/ui.test.ts | dom | tested (regression a963a95 See all from the keyboard) |
