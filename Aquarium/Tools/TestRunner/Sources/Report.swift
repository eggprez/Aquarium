import Foundation

/// The report a run leaves behind, written for Claude to read: what ran, what
/// failed and with what message, and where the logs, result bundles and
/// screenshots are.
enum Report {
    struct File: Codable {
        var generated: Date
        var repository: String
        var branch: String
        var commit: String
        var uncommittedFiles: Int
        var machine: String
        var xcode: String
        var seconds: Double
        var passed: Int
        var failed: Int
        var skipped: Int
        var suites: [SuiteRun]
    }

    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: date)
    }

    @MainActor
    static func write(_ model: Model) async -> URL? {
        guard let root = model.root, let catalogue = model.catalogue else { return nil }
        let runs = model.session.compactMap { model.runs[$0] }
        func git(_ args: String...) async -> String {
            await Shell.run(["git", "-C", root.path] + args).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cases = runs.flatMap(\.cases)
        let file = File(
            generated: Date(),
            repository: root.path,
            branch: await git("rev-parse", "--abbrev-ref", "HEAD"),
            commit: await git("log", "-1", "--format=%h %s"),
            uncommittedFiles: await git("status", "--porcelain").split(separator: "\n").count,
            machine: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            xcode: await Shell.run(["xcodebuild", "-version"]).output.split(separator: "\n").joined(separator: ", "),
            seconds: (model.sessionEnd ?? Date()).timeIntervalSince(model.sessionStart ?? Date()),
            passed: cases.filter { $0.outcome == .passed }.count,
            failed: cases.filter { $0.outcome == .failed }.count,
            skipped: cases.filter { $0.outcome == .skipped }.count,
            suites: runs.map { run in
                var run = run
                run.console = String(run.console.suffix(3000))
                return run
            })

        let resultsRoot = root.appendingPathComponent(catalogue.resultsDir)
        let folder = resultsRoot.appendingPathComponent("reports")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = stamp(model.sessionStart ?? Date()) + "-report"
        let text = markdown(file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = (try? encoder.encode(file)) ?? Data()
        let report = folder.appendingPathComponent(name + ".md")
        try? text.write(to: report, atomically: true, encoding: .utf8)
        try? json.write(to: folder.appendingPathComponent(name + ".json"))
        // The same report under a name that never changes, so "read the latest
        // test report" needs no path.
        try? text.write(to: resultsRoot.appendingPathComponent("latest-report.md"), atomically: true, encoding: .utf8)
        try? json.write(to: resultsRoot.appendingPathComponent("latest-report.json"))
        return report
    }

    static func time(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    static func markdown(_ file: File) -> String {
        var out: [String] = []
        let cases = file.suites.flatMap { run in run.cases.map { (run, $0) } }
        let failures = cases.filter { $0.1.outcome == .failed }
        let broken = file.suites.filter { $0.state != .passed && $0.count(.failed) == 0 || !$0.buildErrors.isEmpty }
        let verdict = failures.isEmpty && broken.isEmpty ? "PASSED" : "FAILED"

        out.append("# Aquarium test report: \(verdict)")
        out.append("")
        out.append("- Generated: \(ISO8601DateFormatter().string(from: file.generated)), took \(time(file.seconds))")
        out.append("- Repository: `\(file.repository)`")
        out.append("- Branch: `\(file.branch)` at `\(file.commit)`" + (file.uncommittedFiles > 0 ? " with \(file.uncommittedFiles) uncommitted file(s)" : ""))
        out.append("- Machine: \(file.machine); \(file.xcode)")
        out.append("- Totals: \(file.passed) passed, \(file.failed) failed, \(file.skipped) skipped")
        out.append("")
        out.append("## For Claude")
        out.append("")
        out.append("This file was written by the test runner app (`Aquarium/Tools/TestRunner`). Each failure below has the test, its message, the end of its log and the paths of its screenshot and element tree. Read `Aquarium/TESTING.md` (\"Known traps\") before calling a failure an app bug: a server that is down, a refused Mac run or a missing simulator runtime are set-up problems. The same data is in `latest-report.json` beside this file. To run one test again: `Tools/run-tests.sh <suite> --only <Target>/<Class>/<test>` from `Aquarium/`.")
        out.append("")
        out.append("## Suites")
        out.append("")
        out.append("| Suite | Result | Passed | Failed | Skipped | Time | Command |")
        out.append("|---|---|---|---|---|---|---|")
        for run in file.suites {
            out.append("| \(run.title) | \(run.state.rawValue)\(run.exitCode.map { " (exit \($0))" } ?? "") | \(run.count(.passed)) | \(run.count(.failed)) | \(run.count(.skipped)) | \(time(run.seconds)) | `\(run.commandLine)` |")
        }
        out.append("")

        if !broken.isEmpty {
            out.append("## Suites that did not run cleanly")
            out.append("")
            for run in broken {
                out.append("### \(run.title): \(run.state.rawValue)")
                out.append("")
                for note in run.notes { out.append("- \(note)") }
                if !run.buildErrors.isEmpty {
                    out.append("")
                    out.append("```")
                    out += run.buildErrors
                    out.append("```")
                }
                if let dir = run.resultDir { out.append(""); out.append("Logs: `\(dir)`") }
                out.append("")
            }
        }

        out.append("## Failures (\(failures.count))")
        out.append("")
        if failures.isEmpty { out.append("None."); out.append("") }
        for (run, test) in failures {
            out.append("### \(run.title) · \(test.run) · \(test.group)/\(test.name)")
            out.append("")
            out.append("- Time: \(time(test.seconds))")
            for message in test.messages {
                out.append("- Message:")
                out.append("")
                out.append("```")
                out.append(message)
                out.append("```")
            }
            if !test.attachments.isEmpty {
                out.append("- Attachments:")
                for path in test.attachments { out.append("  - `\(path)`") }
            }
            if let dir = run.resultDir, run.suiteID.isEmpty == false, test.run != "vitest", test.run != "cargo" {
                out.append("- Log: `\(dir)/\(test.run).log`; result bundle: `\(dir)/\(test.run).xcresult`")
            } else if let dir = run.resultDir {
                out.append("- Log: `\(dir)/console.log`")
            }
            if let excerpt = test.logExcerpt {
                out.append("- End of the test's log:")
                out.append("")
                out.append("```")
                out.append(excerpt)
                out.append("```")
            }
            out.append("")
        }

        let skipped = cases.filter { $0.1.outcome == .skipped }
        if !skipped.isEmpty {
            out.append("## Skipped (\(skipped.count))")
            out.append("")
            out.append("Grouped by reason. A test for another device skipping is normal (iPhone and iPad tests share a bundle); \"server\" or \"fixtures\" reasons mean the QA server was not ready.")
            out.append("")
            let byReason = Dictionary(grouping: skipped) { "\($0.0.title) · \($0.1.run): " + ($0.1.messages.first ?? "no reason given") }
            for reason in byReason.keys.sorted() {
                let tests = byReason[reason] ?? []
                let names = tests.prefix(6).map { "\($0.1.group)/\($0.1.name)" }.joined(separator: ", ")
                out.append("- \(reason): \(tests.count) test(s)\(tests.count <= 6 ? " (\(names))" : ", e.g. \(names)")")
            }
            out.append("")
        }

        let slow = cases.filter { $0.1.seconds >= 20 }.sorted { $0.1.seconds > $1.1.seconds }.prefix(10)
        if !slow.isEmpty {
            out.append("## Slowest tests")
            out.append("")
            for (run, test) in slow { out.append("- \(time(test.seconds)): \(run.title) · \(test.run) · \(test.group)/\(test.name)") }
            out.append("")
        }

        out.append("## Result folders")
        out.append("")
        for run in file.suites { out.append("- \(run.title): \(run.resultDir.map { "`\($0)`" } ?? "none")") }
        out.append("")
        return out.joined(separator: "\n")
    }
}
