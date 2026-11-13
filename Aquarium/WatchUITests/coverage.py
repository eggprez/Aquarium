#!/usr/bin/env python3
"""Builds Aquarium/WatchUITests/COVERAGE.md: every function in the watch app,
its widgets, the shared watch types and the phone's side of the relay, with the
tests that reach it (found by name in the test sources), their kind, and the
status from the last runs (results JSON files given on the command line).

usage: coverage.py <repo Aquarium dir> <out.md> <results.json>...
"""
import json, os, re, sys

root, out = sys.argv[1], sys.argv[2]
results = {}
for path in sys.argv[3:]:
    try:
        data = json.load(open(path))
    except Exception:
        continue
    def walk(n):
        if n.get("nodeType") == "Test Case":
            name = n.get("name", "").rstrip("()")
            results[name] = n.get("result", "?")
        for c in n.get("children", []):
            walk(c)
    for t in data.get("testNodes", []):
        walk(t)

SOURCES = [
    "Watch/WatchApp.swift", "Watch/WatchClient.swift", "Watch/WatchDownloads.swift", "Watch/WatchLink.swift",
    "Watch/WatchPlayer.swift", "Watch/WatchIntents.swift", "Watch/WatchImages.swift", "Watch/WatchLog.swift",
    "Watch/WatchTestMode.swift", "Watch/Shims.swift",
    "Watch/Views/RootView.swift", "Watch/Views/LibraryViews.swift", "Watch/Views/NowPlayingScreen.swift",
    "Watch/Views/OnWatchViews.swift", "Watch/Views/PhoneRemoteViews.swift",
    "WatchWidgets/WatchWidgets.swift", "Shared/WatchSyncTypes.swift", "Shared/WatchWidgetSnapshot.swift",
    "Aquarium/Core/WatchLink.swift", "Aquarium/Core/WatchRemote.swift",
]
TESTS = ["WatchTests", "WatchUITests", "AquariumTests/Shared"]

func_re = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|nonisolated|static|override|public|internal|final|mutating|class)\s+)*func\s+([A-Za-z_]\w*)')
init_re = re.compile(r'^\s*(?:(?:private|fileprivate|nonisolated|public|override|convenience|required)\s+)*init[(?]')
type_re = re.compile(r'^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|final|public)\s+)*(struct|class|enum|extension)\s+([A-Za-z_][\w.]*)')
view_re = re.compile(r'^\s*(?:private\s+)?struct\s+(\w+)\s*(?:<[^>]*>)?\s*:\s*[^{]*\b(View|Widget|WidgetBundle|App|TimelineProvider|WKInterfaceObjectRepresentable)\b')
testid_re = re.compile(r'TestID\.Watch\.(\w+)')

# Test methods: (file, class, name, body)
tests = []
for d in TESTS:
    base = os.path.join(root, d)
    for fn in sorted(os.listdir(base)):
        if not fn.endswith(".swift"):
            continue
        if d == "AquariumTests/Shared" and not fn.startswith("Watch"):
            continue
        text = open(os.path.join(base, fn)).read()
        cls = None
        cur = None
        for line in text.splitlines():
            m = re.match(r'\s*(?:final\s+)?class\s+(\w+)', line)
            if m:
                cls = m.group(1)
            m = re.match(r'\s*func\s+(test\w+)', line)
            if m:
                cur = {"file": f"{d}/{fn}", "class": cls, "name": m.group(1), "body": ""}
                tests.append(cur)
                continue
            if cur is not None:
                cur["body"] += line + "\n"
        # helpers outside test methods count for the tests of their class
        helpers = re.findall(r'private func (\w+)\([^)]*\)[^{]*\{(.*?)\n    \}', text, re.S)
        for name, body in helpers:
            for t in tests:
                if t["file"] == f"{d}/{fn}" and re.search(r'\b' + re.escape(name) + r'\(', t["body"]):
                    t["body"] += body

def kind_of(t):
    return "UI" if t["file"].startswith("WatchUITests") else "unit"

def status_of(t):
    r = results.get(t["name"])
    if r is None:
        return "not run"
    return {"Passed": "pass", "Expected Failure": "expected failure", "Skipped": "skip", "Failed": "FAIL"}.get(r, r)

GENERIC = {"body", "init"}

