import Foundation

/// Append-only launch log at `~/Library/Logs/GitPic.log`.
///
/// This exists because the app's hardest failure mode is invisible from the UI:
/// a Finder-launched bundle gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and if `gh`
/// is not found every upload fails with one collapsed error message. Recording the
/// resolved paths at launch turns "uploads mysteriously fail" into one line to read.
public enum Diagnostics {
    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GitPic.log")
    }

    public static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        // O_APPEND so two launches cannot interleave a partial line — the same
        // reasoning the CLI's history writer uses (`src/history.rs:41-52`).
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
    }

    /// One line describing what the process can actually reach.
    public static func recordLaunch(appVersion: String, tools: ToolPaths?, ghStatus: GHStatus?) {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "<unset>"
        log("launch app=\(appVersion) inheritedPATH=\(path)")
        if let tools {
            log("  gitpic=\(tools.gitpic.path)")
            log("  gh=\(tools.gh?.path ?? "NOT FOUND")")
            log("  childPATH=\(tools.childPATH)")
        } else {
            log("  gitpic=NOT FOUND (app cannot upload)")
        }
        if let ghStatus { log("  ghStatus=\(ghStatus)") }
    }
}
