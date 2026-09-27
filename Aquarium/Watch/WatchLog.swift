//  A log the watch keeps for itself, so a crash can be read about afterwards.
//
//  The unified log is the first place things are written, but the watch
//  offers no way to read it off the wrist, and a process that dies takes
//  its entries with it. So every note of ours also goes to a small file
//  under Application Support, rotated at half a megabyte, and on the way
//  to the background — and just before an export — whatever the system
//  logged from this process (CoreMedia, the network, the session) is
//  copied in beside it. The phone asks for the lot with `requestLogs`.

import Foundation
import OSLog
import WatchKit

enum WatchLog {
    nonisolated static let subsystem = "scottai.FellyJin.watchkitapp"
    private static let limit = 512 * 1024
    private static let kept = 2

    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static var lastSnapshot = Date()
    private static var loggers: [String: Logger] = [:]

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aquarium/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static var current: URL { folder.appendingPathComponent("watch.log") }
    nonisolated private static func rotated(_ n: Int) -> URL { folder.appendingPathComponent("watch.\(n).log") }

    // MARK: - Writing

    /// A note, to the unified log and to the file.
    static func note(_ category: String, _ message: String) {
        write(category, "notice", message)
        logger(category).notice("\(message, privacy: .public)")
    }

    static func error(_ category: String, _ message: String) {
        write(category, "error", message)
        logger(category).error("\(message, privacy: .public)")
    }

    private static func logger(_ category: String) -> Logger {
        lock.lock(); defer { lock.unlock() }
        if let l = loggers[category] { return l }
        let l = Logger(subsystem: subsystem, category: category)
        loggers[category] = l
        return l
    }

    private static func write(_ category: String, _ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(level == "error" ? "E" : "N") [\(category)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        append(line)
    }

    /// Under the lock.
    private static func append(_ line: String) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: current.path) {
                FileManager.default.createFile(atPath: current.path, contents: nil)
                var url = current
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? url.setResourceValues(values)
            }
            handle = try? FileHandle(forWritingTo: current)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        try? handle.write(contentsOf: Data(line.utf8))
        if let offset = try? handle.offset(), offset > limit { rotate() }
    }

    /// Under the lock: the current file becomes .1, .1 becomes .2, and so on.
    private static func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: rotated(kept))
        for n in stride(from: kept - 1, through: 1, by: -1) {
            try? FileManager.default.moveItem(at: rotated(n), to: rotated(n + 1))
        }
        try? FileManager.default.moveItem(at: current, to: rotated(1))
    }

    // MARK: - Memory

    /// What the process may still take, in megabytes: the number that
    /// explains a watch that killed the app.
    static var disk: String {
        WatchDownloads.freeBytes().map { "disk free=\($0 / (1024 * 1024))MB" } ?? "disk free=?"
    }

    static var memory: String {
        let free = os_proc_available_memory() / (1024 * 1024)
        // Zero on the Simulator, which does not keep the count.
        // Memory the app may still use, not storage: see `disk`.
        return free > 0 ? "mem=\(free)MB" : "mem=?"
    }

    // MARK: - The system's side

    /// Copy in what the system logged from this process since the last
    /// time: our subsystem in full, and anything at error or above from any
    /// other. Off the main thread, as the store can take a moment.
    static func snapshotSystemLog() async {
        let since = beginSnapshot()
        let lines: [String] = await Task.detached(priority: .utility) {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
            let position = store.position(date: since)
            guard let entries = try? store.getEntries(at: position) else { return [] }
            var out: [String] = []
            for case let entry as OSLogEntryLog in entries {
                let ours = entry.subsystem == subsystem
                guard ours || entry.level.rawValue >= OSLogEntryLog.Level.error.rawValue else { continue }
                if ours, entry.level.rawValue <= OSLogEntryLog.Level.notice.rawValue { continue } // already in the file
                let level: String
                switch entry.level {
                case .fault: level = "F"
                case .error: level = "E"
                default: level = "N"
                }
                out.append("\(stamp.string(from: entry.date)) \(level) [sys:\(entry.subsystem):\(entry.category)] \(entry.composedMessage)")
            }
            return out
        }.value
        guard !lines.isEmpty else { return }
        appendSnapshot(lines, since: since)
    }

    /// The window since the last snapshot, and the start of a new one.
    private static func beginSnapshot() -> Date {
        lock.withLock {
            let since = lastSnapshot
            lastSnapshot = Date()
            return since
        }
    }

    private static func appendSnapshot(_ lines: [String], since: Date) {
        lock.withLock {
            append("---- system log since \(stamp.string(from: since)) (\(lines.count) lines)\n")
            for line in lines { append(line + "\n") }
        }
    }

    // MARK: - Life

    /// Written at launch. A launch whose predecessor never said goodbye is
    /// noted as such: that is what a crash looks like from here.
    static func launched() {
        let defaults = UserDefaults.standard
        let clean = defaults.object(forKey: "watch_log_clean_exit") == nil ? true : defaults.bool(forKey: "watch_log_clean_exit")
        defaults.set(false, forKey: "watch_log_clean_exit")
        let device = WKInterfaceDevice.current()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        note("app", "launched: Aquarium \(version) (\(build)) on \(device.model) watchOS \(device.systemVersion), pid \(ProcessInfo.processInfo.processIdentifier), \(memory)")
        if !clean {
            error("app", "the previous run did not go to the background before it ended: a crash, a kill, or a watchdog")
        }
    }

    /// Written on the way to the background: the goodbye the next launch
    /// looks for.
    static func backgrounded() {
        note("app", "to background, \(memory)")
        UserDefaults.standard.set(true, forKey: "watch_log_clean_exit")
        Task { await snapshotSystemLog() }
    }

    static func foregrounded() {
        UserDefaults.standard.set(false, forKey: "watch_log_clean_exit")
        note("app", "to foreground, \(memory)")
    }

    // MARK: - Export

    /// Everything, oldest first, as one file the phone can carry.
    static func export() async -> URL? {
        await snapshotSystemLog()
        return lock.withLock { writeExport() }
    }

    /// Under the lock.
    private static func writeExport() -> URL? {
        let out = folder.appendingPathComponent("AquariumWatch-\(Self.fileStamp()).log")
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("AquariumWatch-") {
            try? FileManager.default.removeItem(at: old)
        }
        var data = Data()
        let device = WKInterfaceDevice.current()
        data.append(Data("Aquarium watch log, exported \(stamp.string(from: Date())) from \(device.model) watchOS \(device.systemVersion), \(memory), \(disk)\n\n".utf8))
        for n in stride(from: kept, through: 1, by: -1) {
            if let part = try? Data(contentsOf: rotated(n)) { data.append(part) }
        }
        try? handle?.synchronize()
        if let part = try? Data(contentsOf: current) { data.append(part) }
        guard (try? data.write(to: out, options: .atomic)) != nil else { return nil }
        return out
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
