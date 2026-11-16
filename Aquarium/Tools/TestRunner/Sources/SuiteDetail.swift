import AppKit
import SwiftUI

/// One device or part of the app: what it checks, its choices, its results.
struct SuiteDetail: View {
    @EnvironmentObject var model: Model
    let suite: Suite
    @State private var pane = Pane.all
    @State private var search = ""
    @State private var picking = false
    @State private var advanced = false

    enum Pane: Hashable { case problems, all, log }

    var body: some View {
        let run = model.runs[suite.id]
        let unavailable = !model.canRun(suite)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header(unavailable)
                if let off = suite.off {
                    Callout(symbol: "nosign", tint: .gray, text: off)
                } else if unavailable {
                    Callout(symbol: "wrench.and.screwdriver.fill", tint: .orange,
                            text: "This can't run on this Mac yet: it needs a developer tool called \(suite.requires ?? "") that isn't installed. Ask Claude to set it up if you want these checks here.")
                } else if let note = suite.note {
                    Callout(symbol: "hand.raised.fill", tint: .orange, text: note)
                }
                if suite.off == nil, !(suite.options ?? []).isEmpty || !(model.groups[suite.id] ?? []).isEmpty { choices }
                if let run { results(run) }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { pane = (run?.count(.failed) ?? 0) > 0 ? .problems : .all }
    }

    // MARK: What it is