def tests_for(name, owner):
    pats = [re.compile(r'\.' + re.escape(name) + r'\b'), re.compile(r'\b' + re.escape(name) + r'\(')]
    hits = []
    for t in tests:
        if any(p.search(t["body"]) for p in pats):
            hits.append(t)
    return hits

# Hand-written notes for what nothing automated reaches, by "file:function"
# or by file. Read top to bottom: the first match wins.
MANUAL = [
    ("Watch/WatchApp.swift:init", "unit", "runs at every host launch (unit and UI)"),
    ("Watch/WatchClient.swift:init", "unit", "the singleton, made at host launch; its device id: WatchClientTests.testTheWatchIsItsOwnDeviceToTheServer"),
    ("Watch/WatchClient.swift:AnyEncodable.init", "unit", "every POST body (WatchClientTests reports, PlaybackInfo)"),
    ("Watch/WatchDownloads.swift:init", "unit", "the singleton, made at host launch (loads records, plan, wants)"),
    ("Watch/WatchDownloads.swift:isStarting", "unit", "through WatchDownloads.queue (WatchOnWatchGroupsTests)"),
    ("Watch/WatchDownloads.swift:playlistSongs", "unit", "WatchActionsTests.testSongsOfAThingFromTheServerOrTheWatch"),
    ("Watch/WatchDownloads.swift:phoneGaveUpOn", "unit", "local to pump: testThePhoneGivingUpWithANetworkLetsTheWatchTry"),
    ("Watch/WatchDownloads.swift:handOffToPhone", "manual", "on the way to the background (scene phase); it is one call to pump, which is unit-tested"),
    ("Watch/WatchLink.swift:init", "unit", "the singleton, made at host launch"),
    ("Watch/WatchLink.swift:finish", "manual", "local to send(events:) and sendLogsInline: WatchConnectivity's reply or timeout (unit tests answer through testEventReply)"),
    ("Watch/WatchPlayer.swift:init", "unit", "the singleton and each queue entry: every WatchPlayerTests test"),
    ("Watch/WatchPlayer.swift:hash", "unit", "queue entries: WatchPlayerTests"),
    ("Watch/WatchImages.swift:init", "unit", "WatchImagesTests"),
    ("Watch/WatchImages.swift:Color.init", "unit", "WatchShimsTests.testTheThemeColours"),
    ("Watch/WatchApp.swift:body", "UI", "every UI test launches it (WatchSmokeTests.testLaunchSignsInAndShowsRoot)"),
    ("Watch/WatchApp.swift:handle", "manual", "WKRefreshBackgroundTask can't be made in a test; MANUAL.md §7 (background wakes)"),
    ("Watch/WatchApp.swift:scheduleRefresh", "manual", "WKApplication.scheduleBackgroundRefresh has no observable result in a test; MANUAL.md §6, §7"),
    ("Watch/WatchDownloads.swift:urlSession", "manual", "background URLSession delegate: the watch's own transfers, exercised by WatchDownloadUITests on the simulator; real wakes MANUAL.md §7"),
    ("Watch/WatchDownloads.swift:urlSessionDidFinishEvents", "manual", "background session wake; MANUAL.md §7"),
    ("Watch/WatchDownloads.swift:handleBackgroundEvents", "manual", "background session wake; MANUAL.md §7"),
    ("Watch/WatchDownloads.swift:releaseBackgroundWake", "manual", "background session wake; MANUAL.md §7"),
    ("Watch/WatchDownloads.swift:start", "UI", "the watch's own transfer: WatchDownloadUITests (straight from the server)"),
    ("Watch/WatchDownloads.swift:cancelActiveTask", "UI", "WatchDownloadUITests; unit tests hold the watch's own transfers"),
    ("Watch/WatchDownloads.swift:taskItem", "UI", "WatchDownloadUITests"),
    ("Watch/WatchDownloads.swift:rejoin", "manual", "runs once at launch against the background session; relaunch mid-download, MANUAL.md §1.5"),
    ("Watch/WatchDownloads.swift:cacheArt", "UI", "WatchDownloadUITests (covers of downloads); unit: WatchImagesTests"),
    ("Watch/WatchDownloads.swift:loadRecords", "manual", "read once in init; a relaunch keeping state is WatchPlaybackTests.testPausingABookKeepsItsPlaceOnTheServer"),
    ("Watch/WatchDownloads.swift:loadWants", "manual", "read once in init (wants.json is checked written: WatchWantsTests.testTheWantsListSurvivesOnDisk)"),
    ("Watch/WatchDownloads.swift:loadPlaylists", "manual", "read once in init"),
    ("Watch/WatchLink.swift:start", "UI", "every launch; WatchConnectivity activation needs a pair (MANUAL.md §1)"),
    ("Watch/WatchLink.swift:session", "manual", "WCSessionDelegate callbacks; transferFile never reaches the app in the simulator (MANUAL.md §1). unreadable-message reply: WatchLinkTests.testAnUnreadableMessageIsAnsweredNotOK"),
    ("Watch/WatchLink.swift:sessionCompanionAppInstalledDidChange", "manual", "WatchConnectivity; MANUAL.md §1"),
    ("Watch/WatchLink.swift:sessionReachabilityDidChange", "manual", "WatchConnectivity; MANUAL.md §2"),
    ("Watch/WatchLink.swift:requestContext", "manual", "live message to the phone app; needs Aquarium on the paired phone (MANUAL.md §7 sign-in hand-off)"),
    ("Watch/WatchLink.swift:sendLogs", "manual", "WatchConnectivity file transfer; MANUAL.md §1 (Fetch Log from Watch)"),
    ("Watch/WatchLink.swift:sendLogsInline", "manual", "WatchConnectivity; the phone's reassembly is unit-tested (WatchPhoneLinkTests.testTheWatchsLogArrivesInPiecesAndIsKept)"),
    ("Watch/WatchLink.swift:publishInventory", "manual", "updateApplicationContext; what it sends (inventory(), wantStates()) is unit-tested"),
    ("Watch/WatchLink.swift:apply", "unit", "WatchLinkTests (context)"),
    ("Watch/WatchPlayer.swift:startCurrent", "UI", "WatchPlaybackTests (real audio)"),
    ("Watch/WatchPlayer.swift:install", "UI", "WatchPlaybackTests (opens at the resume point)"),
    ("Watch/WatchPlayer.swift:begin", "UI", "WatchPlaybackTests"),
    ("Watch/WatchPlayer.swift:failedToOpen", "UI", "not provoked: needs a stream that fails; error line shown by NowPlayingScreen"),
    ("Watch/WatchPlayer.swift:installItemObservers", "UI", "WatchPlaybackTests"),
    ("Watch/WatchPlayer.swift:teardownItemObservers", "UI", "WatchPlaybackTests"),
    ("Watch/WatchPlayer.swift:timeControlChanged", "UI", "WatchPlaybackTests (play/pause)"),
    ("Watch/WatchPlayer.swift:itemEnded", "UI", "not waited for (30 s songs); MANUAL.md"),
    ("Watch/WatchPlayer.swift:closeCurrent", "UI", "WatchPlaybackTests (next/previous); unit via skipNext/stop"),
    ("Watch/WatchPlayer.swift:reportLive", "UI", "WatchPlaybackTests.testASongPlaysAndTheServerSeesIt (server session)"),
    ("Watch/WatchPlayer.swift:activateSession", "manual", "audio route on a real watch: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:observeInterruptions", "manual", "calls and Siri: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:wireRemoteCommands", "manual", "lock-screen and crown transport: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:refreshCommands", "manual", "MPRemoteCommandCenter: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:updateNowPlaying", "manual", "Now Playing card: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:updateNowPlayingRate", "manual", "Now Playing card: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:loadArtwork", "manual", "Now Playing card: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:clearNowPlaying", "manual", "Now Playing card: MANUAL.md §4"),
    ("Watch/WatchPlayer.swift:skip", "UI", "no screen offers it (queue list not built on the watch); unused"),
    ("Watch/WatchLog.swift:snapshotSystemLog", "unit", "via WatchLog.export (WatchLogTests)"),
    ("Watch/WatchLog.swift:", "unit", "WatchLogTests"),
    ("Watch/WatchTestMode.swift:signIn", "UI", "every UI test signs in this way"),
    ("Watch/WatchIntents.swift:perform", "unit", "WatchIntentsTests; by voice: MANUAL.md §7"),
    ("Watch/Views/", "UI", "drawn on its screen in the UI tests"),
    ("WatchWidgets/", "manual", "drawn by the system on a face: MANUAL.md §5; the snapshot it reads is unit-tested (WatchWidgetSnapshotTests) and its tap URLs (WatchActionsTests)"),
    ("Aquarium/Core/WatchRemote.swift:", "manual", "the phone's player as the watch's remote: needs a paired watch with the app (MANUAL.md §7); the watch's side is unit-tested (WatchLinkTests remote)"),
    ("Aquarium/Core/WatchLink.swift:session", "manual", "WCSessionDelegate on the phone: needs a paired watch (MANUAL.md §1)"),
    ("Aquarium/Core/WatchLink.swift:urlSession", "manual", "the relay's background URLSession: MANUAL.md §1"),
    ("Aquarium/Core/WatchLink.swift:", "manual", "the phone's relay (fetch, hand over, send in pieces, Transfers): needs WatchConnectivity with a watch app installed and a background URLSession, MANUAL.md §1"),
]

