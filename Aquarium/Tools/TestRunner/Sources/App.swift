import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TestRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model.shared

    var body: some Scene {
        Window("Aquarium Tests", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)
                .task {
                    // Keep the server's light honest while the window is open.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        if !model.qaBusy { await model.checkServer() }
                    }
                }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Start Testing") { model.run(model.suites.map(\.id).filter(model.checked.contains)) }
                    .keyboardShortcut("r")
                    .disabled(model.running || model.checked.isEmpty)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.running)
                Button("Refresh the List of Checks") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.running)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run straight from `swift run` there is no bundle, so ask for a Dock icon and a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        runFromArguments()
    }

    /// `--run unit,ipad` (or `--run all`) starts those suites at once and quits
    /// when the report is written, printing its path: the same run and report
    /// as the buttons, for a script or for Claude.
    private func runFromArguments() {
        let arguments = CommandLine.arguments
        // `--server start|stop` does what the window's button does, then quits.
        if let flag = arguments.firstIndex(of: "--server"), arguments.count > flag + 1 {
            Task { @MainActor in
                let model = Model.shared
                if arguments[flag + 1] == "stop" { await model.stopServer() } else { await model.startServer() }
                print("QA server is \(model.qaUp == true ? "up" : "down")")
                exit(0)
            }
            return
        }
        let model = Model.shared
        // `--show <suite>` opens on that suite's page instead of the summary.
        let shown = arguments.firstIndex(of: "--show").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        if arguments.contains("--snapshot") { NSApp.appearance = NSAppearance(named: .aqua) }
        guard let flag = arguments.firstIndex(of: "--run"), arguments.count > flag + 1 else {
            // `--snapshot file.png` alone: a picture of the window as it opens, then quit.
            if let shot = arguments.firstIndex(of: "--snapshot"), arguments.count > shot + 1 {
                Task { @MainActor in
                    await model.checkEnvironment()
                    model.selection = shown
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    Self.snapshot(to: arguments[shot + 1])
                    exit(0)
                }
            }
            return
        }
        let wanted = arguments[flag + 1] == "all" ? model.suites.map(\.id) : arguments[flag + 1].components(separatedBy: ",")
        let ids = wanted.filter { model.suite($0) != nil }
        guard !ids.isEmpty else { print("no such suite: \(arguments[flag + 1])"); exit(2) }
        // `--only Target/Class,…` narrows every suite named to those classes or files.
        if let only = arguments.firstIndex(of: "--only"), arguments.count > only + 1 {
            for id in ids { model.only[id] = Set(arguments[only + 1].components(separatedBy: ",")) }
        }
        Task { @MainActor in
            await model.checkEnvironment()
            model.selection = shown
            model.run(ids)
            while model.running { try? await Task.sleep(nanoseconds: 500_000_000) }
            // `--snapshot file.png` saves a picture of the window as the run ends.
            if let shot = arguments.firstIndex(of: "--snapshot"), arguments.count > shot + 1 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                Self.snapshot(to: arguments[shot + 1])
            }
            print("report: \(model.reportURL?.path ?? "none")")
            exit(ids.allSatisfy { model.runs[$0]?.state == .passed } ? 0 : 1)
        }
    }

    private static func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        if model.catalogue == nil {
            MissingRepository()
        } else {
            HStack(spacing: 0) {
                ChoicePanel().frame(width: 340)
                Divider()
                Group {
                    if let suite = model.suite(model.selection) {
                        SuiteDetail(suite: suite).id(suite.id)
                    } else {
                        Overview()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}

struct MissingRepository: View {
    @EnvironmentObject var model: Model
    @State private var picking = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Where is the Aquarium project?").font(.title2.weight(.semibold))
            Text(model.loadError ?? "Choose the FellyJin folder so the checks can be found.")
                .foregroundStyle(.secondary)
            Button("Choose the Project Folder…") { picking = true }.controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.chooseRoot(url) }
        }
    }
}

// MARK: Shared pieces

extension Color {
    static func named(_ name: String?) -> Color {
        switch name {
        case "blue": return .blue
        case "teal": return .teal
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        case "indigo": return .indigo
        case "red": return .red
        default: return .accentColor
        }
    }
}

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// A coloured note: something to know before or after a run.
struct Callout: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold))
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension Model {
    /// "about 12 min", from how long the suite took last time.
    func lastTime(_ id: String) -> String? {
        guard let seconds = lastSeconds[id] else { return nil }
        return seconds < 90 ? "about a minute" : "about \(Int((seconds / 60).rounded())) min"
    }

    /// Lines the run script printed that say something went differently
    /// (refused, skipped, could not run), without its routine tallies.
    func plainNotes(_ run: SuiteRun) -> [String] {
        run.notes.filter { !$0.contains("exit 0") && !$0.contains("TEST FAILED") }
    }

    /// A suite that ended badly without a single failed check: it never got going.
    func couldNotRun(_ run: SuiteRun) -> Bool {
        run.state == .failed && run.count(.failed) == 0
    }

    func startTicked() { run(suites.map(\.id).filter(checked.contains)) }
}

