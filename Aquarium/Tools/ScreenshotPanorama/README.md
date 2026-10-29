# Screenshot panoramas

`panorama.py` draws each platform's App Store screenshots as one wide picture and cuts it into cards. Run `python3 panorama.py` to render every set, or pass `iphone`, `watch`, `duo` or `tv` to render one. The output goes to `../../AppStore/Screenshots-Panorama/<set>/`: the numbered cards, `strip.png` (the whole canvas) and `preview.png` (the cards with the store's gaps, for checking the seams).

## Captures (2026-10-23, main at 0a1512b, Debug build)

Everything in `captures/` comes from the public Jellyfin demo server (`https://demo.jellyfin.org/stable`, user `demo`). Each simulator signed in with Quick Connect, and the code was approved through the demo account's API.

- iPhone 18 Pro Max (1320×2868), with the status bar overridden to 9:41 and full bars.
- Apple Watch Series 12 46 mm (416×496), signed in by its paired iPhone. The simulator always shows a red "phone disconnected" glyph by the clock, so that glyph was painted out.
- iPhone Duo, the open inside screen (2853×2007), captured with `simctl io … screenshot --display=49F9A0CF-…`.
- Apple TV 4K at 1080p (1920×1080), captured from inside an XCUIRemote test probe, because `simctl` cannot screenshot tvOS.

The demo server has no Live TV. `iptv_fixture.py` writes a made-up M3U and XMLTV guide whose channel names are invented and whose programmes are the demo's own films. Serve it with `ruby -run -e httpd . -p 8790`, then launch the app with `-livetv_source custom -iptv_playlist_url http://127.0.0.1:8790/channels.m3u -iptv_guide_url http://127.0.0.1:8790/guide.xml`. The fixture's paths point at a session scratchpad, so edit them before reusing it.

The player shots use the Debug hooks: `-AquariumPlayLandscape YES -AquariumPlayMenu more` at launch, then `debug_url aquarium://play/<id>` and `notifyutil -p aquarium.debug.openurl` (iOS), or `aquarium.debug.tab.info|sync|picture` (tvOS).
