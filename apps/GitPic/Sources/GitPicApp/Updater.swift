import AppKit
import GitPicCore

/// Installing a newer GitPic: `brew upgrade --cask gitpic` when Homebrew owns this bundle,
/// and a verified download when it does not.
///
/// **Homebrew first, always.** Replacing a cask-managed bundle behind brew's back leaves its
/// manifest describing a version that is no longer on disk, so the next `brew upgrade` fights
/// it. Asking brew to do the install keeps one owner of what is in `/Applications`, and that
/// argument is untouched by anything below — the in-app installer is not an alternative to
/// brew, it is what happens when brew is not the owner.
///
/// **What changed, and why it is not a weakening.** This file used to argue that self-update
/// was unsafe here at all, because an ad-hoc signature gives no chain to verify a download
/// against. That is true and it is also true of the Homebrew path: a cask's `sha256` is
/// likewise a hash fetched over TLS from GitHub, and brew has no signature chain either. The
/// in-app installer verifies the SHA-256 that `api.github.com` reports for the asset, so the
/// trust root is the same one already shipped rather than a new, lower one. Neither survives
/// a compromised GitHub account; the only real improvement is a Developer ID plus
/// notarisation, which is out of reach for both. See `SelfUpdate` for the full statement.
///
/// **Why neither can happen in this process.** The thing being replaced is the bundle this
/// code is executing from — measured: renaming a running executable's directory away gets the
/// process `Killed: 9`. So the work is handed to a detached script that waits for this process
/// to exit first, and the app quits. Everything else follows: the script cannot report into a
/// UI that no longer exists, so it logs; and it reopens the app whichever way the install
/// went, because the alternative is a user left with no GitPic and no explanation.
///
/// The two paths differ in what happens *after* the quit, and that is the interesting part.
/// brew goes to the network with the app already gone, so a stall costs the user everything —
/// hence the watchdog below. The in-app installer has already downloaded, verified and staged
/// while the window was open, so all that is left is two renames.
@MainActor
enum Updater {

    /// The cask's name, which is deliberately not the formula's.
    ///
    /// The tap ships two entries: the cask `gitpic` installs the app, the formula
    /// `gitpic_cli` installs only the binary (see AGENTS.md). `brew upgrade gitpic` without
    /// `--cask` is ambiguous and Homebrew resolves it in favour of a formula, so both the
    /// flag and this spelling are load-bearing.
    ///
    /// `nonisolated` because ``resolve(report:)`` reads it from a detached task — an immutable
    /// `String` needs no actor to be read safely, and the alternative was hoisting a copy
    /// into every closure that mentions it.
    nonisolated static let caskName = "gitpic"

    /// Seconds `brew upgrade` gets in the generated script before the watchdog kills it.
    ///
    /// Interpolated into both the `sleep` and the message it logs, so the number in the log
    /// cannot drift from the one that was waited.
    private static let upgradeBound = 900

    /// Its own queue rather than `Task.detached`: the probes below block for up to 8 s and
    /// 20 s, and a cooperative thread parked that long is one fewer for everything else in
    /// the app. Same reason `AppDelegate` gives tool discovery a `discoveryQueue` instead of
    /// running it on the pool.
    private nonisolated static let probeQueue = DispatchQueue(label: "dev.gitpic.app.brew-probe")