// MARK: Left: what to test

struct ChoicePanel: View {
    @EnvironmentObject var model: Model
    @State private var confirmingStop = false

    var body: some View {
        let grouped = Dictionary(grouping: model.suites, by: \.group)
        let order = model.suites.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Button { model.selection = nil } label: {
                        HStack(spacing: 10) {
                            IconTile(symbol: "list.bullet.clipboard.fill", tint: .gray)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Summary").fontWeight(.medium)
                                Text("Results and the report for Claude").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(model.selection == nil ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    HStack(alignment: .firstTextBaseline) {
                        Text("What do you want to test?").font(.headline)
                        Spacer()
                        Button("Untick All") { model.checked = [] }
                            .buttonStyle(.link).font(.caption)
                            .disabled(model.checked.isEmpty || model.running)
                    }
                    .padding(.top, 14).padding(.horizontal, 8)
                    Text("Tick one or more, or use a quick pick.").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                    HStack(spacing: 8) {
                        ForEach(model.catalogue?.presets ?? [], id: \.self) { preset in
                            Button { model.checked = Set(preset.suites) } label: {
                                Label(preset.title, systemImage: preset.icon).frame(maxWidth: .infinity)
                            }
                            .help(preset.detail)
                        }
                    }
                    .disabled(model.running)
                    .padding(.horizontal, 8).padding(.top, 4)

                    ForEach(order, id: \.self) { group in
                        Text(group.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 14).padding(.leading, 8)
                        ForEach(grouped[group] ?? []) { SuiteCard(suite: $0) }
                    }
                }
                .padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                serverRow
                if model.running {
                    Button(role: .destructive) { model.stop() } label: {
                        Label("Stop Testing", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.extraLarge)
                } else {
                    Button { model.startTicked() } label: {
                        Label(model.checked.isEmpty ? "Tick Something to Test" : "Start Testing", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .disabled(model.checked.isEmpty)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder private var serverRow: some View {
        if let up = model.qaUp {
            HStack(spacing: 6) {
                Image(systemName: up ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(up ? .green : .orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.qaBusy ? "Test server…" : up ? "Test server is running" : "Test server is off")
                    if !up && !model.qaBusy {
                        Text("Most checks need it. Press Start.").foregroundStyle(.secondary)
                    }
                }
                .help("A practice media server on this Mac, filled with sample films and shows, that the checks sign in to.")
                Spacer()
                if model.qaBusy {
                    ProgressView().controlSize(.small)
                } else if model.catalogue?.qaAgents != nil {
                    if up {
                        if let server = model.catalogue?.qaServer, let web = URL(string: server + "/web/") {
                            Button("Open") { NSWorkspace.shared.open(web) }.help("Open the test server's web page")
                        }
                        Button("Turn Off") { confirmingStop = true }.disabled(model.running)
                            .confirmationDialog("Turn off the test server?", isPresented: $confirmingStop) {
                                Button("Turn It Off", role: .destructive) { Task { await model.stopServer() } }
                            } message: {
                                Text("Any testing that is using it, here or in a Claude session, will fail. It stays off until you press Start or log in to this Mac again.")
                            }
                    } else {
                        Button("Start") { Task { await model.startServer() } }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
    }
}

struct SuiteCard: View {
    @EnvironmentObject var model: Model
    let suite: Suite

    var body: some View {
        let ticked = model.checked.contains(suite.id)
        let unavailable = suite.requires.map(model.missingTools.contains) ?? false
        HStack(spacing: 10) {
            Button {
                if ticked { model.checked.remove(suite.id) } else { model.checked.insert(suite.id) }
            } label: {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(ticked ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(model.running || unavailable)
            .help(ticked ? "Leave this out" : "Include this")
            IconTile(symbol: suite.icon ?? "checkmark.seal", tint: unavailable ? .gray : .named(suite.tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(suite.title).fontWeight(.medium)
                Text(subtitle(unavailable)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            StateBadge(run: model.runs[suite.id], couldNotRun: model.runs[suite.id].map(model.couldNotRun) ?? false)
        }
        .padding(8)
        .background(model.selection == suite.id ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = suite.id }
        .help(suite.detail)
    }

    private func subtitle(_ unavailable: Bool) -> String {
        if unavailable { return "Can't run on this Mac" }
        let count = model.testCount(suite.id)
        let checks = count == 1 ? "1 check" : count > 0 ? "\(count) checks" : "Checks"
        return model.lastTime(suite.id).map { "\(checks) · \($0) last time" } ?? checks
    }
}

struct StateBadge: View {
    let run: SuiteRun?
    var couldNotRun = false

    var body: some View {
        if let run {
            switch run.state {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting its turn")
            case .running: ProgressView().controlSize(.small)
            case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Everything passed")
            case .failed:
                if couldNotRun {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Couldn't run")
                } else {
                    Text("\(run.count(.failed))").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .help("\(run.count(.failed)) problem(s) found")
                }
            case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(.orange).help("Stopped early")
            }
        }
    }
}
