> **2026-09-24:** renamed for Guideline 4.1(a). Live values in App Store Connect: name "Aquarium Media" (plain "Aquarium" is taken), subtitle "AI-built home media player", "jellyfin" dropped from keywords, iOS + tvOS 1.2 (60). Sections below may still show the older wording.

# App Store Connect metadata — Aquarium 1.0 (46)

## Status, 2026-09-12 evening

Done in App Store Connect (app record 6799581721, which already existed):
- iOS and tvOS 1.0: promotional text, description, keywords, support URL,
  copyright, all with the AI disclosure first. Builds 45 uploaded from the
  archives and attached to both versions. Export compliance answered by the
  Info.plist key.
- App Information: subtitle "AI-built Jellyfin client", Entertainment /
  Utilities, content rights "no third-party content", age rating 4+.
- App Privacy: policy URL and Apple TV policy text set, "No data collected"
  published.
- Privacy policy committed to github.com/eggprez/FellyJin as PRIVACY.md.

Deep-dive pass (security, function, guidelines), 2026-09-12 evening — all in build 46:
- Sign-out now cancels running downloads and deletes their resume data (which
  carried the old token inside the archived request); the Downloads root is
  excluded from backup.
- Item ids from the server or a deep link are escaped before they become a
  folder name or a URL path segment.
- The server-identity pin is enforced: once the saved address answers as a
  different server, every request throws until sign-out, the probe itself is
  sent without the token, and the alert has no "Cancel".
- Live TV playlist and guide downloads are capped (16 MB / 128 MB) and must be
  http(s); stream URLs of any other scheme are dropped; XML external entities
  are explicitly off.
- Server address no longer logged as public; `iptv_user_agent` now syncs.
- Player lets audio continue in the background (`audiovisualBackgroundPlaybackPolicy`),
  which is what the "audio" background mode promises.
- Sign-in screen explains what a server address is.
- Listing: bitrate ladder corrected (36 → 2.5 Mbps), review notes reworded
  for the background mode, privacy policy and Apple TV privacy text now
  describe iCloud sync of the token (Keychain) and session (KVS).
- Verified live against the public demo server on iPhone: sign-in, Home,
  direct-play playback with progress reporting, season/episode pages, Live TV
  guide (mock playlist), sign-out.

**Submitted 2026-09-12: iOS 1.0 (46) and tvOS 1.0 (46) are both "Waiting for
Review".** Two things had to change at the last moment: App Store Connect
refuses a demo account with an empty password, and the demo user has none, so
"Sign-in required" is unticked and the account is the first paragraph of the
reviewer notes instead; and the content-rights declaration made in the UI had
not stuck, so it was set again through the API.
- The macOS 1.0 platform version stays in "Prepare for Submission"; never
  submit it.


Everything below is written to be pasted straight into App Store Connect.
Character limits are Apple's; each field is within them.

## App record

| Field | Value |
|---|---|
| Name | Aquarium Media |
| Bundle ID | scottai.FellyJin |
| SKU | fellyjin-apple |
| Primary language | English (U.S.) |
| Platforms | iOS (iPhone + iPad), tvOS |
| Mac | **Off** — untick "Make available on Mac" under Pricing and Availability |
| Primary category | Entertainment |
| Secondary category | Utilities |
| Price | Free |
| Copyright | 2026 Scott Bindelglass |
| Version | 1.0 |

## Subtitle (30 chars max)

    AI-built Jellyfin client

(24 characters. The AI disclosure goes in the subtitle on purpose: it is the
one line that shows under the name everywhere the app is listed.)