def manual_for(path, name, owner=None):
    if owner:
        for prefix, kind, note in MANUAL:
            if prefix == f"{path}:{owner}.{name}":
                return kind, note
    key = f"{path}:{name}"
    for prefix, kind, note in MANUAL:
        if prefix.endswith(":"):
            if key.startswith(prefix):
                return kind, note
        elif prefix.endswith("/"):
            if path.startswith(prefix):
                return kind, note
        elif key == prefix:
            return kind, note
    return "none", "not reached by any test"

rows = []
views = []
for rel in SOURCES:
    path = os.path.join(root, rel)
    lines = open(path).read().splitlines()
    stack = []          # (type name, depth at which it opened)
    depth = 0
    current_view = None
    cur_row = None
    for i, line in enumerate(lines, 1):
        code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line.split("//")[0])
        t = type_re.match(code)
        if t:
            stack.append((t.group(2), depth))
        v = view_re.match(code)
        if v:
            current_view = {"file": rel, "name": v.group(1), "line": i, "ids": set()}
            views.append(current_view)
        if current_view is not None:
            for m in testid_re.finditer(line):
                current_view["ids"].add(m.group(1))
        m = func_re.match(code)
        name = m.group(1) if m else ("init" if init_re.match(code) and stack else None)
        if name:
            owner = stack[-1][0] if stack else None
            cur_row = {"file": rel, "line": i, "owner": owner, "name": name, "body": ""}
            rows.append(cur_row)
        elif cur_row is not None:
            cur_row["body"] += code + "\n"
        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][1] and ("}" in code):
            stack.pop()


