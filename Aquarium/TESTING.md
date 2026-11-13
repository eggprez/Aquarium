# Testing the Apple app

Everything here runs headlessly from `Aquarium/` (the folder with
`Aquarium.xcodeproj`). The Linux app has its own tests; see `Linux/CLAUDE.md`.

## Quick start

```
Tools/run-tests.sh unit      # logic tests: iPhone sim, Apple TV sim, Mac, watch sim
Tools/run-tests.sh iphone    # UI tests: SE, 17, 18 Pro Max, Duo (if its runtime exists)
Tools/run-tests.sh ipad      # UI tests: iPad Air 11-inch
Tools/run-tests.sh mac       # UI tests on this Mac (quit Aquarium first)
Tools/run-tests.sh tv        # UI tests: Apple TV 4K
Tools/run-tests.sh watch     # UI tests: Apple Watch Series 12 46 mm
Tools/run-tests.sh all
Tools/run-tests.sh iphone --device duo --only AquariumUITests/PhoneSmokeTests
```

Results go to `TestResults/<timestamp>-<suite>/` (git-ignored): one `.xcresult`
and one `.log` per plan and device, and `summary.txt`. Read a result with
`xcrun xcresulttool get test-results summary --path <file>.xcresult`, or open it
in Xcode. Failure screenshots and the element tree are attached to every failed
test.

The script makes simulators of its own, named `Aquarium Test …` (created the
first time, booted when needed, never shut down). It never touches the other
simulators, which hold real sign-ins.

Before each UI suite it runs the QA folder's `suite-reset.py suite-<name>`, which
puts that suite's account back to its baseline (see `FIXTURES.md` in the QA
folder). `--no-reset` skips that.

## What there is

| Target | Kind | Runs on | Folder (synchronized: new files need no project edit) |
|---|---|---|---|
| `AquariumTests` | unit, hosted by Aquarium.app | iOS, tvOS, macOS | `AquariumTests/` |
| `AquariumUITests` | UI | iOS (iPhone and iPad), tvOS, macOS | `AquariumUITests/{Shared,iPhone,iPad,Mac,TV}` |
| `AquariumWatchTests` | unit, hosted by AquariumWatch.app | watchOS | `WatchTests/` |
| `AquariumWatchUITests` | UI | watchOS | `WatchUITests/` (+ `AquariumUITests/Shared`) |

The identifier catalogue `Shared/TestIDs/` is compiled into the app, the watch
app and both UI-test bundles.

| Scheme | Test plans (`TestPlans/`) |
|---|---|
| `Aquarium` | `Unit` (default), `iPhone`, `iPad`, `Mac`, `TV` |
| `AquariumWatch` | `Watch` (default), `WatchUnit` |

The four UI plans run the same `AquariumUITests` bundle; each sets
`AQUARIUM_SUITE` (which server account to use). iPhone and iPad tests are told
apart at run time (their base classes skip on the other idiom); Mac and TV
tests are compiled only for their platform.

### Commands without the script

