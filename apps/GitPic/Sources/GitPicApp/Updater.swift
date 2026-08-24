import AppKit
import GitPicCore

/// Running `brew upgrade --cask gitpic` on the app's own behalf.
///
/// **Why this shells out to Homebrew instead of updating itself.** The app is distributed
/// as a Homebrew cask and signed ad-hoc — no Developer ID, no notarisation (see
/// `scripts/build-app.sh`). A Sparkle-style updater would therefore have no signature
/// chain to verify a download against, which is the one thing that makes self-update safe;
/// and replacing the bundle behind Homebrew's back leaves the cask's manifest describing a
/// version that is no longer on disk, so the next `brew upgrade` would fight it. Asking
/// brew to do the install keeps one owner of what is in `/Applications`.
///
/// **Why it cannot happen in this process.** The thing being replaced is the bundle this
/// code is executing from. So the work is handed to a detached script that waits for this
/// process to exit first, and the app quits. That ordering is the whole design here, and
/// everything below follows from it: the script cannot report back into a UI that no longer
/// exists, so it logs; and it reopens the app whether or not brew succeeded, because the
/// alternative is a user left with no GitPic and no explanation.
@MainActor
enum Updater {

    /// The cask's name, which is deliberately not the formula's.
    ///
    /// The tap ships two entries: the cask `gitpic` installs the app, the formula
    /// `gitpic_cli` installs only the binary (see AGENTS.md). `brew upgrade gitpic` without
    /// `--cask` is ambiguous and Homebrew resolves it in favour of a formula, so both the
    /// flag and this spelling are load-bearing.
    ///
    /// `nonisolated` because ``availability()`` reads it from a detached task — an immutable
    /// `String` needs no actor to be read safely, and the alternative was hoisting a copy
    /// into every closure that mentions it.
    nonisolated static let caskName = "gitpic"

    enum Availability: Equatable {
        /// brew is here and it is managing this app: an upgrade can be offered.
        case ready(brew: URL)
        /// It cannot be offered. The reason is for the log, not the window — the UI just
        /// falls back to the release page.
        case unavailable(reason: String)
    }

    /// Whether to offer 立即更新 at all.
    ///
    /// Two questions, and both have to be asked. Finding `brew` says nothing about whether
    /// *this* app came from it — a drag-installed copy on a machine that also has Homebrew
    /// is entirely ordinary, and `brew upgrade --cask gitpic` there fails with "not
    /// installed". Offering a button that cannot work is worse than not offering one, so
    /// the cask is checked too.
    ///
    /// Both halves spawn a process, so both go off the main actor.
    static func availability() async -> Availability {
        let probe = await Task.detached { () -> Availability in
            guard let brew = ToolDiscovery.locateBrew() else {
                return .unavailable(reason: "brew not found on this machine")
            }
            switch ToolDiscovery.brewCaskStatus(Self.caskName, brew: brew) {
            case .installed:
                return .ready(brew: brew)
            case .notInstalled(let status):
                return .unavailable(
                    reason: "brew does not manage this app (list --cask exited \(status))")
            case .unusable(let reason):
                return .unavailable(reason: reason)
            }
        }.value
        if case .unavailable(let reason) = probe {
            Diagnostics.log("update: no in-app upgrade — \(reason)")
        }
        return probe
    }

    /// `GITPIC_APP_DRY_RUN=1` writes the script and stops there — nothing is spawned and the
    /// app does not quit.
    ///
    /// The same flag `AppDelegate` uses to keep an upload off the network, honoured here for
    /// the same reason it gives: a dry run that silently does the real thing from one path is
    /// worse than having no dry-run mode at all. Replacing `/Applications/GitPic.app` is at
    /// least as consequential as a commit to the image host, and it is the one action in this
    /// app that cannot be undone by deleting something afterwards.
    ///
    /// It also makes the generated script inspectable: the log names the path, and the file
    /// is left on disk to read.
    private static let dryRun = ProcessInfo.processInfo.environment["GITPIC_APP_DRY_RUN"] == "1"

    /// Quit, upgrade, reopen.
    ///
    /// Returns only if the handoff itself failed; on success this process is on its way
    /// out. The caller has already confirmed with the user — see `UpdateSheet` — because
    /// this closes their window and takes the menu-bar icon away for as long as the
    /// download takes.
    static func upgradeAndRelaunch(brew: URL) throws {
        let script = try writeScript(brew: brew)
        if dryRun {
            Diagnostics.log("update: DRY RUN — script written to \(script.path),"
                            + " not spawned, not quitting")
            return
        }
        // Detached on purpose. The child is reparented when this process exits and keeps
        // running, which is exactly what has to happen: the script's first job is to wait
        // for that exit.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        // A clean, explicit environment for the same reason `ToolPaths.childPATH` exists —
        // except that this child needs brew's own prefix on PATH, since brew re-execs
        // itself and shells out to `curl`, `git` and `ditto`.
        task.environment = [
            "PATH": "\(brew.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        try task.run()

        Diagnostics.log("update: handed off to \(script.path) (pid \(task.processIdentifier));"
                        + " quitting so brew can replace the bundle")
        // Not `exit()`: `NSApp.terminate` runs the normal shutdown, which is what lets
        // `windowWillClose` give back the activation policy and stop an in-flight login.
        NSApp.terminate(nil)
    }

    /// The script, written to a temporary file rather than passed as `bash -c`.
    ///
    /// A file because it is worth being able to read afterwards when an upgrade went
    /// wrong — the log names this path.
    private static func writeScript(brew: URL) throws -> URL {
        let log = Diagnostics.logURL.deletingLastPathComponent()
            .appendingPathComponent("GitPic-update.log")
        let bundle = Bundle.main.bundleURL
        // Quoted with single quotes and the one escape that needs: a path containing a
        // quote is absurd for an installed .app but this is shell code being generated,
        // and "absurd" is not "impossible".
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

        let script = """
        #!/bin/bash
        # Written by GitPic's Updater. Safe to delete.
        exec >>\(q(log.path)) 2>&1
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) upgrade \(Self.caskName) ==="

        # Wait for GitPic to exit so brew is not replacing a running bundle. Bounded:
        # a hung app must not leave this looping forever, and after the bound brew is
        # allowed to try anyway — it is the one that can refuse safely.
        for _ in $(seq 1 120); do
          kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
          sleep 0.5
        done

        \(q(brew.path)) upgrade --cask \(q(Self.caskName))
        status=$?
        echo "brew exited $status"

        # Reopen either way. A failed upgrade must not cost the user their app: the old
        # bundle is still on disk in that case, and this is the only thing that puts the
        # menu-bar icon back.
        open -a \(q(bundle.path)) || open -a GitPic || echo "could not reopen GitPic"
        exit $status
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-update-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