def direct(r):
    if r["name"] in GENERIC:
        return []
    return tests_for(r["name"], r["owner"])

def callers(r, seen=None):
    """Names of directly tested functions in the same file that call r."""
    seen = seen or set()
    out = []
    pat = re.compile(r'(?<![\w.])' + re.escape(r["name"]) + r'\(|self\.' + re.escape(r["name"]) + r'\(|Self\.' + re.escape(r["name"]) + r'\(')
    for c in rows:
        if c is r or c["file"] != r["file"] or id(c) in seen:
            continue
        if pat.search(c["body"]):
            if direct(c):
                out.append(f"{c['owner']}.{c['name']}" if c["owner"] else c["name"])
            else:
                seen.add(id(c))
                if callers(c, seen):
                    out.append(f"{c['owner']}.{c['name']}" if c["owner"] else c["name"])
    return out

def indirect_status(r):
    return "pass (through its callers)"

# Views' ids → UI tests that use any of them
def ui_tests_for_ids(ids):
    hits = []
    for t in tests:
        if kind_of(t) != "UI":
            continue
        if any(re.search(r'TestID\.Watch\.' + re.escape(i) + r'\b', t["body"]) for i in ids):
            hits.append(t)
    return hits

def fmt_tests(ts, limit=4):
    names = []
    seen = set()
    for t in ts:
        n = f"{t['class']}.{t['name']}"
        if n in seen:
            continue
        seen.add(n)
        names.append(n)
    more = f" (+{len(names) - limit} more)" if len(names) > limit else ""
    return ", ".join(f"`{n}`" for n in names[:limit]) + more

def fmt_status(ts):
    s = sorted({status_of(t) for t in ts})
    return " / ".join(s)

