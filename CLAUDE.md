# Aquarium

Jellyfin client in two independent apps that share behaviour but not code:

- `Aquarium/`: the Apple app (SwiftUI; iPhone, iPad, Apple TV, Mac, Watch).
- `Linux/`: the Linux app (Tauri 2 + libmpv, shipped as a `.deb`). Its build, test hooks and invariants are in `Linux/CLAUDE.md`, and every path there is relative to `Linux/`.

Both apps live on `main`. `PRIVACY.md` stays at the root because the App Store listing links to it. `.github/workflows/linux-release.yml` builds the Linux `.deb` on `v*` tags.

## Tests change with the app

Both apps have test suites, and the Mac app "Aquarium Tests" (`Aquarium/Tools/TestRunner`, built as "Aquarium Tests.app" in the top folder) runs them and writes a report. Any change to what an app does carries its tests in the same piece of work:

- A new feature gets tests for it; changed behaviour gets its existing tests changed to match; a fixed bug gets a test that would have caught it. Unit tests for logic, UI tests for what a person sees and taps, on every platform the change reaches.
- Apple app: tests go in the platform folders listed in `Aquarium/TESTING.md` ("Who owns what"), new accessibility identifiers in `Aquarium/Shared/TestIDs/`. Linux app: see `Linux/TESTING.md`.
- The runner finds new test classes and files by scanning those folders, so a new test needs no change to it. A new suite, device or run option is an entry in `Aquarium/Tools/TestRunner/suites.json` (and in `Aquarium/Tools/run-tests.sh` if the script has to learn it).
- What cannot be tested automatically goes in the platform's `MANUAL.md`, and `COVERAGE.md` is brought up to date.
- Run the suites the change touches before calling it done, and say which ran and which did not.

When asked to look at test results, read `Aquarium/TestResults/latest-report.md` (the runner writes it after every run; `latest-report.json` has the same data, and `Aquarium/TestResults/reports/` keeps the earlier ones).
