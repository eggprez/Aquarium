# Aquarium Privacy Policy

_Last updated: 16 November 2026_

Aquarium is a client application for Jellyfin media servers, available for
iPhone, iPad and Apple TV. This policy describes what the app does with your
information. The short version: **Aquarium collects nothing.**

## What the app stores on your device

- **Your server address, user name and session details**, so you stay signed
  in between launches.
- **Your access token** for that server, in the device's system keychain.
- **If you connect a Seerr server** (optional, in Settings): its address and
  the session it gave you, in the same keychain. No password is stored.
- **Your settings** (playback quality, subtitle preferences, theme, and so on).
- **Downloads** you have chosen to keep for offline viewing, together with
  your playback position for them.

All of this stays on the device, with one exception described below (your own
iCloud). You can remove it at any time by signing out (which deletes the
session and token and stops any downloads in progress) or by deleting the app.

## What the app sends, and to whom

The only network peers Aquarium talks to are **the Jellyfin server you entered
at sign-in** and, if you connect one, **the Seerr server you entered in
Settings**. It sends the Jellyfin server your sign-in credentials, requests for
your library and media, and playback progress (so the server can show what you
have watched). What that server does with this information is governed by
whoever operates it — usually you.

A Seerr server takes requests for films and shows the library doesn't have.
Aquarium signs in to it with your Jellyfin account (by approving a one-time
Quick Connect code, or with your Jellyfin user name and password if the server
has no Quick Connect), and sends it your searches, the requests you make, and
requests for the posters of the titles it lists. Posters are fetched through
the Seerr server itself, not from the film database it draws on, so no other
party hears from your device. As with Jellyfin, what that server does with
this information is governed by whoever operates it.

If you have iCloud enabled, the app synchronises between **your own devices**:
your settings, your server address and user name, and the addresses of any
Live TV playlist and guide you entered (through Apple's iCloud Key-Value
Store), and your access token (through iCloud Keychain, so it is end-to-end
encrypted by Apple). None of this is visible to the developer. Apple's privacy
policy applies to that transport, and turning iCloud off for the app stops it.

Aquarium has **no server of its own**. It contains **no analytics, no crash
reporting, no advertising, and no tracking**. The developer receives no
information from the app, and has no way to see who uses it or how.

## Third parties

None. The app embeds no third-party SDKs.

## Children

The app does not knowingly collect information from anyone, of any age.

## Changes

If this policy changes, the new version will be published at the same address
with an updated date.

## Contact

Questions about this policy can be sent to the support address listed on the
App Store page.
