import Foundation

enum Shell {
    /// Runs a command through a login shell (so Homebrew, Node and Cargo are on
    /// the path, which a Finder-launched app's own environment lacks) and
    /// returns its exit code and output.
    static func run(_ args: [String], cwd: URL? = nil) async -> (code: Int32, output: String) {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = make(args, cwd: cwd)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    done.resume(returning: (127, "\(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    static func make(_ args: [String], cwd: URL?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", #"exec "$@""#, "zsh"] + args
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Every process below `pid`, deepest first.
    static func descendants(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let children = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        return children.flatMap { descendants(of: $0) + [$0] }
    }

    /// Ends a command and everything it started (the script's xcodebuild), by
    /// process id only: never by name, which would take the simulators' apps too.
    static func terminateTree(_ pid: Int32) {
        for child in descendants(of: pid) { kill(child, SIGTERM) }
        kill(pid, SIGTERM)
    }
}