    /// Which upgrade to offer for this install, if any.
    ///
    /// Each question the probe asks rules out a way the button could do the wrong thing.
    /// Finding `brew` says nothing about whether *this* app came from it — a drag-installed
    /// copy on a machine that also has Homebrew is entirely ordinary, and `brew upgrade --cask
    /// gitpic` there fails with "not installed". And the cask being installed still does not
    /// make *this* bundle the one brew manages: a copy running from `dist-app/`, or a second
    /// one in `~/Applications` while the cask is also installed, would upgrade
    /// `/Applications/GitPic.app` and then be reopened *at its own path* — an old build, still
    /// reporting the same update, with brew reporting nothing left to do. The user can repeat
    /// that forever.
    ///
    /// The decision itself is `SelfUpdate.route`, a pure function in `GitPicCore` so that
    /// every row of it is testable; what is left here is gathering the facts it needs off the
    /// main actor.
    static func resolve(report: UpdateReport) async -> SelfUpdate.Route {
        let bundle = Bundle.main.bundleURL
        // The bundle's own version, not `report.current` — that one is the CLI's, and this
        // replaces the bundle.
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let asset = report.installableAsset()
        let latest = report.latest
        let route: SelfUpdate.Route = await withCheckedContinuation { cont in
            probeQueue.async {
                cont.resume(returning: SelfUpdate.route(
                    location: SelfUpdate.location(of: bundle),
                    bundleVersion: mine,
                    latest: latest,
                    brew: SelfUpdate.brewOwnership(cask: Self.caskName, bundle: bundle),
                    asset: asset))
            }
        }
        switch route {
        case .homebrew:
            Diagnostics.log("update: Homebrew owns this bundle — offering brew upgrade")
        case .selfInstall(let asset, _):
            Diagnostics.log("update: Homebrew does not own this bundle — offering to install"
                            + " \(asset.name) (\(asset.size) bytes)")
        case .unavailable(let reason, let retryable):
            Diagnostics.log("update: no in-app upgrade — \(reason)"
                            + (retryable ? " (will ask again)" : ""))
        }
        return route
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

    /// Download, verify, stage, then quit and let the script swap the bundles.
    ///
    /// **Everything that can fail harmlessly happens before the app quits.** The download, the
    /// digest check, the mount and the copy all run with the window still open, so a failure
    /// costs nothing but a message — and `onProgress` is what the sheet draws. Only once a
    /// verified bundle is staged beside the old one does this hand off and terminate.
    ///
    /// That ordering is the whole reason this path needs no watchdog while the brew one does:
    /// brew goes to the network *after* the app is gone.
    static func installAndRelaunch(
        asset: ReleaseAsset,
        sha256: String,
        version: String,
        onProgress: @Sendable @escaping (SelfUpdate.Progress) -> Void
    ) async throws {
        let dmg = try await SelfUpdate.download(asset: asset, sha256: sha256,
                                                onProgress: onProgress)
        // From here the image is verified. It is removed either way — a staged copy is what
        // gets installed, so keeping five megabytes of disk image afterwards serves nobody.
        defer { try? FileManager.default.removeItem(at: dmg) }

        let target = Bundle.main.bundleURL
        let staged = try await withCheckedThrowingContinuation { cont in
            probeQueue.async {
                cont.resume(with: Result {
                    try SelfUpdate.stage(dmg: dmg, expectedVersion: version, replacing: target)
                })
            }
        }
        let script = try SelfUpdate.handOff(staged: staged, dryRun: dryRun)
        if dryRun {
            Diagnostics.log("update: DRY RUN — staged at \(staged.bundle.path),"
                            + " script at \(script.path), not quitting")
            return
        }
        // Not `exit()`: `NSApp.terminate` runs the normal shutdown, which is what lets
        // `windowWillClose` give back the activation policy and stop an in-flight login.
        NSApp.terminate(nil)
    }

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

    /// Delete what past upgrades left behind: the generated scripts, any disk image a
    /// cancelled download abandoned, and the staging or backup directories an interrupted
    /// install could not clean up itself.
    ///
    /// The script cannot delete itself: `bash` reads a script lazily, so `rm "$0"` from
    /// inside it is a file being unlinked while more of it is still to be parsed. And it
    /// cannot be deleted by the app it relaunches either, because at that moment it is still
    /// running — it is the process that called `open -a`. So the cleanup lands one launch
    /// later, which is what the age bound is for: a day is far longer than any upgrade, so
    /// nothing still in use can match.
    ///
    /// The install path adds two more kinds, and they matter more than a 2 KB script: the
    /// staging directory is a whole copy of the app, and the backup is the old one. The script
    /// removes both on success, but it deliberately keeps the backup until *after* the reopen,
    /// so a crash in between leaves them in `/Applications`.
    ///
    /// Called at launch. Failures are ignored by design — this is tidying, and a directory
    /// that refuses a delete is not worth a word to the user.
    static func sweepStaleScripts() {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-86_400)
        var swept = 0
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in entries where Self.isStaleArtefactName(url.lastPathComponent) {
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                guard let modified, modified < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { swept += 1 }
            }
        }
        if swept > 0 { Diagnostics.log("update: swept \(swept) stale upgrade file(s)") }

        // The bundle-sized ones, beside wherever the app is installed.
        let leftovers = SelfUpdate.sweepLeftovers(olderThan: cutoff)
        if !leftovers.isEmpty {
            Diagnostics.log("update: swept \(leftovers.count) leftover install director(ies):"
                            + " \(leftovers.map(\.lastPathComponent).joined(separator: ", "))")
        }
    }

    /// The temporary-directory names this feature owns.
    ///
    /// `gitpic-update-*` covers both the old upgrade scripts and an abandoned `.dmg`, because
    /// the download names its file the same way; `gitpic-install-*.sh` is the swap script.
    private static func isStaleArtefactName(_ name: String) -> Bool {
        guard name.hasPrefix("gitpic-update-") || name.hasPrefix("gitpic-install-")
                || name.hasPrefix("gitpic-mount-") else { return false }
        return name.hasSuffix(".sh") || name.hasSuffix(".dmg")
            || name.hasPrefix("gitpic-mount-")
    }
}