```
xcodebuild test -scheme Aquarium -testPlan Unit   -destination 'id=<iPhone sim>' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test -scheme Aquarium -testPlan iPhone -destination 'id=<iPhone sim>' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test -scheme Aquarium -testPlan iPad   -destination 'id=<iPad sim>'   CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test -scheme Aquarium -testPlan TV     -destination 'id=<Apple TV sim>' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test -scheme Aquarium -testPlan Mac    -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS= ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=NO
xcodebuild test -scheme AquariumWatch -testPlan Watch     -destination 'id=<watch sim>' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test -scheme AquariumWatch -testPlan WatchUnit -destination 'id=<watch sim>' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Add `-only-testing:AquariumUITests/PadSmokeTests` (or `/Class/testMethod`) to
narrow a run, and `-resultBundlePath <dir>.xcresult` to keep the result.
Environment for the test runner goes on the command line with the
`TEST_RUNNER_` prefix: `TEST_RUNNER_AQUARIUM_SUITE=spare1`.

## Test mode (the app's side)

A **Debug** build launched with `-AquariumUITest YES` (or `AQUARIUM_UITEST=1`)
runs in test mode. Release builds have none of it; a normal launch of a debug
build is unchanged. Names live in `Shared/TestIDs/TestLaunch.swift`; the app's
side is `Aquarium/Core/TestMode.swift` and `Watch/WatchTestMode.swift`.

| Switch | Effect |
|---|---|
| `-AquariumUITest YES` | test mode: state kept apart (below), `.testAnchor` elements exist |
| `-AquariumTestReset YES` | start clean: test defaults, test tokens and test folders emptied first |
| env `AQUARIUM_TEST_SERVER`, `AQUARIUM_TEST_USER`, `AQUARIUM_TEST_PASSWORD` | sign in at launch through the app's own `login` (watch: `AuthenticateByName` + the phone's install path), skipped if that user is already signed in |
| `-AquariumTestEngine automatic\|apple\|mpv` | the player engine preference (the policy still pins iPad) |
| `-AquariumTestAnimations NO` | `UIView.setAnimationsEnabled(false)` (iOS, tvOS) |

What test mode keeps apart, so a run never reads or wipes real data (this
matters on the Mac, where the debug build shares `~/Library/Containers/scottai.FellyJin`
with the copy in real use):

- `UserDefaults.standard` and `@AppStorage` answer from the suite
  `scottai.FellyJin.uitest` (preferences, saved accounts, the device id, so a
  test run is its own device on the server).
- Tokens are kept in that suite, never the keychain (no simulator keychain, no
  iCloud Keychain, no entitlement needed: ad-hoc and unsigned builds sign in).
- Application Support, Caches and Documents each get an `AquariumUITest`
  subfolder (`AppDirectory.url`).
- iCloud key-value sync is off, Spotlight is not written or wiped, and the
  background download sessions get `.uitest` names.

Not kept apart: the app group container (widget, Top Shelf, Live Activity
snapshots — written on iOS and tvOS only, which run on the test simulators), the
watch relay session on iOS, and Handoff activities.

`TestApp.launch()` passes `-AquariumUITest YES -AquariumTestReset YES
-AquariumTestAnimations NO` (and `-ApplePersistenceIgnoreState YES` on a Mac)
and this suite's credentials. `launch(reset: false)` relaunches keeping state;
`launch(signIn: false)` stops at the sign-in screen.

The unit plans launch the host app with `-AquariumUITest YES -AquariumTestReset
YES` too, so unit tests that touch `Preferences` or `Keychain` are isolated.

Other debug hooks still work alongside: `Core/DebugLinkHook.swift` (iPhone/iPad:
`defaults write` + `notifyutil`), `Player/TV/RemoteDebugHook.swift` (Apple TV).
In test mode `defaults write scottai.FellyJin …` writes the real domain, not the
test suite: write to `scottai.FellyJin.uitest` instead.

## Accessibility identifiers

One catalogue, `Shared/TestIDs/`: `TestID.swift` (the rule), one file per area
(`TestID+Shell.swift`, `+Browse`, `+Music`, `+Player`, `+Settings`, `+Watch`).
A view never writes an identifier as a literal; it names one from there, and
tests use the same constant.

- Name: `<area>.<screen or part>.<element>[.<key>]`, lowerCamelCase segments:
  `player.pill.audio`, `home.row.nextUp`, `item.card.<jellyfin id>`.
- A screen's own anchor is `<area>.root` or `<area>.<screen>.root`.
- One of many takes a stable key last: a Jellyfin id or an enum raw value,
  never a visible title (`TestID.key(_:)` only when text is all there is).
- Controls: `.accessibilityIdentifier(TestID.X.y)` on the control itself
  (before `.tag` in a Picker). Changes nothing VoiceOver reads.
- Screens and regions: `.testAnchor(TestID.X.y)`. Never
  `.accessibilityIdentifier` on a stack or scroll view: SwiftUI hands it down
  to every child. An anchor is an extra invisible element behind the view, so
  it exists only in test mode. Find anchors with `app.element(id)` (type `.other`).

Known gaps (find these by label or by position instead): the AirPlay route list
(system UI), the Mac Live TV filter field (`.searchable`), Tab Bar settings drag
handles, the scrub preview thumbnail (inside an element that ignores its
children), and possibly Mac menu-bar items and NSAlert buttons, if SwiftUI does
not hand their identifiers to AppKit (not yet checked).

## Who owns what

Five platform agents work in parallel worktrees. Each adds files only in its
own folders; nobody needs to edit `project.pbxproj`.

| Owner | UI tests | Unit tests | Base classes |
|---|---|---|---|
| iPhone (all sizes, incl. Duo) | `AquariumUITests/iPhone/` | `AquariumTests/iPhone/` | `PhoneUITestCase`, `PhoneUnitTestCase` |
| iPad | `AquariumUITests/iPad/` | `AquariumTests/iPad/` | `PadUITestCase`, `PadUnitTestCase` |
| Mac | `AquariumUITests/Mac/` | `AquariumTests/Mac/` | `MacUITestCase`, `MacUnitTestCase` |
| Apple TV | `AquariumUITests/TV/` | `AquariumTests/TV/` | `TVUITestCase`, `TVUnitTestCase` |
| Watch | `WatchUITests/` | `WatchTests/` | `WatchUITestCase` |
| shared (change with care, tell the others) | `AquariumUITests/Shared/` | `AquariumTests/Shared/` | `AquariumUITestCase` |

- Wrap every file in a platform folder in its `#if os(...)` (iPhone and iPad:
  `#if os(iOS)`), as the base class files are: the bundles build for every
  platform they support.
