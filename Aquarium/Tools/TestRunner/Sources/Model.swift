import Foundation
import SwiftUI

@MainActor
final class Model: ObservableObject {
    @Published var root: URL?
    @Published var catalogue: Catalogue?
    @Published var loadError: String?
    @Published var groups: [String: [TestGroup]] = [:]
    @Published var checked: Set<String> = []
    @Published var selection: String?
    /// suite → option → value (`on` for a switch that is on).
    @Published var optionValues: [String: [String: String]] = [:]
    /// suite → the classes or files a run is narrowed to (empty: everything).
    @Published var only: [String: Set<String>] = [:]
    @Published var runs: [String: SuiteRun] = [:]
    /// The suites of the latest run, in the order they ran.
    @Published var session: [String] = []
    @Published var running = false
    @Published var currentID: String?
    @Published var sessionStart: Date?
    @Published var sessionEnd: Date?
    @Published var reportURL: URL?
    /// Set when the results on show were read from the last report, not run just now.
    @Published var resultsFromDisk: Date?
    /// How long each suite took last time, to give an idea before a run.
    @Published var lastSeconds: [String: Double] = UserDefaults.standard.dictionary(forKey: "lastSeconds") as? [String: Double] ?? [:]
    @Published var qaUp: Bool?
    /// Starting or stopping the QA server.
    @Published var qaBusy = false
    @Published var missingTools: Set<String> = []

    static let shared = Model()

    private var process: Process?
    private var stopRequested = false
    private var offsets: [String: Int] = [:]

    static let catalogueFile = "Aquarium/Tools/TestRunner/suites.json"

    init() {
        root = Self.findRoot()
        reload()
        selection = nil
        loadLastReport()
    }

    // MARK: Catalogue

