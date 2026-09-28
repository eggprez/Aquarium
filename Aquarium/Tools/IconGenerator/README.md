# Icon generator

The app's mark — a squircle ring with a play triangle inside it, on the brand
gradient, with the Aquarium bubble trail rising past its corner — is drawn in code rather than kept as a hand-made bitmap, so every
size is a fresh rasterisation instead of a resample, and a change to the mark
reaches all four platforms at once.

```sh
swiftc -O brand.swift main.swift -o build-icons && ./build-icons stage
```

That writes a staging tree whose layout mirrors `Aquarium/Assets.xcassets`:

- `AppIcon.appiconset/` — **superseded on iOS and macOS by `App Icons/AppIcon.icon`**
  (see below); it is still written but no longer copied in. It was the iOS 1024 (default, dark and tinted variants) and
  every macOS size. The iOS default is written **without an alpha channel**,
  which the App Store requires, and full-bleed square with no corner rounding
  baked in — iOS masks it itself. The dark and tinted variants are transparent
  artwork, as Apple expects: the system supplies the backdrop and, for tinted,
  the colour.
- `Logo.imageset/` — the same tile with its corners baked in, for `Image("Logo")`
  on the sign-in screen and in `BrandMark`.
- `Watch/AppIcon.appiconset/watch-1024.png` — the Apple Watch icon, for
  `Watch/Assets.xcassets`. watchOS masks every icon into a circle, so this one
  is composed for the inscribed disc: full-bleed and opaque like the iOS tile,
  but the ring is pulled in until its corners clear the circumference and the
  bubbles are laid out around the disc rather than the corner (`circleIcon`
  and `watchBubbles` in `brand.swift`).
- `App Icon.brandassets/` — the tvOS layered icon as four parallax layers
  (Back gradient, Middle shadow, Front mark, Bubbles on top) at 400×240 and at the 1280×768 App
  Store size, plus the two top shelf images.
- `proof.png` — a contact sheet of everything above, for eyeballing before you
  copy it in.

Copy the PNGs over the matching files in the asset catalog; the filenames match
what the existing `Contents.json` files already reference. `brand.swift` holds
the geometry and the painting, `main.swift` only decides what gets written.

Marks are authored in a 1024×1024 box. `markInset(forPixelSize:)` is what keeps
a 16pt macOS icon legible: small renderings get a slightly larger, slightly
thinner ring, because a heavy ring closes up into a blob once the hole is under
a couple of pixels.

Note that the Linux/Tauri build at the repo root carries its own icons
(`src-tauri/icons/`, `public/fellyjin-logo.png`, `FellyJin.png`) and this
generator does not touch them.

## App icons (Icon Composer) — `app_icons.py`

Since Sept 2026 the iOS and macOS app icon, and the twelve alternates people
pick in Settings → App Icon, are Icon Composer documents in
`Aquarium/App Icons/*.icon`, written by `app_icons.py`:

```sh
python3 app_icons.py "../../Aquarium/App Icons" --previews ../../Aquarium/Assets.xcassets
python3 app_icons.py /tmp/icons --proof           # renders every look to /tmp/icons/proof
```

Each is a gradient fill and up to four groups of flat SVG layers; Liquid Glass
adds the depth, and the system derives Clear and Tinted. Dark is authored: each
icon names a dark background, and a layer can carry `dark=` art (and `mono=` art
for Clear/Tinted, for layers drawn dark on a light ground, which would
otherwise read as nothing). In `icon.json` a specialised property is a list
whose first entry has no `appearance` — with a plain key beside it the dark
entry is silently ignored.

Xcode compiles a `.icon` into the iOS 26+ glass icon *and* flattens it into
the default/dark/tinted 1024s iOS 17–25 use, so nothing else is needed. The
alternates are listed in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` for
the iPhone SDKs only; the picker (`AppIconSettingsView.swift`) shows the
`App Icon Previews` imagesets, because an app icon can't be loaded by name.
Adding an icon means: a function here, an entry in `ICONS`, the build setting,
and a row in `AppIconChoice.shelves`.

Proofs render through Icon Composer's own renderer:
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`
(`--rendition Default|Dark|ClearLight|ClearDark|TintedLight|TintedDark`). The
tvOS icon (`App Icon.brandassets`) is untouched and still comes from `brand.swift`.

## Bubbles

Every icon carries the same bubble trail: `BUBBLES` in `app_icons.py` and
`bubbles` in `brand.swift` are one list and must be changed together. In the
`.icon` documents the bubbles are their own glass group on top (inside the top
group for icons that already use Icon Composer's four); each icon picks a
bubble ink that reads on its background. In `brand.swift` they are shaded by
hand, and are their own top parallax layer on tvOS.
