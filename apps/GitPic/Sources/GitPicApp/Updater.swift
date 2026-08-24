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

    /// Seconds `brew upgrade` gets in the generated script before the watchdog kills it.
    ///
    /// Interpolated into both the `sleep` and the message it logs, so the number in the log
    /// cannot drift from the one that was waited.
    private static let upgradeBound = 900

    enum Availability: Equatable {
        /// brew is here and it is managing this app: an upgrade can be offered.
        case ready(brew: URL)
        /// It cannot be offered. The reason is for the log, not the window — the UI just
        /// falls back to the release page.
        ///
        /// `retryable` separates a fact about this install — the bundle is not where a cask
        /// puts one, brew answered that it does not manage it — from a probe that simply did
        /// not get an answer this time. Only the first kind is worth remembering, because
        /// caching the second told users with a working Homebrew that their app was not
        /// installed by it, for as long as the process lived. See
        /// `AppModel.resolveUpgradePath()`.
        case unavailable(reason: String, retryable: Bool)
    }

    /// Its own queue rather than `Task.detached`: the two probes in ``probe(bundle:)`` block
    /// for up to 8 s and 20 s, and a cooperative thread parked that long is one fewer for
    /// everything else in the app. Same reason `AppDelegate` gives tool discovery a
    /// `discoveryQueue` instead of running it on the pool.
    private nonisolated static let probeQueue = DispatchQueue(label: "dev.gitpic.app.brew-probe")

    /// Whether to offer 立即更新 at all.
    ///
    /// Three questions now, and each one rules out a way the button could do the wrong
    /// thing. Finding `brew` says nothing about whether *this* app came from it — a
    /// drag-installed copy on a machine that also has Homebrew is entirely ordinary, and
    /// `brew upgrade --cask gitpic` there fails with "not installed". Offering a button that
    /// cannot work is worse than not offering one, so the cask is checked too.
    ///
    /// And the cask being installed still does not make *this* bundle the one brew manages,
    /// which is the question that was missing. A copy running from `dist-app/`, or a second
    /// one dragged into `~/Applications` while the cask is also installed, would upgrade
    /// `/Applications/GitPic.app` and then be reopened *at its own path* by the script — an
    /// old build, still reporting the same update, with brew reporting nothing left to do.
    /// The user can repeat that forever. So the running bundle has to be somewhere a cask
    /// installs to, and that question is asked first because it is the only one that is free.
    static func availability() async -> Availability {
        let bundle = Bundle.main.bundleURL
        let probe: Availability = await withCheckedContinuation { cont in
            probeQueue.async { cont.resume(returning: Self.probe(bundle: bundle)) }
        }
        if case .unavailable(let reason, let retryable) = probe {
            Diagnostics.log("update: no in-app upgrade — \(reason)"
                            + (retryable ? " (will ask again)" : ""))
        }
        return probe
    }

    /// The blocking half of ``availability()``, off the main actor on ``probeQueue``.
    private nonisolated static func probe(bundle: URL) -> Availability {
        guard bundleIsWhereACaskInstalls(bundle) else {
            // A fact about this process, not a probe that failed: asking again cannot
            // change where the running bundle lives.
            return .unavailable(
                reason: "this copy runs from \(bundle.path), which is not where brew installs"
                    + " a cask — upgrading would replace a different bundle",
                retryable: false)
        }
        guard let brew = ToolDiscovery.locateBrew() else {
            // Retryable, and deliberately so even though "no brew on this machine" is the
            // common reading: `locateBrew()` also returns nil when its 8 s login-shell probe
            // times out, and the two are indistinguishable from here. Being wrong in the
            // other direction is the expensive one.
            return .unavailable(reason: "brew not found on this machine", retryable: true)
        }
        switch ToolDiscovery.brewCaskStatus(Self.caskName, brew: brew) {
        case .installed:
            return .ready(brew: brew)
        case .notInstalled(let status):
            // brew answered. That answer does not change until something is installed.
            return .unavailable(
                reason: "brew does not manage this app (list --cask exited \(status))",
                retryable: false)
        case .unusable(let reason):
            // The bound was hit or the command could not be read — no answer was obtained.
            return .unavailable(reason: reason, retryable: true)
        }
    }

    /// Whether `bundle` sits in a directory Homebrew installs casks into: `/Applications`,
    /// or `~/Applications` for a machine with `HOMEBREW_CASK_OPTS="--appdir=~/Applications"`.
    ///
    /// An `--appdir` beyond those two is not recognised, and the cost is worth stating: that
    /// install sees the release page instead of a button. It is the safe direction to fail
    /// in — the alternative is spending the user's bandwidth replacing a bundle this process
    /// cannot show is the one it is running from.
    private nonisolated static func bundleIsWhereACaskInstalls(_ bundle: URL) -> Bool {
        let parent = bundle.resolvingSymlinksInPath().deletingLastPathComponent()
            .standardizedFileURL.path
        let appDirs = [
            "/Applications",
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Applications").standardizedFileURL.path,
        ]
        return appDirs.contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == parent
        }
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
        // Inherited, with `PATH` overridden — the policy `GitpicRunner.run` uses, rather than
        // the two hand-picked keys this used to build. brew re-execs itself and shells out to
        // `curl`, `git` and `ditto`, so it needs its own prefix on PATH; but it also needs
        // whatever proxy configuration the app was launched with, and a two-key environment
        // silently dropped `HTTPS_PROXY`/`ALL_PROXY` and left every fetch going direct. On a
        // machine that reaches GitHub only through a local proxy that is the difference
        // between an upgrade and a stall.
        //
        // Necessary rather than sufficient, and worth being honest about: a Finder-launched
        // `.app` has no shell profile applied, so if the proxy is only exported in one there
        // is nothing here to inherit. The bound in the script is what makes that survivable.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(brew.deletingLastPathComponent().path):\(ToolPaths.childPATH)"
        // `HOMEBREW_NO_AUTO_UPDATE` is deliberately *not* set: the tap has to be refreshed
        // for the new cask to be visible at all, so suppressing that would reliably turn
        // "upgrade" into "nothing to do".
        task.environment = env
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

        # Bounded too, and for a sharper reason than the loop above: the reopen at the
        # bottom runs only after brew returns, so an upgrade that never returns costs the
        # user the whole app. GitPic is .accessory — once it has quit there is no Dock
        # icon, no menu-bar icon, and the dialog that named this log went with it — so the
        # only way back would be `open -a GitPic` typed into a terminal. macOS ships no
        # timeout(1), hence the watchdog.
        #
        # The bound is generous on purpose: a slow-but-progressing download must not be
        # killed, and brew refreshes its taps over git before it fetches the disk image.
        # What it buys is that a wedged upgrade is temporary. A killed one can leave the
        # cask half-installed and the reopen below then falls through to `open -a GitPic`,
        # which is worse than a clean upgrade and much better than never coming back.
        \(q(brew.path)) upgrade --cask \(q(Self.caskName)) &
        brew_pid=$!
        (
          sleep \(Self.upgradeBound)
          kill -TERM "$brew_pid" 2>/dev/null || exit 0
          echo "watchdog: brew exceeded \(Self.upgradeBound)s, sent SIGTERM"
          sleep 10
          kill -KILL "$brew_pid" 2>/dev/null && echo "watchdog: escalated to SIGKILL"
        ) &
        watchdog_pid=$!
        wait "$brew_pid"
        status=$?
        kill "$watchdog_pid" 2>/dev/null

        # 143 and 137 are SIGTERM and SIGKILL, so they are the watchdog's verdict rather
        # than brew's. Worth telling apart in the only report this script can make.
        case $status in
          143|137) echo "brew was killed by the watchdog (status $status)" ;;
          0)       echo "brew exited 0" ;;
          *)       echo "brew failed (status $status)" ;;
        esac

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

    /// Delete `gitpic-update-*.sh` left in the temporary directory by past upgrades.
    ///
    /// The script cannot delete itself: `bash` reads a script lazily, so `rm "$0"` from
    /// inside it is a file being unlinked while more of it is still to be parsed. And it
    /// cannot be deleted by the app it relaunches either, because at that moment it is still
    /// running — it is the process that called `open -a`. So the cleanup lands one launch
    /// later, which is what the age bound is for: a day is far longer than any upgrade, so
    /// nothing still in use can match.
    ///
    /// Called at launch. Failures are ignored by design — this is tidying, and a temporary
    /// directory that refuses a delete is not worth a word to the user.
    static func sweepStaleScripts() {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var swept = 0
        for url in entries where url.lastPathComponent.hasPrefix("gitpic-update-")
            && url.pathExtension == "sh" {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { swept += 1 }
        }
        if swept > 0 { Diagnostics.log("update: swept \(swept) stale upgrade script(s)") }
    }
}