    private func header(_ unavailable: Bool) -> some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                IconTile(symbol: suite.icon ?? "checkmark.seal", tint: .named(suite.tint), size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(suite.title).font(.largeTitle.weight(.bold))
                    Text(suite.detail).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(facts).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { model.run([suite.id]) } label: { Label("Test Just This", systemImage: "play.fill") }
                    .controlSize(.large)
                    .disabled(model.running || unavailable)
                    .help(suite.off != nil ? "Turned off for now" : "Start testing \(suite.title) now, on its own")
            }
        }
    }

    private var facts: String {
        var parts: [String] = []
        let count = model.testCount(suite.id)
        if count > 0 { parts.append(count == 1 ? "1 check" : "\(count) checks") }
        if let time = model.lastTime(suite.id) { parts.append("took \(time) last time") }
        return parts.joined(separator: " · ")
    }

    // MARK: Choices

    private var choices: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                if !(suite.options ?? []).isEmpty { Text("Choices").font(.headline) }
                ForEach(suite.options ?? []) { option in
                    VStack(alignment: .leading, spacing: 3) {
                        if let choices = option.choices {
                            Picker(option.title, selection: value(option.id)) {
                                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
                            }
                            .fixedSize()
                        } else {
                            Toggle(option.title, isOn: Binding(
                                get: { value(option.id).wrappedValue == "on" },
                                set: { value(option.id).wrappedValue = $0 ? "on" : "" }))
                        }
                        if let help = option.help {
                            Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                DisclosureGroup("For the technically minded", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        let groups = model.groups[suite.id] ?? []
                        if !groups.isEmpty {
                            let picked = model.only[suite.id]?.count ?? 0
                            HStack {
                                Button(picked == 0 ? "Run Only Some Checks…" : "Running \(picked) of \(groups.count) Groups…") { picking = true }
                                    .popover(isPresented: $picking, arrowEdge: .bottom) { GroupPicker(suite: suite) }
                                Text(picked == 0 ? "Everything runs unless you pick groups here." : "Only the groups you picked will run.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Text("The command this runs:").font(.callout).foregroundStyle(.secondary)
                        Text(model.arguments(for: suite).joined(separator: " "))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.secondary)
            }
            .disabled(model.running)
        }
    }

    private func value(_ option: String) -> Binding<String> {
        Binding(get: { model.optionValues[suite.id]?[option] ?? "" },
                set: { model.optionValues[suite.id, default: [:]][option] = $0 })
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ run: SuiteRun) -> some View {
        let failed = run.cases.filter { $0.outcome == .failed }
        HStack(alignment: .firstTextBaseline) {
            Text("Results").font(.title3.weight(.semibold))
            Text(summary(run)).foregroundStyle(.secondary)
            Spacer()
            if let dir = run.resultDir {
                Button("Show the Files") { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
                    .controlSize(.small)
                    .help("Open the folder with this run's logs, screenshots and result files")
            }
        }
        .padding(.top, 6)

        ForEach(model.plainNotes(run), id: \.self) {
            Callout(symbol: "info.circle.fill", tint: .orange, text: $0)
        }
        if model.couldNotRun(run) {
            Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                    text: "This didn't get as far as checking anything. That is usually a set-up hiccup (the app didn't build, a practice device didn't start, or Aquarium was open), not a fault in the app. The report has the technical reason for Claude.")
        }

        Picker("", selection: $pane) {
            Text(failed.isEmpty ? "Problems" : "Problems (\(failed.count))").tag(Pane.problems)
            Text("All Checks (\(run.cases.count))").tag(Pane.all)
            Text("Technical Log").tag(Pane.log)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()

        switch pane {
        case .problems:
            if failed.isEmpty {
                Text(run.state == .running || run.state == .queued ? "None so far." : "No problems here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(failed) { ProblemCard(test: $0) }
        case .all:
            allChecks(run)
        case .log:
            if !run.buildErrors.isEmpty {
                Text(run.buildErrors.joined(separator: "\n"))
                    .font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
            }
            Text("Everything the tools printed while this ran. Useful to Claude or a developer; safe to ignore otherwise.")
                .font(.callout).foregroundStyle(.secondary)
            ConsoleView(text: run.console)
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func summary(_ run: SuiteRun) -> String {
        switch run.state {
        case .queued: return "Waiting its turn"
        case .running: return run.currentTest.map { "Now: \(Hero.plain($0, model: model))" } ?? "Getting ready"
        default:
            var parts = ["\(run.count(.passed)) passed"]
            if run.count(.failed) > 0 { parts.append("\(run.count(.failed)) with a problem") }
            if run.count(.skipped) > 0 { parts.append("\(run.count(.skipped)) skipped") }
            return parts.joined(separator: ", ") + " · \(Report.time(run.seconds))"
        }
    }

    @ViewBuilder
    private func allChecks(_ run: SuiteRun) -> some View {
        let shown = run.cases.filter {
            search.isEmpty || "\(Plain.group($0.group)) \(Plain.test($0.name)) \($0.name)".localizedCaseInsensitiveContains(search)
        }
        let labels = shown.map(\.run).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        TextField("Search the checks", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
        if run.cases.isEmpty {
            Text(run.state == .running || run.state == .queued
                 ? "Getting the app ready. Checks appear here one by one as they finish."
                 : "No checks ran.")
                .foregroundStyle(.secondary)
        }
        ForEach(labels, id: \.self) { label in
            let tests = shown.filter { $0.run == label }
                .sorted { ($0.outcome == .failed ? 0 : 1, $0.group, $0.name) < ($1.outcome == .failed ? 0 : 1, $1.group, $1.name) }
            Card {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("\(model.runName(label)) · \(tests.count) check\(tests.count == 1 ? "" : "s")").font(.headline).padding(.bottom, 8)
                    ForEach(Array(tests.enumerated()), id: \.element.id) { index, test in
                        if index > 0 { Divider() }
                        CheckRow(test: test)
                    }
                }
            }
        }
    }
}

struct CheckRow: View {
    let test: CaseResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(Plain.test(test.name)).fixedSize(horizontal: false, vertical: true)
                Text(caption).font(.caption).foregroundStyle(test.outcome == .failed ? .red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(Report.time(test.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .help("\(test.group)/\(test.name)")
    }

    private var caption: String {
        let group = Plain.group(test.group)
        switch test.outcome {
        case .skipped:
            let why = (test.messages.first ?? "").replacingOccurrences(of: "Test skipped - ", with: "")
            return why.isEmpty ? "\(group) · skipped" : "\(group) · skipped: \(why)"
        case .failed: return "\(group) · \(test.messages.first ?? "did not go as expected")"
        case .expectedFailure: return "\(group) · a known problem, still there"
        case .passed: return group
        }
    }

    @ViewBuilder private var icon: some View {
        switch test.outcome {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .expectedFailure: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}

/// Narrows a run to some groups of checks (test classes or files).
struct GroupPicker: View {
    @EnvironmentObject var model: Model
    let suite: Suite
    @State private var search = ""

    var body: some View {
        let groups = (model.groups[suite.id] ?? []).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || Plain.group($0.name).localizedCaseInsensitiveContains(search)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Button("Clear") { model.only[suite.id] = [] }
                    .disabled((model.only[suite.id] ?? []).isEmpty)
            }
            Text("Tick nothing to run everything.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { group in
                        Toggle(isOn: Binding(
                            get: { model.only[suite.id]?.contains(group.id) ?? false },
                            set: { on in
                                if on { model.only[suite.id, default: []].insert(group.id) } else { model.only[suite.id]?.remove(group.id) }
                            })) {
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(Plain.group(group.name))
                                    Text(group.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(group.tests)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
        .frame(width: 380, height: 420)
    }
}

/// The command's own output, kept scrolled to the end.
struct ConsoleView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 10, height: 10)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToEndOfDocument(nil)
    }
}
