import Foundation

/// Append-only launch log at `~/Library/Logs/GitPic.log`.
///
/// This exists because the app's hardest failure mode is invisible from the UI: a
/// Finder-launched bundle gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so nothing on a
/// Homebrew or nix prefix is findable by name, and if `gitpic` is not located the app
/// cannot upload at all. Recording the resolved path at launch turns "uploads
/// mysteriously fail" into one line to read.
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
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // A real `O_APPEND`, which is what this comment claimed while the code did
        // `FileHandle(forWritingTo:)` + `seekToEnd()` + `write`. There is no O_APPEND
        // on `FileHandle`: that opens `O_WRONLY` and then performs exactly the
        // seek-then-write race `O_APPEND` exists to replace — the `seekToEnd()` was
        // itself the proof the descriptor was not in append mode. It matters because
        // this log is deliberately machine-global (AGENTS.md), so a `swift run` build
        // and the installed `/Applications/GitPic.app` write the same file: both
        // resolved `seekToEnd()` to the same offset and the second `write` landed on
        // top of the first, losing the launch record the file exists to keep. The CLI's
        // history writer, which this cites, really does use `O_APPEND` plus one write.
        //
        // `O_CREAT` also replaces the `fileExists`/`createFile` pair, which was its own
        // small race.
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < buf.count {
                let n = write(fd, base + written, buf.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    /// One line describing what the process can actually reach.
    public static func recordLaunch(appVersion: String, tools: ToolPaths?) {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "<unset>"
        log("launch app=\(appVersion) inheritedPATH=\(path)")
        if let tools {
            log("  gitpic=\(tools.gitpic.path)")
            log("  childPATH=\(ToolPaths.childPATH)")
        } else {
            log("  gitpic=NOT FOUND (app cannot upload)")
        }
    }
}
