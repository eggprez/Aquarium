import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The summary page: where things stand, what to do next, and the report.
struct Overview: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let runs = model.session.compactMap { model.runs[$0] }
        let problems = runs.flatMap { run in run.cases.filter { $0.outcome == .failed }.map { (run, $0) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Hero(runs: runs, problemCount: problems.count)
                if runs.isEmpty {
                    HowItWorks()
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("What was tested").font(.headline).padding(.bottom, 8)
                            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                                if index > 0 { Divider() }
                                AreaRow(run: run)
                            }
                        }
                    }
                    if !problems.isEmpty {
                        Text("Problems found").font(.title3.weight(.semibold)).padding(.top, 6)
                        Text("Each one is a check that did not go as expected. You don't need to understand the details: the report has all of it for Claude.")
                            .foregroundStyle(.secondary)
                        ForEach(problems.prefix(40), id: \.1.id) { run, test in
                            ProblemCard(test: test, area: model.suite(run.suiteID)?.title ?? run.title)
                        }
                        if problems.count > 40 {
                            Text("And \(problems.count - 40) more. Pick a device on the left to see all of its problems; the report lists every one.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The big statement at the top: ready, testing, passed, or problems.
struct Hero: View {
    @EnvironmentObject var model: Model
    let runs: [SuiteRun]
    let problemCount: Int

    var body: some View {
        let cases = runs.flatMap(\.cases)
        let stuck = runs.filter(model.couldNotRun)
        let stopped = runs.contains { $0.state == .stopped }
        Card {
            if model.running {
                running(cases)
            } else if runs.isEmpty {
                statement("play.circle.fill", .accentColor, "Ready when you are",
                          "Tick what you want to test on the left, then press Start Testing. Not sure? Press Quick check, then Start Testing.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if problemCount > 0 {
                        statement("xmark.octagon.fill", .red,
                                  problemCount == 1 ? "1 problem found" : "\(problemCount) problems found",
                                  tally(cases) + (stuck.isEmpty ? "" : " \(names(stuck)) couldn't run at all."))
                    } else if !stuck.isEmpty {
                        statement("exclamationmark.triangle.fill", .orange, "Some testing couldn't run",
                                  "\(names(stuck)) didn't get as far as checking anything. That is usually a set-up hiccup, not a fault in the app. " + tally(cases))
                    } else if stopped {
                        statement("stop.circle.fill", .orange, "Stopped early", tally(cases))
                    } else {
                        statement("checkmark.seal.fill", .green, "Everything passed", tally(cases))
                    }
                    if let date = model.resultsFromDisk {
                        Text("These are the results of the last run, \(date.formatted(.relative(presentation: .named))).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let report = model.reportURL {
                        Divider()
                        ReportActions(report: report, needsAttention: problemCount > 0 || !stuck.isEmpty)
                    }
                }
            }
        }
    }

    private func statement(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(detail).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func names(_ runs: [SuiteRun]) -> String {
        ListFormatter.localizedString(byJoining: runs.map { model.suite($0.suiteID)?.title ?? $0.title })
    }

    private func tally(_ cases: [CaseResult]) -> String {
        let passed = cases.filter { $0.outcome == .passed }.count
        let skipped = cases.filter { $0.outcome == .skipped }.count
        var text = "\(passed) check\(passed == 1 ? "" : "s") passed"
        if skipped > 0 { text += ", \(skipped) skipped" }
        if let start = model.sessionStart, let end = model.sessionEnd {
            text += ", in \(Report.time(end.timeIntervalSince(start)))"
        }
        return text + "."
    }

    @ViewBuilder
    private func running(_ cases: [CaseResult]) -> some View {
        let current = model.currentID.flatMap { model.runs[$0] }
        let position = (model.currentID.flatMap { model.session.firstIndex(of: $0) } ?? 0) + 1
        let failed = cases.filter { $0.outcome == .failed }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                ProgressView().controlSize(.large).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.map { "Testing \(model.suite($0.suiteID)?.title ?? $0.title)" } ?? "Writing the report").font(.largeTitle.weight(.bold))
                    Text("Part \(position) of \(model.session.count). You can keep using your Mac"
                         + (model.session.contains("mac") ? ", except during the Mac part, which takes over the screen." : "."))
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let start = model.sessionStart {
                    Text(start, style: .timer).font(.title2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ProgressView().progressViewStyle(.linear)
            HStack(spacing: 14) {
                Text(cases.isEmpty ? "Getting the app ready. The first results take a few minutes."
                     : "\(cases.count) check\(cases.count == 1 ? "" : "s") done")
                if failed > 0 {
                    Text("\(failed) problem\(failed == 1 ? "" : "s") so far").foregroundStyle(.red)
                }
                Spacer()
                if let now = current?.currentTest { Text("Now: \(Self.plain(now, model: model))").lineLimit(1).truncationMode(.tail) }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// "iPhone-small · PhoneSettingsTests.testThemeSticks" → "iPhone SE: Theme sticks".
    static func plain(_ current: String, model: Model) -> String {
        let parts = current.components(separatedBy: " · ")
        guard parts.count == 2 else { return current }
        let test = parts[1].components(separatedBy: ".").last ?? parts[1]
        return "\(model.runName(parts[0])): \(Plain.test(test))"
    }
}

/// The report: the thing to hand to Claude.
struct ReportActions: View {
    let report: URL
    let needsAttention: Bool
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(needsAttention ? "Next: give the report to Claude" : "The report is saved").font(.headline)
                Text(needsAttention
                     ? "Press Copy, then paste into a chat with Claude and ask it to take a look. The report has everything it needs: what ran, what went wrong and where the screenshots are."
                     : "Nothing needs fixing. You can still copy the report if you want Claude to see the results.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if needsAttention {
                copyButton.buttonStyle(.borderedProminent)
            } else {
                copyButton
            }
            Menu {
                Button("Save a Copy…") { save() }
                Button("Show the Report in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
                Button("Open the Report") { NSWorkspace.shared.open(report) }
                Button("Copy Where the Report Is Saved") { put(report.path) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More things to do with the report")
        }
    }

    private var copyButton: some View {
        Button {
            guard let text = try? String(contentsOf: report, encoding: .utf8) else { return }
            put(text)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy Report for Claude", systemImage: copied ? "checkmark" : "doc.on.clipboard")
        }
        .controlSize(.large)
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Aquarium test report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: report, to: url)
        }
    }
}

struct HowItWorks: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("How this works").font(.headline)
                step("1.circle.fill", "Choose what to test",
                     "Each item on the left is a device or a part of the app. Click one to read what it checks. \"Quick check\" ticks the fast ones for you.")
                step("2.circle.fill", "Press Start Testing",
                     "The Mac builds the app and tries it out on practice devices by itself. Most of it happens in the background; you can watch results arrive here.")
                step("3.circle.fill", "Give the report to Claude",
                     "When it finishes you'll see either \"Everything passed\" or a list of problems, with a button that copies a full report to paste into a chat with Claude.")
            }
        }
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One tested area on the summary: its result in a sentence.
struct AreaRow: View {
    @EnvironmentObject var model: Model
    let run: SuiteRun

    var body: some View {
        let suite = model.suite(run.suiteID)
        Button { model.selection = run.suiteID } label: {
            HStack(spacing: 12) {
                IconTile(symbol: suite?.icon ?? "checkmark.seal", tint: .named(suite?.tint), size: 30)
                Text(suite?.title ?? run.title).fontWeight(.medium)
                Spacer()
                Text(sentence).foregroundStyle(colour)
                if run.state == .running { ProgressView().controlSize(.small) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See the details")
    }

    private var sentence: String {
        let failed = run.count(.failed), passed = run.count(.passed)
        switch run.state {
        case .queued: return "Waiting its turn"
        case .running: return passed + failed == 0 ? "Getting ready" : "\(passed + failed) done so far"
        case .stopped: return "Stopped early"
        case .passed: return "All \(passed) passed · \(Report.time(run.seconds))"
        case .failed:
            if model.couldNotRun(run) { return "Couldn't run" }
            return "\(failed) problem\(failed == 1 ? "" : "s"), \(passed) passed · \(Report.time(run.seconds))"
        }
    }

    private var colour: Color {
        switch run.state {
        case .passed: return .green
        case .failed: return model.couldNotRun(run) ? .orange : .red
        case .stopped: return .orange
        default: return .secondary
        }
    }
}

/// One failed check, said plainly, with the technical part folded away.
struct ProblemCard: View {
    @EnvironmentObject var model: Model
    let test: CaseResult
    var area: String?
    @State private var open = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Plain.test(test.name)).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(([area, model.runName(test.run), Plain.group(test.group)].compactMap { $0 })
                            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                            .joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !test.messages.isEmpty {
                    Text("What the check reported:").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(test.messages, id: \.self) { message in
                    Text(message).font(.callout).textSelection(.enabled)
                        .lineLimit(open ? nil : 3).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let picture = test.attachments.first(where: { ["png", "jpg", "jpeg", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }) {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: picture)) } label: {
                            Label("See the Screen When It Failed", systemImage: "photo")
                        }
                    }
                    Button(open ? "Hide Technical Details" : "Technical Details") { open.toggle() }
                }
                .controlSize(.small)
                if open {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(test.run) · \(test.group)/\(test.name) · \(Report.time(test.seconds))")
                        if let excerpt = test.logExcerpt { Text(excerpt) }
                    }
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
