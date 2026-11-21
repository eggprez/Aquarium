# Feature list

Things the apps should gain, one entry each, with what is there today so a
session can start from the gap rather than rediscover it. Started 2026-11-05.
Each entry names the Apple files it touches; the Linux app follows later
unless the entry says otherwise.

## Music

### Music search, online and offline, from three places

**Wanted:** one music search that works whether or not the server is in
reach, and that is offered in three places:

1. The main Search tab (the search the whole app shares).
2. The Music tab.
3. The music section under Downloads.

Offline it searches what is downloaded; online it searches the server and
shows what is downloaded when the server drops out mid-search. Same results
layout everywhere: artists, albums, songs.

**Today:**

- The Music tab already has this: `MusicSearchView` in
  `Aquarium/Aquarium/Music/MusicTabView.swift` searches the server, falls
  back to `OfflineMusic.search` when the server is unreachable, and keeps
  the local hits if the server dies during a search.
- The main Search tab (`Aquarium/Aquarium/Views/SearchView.swift`) asks the
  server for music above the video grid but has no offline path at all: with
  the server away it finds nothing, downloaded music included.
- The Downloads page's Music door opens `OnDeviceLibraryView(isDownloadedPage:
  true)` in `Aquarium/Aquarium/Music/OnDeviceViews.swift`, which has no
  search field.

**Built 2026-11-06** (branch `claude/music-search-grid`): one engine and one
results view in `Aquarium/Aquarium/Music/MusicSearch.swift`, used by all
three. The Search tab answers from the downloads when the server is out of
reach or stops answering mid-search, and says so under the field. The
Downloaded page (Downloads → Music, and Library → Downloaded) has its own
field that searches the downloads alone, even online, and opens the
on-device pages. The Music tab keeps its field, now on the shared engine.
Not yet: Mac and Apple TV have no music results at all, as before.

**Follow-up 2026-11-06** (branch `claude/music-search-field`): the field
was the system's `.searchable` drawer, which stays folded under an inline
title until the list is pulled down and is not drawn at all on the Duo's
inside screen, so neither the Music tab nor the Downloaded page had a search
anyone could see. Both now draw their own field under the bar
(`MusicSearchField` in `MusicSearch.swift`), in view at every width, with
Cancel beside it while a search is up.

### Artist page: top songs, then every album in a grid, then the rest

**Wanted:** the artist page in this order:

1. Top songs.
2. All albums, as a grid that wraps (not a sideways carousel), so a
   prolific artist's whole discography is on the page.
3. Everything else underneath: Appears On, biography, similar artists.

**Built 2026-11-06** (same branch): `ArtistDetailView` in
`Aquarium/Aquarium/Music/MusicDetails.swift` now draws its albums with
`AlbumGrid` (two across on a phone, as many as fit on an iPad) under Top
Songs, and asks for up to 500 albums rather than 100. The on-device artist
page in `Aquarium/Aquarium/Music/OnDeviceViews.swift` does the same; its
genre page keeps the shelf. Appears On, About and Similar Artists follow,
unchanged.

## Requests

### Asking for films and shows through Seerr

**Wanted:** Seerr fully part of the app, not a web page inside it, and held
to the same security as the Jellyfin connection.

**Built 2026-11-16** (branch `claude/seerr-requests`), Apple app and Linux
app. `Aquarium/Aquarium/Core/Seerr/` is the client (its header comment has
the security rules: Quick Connect sign-in with the app's own Jellyfin
session, no password kept, no admin API key, session in the keychain, cookie
to one origin, posters through Seerr only). `Aquarium/Aquarium/Views/Seerr/`
is the screens: a "Not in Your Library" row in Search, a request page per
title, a Seerr page (called Requests until 2026-11-16; your requests as one carousel, then Trending /
Popular / Upcoming; a notice when Seerr's Cache Images is off, since Seerr
then serves no posters), a missing-seasons banner on a show, missing films on a collection
and on a person, "Like This, Not in Your Library" on a film's, show's,
season's and episode's page, and Settings → Account → Requests. Linux: `Linux/src/seerr.ts`,
`Linux/src/views/requests.ts`, `Linux/src-tauri/src/seerr.rs`.

**To do:**

- Check against a real Seerr server (the tests use a stand-in; see
  `Aquarium/TESTING.md` and each platform's `MANUAL.md`).
- Build and run the Linux side on the Linux machine: it was written on a Mac
  with no Node or Cargo and has never been compiled.
- Not built, by choice: approving or declining as an administrator, reporting
  a problem with a title, a Home row of requests, notifications, the Watch.
- Apple TV: after Request is pressed, focus goes to the tab strip instead of
  Cancel Request.

## Watching together

### SharePlay: start from whose progress

**Wanted:** on a SharePlay call where each person has their own account
(same Jellyfin server or not), a question asking whose saved spot everyone
starts from.

**Built 2026-11-18**, iPhone, iPad and Mac (`Aquarium/Aquarium/Core/SharePlay.swift`,
the alert in `Player/PlayerScreen.swift`, rows in `Player/Chrome/PlayerMenus.swift`
and `Player/PlayerMacMenus.swift`). Each device sends its account's saved
spot (`SharedProgress`) over the session; the person who put the title on is
asked "Start from whose progress?" (you, each friend with a spot, From the
Beginning); the pick is a seek, which the coordinator makes everyone's.
"…" → Start From Someone's Progress… asks again. A device that joins now
opens at the start and is placed by the coordinator, instead of seeking to
its own spot (which would have moved everyone).

**To do:**

- Try it on a real FaceTime call (iPhone MANUAL.md); no simulator can.
- Fixed the same day: "Start Only for Me" no longer shows an error; no
  `aquarium://` fallback link (the App Store is offered instead); the
  invitation carries the poster; streams are matched by the item id in the
  address (no main-actor read, which could trap); a joiner whose server or
  account can't open the title is told and leaves; an mpv joiner switches
  engine even with Settings set to mpv, and only for the session's title;
  closing the player leaves SharePlay; End SharePlay for Everyone; "Alex
  paused / played / jumped to 23:10" toasts; with no call on, iPhone and iPad
  open the system's SharePlay sheet to start one.