- Name test classes with the platform in front (`PhoneDetailTests`,
  `PadSidebarTests`) so names never collide across folders.
- A new identifier goes in the catalogue file for its area. Two agents adding
  names to the same `TestID+*.swift` is a normal merge (append within the
  enum); a view file that still lacks an identifier is a small edit, kept to
  `.accessibilityIdentifier`/`.testAnchor` lines only.
- App changes from a platform agent: identifiers and test hooks only.

## Writing a UI test

```swift
#if os(iOS)
import XCTest

final class PhoneResumeTests: PhoneUITestCase {
    func testContinueWatchingShows() throws {
        let fx = try Fixtures.require()
        let api = try JellyfinAPI.signIn()               // the suite's account, its own device
        let film = try fx.item("film.long_direct")        // a key from fixtures.json
        try api.setResume(film.id, seconds: 300)
        launch()                                          // clean, signed in, Home
        app.element(TestID.Home.root).waitToExist(60)
        app.scroll(to: app.element(TestID.Home.shelf(TestID.Home.rowResume)))
        attachScreenshot("continue watching")
    }
}
#endif
```

Helpers in `AquariumUITests/Shared/`:

- `AquariumUITestCase`: skips when the QA server is down or the suite has no
  account; `continueAfterFailure = false`; screenshot + element tree on every
  failure; `launch(...)`, `attachScreenshot(_:)`; terminates the app after each test.
- `TestApp`: the launch arguments above.
- `QA`: server address, suite name, `QA.account()` / `account(named:)`
  (passwords from the QA folder's `suite-accounts.txt` at run time; never in the
  repo), `isReachable()`.
- `Fixtures`: `fixtures.json` (env `AQUARIUM_FIXTURES`, default the QA folder);
  `Fixtures.require()` skips when absent; `item(key)`, `libraryId(name)`.
- `JellyfinAPI`: synchronous REST as the suite user, from its own device id:
  `markPlayed/markUnplayed`, `setFavorite`, `setResume(seconds:)`,
  `resetItem`, `userData(id)`, `sessions()`, `waitForPlayback(of:)`.
- `Elements`: `app.element(id)`, `button(id)`, `elements(prefix:)`,
  `waitToExist`, `waitToVanish`, `tapWhenReady`, `app.scroll(to:)` (iOS, watchOS).
- `Remote` (tvOS): `press(_:times:)`, `select()`, `menu()`, `focused(in:)`,
  `focus(on:in:)`.

Environment for the runner (plans set `AQUARIUM_SUITE`; the rest default):
`AQUARIUM_SUITE`, `AQUARIUM_QA_DIR`, `AQUARIUM_QA_SERVER`, `AQUARIUM_FIXTURES`,
`AQUARIUM_QA_USER` + `AQUARIUM_QA_PASSWORD`. Suite accounts: `suite-iphone`,
`suite-ipad`, `suite-mac`, `suite-tv`, `suite-watch`, plus `suite-spare1/2`
and the `fx-*` accounts (limited, no transcode, no download, kid, language,
disabled…) in `suite-accounts.txt`.

## Writing a unit test

`@testable import Aquarium` (or `AquariumWatch` in `WatchTests/`). For code
that talks to the server, `AquariumTests/Shared/Support`:

```swift
@MainActor
final class PhoneSomethingTests: PhoneUnitTestCase {
    override func setUp() async throws { ClientStub.install() }
    override func tearDown() async throws { ClientStub.remove() }

    func testSomething() async throws {
        StubURLProtocol.stub("/Users/\(ClientStub.userId)/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        // call JellyfinClient.shared ...
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "...")
    }
}
```