    static func findRoot() -> URL? {
        var candidates: [URL] = []
        if let saved = UserDefaults.standard.string(forKey: "repoRoot") { candidates.append(URL(fileURLWithPath: saved)) }
        if let env = ProcessInfo.processInfo.environment["AQUARIUM_REPO"] { candidates.append(URL(fileURLWithPath: env)) }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "AquariumRepoRoot") as? String {
            candidates.append(URL(fileURLWithPath: baked))
        }
        for start in [Bundle.main.bundleURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            var folder = start
            for _ in 0..<8 { candidates.append(folder); folder = folder.deletingLastPathComponent() }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(catalogueFile).path) }
    }

    func chooseRoot(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(Self.catalogueFile).path) else {
            loadError = "That folder has no \(Self.catalogueFile)."
            return
        }
        UserDefaults.standard.set(url.path, forKey: "repoRoot")
        root = url
        reload()
    }

    /// Reads `suites.json` and scans the test folders again, so tests added
    /// since the app opened are counted and can be picked.
    func reload() {
        guard let root else { loadError = "The repository was not found."; return }
        do {
            let data = try Data(contentsOf: root.appendingPathComponent(Self.catalogueFile))
            let loaded = try JSONDecoder().decode(Catalogue.self, from: data)
            catalogue = loaded
            loadError = nil
            groups = Dictionary(uniqueKeysWithValues: loaded.suites.map { ($0.id, Discovery.groups(for: $0, root: root)) })
            if !loaded.suites.contains(where: { $0.id == selection }) { selection = nil }
            for (id, picked) in only { only[id] = picked.intersection(Set((groups[id] ?? []).map(\.id))) }
        } catch {
            loadError = "suites.json could not be read: \(error)"
        }
        Task { await checkEnvironment() }
    }

    func checkEnvironment() async {
        guard let catalogue else { return }
        var missing = Set<String>()
        for tool in Set(catalogue.suites.compactMap(\.requires)) {
            if await Shell.run(["/usr/bin/which", tool]).code != 0 { missing.insert(tool) }
        }
        missingTools = missing
        await checkServer()
    }

    func checkServer() async {
        guard let catalogue else { return }
        if let server = catalogue.qaServer, let url = URL(string: server + "/System/Info/Public") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let response = try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse
            qaUp = response?.statusCode == 200
        }
    }

    // MARK: The QA server

    /// Starts the QA server's launch agents (they also start it at login) and
    /// waits until it answers.
    func startServer() async {
        await serverAgents { domain, label in
            let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
            _ = await Shell.run(["/bin/launchctl", "bootstrap", domain, plist])   // already loaded: an error, and fine
            _ = await Shell.run(["/bin/launchctl", "kickstart", "\(domain)/\(label)"])
        }
        for _ in 0..<45 where qaUp != true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await checkServer()
        }
    }

    /// Stops them until Start is pressed or the next login.
    func stopServer() async {
        await serverAgents { domain, label in
            _ = await Shell.run(["/bin/launchctl", "bootout", "\(domain)/\(label)"])
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await checkServer()
    }

    private func serverAgents(_ each: (String, String) async -> Void) async {
        guard !qaBusy, let agents = catalogue?.qaAgents else { return }
        qaBusy = true
        for label in agents { await each("gui/\(getuid())", label) }
        qaBusy = false
    }

    /// Shows the last run's results when the app opens, so the report is there to copy.
    func loadLastReport() {
        guard let root, let catalogue else { return }
        let folder = root.appendingPathComponent(catalogue.resultsDir)
        let json = ProcessInfo.processInfo.environment["AQUARIUM_REPORT"].map { URL(fileURLWithPath: $0) }
            ?? folder.appendingPathComponent("latest-report.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: json), let file = try? decoder.decode(Report.File.self, from: data) else { return }
        let known = file.suites.filter { suite($0.suiteID) != nil }
        guard !known.isEmpty else { return }
        runs = Dictionary(uniqueKeysWithValues: known.map { ($0.suiteID, $0) })
        session = known.map(\.suiteID)
        sessionEnd = file.generated
        sessionStart = file.generated.addingTimeInterval(-file.seconds)
        resultsFromDisk = file.generated
        let text = json.deletingPathExtension().appendingPathExtension("md")
        reportURL = FileManager.default.fileExists(atPath: text.path) ? text : nil
    }

    func runName(_ label: String) -> String { catalogue?.runNames?[label] ?? label }

    var suites: [Suite] { catalogue?.suites ?? [] }
    func suite(_ id: String?) -> Suite? { suites.first { $0.id == id } }
    func testCount(_ id: String) -> Int { (groups[id] ?? []).reduce(0) { $0 + $1.tests } }

    /// The command a suite runs with the options and classes picked now.
    func arguments(for suite: Suite) -> [String] {
        var args = suite.command
        for option in suite.options ?? [] {
            let value = optionValues[suite.id]?[option.id] ?? ""
            if option.choices == nil {
                if value == "on" { args.append(option.flag) }
            } else if !value.isEmpty {
                args += [option.flag, value]
            }
        }
        let picked = (groups[suite.id] ?? []).map(\.id).filter { only[suite.id]?.contains($0) ?? false }
        switch suite.kind {
        case .xcode: for token in picked { args += ["--only", token] }
        case .vitest: args += picked.isEmpty ? (suite.paths ?? []) : picked
        case .cargo: break
        }
        return args
    }

    // MARK: Running

    func run(_ ids: [String]) {
        guard !running, !ids.isEmpty, root != nil else { return }
        running = true
        stopRequested = false
        reportURL = nil
        resultsFromDisk = nil
        runs = [:]
        session = ids
        sessionStart = Date()
        sessionEnd = nil
        for id in ids {
            guard let suite = suite(id) else { continue }
            runs[id] = SuiteRun(suiteID: id, title: suite.title,
                                commandLine: arguments(for: suite).joined(separator: " "))
        }
        Task {
            for id in ids {
                guard let suite = suite(id) else { continue }
                if stopRequested { runs[id]?.state = .stopped; continue }
                currentID = id
                await runSuite(suite)
            }
            currentID = nil
            sessionEnd = Date()
            reportURL = await Report.write(self)
            running = false
        }
    }

    func stop() {
        stopRequested = true
        if let process, process.isRunning { Shell.terminateTree(process.processIdentifier) }
    }

    private func runSuite(_ suite: Suite) async {
        guard let root, let catalogue else { return }
        let id = suite.id
        let started = Date()
        runs[id]?.started = started
        runs[id]?.state = .running

        if let tool = suite.requires, missingTools.contains(tool) {
            runs[id]?.notes = ["Not run: `\(tool)` is not installed on this Mac."]
            runs[id]?.state = .failed
            runs[id]?.finished = Date()
            return
        }

        let resultsRoot = root.appendingPathComponent(catalogue.resultsDir)
        try? FileManager.default.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
        var args = arguments(for: suite)
        var ownDir: URL?
        if suite.kind == .xcode {
            args += ["--results", resultsRoot.path]
        } else {
            let stamp = Report.stamp(started)
            let dir = resultsRoot.appendingPathComponent("\(stamp)-\(id)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ownDir = dir
            if suite.kind == .vitest {
                args += ["--reporter=default", "--reporter=json", "--outputFile.json=\(dir.path)/vitest.json"]
            }
        }

        let process = Shell.make(args, cwd: root.appendingPathComponent(suite.cwd))
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.appendConsole(text, to: id) } }
        }
        self.process = process
        offsets = [:]

        let scriptSuite = suite.command.count > 1 ? suite.command[1] : id
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if suite.kind == .xcode, let dir = Self.liveDir(in: resultsRoot, suite: scriptSuite, since: started) {
                    self.readLogs(in: dir, suiteID: id)
                }
            }
        }
        let code: Int32 = await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                done.resume(returning: 127)
            }
        }
        watcher.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)   // the last of the output
        pipe.fileHandleForReading.readabilityHandler = nil
        self.process = nil

        let console = runs[id]?.console ?? ""
        var dir = ownDir
        switch suite.kind {
        case .xcode:
            let printed = matches(#"(?m)^results: (.+)$"#, in: console).last.map { URL(fileURLWithPath: $0[1]) }
            dir = printed ?? Self.liveDir(in: resultsRoot, suite: scriptSuite, since: started)
            if let dir { await finishXcode(id, dir: dir) }
        case .vitest:
            if let dir { runs[id]?.cases = Vitest.cases(in: dir.appendingPathComponent("vitest.json"),
                                                        cwd: root.appendingPathComponent(suite.cwd)) }
        case .cargo:
            runs[id]?.cases = Cargo.cases(in: console)
        }
        if let dir {
            try? console.write(to: dir.appendingPathComponent("console.log"), atomically: true, encoding: .utf8)
            runs[id]?.resultDir = dir.path
        }
        if (runs[id]?.cases.isEmpty ?? true) && code != 0 && (runs[id]?.buildErrors.isEmpty ?? true) {
            runs[id]?.buildErrors = console.components(separatedBy: "\n").suffix(25).filter { !$0.isEmpty }
        }
        runs[id]?.exitCode = code
        runs[id]?.finished = Date()
        // Only a whole, successful run says how long the suite takes.
        if !stopRequested, code == 0, (only[id] ?? []).isEmpty, let took = runs[id]?.seconds {
            lastSeconds[id] = took
            UserDefaults.standard.set(lastSeconds, forKey: "lastSeconds")
        }
        runs[id]?.currentTest = nil
        let failed = code != 0 || (runs[id]?.count(.failed) ?? 0) > 0
        runs[id]?.state = stopRequested ? .stopped : failed ? .failed : .passed
    }

    private func appendConsole(_ text: String, to id: String) {
        guard var run = runs[id] else { return }
        run.console += text
        if run.console.count > 600_000 { run.console = String(run.console.suffix(400_000)) }
        runs[id] = run
    }

    /// The folder the script made for this run: `<stamp>-<suite>`, newer than the start.
    private static func liveDir(in resultsRoot: URL, suite: String, since: Date) -> URL? {
        let keys: [URLResourceKey] = [.creationDateKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: resultsRoot, includingPropertiesForKeys: keys)) ?? []
        return folders
            .filter { $0.lastPathComponent.hasSuffix("-\(suite)") }
            .compactMap { url -> (URL, Date)? in
                guard let made = try? url.resourceValues(forKeys: Set(keys)).creationDate,
                      made >= since.addingTimeInterval(-2) else { return nil }
                return (url, made)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private static func logs(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" && !$0.lastPathComponent.hasPrefix("reset-") && $0.lastPathComponent != "console.log" }
            .sorted { $0.path < $1.path }
    }

    /// Follows xcodebuild's logs while it runs, so tests tick over live.
    private func readLogs(in dir: URL, suiteID id: String) {
        guard var run = runs[id] else { return }
        for log in Self.logs(in: dir) {
            let label = log.deletingPathExtension().lastPathComponent
            guard let handle = try? FileHandle(forReadingFrom: log) else { continue }
            try? handle.seek(toOffset: UInt64(offsets[log.path] ?? 0))
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            guard let end = data.lastIndex(of: 10) else { continue }
            let chunk = data[data.startIndex..<end]
            offsets[log.path, default: 0] += chunk.count + 1
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                let line = String(line)
                if let result = XcodeLog.finished(line, run: label) {
                    run.cases.removeAll { $0.id == result.id }
                    run.cases.append(result)
                } else if let test = XcodeLog.started(line) {
                    run.currentTest = "\(label) · \(test)"
                }
            }
        }
        runs[id] = run
    }

    /// Replaces the live tallies with what the result bundles say, and gathers
    /// what a failure needs: its messages, its log, its screenshots.
    private func finishXcode(_ id: String, dir: URL) async {
        readLogs(in: dir, suiteID: id)
        var cases = runs[id]?.cases ?? []
        var buildErrors: [String] = []
        for log in Self.logs(in: dir) {
            let label = log.deletingPathExtension().lastPathComponent
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let bundle = dir.appendingPathComponent("\(label).xcresult")
            var final = FileManager.default.fileExists(atPath: bundle.path) ? await XCResult.cases(in: bundle, run: label) : []
            if final.contains(where: { $0.outcome == .failed }) {
                let files = await XCResult.failureAttachments(in: bundle, to: dir.appendingPathComponent("attachments/\(label)"))
                for index in final.indices where final[index].outcome == .failed {
                    final[index].attachments = files["\(final[index].group)/\(final[index].name)"] ?? []
                    final[index].logExcerpt = XcodeLog.excerpt(for: final[index], in: text)
                }
            }
            if !final.isEmpty {
                cases.removeAll { $0.run == label }
                cases += final
            }
            if !cases.contains(where: { $0.run == label && $0.outcome != .failed }) {
                buildErrors += XcodeLog.errors(in: text).map { "\(label): \($0)" }
            }
        }
        runs[id]?.cases = cases
        runs[id]?.buildErrors = buildErrors
        if let summary = try? String(contentsOf: dir.appendingPathComponent("summary.txt"), encoding: .utf8) {
            runs[id]?.notes = summary.split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
        }
    }
}