## Promotional text (170 chars max, editable without a new build)

    BUILT WITH AI. This app was written with AI assistance (Anthropic's Claude), shared as-is by one person. Please know that before you install it.

(151 characters. Promotional text sits above the description on the store
page, so this is the first sentence anyone reads.)

## Description (4000 chars max)

*** THIS APP WAS MADE WITH AI ***
Aquarium was written with AI assistance: the code, the artwork and this listing were produced with Anthropic's Claude, directed and tested by one developer. It is a personal project shared as-is, with no guarantee of updates or support. If that is not something you want to run, this is the place to stop.

Aquarium is a native client for Jellyfin media servers, built for iPhone, iPad and Apple TV. Sign in to your own server and your films, shows and Live TV are there, with a home screen that picks up where you left off.

It is a personal project, shared as-is. It needs a Jellyfin server you already run; Aquarium does not host, sell or supply any content of its own.

WATCH
• Direct play when the device can open the file, and the server's HLS stream when it cannot, from 36 Mbps down to 2.5 Mbps in six steps.
• Adaptive quality drops a rung when a stream keeps stalling and climbs back after five clean minutes. Cap it at the quality you choose, or turn it off.
• Skip intro and skip credits from the server's media segments, and an Up Next card with autoplay over the closing stretch of an episode.
• Sleep timer: 15, 30, 60 or 90 minutes, or stop after this episode.
• Per-series audio and subtitle memory: override the language once and the next episode opens the same way.
• Picture in Picture, AirPlay, lock screen and Control Centre transport, and hardware decoding with nothing to configure.

DOWNLOAD (iPhone and iPad)
• Keep an episode, a season or a whole series on the device, in the original file or transcoded to fit.
• A disk-space check tells you what a season would need and offers the qualities that would fit.
• Downloads keep running with the app in the background and resume across relaunches.
• Watching offline records your position and pushes it back to the server when it is reachable again.

BROWSE
• Home: a rotating media bar drawn from your library, Continue Watching, Next Up and the latest additions to each library.
• Libraries with sorting, filtering and paging; search with recent terms; favourites and watched toggles.
• Detail pages with cast, "More like this" from the server's own recommendations, and a line saying exactly what the file is.
• Live TV with the channel list and current-programme guide.

APPLE TV
• A layout built for the remote: the top shelf on the home screen shows your Next Up posters, with progress bars on anything part-watched. Press Play on one and it starts.
• The Siri Remote drives playback; the info panel is a swipe away.

PRIVACY
• Your access token lives in the system keychain and is sent as a header, never in a URL.
• The server's identity is pinned at sign-in: if the saved address ever answers as a different server, the app stops rather than signing in to it.
• No analytics, no crash reporting, no account of its own. Nothing leaves the device except to the server you signed in to.

Settings sync between your devices through iCloud, so a quality cap or a subtitle size set on the iPad is already set on the Apple TV.

Requires a Jellyfin server (10.9 or later) that you run or have an account on. Jellyfin is a trademark of the Jellyfin project; Aquarium is an independent client and is not affiliated with or endorsed by it.

## Keywords (100 chars max, comma separated)

    jellyfin,media,server,player,stream,video,tv,shows,movies,offline,download,live tv,home theater

(95 characters.)

## URLs

| Field | Value |
|---|---|
| Support URL | https://github.com/eggprez/FellyJin |
| Marketing URL | leave blank |
| Privacy Policy URL | https://github.com/eggprez/FellyJin/blob/main/PRIVACY.md |

## App Privacy (Data Collection)

Answer **"No, we do not collect data from this app."**

Rationale: the app has no analytics, no crash reporter, no account of its own,
and no server of the developer's. The only network peer is the Jellyfin server
the user typed in, which the user controls. Data that stays on device (session,
preferences, downloads) or goes only to the user's own server is not
"collected" under Apple's definition. The privacy manifest in the binary
declares the same (`NSPrivacyCollectedDataTypes` empty, no tracking).

## Age rating

Every question: **None / No**. The app ships no content; it plays whatever is
on the user's own server. Result: 4+.
- Unrestricted web access: No (the app has no browser).
- Gambling, contests: No.
- User-generated content: No — there is no sharing, posting or messaging.
- Parental controls: No.
- Medical / health: No.

## Content rights

"Does your app contain, show, or access third-party content?" — **No**.
The app displays only content the user has placed on their own server.

## Export compliance

Handled by `ITSAppUsesNonExemptEncryption = false` in Info.plist; the upload
carries the answer and App Store Connect will not ask. The app uses only the
system TLS stack (exempt).

## Advertising identifier

No, the app does not use the IDFA.

## App Review Information

Contact: your name, phone and email.

**Demo account**: tick "Sign-in required".

| | |
|---|---|
| User name | demo |
| Password | (leave empty — the demo user has no password) |

**Notes for the reviewer** (paste as-is):

    DISCLOSURE: this app was written with AI assistance (Anthropic's Claude),
    directed and tested by the developer. The store listing says so in the
    subtitle, the promotional text and the first paragraph of the description,
    because the developer wants users to know before they install.

    Aquarium is a client for a self-hosted Jellyfin media server; it has no
    server or content of its own. To review it, sign in to the public Jellyfin
    demo server:

      Server address:  https://demo.jellyfin.org/stable
      User name:       demo
      Password:        (none — leave the field empty)

    On the sign-in screen, enter the server address first, wait for the
    server name ("Stable Demo") to appear, then the user name, then Sign In.
    The demo server carries a small public-domain library, enough to browse,
    search and play. Live TV and Downloads depend on the server's setup; the
    demo server has no Live TV configured.

    Both the iOS and tvOS builds are the same app; the Apple TV version adds
    a Top Shelf extension that shows Next Up posters on the home screen once
    the user has signed in and opened Home.

    App Transport Security: the app sets NSAllowsArbitraryLoads because a
    home media server is very often reached over plain HTTP on the local
    network (e.g. http://192.168.1.10:8096). Refusing HTTP would make the app
    unusable for its core audience. The sign-in screen says so explicitly, and
    Settings shows an HTTP/HTTPS indicator for the life of the session. The
    demo server above is HTTPS.

    Background modes: "audio" only. It is what Picture in Picture, AirPlay,
    the lock screen and Control Centre transport, and audio continuing after
    the screen locks all require. Downloads use background URLSessions and
    need no mode.

    Jellyfin is an open-source media server (jellyfin.org); Aquarium is an
    independent third-party client and says so in its description.

## Build

Upload 1.0 (1) for both platforms from the archives, then attach the build
to each platform's version page. Version 1.0 on iOS and 1.0 on tvOS can be
submitted together from the same app record.

## Screenshots (see `Screenshots/`)

| Device class | Size | Required |
|---|---|---|
| iPhone 6.9" | 1320 × 2868 | yes (covers all smaller iPhones) |
| iPad 13" | 2064 × 2752 | yes (iPad is in the device family) |
| Apple TV | 1920 × 1080 | yes |

---

# tvOS 1.1 (49) — submitted 2026-09-20

**tvOS 1.1 is "Waiting for Review", set to release automatically on approval.**
iOS 1.1 was *not* touched: iOS 1.0 is still Rejected and being fixed separately.
The macOS 1.0 record remains in Prepare for Submission and is still never to be
submitted.

- Build 49, archived from that day's source (it includes the layout fixes made
  on 20 Sept; the 19 Sept tvOS archive was already stale). Builds 47 and 48 of
  the tvOS 1.1 train had been uploaded on the 19th, which is why 49 is the one.
- Carried over automatically from tvOS 1.0: description, keywords, the four
  Apple TV screenshots, and the whole App Review Information block (contact,
  notes, demo-server instructions).
- **Not** carried over: promotional text. It came back empty on the new record
  and was re-set by hand to the "BUILT WITH AI" line. Check this every version.
- The "What's New" text deliberately leaves the AI disclosure out — the
  subtitle, promotional text and description all still carry it.

## What's New (tvOS 1.1), as submitted

WHO'S WATCHING
• More than one account on the same Apple TV. Sign in once, then switch between people in Settings — no password the second time.
• The sign-in screen lists the users your server publishes, so most people just press a name.

CAST AND CREW
• Press an actor or director to open their page: photo, biography and everything of theirs in your library.
• Trailers play from a detail page where the server has one.

PLAYBACK
• Audio and subtitle menus now list every track the file really carries, including on a transcoded stream.
• Audio and video drifting apart can be nudged back into line from inside the player.
• A settings panel of its own in the transport bar, for what the remote cannot otherwise reach.
• Fixed a crash when changing quality during playback.

LIVE TV
• Channels tagged HDR that actually carry H.264 now open instead of failing.
• Reworked how the guide and the player hold on to a channel, so leaving and re-entering Live TV is steadier.

SETTINGS
• A Settings page rebuilt for the remote, so focus reaches every row.

ALSO
• Libraries reload faster — only what changed since last time is fetched.
• Home no longer loads itself twice when you come back to the tab.
• A pass over security, memory use and layout throughout the app.

## Two claims in those notes that were never reproduced

Worth knowing if a reviewer or a user pushes back:
- the Live TV stability/back-out work was reasoned from reading the code, not
  reproduced against a real freeze (hence "steadier", not "fixed");
- the faster library reload (delta sync) was verified against the mock server
  only, never a real Jellyfin server.

## Open, and not ours to do

App Store Connect is showing the EU **trader status** warning: it must be
provided or the apps are removed from the EU App Store. It needs an Admin or
Account Holder and is a legal identity declaration. It did not block this
submission.