`StubURLProtocol` matches by path (or `"METHOD path"`), records every request
with its body, answers 404 to anything not stubbed, and can fail with a
`URLError`. The seam is `JellyfinClient.testProtocolClasses` +
`resetConnections()` (DEBUG only); on the watch,
`JellyfinClient.shared.useTestProtocols([StubURLProtocol.self])`.
`StubURLProtocol.swift` is also compiled into `AquariumWatchTests` by a project
exception; anything else watch tests need goes in `WatchTests/`.

## Known traps

- **Never `pkill`/`killall Aquarium`.** It kills every simulator's copy and the
  Mac's. Use `xcrun simctl terminate <udid> scottai.FellyJin`.
- **The Mac app in real use.** The debug build has the same bundle id: launching
  it for a test quits a running Aquarium. `MacUITestCase` skips and the script
  refuses while one is running. Test mode keeps the data apart either way.
- **Mac signing.** The team's Mac provisioning profile doesn't list this Mac
  ("doesn't include the currently selected device"), and the app's iCloud and
  SharePlay entitlements need a profile. So Mac test runs (unit and UI) are
  ad-hoc signed with no entitlements and no sandbox (the flags above, `MAC_SIGN`
  in the script). Unsandboxed, test mode's state is
  `~/Library/Preferences/scottai.FellyJin.uitest.plist` and
  `~/Library/{Application Support,Caches}/AquariumUITest`; the real app's
  container is never opened. Mac unit tests pass this way.
- **Mac UI testing needs Automation Mode.** Without it the runner stops with
  "Timed out while enabling automation mode". On 2026-11-13 the Mac's owner ran
  `sudo automationmodetool enable-automationmode-without-authentication`, so
  `/var/db/com.apple.dt.automationmode/no-auth-required` exists and runs need no
  approval. That is a security setting: the person, not an agent, changes it.
  The script refuses the Mac suite while the real app
  (`Aquarium.app/Contents/MacOS/Aquarium`) is running; simulator copies don't count.
- **QA folder in the Mac runner.** The Mac UI runner is sandboxed, so its home
  isn't yours; the script passes `TEST_RUNNER_AQUARIUM_QA_DIR`. Without it every
  Mac UI test skips. Pass it yourself when calling xcodebuild directly.
- **No recordings, no diagnostics.** UI plans set `uiTestingScreenshotsLifetime`
  to `keepNever` (otherwise each test is screen-recorded and fetching it costs
  ~2 min per test), and the script passes `-collect-test-diagnostics never`
  (otherwise a failure costs up to 10 min of `simctl diagnose`).
- **Watch pair.** The watch suites use their own pair, "Aquarium Test Watch B" +
  "Aquarium Test iPhone B". Never run phone unit tests on the watch's phone:
  that installs Aquarium there, and its signed-out context signs the watch out;
  only unpairing and erasing both clears it.
- **Sessions.** Jellyfin 12.2 returns nothing for `/Sessions?ControllableByUserId`
  for Aquarium; read `/Sessions` and pick the app's session yourself. Sessions
  left by earlier tests stay "playing", so match by session id or position.
- **Notes files.** Each platform folder's COVERAGE.md and MANUAL.md are excluded
  from the UI-test target in project.pbxproj; a new notes file in a test folder
  needs the same exception, or the build fails with "Multiple commands produce".
- **Signing on simulators.** A build with `CODE_SIGNING_ALLOWED=NO` installed on
  a simulator that has a real sign-in wipes that sign-in (keychain access goes
  with the entitlements). The script only uses its own simulators, and test mode
  needs no keychain, but don't install test builds on the other simulators.
- **Shared DerivedData.** Each checkout/worktree builds into its own DerivedData
  folder; two builds in the *same* checkout at once contend. Run one xcodebuild
  per worktree at a time.
- **iPad engine.** mpv can't be forced on iPad (the preference is pinned).
- **Watch.** `transferFile` never reaches the watch app in a simulator; the
  watch signs itself in in test mode instead of waiting for the phone.
- **Short titles.** The QA server marks anything under 5 minutes Played with
  position 0 on stop: test resume on long titles (fixtures `film.long_*`).
- **Throttle proxy.** Port 8098 can hang below ~2.6 Mbps and look like "Server
  offline"; tests use 8196 unless a test sets `AQUARIUM_QA_SERVER`.
- **Anchors.** `.testAnchor` elements only exist in test mode, and a view inside
  an element with `.accessibilityElement(children: .ignore)` or `.combine`
  hides its anchors; tag the outer element.
- **Duo.** The Duo simulator needs the iOS 27.1 (Duo) runtime; if it is missing
  the script reports the Duo as skipped. Hinge poses are driven by Device Hub,
  not by XCUITest.
