# App Store Connect metadata — Aquarium 1.4

Changes from the 1.3 listing (`metadata-1.3.md`); everything not listed here
(subtitle, keywords, URLs, the reviewer's demo account and technical notes)
carries over unchanged. Nothing here is submitted for App Store review: 1.4
goes to external TestFlight first, and the developer releases.

## What's New in 1.4

iOS:

```
• A new video player on iPhone and iPad. Your files play as they are, MKV, DTS, TrueHD and PGS subtitles included, with no conversion on the server.
• New player controls: pills along the bottom for audio, subtitles, quality and Up Next, and a back button. Turn your phone upright or sideways for any film.
• Auto quality: plays your downloaded copy if there is one, then the original file, and steps down only when the connection struggles. Pick a quality in the player to keep it there.
• Downloads recover from dropped connections and pick up where they left off after a relaunch.
• Siri and Shortcuts, a Follow widget, SharePlay, and an A–Z index for long libraries.
• Use your Apple Watch as a remote for your iPhone.
• Set audio sync for your TV with your iPhone's camera.
• A redesigned Settings page, and many fixes across music, CarPlay, widgets and the iPad layout.
```

tvOS:

```
• The player's controls have been redesigned, with the same cards for audio, subtitles and quality as on iPhone.
• Audio sync can be measured with your iPhone's camera, for each playback speed.
• Home, Search, Favorites, the TV guide and title pages are easier to reach and read from the sofa.
• The default audio track is the one your server picks, and the Top Shelf updates after you watch.
```

macOS:

```
• A new video player. Your files play as they are, MKV, DTS and TrueHD included, with no conversion on the server.
• Redesigned player controls, with Auto quality and a back button in full screen.
• Alerts, menus and Refresh act on the window you're using; title pages no longer resize the main window.
• Better VoiceOver labels and keyboard control in the library, sidebar and episode lists.
```

## Description — the WATCH section (iOS and macOS)

The 1.3 bullets "Direct play when your device can open the file…" and
"Adaptive quality steps down…" are replaced by:

iOS:

```
• Your files play as they are: MKV, DTS, TrueHD, Dolby Digital and PGS subtitles, with no conversion on the server.
• Auto quality plays your downloaded copy first, then the original file, and steps down only when a connection struggles. Pick a quality in the player to keep it.
```

macOS:

```
• Your files play as they are: MKV, DTS, TrueHD and Dolby Digital, with no conversion on the server.
• Auto quality plays the original file and steps down only when a connection struggles. Pick a quality in the player to keep it.
```

## TestFlight — What to Test (build 90)

```
1.4 is a big release: a new video player on iPhone, iPad and Mac.

Please try:
• Playing films and episodes, especially MKV files and ones with DTS or TrueHD audio or image subtitles.
• The pills under the timeline: audio, subtitles, quality and Up Next. On a small iPhone held upright, check they all fit.
• Turning your phone upright and sideways while a film plays.
• Quality: leave it on Auto, or pick one and check it sticks for the next episode.
• Downloads: start a season, lock the phone or lose Wi-Fi for a bit, and check it finishes.
• On Apple TV: the new controls, and audio sync in Settings > Audio.

Send feedback with a screenshot from TestFlight: take a screenshot and tap Share Beta Feedback.
```

## Notes for the reviewer — NEW IN 1.4

Appended after the 1.3 notes, replacing "NEW IN 1.3":

```
NEW IN 1.4
- iPhone, iPad and Mac video playback now uses libmpv (MPVKit, LGPL build, dynamically linked frameworks), as the Apple TV already did, so files the server would otherwise have to convert play directly.
- Siri / Shortcuts intents and a Follow widget; SharePlay for watching together over FaceTime.
- The Apple Watch can act as a remote for the iPhone's player.
- Audio sync measured with the iPhone's camera: the camera is used only while the user runs that test, and the frames are never stored or sent anywhere.
```
