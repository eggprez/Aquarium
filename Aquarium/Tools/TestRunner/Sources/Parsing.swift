import Foundation

/// Finds the tests a suite has, by reading its source folders.
enum Discovery {
    static func groups(for suite: Suite, root: URL) -> [TestGroup] {
        var found: [TestGroup] = []
        for source in suite.sources ?? [] {
            let folder = root.appendingPathComponent(source.path)
            let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []).sorted { $0.path < $1.path }
            for file in files {
                switch suite.kind {
                case .xcode where file.pathExtension == "swift":
                    found += swiftClasses(in: file, target: source.target ?? "")
                case .vitest where file.lastPathComponent.hasSuffix(".test.ts"):
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    let tests = matches(#"(?m)^\s*(?:it|test)(?:\.\w+)*\("#, in: text).count
                    let cwd = root.appendingPathComponent(suite.cwd).path + "/"
                    found.append(TestGroup(id: file.path.replacingOccurrences(of: cwd, with: ""),
                                           name: file.lastPathComponent, tests: tests))
                default: break
                }
            }
        }
        return found
    }

    private static func swiftClasses(in file: URL, target: String) -> [TestGroup] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var groups: [TestGroup] = []
        for line in text.split(separator: "\n") {
            if let name = matches(#"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:"#, in: String(line)).first?[1] {
                groups.append(TestGroup(id: "\(target)/\(name)", name: name, tests: 0))
            } else if !groups.isEmpty, !matches(#"^\s*func\s+test\w*\s*\("#, in: String(line)).isEmpty {
                groups[groups.count - 1].tests += 1
            }
        }
        return groups.filter { $0.tests > 0 }
    }
}

func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let whole = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: whole).map { match in
        (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

/// xcodebuild's own lines, read while a run is going.
enum XcodeLog {
    /// `Test Case '-[Target.Class method]' passed (1.234 seconds).`
    static func finished(_ line: String, run: String) -> CaseResult? {
        guard line.hasPrefix("Test Case"),
              let m = matches(#"^Test Case '-\[\S+?\.(\S+) (\S+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)"#, in: line).first
        else { return nil }
        let outcome: Outcome = m[3] == "passed" ? .passed : m[3] == "failed" ? .failed : .skipped
        return CaseResult(run: run, group: m[1], name: m[2], outcome: outcome, seconds: Double(m[4]) ?? 0)
    }

    static func started(_ line: String) -> String? {
        guard line.hasPrefix("Test Case") else { return nil }
        return matches(#"^Test Case '-\[\S+?\.(\S+) (\S+)\]' started"#, in: line).first.map { "\($0[1]).\($0[2])" }
    }

    /// What a failed test printed, from its "started" line to its "failed" line.
    static func excerpt(for test: CaseResult, in log: String) -> String? {
        let lines = log.components(separatedBy: "\n")
        let marker = ".\(test.group) \(test.name)]'"
        guard let start = lines.firstIndex(where: { $0.contains(marker) && $0.contains("started") }),
              let end = lines[start...].firstIndex(where: { $0.contains(marker) && $0.contains("' failed") })
        else { return nil }
        return lines[start...end].suffix(40).joined(separator: "\n")
    }

    /// Why a run never reached its tests.
    static func errors(in log: String) -> [String] {
        var seen = Set<String>()
        return log.components(separatedBy: "\n").filter { line in
            (line.contains("error:") || line.hasPrefix("Testing failed") || line.contains("BUILD FAILED")
                || line.contains("xcodebuild: error")) && seen.insert(line).inserted
        }.prefix(30).map { String($0.prefix(600)) }
    }
}

/// The finished result bundle: the authority on what passed.
enum XCResult {
    static func cases(in bundle: URL, run: String) async -> [CaseResult] {
        let result = await Shell.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle.path])
        guard result.code == 0, let start = result.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any]
        else { return [] }
        var cases: [CaseResult] = []
        func walk(_ node: [String: Any], suite: String) {
            let type = node["nodeType"] as? String ?? ""
            let name = node["name"] as? String ?? ""
            let children = node["children"] as? [[String: Any]] ?? []
            if type == "Test Case" {
                let outcome: Outcome
                switch node["result"] as? String {
                case "Passed": outcome = .passed
                case "Skipped": outcome = .skipped
                case "Expected Failure": outcome = .expectedFailure
                default: outcome = .failed
                }
                var messages: [String] = []
                func collect(_ nodes: [[String: Any]]) {
                    for child in nodes {
                        let kind = child["nodeType"] as? String ?? ""
                        if kind == "Failure Message" || kind == "Skip Message", let text = child["name"] as? String {
                            if !messages.contains(text) { messages.append(text) }
                        }
                        collect(child["children"] as? [[String: Any]] ?? [])
                    }
                }
                collect(children)
                cases.append(CaseResult(run: run, group: suite,
                                        name: name.replacingOccurrences(of: "()", with: ""),
                                        outcome: outcome, seconds: node["durationInSeconds"] as? Double ?? 0,
                                        messages: messages))
            } else {
                for child in children { walk(child, suite: type == "Test Suite" ? name : suite) }
            }
        }
        for node in json["testNodes"] as? [[String: Any]] ?? [] { walk(node, suite: "") }
        return cases
    }

    /// Saves the failed tests' screenshots and element trees next to the
    /// bundle; returns the files by `Class/test`.
    static func failureAttachments(in bundle: URL, to folder: URL) async -> [String: [String]] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = await Shell.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle.path,
                             "--output-path", folder.path, "--only-failures"])
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var files: [String: [String]] = [:]
        for entry in manifest {
            let test = (entry["testIdentifier"] as? String ?? "").replacingOccurrences(of: "()", with: "")
            for attachment in entry["attachments"] as? [[String: Any]] ?? [] {
                if let name = attachment["exportedFileName"] as? String {
                    files[test, default: []].append(folder.appendingPathComponent(name).path)
                }
            }
        }
        return files
    }
}

