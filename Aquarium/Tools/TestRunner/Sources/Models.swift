import Foundation

/// `suites.json`, read from the repository every time the app opens or
/// Reload is pressed. Adding a suite or an option is an edit there, not here.
struct Catalogue: Decodable {
    var resultsDir: String
    var qaServer: String?
    /// The launch agents (in ~/Library/LaunchAgents) that run the QA server and its proxy.
    var qaAgents: [String]?
    /// A run's label (`iPhone-small`) in words (`iPhone SE`).
    var runNames: [String: String]?
    /// One-press choices of what to tick.
    var presets: [Preset]?

    struct Preset: Decodable, Hashable {
        var title: String
        var icon: String
        var detail: String
        var suites: [String]
    }
    var suites: [Suite]
}

struct Suite: Decodable, Identifiable, Hashable {
    var id: String
    var group: String
    var title: String
    var detail: String
    var note: String?
    /// Set to switch the suite off without deleting it: it stays in the list,
    /// greyed out, with this sentence saying why.
    var off: String?
    /// An SF Symbol and a colour name for the suite's tile.
    var icon: String?
    var tint: String?
    var kind: Kind
    /// Folder the command runs in, relative to the repository.
    var cwd: String
    var command: [String]
    /// vitest: the paths run when no file is picked.
    var paths: [String]?
    /// Folders scanned for tests, so new tests show up without an edit.
    var sources: [Source]?
    var options: [Option]?
    /// A command that has to exist (`node`, `cargo`).
    var requires: String?

    enum Kind: String, Decodable { case xcode, vitest, cargo }

    struct Source: Decodable, Hashable {
        var path: String
        /// xcode: the test target these files belong to.
        var target: String?
    }

    /// A switch (no `choices`) or a picker. An empty choice value leaves the flag out.
    struct Option: Decodable, Hashable, Identifiable {
        var id: String
        var title: String
        var flag: String
        /// A sentence under the control saying what it does.
        var help: String?
        var choices: [Choice]?
    }

    struct Choice: Decodable, Hashable {
        var title: String
        var value: String
    }
}

/// A test class (Swift) or a test file (TypeScript) found in a suite's sources.
struct TestGroup: Identifiable, Hashable {
    /// What narrows a run to it: `Target/Class`, or a file path relative to the suite's folder.
    var id: String
    var name: String
    var tests: Int
}

enum Outcome: String, Codable {
    case passed, failed, skipped, expectedFailure
}

struct CaseResult: Codable, Identifiable, Hashable {
    /// Which run of the suite: `iPhone-duo`, `Unit-Mac`, `vitest`…
    var run: String
    var group: String
    var name: String
    var outcome: Outcome
    var seconds: Double
    var messages: [String] = []
    var attachments: [String] = []
    var logExcerpt: String?

    var id: String { "\(run)|\(group)|\(name)" }
}

enum RunState: String, Codable {
    case queued, running, passed, failed, stopped
}

struct SuiteRun: Codable {
    var suiteID: String
    var title: String
    var commandLine: String
    var state: RunState = .queued
    var exitCode: Int32?
    var started: Date?
    var finished: Date?
    var resultDir: String?
    /// The script's own one-line-per-run summary, and anything it refused or skipped.
    var notes: [String] = []
    /// Compiler and runner errors from runs that never got as far as tests.
    var buildErrors: [String] = []
    var cases: [CaseResult] = []
    var console: String = ""
    var currentTest: String?

    func count(_ outcome: Outcome) -> Int { cases.filter { $0.outcome == outcome }.count }
    var seconds: Double { (finished ?? Date()).timeIntervalSince(started ?? Date()) }
}

/// Test and class names in words, for people who do not read code.
enum Plain {
    /// `testACancelOnThePhoneIsACancelHere` → "A cancel on the phone is a cancel here".
    static func test(_ name: String) -> String {
        if name.contains(" ") { return name }
        if name.contains("_") { return sentence(name.replacingOccurrences(of: "_", with: " ")) }
        return words(name.hasPrefix("test") ? String(name.dropFirst(4)) : name)
    }

    /// `PadContextMenuTests` → "Context menu"; a file path → its name.
    static func group(_ name: String) -> String {
        if name.contains("::") { return sentence((name.components(separatedBy: "::").last ?? name).replacingOccurrences(of: "_", with: " ")) }
        if name.contains("/") || name.contains(".") {
            let file = (name as NSString).lastPathComponent
            return words(file.components(separatedBy: ".").first ?? file)
        }
        var name = name
        for suffix in ["UITests", "Tests", "Test"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            break
        }
        for prefix in ["Phone", "Pad", "Mac", "TV", "Watch"] where name.hasPrefix(prefix) && name.count > prefix.count {
            name.removeFirst(prefix.count)
            break
        }
        return words(name)
    }

    private static func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    static func words(_ name: String) -> String {
        let letters = Array(name.replacingOccurrences(of: "iPhone", with: "Iphone").replacingOccurrences(of: "iPad", with: "Ipad"))
        var spaced = ""
        for (index, letter) in letters.enumerated() {
            if index > 0 {
                let before = letters[index - 1]
                let after = index + 1 < letters.count ? letters[index + 1] : nil
                if letter.isUppercase, before.isLowercase || before.isNumber || (before.isUppercase && (after?.isLowercase ?? false)) {
                    spaced.append(" ")
                } else if letter.isNumber, before.isLetter {
                    spaced.append(" ")
                }
            }
            spaced.append(letter)
        }
        let parts = spaced.split(separator: " ").enumerated().map { index, word -> String in
            let word = String(word)
            if word == "Iphone" { return "iPhone" }
            if word == "Ipad" { return "iPad" }
            if word.count > 1, word == word.uppercased() { return word }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word.lowercased()
        }
        return parts.joined(separator: " ")
    }
}
