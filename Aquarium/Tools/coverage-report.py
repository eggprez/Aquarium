#!/usr/bin/env python3
"""What the tests ran, file by file.

    Tools/coverage-report.py [--out <path without extension>] <run folder>…

Reads the coverage Xcode keeps in every .xcresult under the run folders
(TestResults/<stamp>-<suite>/) and joins them: a function counts as reached
when any run reached it, on any device. Writes <out>.md and <out>.json
(default: coverage.md / coverage.json in the first folder) and prints the
summary. Only the app's own code is counted: not the test bundles, not MPVKit.

A function's covered lines are the most any one run covered, so a file's
figure is a floor: two runs that each cover a different half of one function
count as a half, not the whole.
"""
import json
import os
import re
import subprocess
import sys

APP_TARGETS = ("Aquarium.app", "AquariumWatch.app", "LiveActivities.appex",
               "TopShelf.appex", "WatchWidgets.appex")
# Compiled into the app but not behaviour: the identifier catalogue and the
# hooks tests and debugging use.
LEFT_OUT = ("/Shared/TestIDs/", "/Core/TestMode.swift", "/Watch/WatchTestMode.swift",
            "/Core/DebugLinkHook.swift", "/Player/TV/RemoteDebugHook.swift")


def report(bundle):
    try:
        out = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", bundle],
                             capture_output=True, text=True, timeout=600).stdout
        return json.loads(out)
    except Exception:
        return None


def main():
    args = sys.argv[1:]
    out = None
    if args[:1] == ["--out"]:
        out, args = args[1], args[2:]
    if not args:
        print(__doc__)
        return 2
    out = out or os.path.join(args[0], "coverage")
    # Paths from the project folder down, whichever checkout built them.
    inside = re.compile(r".*/Aquarium/((?:Aquarium|Watch|WatchWidgets|Shared|LiveActivities|TopShelf)/.*)")

    files = {}   # path -> {(name, line): [covered, executable, count]}
    runs = []
    for folder in args:
        for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            if not name.endswith(".xcresult"):
                continue
            data = report(os.path.join(folder, name))
            if not data:
                continue
            runs.append(name[:-len(".xcresult")])
            for target in data.get("targets", []):
                if target.get("name") not in APP_TARGETS:
                    continue
                for f in target.get("files", []):
                    path = f["path"]
                    found = inside.match(path)
                    path = found.group(1) if found else path
                    if any(part in path for part in LEFT_OUT):
                        continue
                    functions = files.setdefault(path, {})
                    for fn in f.get("functions", []):
                        key = (fn["name"], fn["lineNumber"])
                        best = functions.setdefault(key, [0, fn["executableLines"], 0])
                        best[0] = max(best[0], fn["coveredLines"])
                        best[1] = max(best[1], fn["executableLines"])
                        best[2] = max(best[2], fn["executionCount"])
    if not files:
        print("no coverage found in " + ", ".join(args))
        return 1

    rows = []
    for path, functions in files.items():
        covered = sum(v[0] for v in functions.values())
        lines = sum(v[1] for v in functions.values())
        missed = sorted(((line, name) for (name, line), v in functions.items() if v[2] == 0))
        rows.append({
            "file": path, "lines": lines, "covered": covered,
            "percent": round(100 * covered / lines, 1) if lines else 100.0,
            "functions": len(functions), "functionsNeverRun": len(missed),
            "neverRun": [{"line": line, "name": name} for line, name in missed],
        })
    rows.sort(key=lambda r: r["file"])
    total = sum(r["lines"] for r in rows)
    covered = sum(r["covered"] for r in rows)
    fns = sum(r["functions"] for r in rows)
    never = sum(r["functionsNeverRun"] for r in rows)
    summary = {
        "runs": runs, "lines": total, "covered": covered,
        "percent": round(100 * covered / total, 1) if total else 0,
        "functions": fns, "functionsNeverRun": never, "files": rows,
    }
    with open(out + ".json", "w") as f:
        json.dump(summary, f, indent=1)

    md = ["## Coverage", "",
          "From: " + ", ".join(runs) + ". A function counts as reached when any of these runs reached it.",
          "",
          "- Lines: %d of %d (%.1f%%)" % (covered, total, summary["percent"]),
          "- Functions never run: %d of %d" % (never, fns),
          ""]
    folders = {}
    for r in rows:
        f = folders.setdefault(os.path.dirname(r["file"]), [0, 0, 0, 0])
        f[0] += r["covered"]; f[1] += r["lines"]; f[2] += r["functionsNeverRun"]; f[3] += r["functions"]
    md += ["| Folder | Lines covered | Functions never run |", "|---|---|---|"]
    for name in sorted(folders):
        c, l, n, t = folders[name]
        md.append("| `%s` | %.0f%% of %d | %d of %d |" % (name, 100 * c / l if l else 100, l, n, t))
    md += ["", "### Least covered files", "",
           "By lines the tests never ran. Every file and every function never run is in `%s`."
           % os.path.basename(out + ".json"), "",
           "| File | Covered | Lines not run | Functions never run |", "|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: r["covered"] - r["lines"])[:40]:
        md.append("| `%s` | %.0f%% | %d | %d of %d |" % (
            r["file"], r["percent"], r["lines"] - r["covered"], r["functionsNeverRun"], r["functions"]))
    untouched = [r["file"] for r in rows if r["covered"] == 0 and r["lines"] > 0]
    if untouched:
        md += ["", "### Files no test ran at all (%d)" % len(untouched), ""]
        md += ["- `%s`" % f for f in untouched]
    md.append("")
    text = "\n".join(md)
    with open(out + ".md", "w") as f:
        f.write(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