enum Vitest {
    /// vitest's JSON reporter (the Jest shape).
    static func cases(in file: URL, cwd: URL) -> [CaseResult] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var cases: [CaseResult] = []
        for testFile in json["testResults"] as? [[String: Any]] ?? [] {
            let path = (testFile["name"] as? String ?? "").replacingOccurrences(of: cwd.path + "/", with: "")
            let tests = testFile["assertionResults"] as? [[String: Any]] ?? []
            for test in tests {
                let outcome: Outcome
                switch test["status"] as? String {
                case "passed": outcome = .passed
                case "failed": outcome = .failed
                default: outcome = .skipped
                }
                cases.append(CaseResult(run: "vitest", group: path,
                                        name: test["fullName"] as? String ?? test["title"] as? String ?? "?",
                                        outcome: outcome, seconds: (test["duration"] as? Double ?? 0) / 1000,
                                        messages: (test["failureMessages"] as? [String] ?? []).map { String($0.prefix(4000)) }))
            }
            // A file that could not even be loaded has no tests, only a message.
            if tests.isEmpty, testFile["status"] as? String == "failed" {
                cases.append(CaseResult(run: "vitest", group: path, name: "(file failed to load)", outcome: .failed,
                                        seconds: 0, messages: [String((testFile["message"] as? String ?? "").prefix(4000))]))
            }
        }
        return cases
    }
}

enum Cargo {
    /// `test module::name ... ok`, and the `---- name stdout ----` blocks.
    static func cases(in output: String) -> [CaseResult] {
        var cases: [CaseResult] = []
        var details: [String: [String]] = [:]
        var current: String?
        for line in output.components(separatedBy: "\n") {
            if let m = matches(#"^test (\S+) \.\.\. (ok|FAILED|ignored)"#, in: line).first {
                let parts = m[1].components(separatedBy: "::")
                cases.append(CaseResult(run: "cargo", group: parts.dropLast().joined(separator: "::"),
                                        name: parts.last ?? m[1],
                                        outcome: m[2] == "ok" ? .passed : m[2] == "FAILED" ? .failed : .skipped,
                                        seconds: 0))
                current = nil
            } else if let m = matches(#"^---- (\S+) stdout ----"#, in: line).first {
                current = m[1]
            } else if line.hasPrefix("failures:") || line.hasPrefix("test result:") {
                current = nil
            } else if let current {
                details[current, default: []].append(line)
            }
        }
        return cases.map { test in
            var test = test
            let full = test.group.isEmpty ? test.name : "\(test.group)::\(test.name)"
            if let text = details[full] {
                test.messages = [String(text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))]
            }
            return test
        }
    }
}