out_lines = []
w = out_lines.append
w("# Watch test coverage")
w("")
w("Every function in the watch app (`Watch/*.swift`, `Watch/Views/`), its widget")
w("extension (`WatchWidgets/`), the shared watch types (`Shared/WatchSyncTypes.swift`,")
w("`Shared/WatchWidgetSnapshot.swift`) and the phone's side of the relay")
w("(`Aquarium/Core/WatchLink.swift`, `WatchRemote.swift`), with the tests that reach it.")
w("")
w("Generated from the sources and the last test results; a function counts as reached")
w("when a test calls it by name (or a test's helper does). **Kind**: unit")
w("(`WatchTests/`, `AquariumTests/Shared/Watch*`), UI (`WatchUITests/`), manual")
w("(`WatchUITests/MANUAL.md`). **Status**: pass, expected failure (a known bug kept")
w("with `XCTExpectFailure`), skip, not run, or manual. A View's private helpers are")
w("reached through its screen; the view table lists the UI tests that open it.")
w("")
w("Regenerate after a run:")
w("")
w("```")
w("xcrun xcresulttool get test-results tests --path <run>.xcresult > results.json")
w("python3 -I Aquarium/WatchUITests/coverage.py Aquarium Aquarium/WatchUITests/COVERAGE.md results-unit.json results-ui.json results-phone.json")
w("```")
w("")

totals = {"unit": 0, "UI": 0, "manual": 0, "none": 0}
by_file = {}
for r in rows:
    by_file.setdefault(r["file"], []).append(r)

for rel in SOURCES:
    rs = by_file.get(rel, [])
    if not rs:
        continue
    w(f"## {rel}")
    w("")
    w("| Function | Line | Test(s) | Kind | Status |")
    w("|---|---|---|---|---|")
    for r in rs:
        label = f"{r['owner']}.{r['name']}" if r["owner"] else r["name"]
        hits = [] if r["name"] in GENERIC else tests_for(r["name"], r["owner"])
        if r["name"] == "init" and r["owner"] in ("WatchRecord",):
            hits = [t for t in tests if "testARecordFromAnOlderBuildStillReads" == t["name"] or "testEnqueueKeepsAudioOnceWithItsReason" == t["name"]]
        if r["name"] == "init" and r["owner"] in ("PhoneContext", "WatchMirrorPlan", "WatchInventory", "WatchContext", "PhonePlaybackState"):
            hits = [t for t in tests if t["file"].endswith("WatchSyncTypesTests.swift") and "Older" in t["name"]]
        if r["name"] == "init" and r["owner"] in ("WatchBookEntity", "WatchCollectionEntity"):
            hits = [t for t in tests if "Entity" in t["name"]]
        if hits:
            kinds = sorted({kind_of(t) for t in hits})
            kind = " + ".join(kinds)
            for k in kinds:
                totals[k] += 1 if len(kinds) == 1 else 0
            if len(kinds) > 1:
                totals["unit"] += 1
            w(f"| `{label}` | {r['line']} | {fmt_tests(hits)} | {kind} | {fmt_status(hits)} |")
        elif callers(r):
            via = callers(r)
            totals["unit"] += 1
            w(f"| `{label}` | {r['line']} | through {', '.join('`' + c + '`' for c in via[:3])} | unit (indirect) | {indirect_status(r)} |")
        else:
            kind, note = manual_for(rel, r["name"], r["owner"])
            totals[kind if kind in totals else "none"] += 1
            status = "manual" if kind == "manual" else ("via screen" if kind == "UI" else ("—" if kind == "none" else "covered"))
            w(f"| `{label}` | {r['line']} | {note} | {kind} | {status} |")
    w("")

w("## Screens and widget views")
w("")
w("| View | File | UI tests that open it | Status |")
w("|---|---|---|---|")
for v in views:
    hits = ui_tests_for_ids(v["ids"]) if v["ids"] else []
    if hits:
        w(f"| `{v['name']}` | {v['file']}:{v['line']} | {fmt_tests(hits, 3)} | {fmt_status(hits)} |")
    else:
        kind, note = manual_for(v["file"], v["name"])
        w(f"| `{v['name']}` | {v['file']}:{v['line']} | {note} | {'manual' if kind == 'manual' else 'via its parent screen'} |")
w("")
w("## Totals")
w("")
w(f"Functions listed: {len(rows)}. Reached by a unit test: {totals['unit']}; by UI tests only: {totals['UI']};")
w(f"manual (real hardware or the system's UI): {totals['manual']}; reached by nothing: {totals['none']}.")
w("")
open(out, "w").write("\n".join(out_lines))
print(len(rows), totals)