- Linux: no SharePlay (Apple only).

### SharePlay on the Apple TV

**Wanted:** SharePlay on the Apple TV as well.

**Built 2026-11-18** (`Core/SharePlay.swift`, the part at the end;
`Player/PlayerModel+Group.swift`; `Aquarium-tvOS.entitlements`). The Apple
TV's player is mpv, so its session is joined through an
`AVDelegatingPlaybackCoordinator`: the coordinator's orders (play from here
at this moment, pause, seek) are carried out on mpv, and the remote's
play/pause and jumps are asked of the coordinator. Swipe down in the player
→ Watch Together tab. An Apple TV and an iPhone can be in the same session.

**To do:**

- Never run in a real session: no simulator has FaceTime. Check on the Apple
  TV with a call on it, or one moved to it from an iPhone (TV MANUAL.md).
  What SyncPlay shares with it (the player's group seam) is tested.
- The Apple TV has no system sheet to start a call from: with no call on it
  says to start one first.

### "TV shows don't have SharePlay" (reported 2026-11-18)

**Fixed 2026-11-18**, two causes found:

- Watch Together was last in the "…" card, under Speed, Sleep timer and
  After this. An episode is the title with all three, so on a phone held
  sideways it was below the fold. It is first in the card now.
- An episode that is downloaded plays from the download, and Watch Together
  was never offered on a download. It is now: choosing it leaves the
  download for the server's stream at the same moment. A device joining a
  session also opens the server's stream rather than its own download,
  which the coordinator could not match to anyone else's.

**To do:** confirm on the phone which of the two it was.

### SyncPlay (Jellyfin's own watch-together)

**Wanted:** the Jellyfin equivalent, under SharePlay, on iOS and tvOS.

**Built 2026-11-18**, iPhone, iPad, Mac ("…" card) and Apple TV (Watch
Together tab): `Core/SyncPlay.swift`, `Core/SyncPlayWire.swift`,
`Player/Chrome/WatchTogether.swift`, `Player/PlayerModel+Group.swift`.
"Watch Together with SyncPlay" asks which of the server's groups to join, or
starts one named for you with what is playing put on. Everyone in the group
is on the same server; pause, play and jumps are everyone's; a device that
runs dry holds the rest; the next thing anyone plays is put on for the
group. No FaceTime call, and it works with people in a browser or another
Jellyfin client. Settings has a SyncPlay row (Account page on the Apple TV)
for joining with nothing playing. One of SharePlay and SyncPlay at a time.

**To do:**

- Tested against the QA server with a scripted second person
  (`PhoneSyncPlayTests`, `TVSyncPlayTests`). Not yet tried with two real
  devices side by side, or with Jellyfin's web client in the group.
- The group plays at normal speed (the speed chips are hidden in a group).
- Not built: the group's queue beyond one title (add next, reorder), who
  pressed pause (the server doesn't say), a SyncPlay item in the Mac's
  Playback menu (it is in the "…" card), Linux.

## Brand

### One-word wordmark ("aquarium" with a bubble for the i's dot)

**Wanted:** the name drawn as one word. "Aqua·rium", with its two weights and
two colours, came from FellyJin, where the split joined two real words.
Option 03 of the sixty on the wordmark page was picked on 2026-11-20.

**Built 2026-11-20**, every platform. The Apple app has `Shared/Wordmark.swift`
(SF Rounded heavy, lowercase, a dotless i with a purple `WordmarkBubble`
over it, read as "Aquarium"). It is compiled into the app, the watch app and
the watch widgets, and drawn in `BrandMark`, both sign-in headers
(`LoginView`), the tent idle screen, and the watch widget's empty state. The
tvOS Top Shelf images are redrawn by `Tools/IconGenerator` (`drawWordmark`).
Linux has `wordmark()` in `src/ui.ts` and `.wordmark .wm-i::after` in
`styles.css`, used in the sidebar (`index.html`), the sign-in card and
Settings → About.

**To do:**

- Linux has no bundled rounded face, so it uses one only if the system has
  one, otherwise Inter. Bundle Nunito (`@fontsource-variable/nunito`) if Inter
  looks too square next to the Apple app.
- The watch's navigation title and the "Aquarium" storage label stay plain
  text (system title, data label).
- Check the bubble by eye on hardware (iPhone MANUAL.md "The wordmark", Linux
  TESTING.md 29, the Top Shelf in TV MANUAL.md §4).

## Phone layout

### A top bar that floats over the artwork

**Wanted:** the iPhone's solid band at the top looked clunky. Something
modern that fades, or sits on the posters, and hides as little of them as
possible. Ten mock-ups on 2026-11-20; option 6 (a progressive blur) was
picked and then cut down three times until only the clock strip was blurred.

**Built 2026-11-20**, iPhone (`Views/PhoneHeroBar.swift`, used by `HomeView`
and `ItemDetailView`). The hero and a title's artwork run to the top of the
screen; the wordmark with Search and Refresh, or Back, float on it in white.
Behind the clock is a blur with no tint of its own, so it takes the
poster's colours, and it ends at the bottom of the status bar. Once the
artwork has scrolled away the blur reaches past the bar's row, the glyphs
turn the page's colour, and a title page shows its name beside Back.

**Built 2026-11-20, iPad and Mac** (`Views/HeroBarBlur.swift`). The iPad's
floating bar used to gain a tinted band with a hairline once the page scrolled;
it now has the same untinted blur, thin under the clock over artwork and
deeper once the page is under it. On the Mac, Home's hero and a title page's
wash now run up under the window toolbar instead of starting below a band, and
the same two-step blur sits pinned beneath the toolbar (the window-colour wash
across the top of the hero is gone).

**Built 2026-11-21, every solid bar** (`BarBlur` in `Views/HeroBarBlur.swift`,
`TopBarFrame` in `Views/Components.swift`). No page draws a solid band any
more. The iPhone Duo floats `PhoneHeroBar` on Home and title pages too, on
both screens, in the frame its solid bar took — below the front screen's
dead touch strip, on the inside screen's status strip when held upright —
with the artwork reaching up by that much. Search and Live TV keep
`AppTopBar` with the blur under it instead of the band and hairline (Live
TV's header stands above the guide rather than over it, so there the blur
has only the page under it).

**Fixed 2026-11-21, no blur on the Duo until the page scrolled.** Over
artwork the blur covered only what the status bar took above the bar, and on
the Duo's front screen and its inside screen held sideways that is nothing
(the safe area's top is zero), so the bar had no blur until the page had
scrolled past the hero. The blur over artwork is now never shorter than 47
points (`BarBlur.least`, what an iPhone 17 has): there it starts at the top
of the screen and eases out behind the bar's row. Phones with a shorter
status bar come up to the same 47: an iPhone SE had 8 points of blur, a
notched iPhone 35, an iPhone 15 or 16 42. An iPhone 17 and the Pros are
unchanged.

**To do:**

- The untinted blur is the backdrop's `variableBlur` filter, which UIKit
  does not publish (looked up by name, with a paler masked blur if it ever
  stops answering); on the Mac it goes on `NSVisualEffectView`'s backdrop
  layer, which AppKit builds only after the first layout. Watch App Review.
- Check dark mode and a real iPhone by eye (iPhone MANUAL.md, "The floating
  top bar"), and the Duo's inside screen held upright on hardware (the
  simulator's hinge was checked closed, half-open and open, sideways).
