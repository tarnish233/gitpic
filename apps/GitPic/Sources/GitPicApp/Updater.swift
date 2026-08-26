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
/// code is executing from, so the work is handed to a detached script that waits for this
/// process to exit first, and the app quits. Everything else follows: the script cannot report
/// into a UI that no longer exists, so it logs; and it reopens the app whichever way the
/// install went, because the alternative is a user left with no GitPic and no explanation.
///
/// This file used to justify that ordering with "measured: renaming a running executable's
/// directory away gets the process `Killed: 9`". **That measurement was wrong** — re-run twice
/// against a live install, a `mv` of the bundle directory leaves the process running happily
/// from the moved-aside copy. The ordering stands on the plainer argument: a half-replaced
/// bundle is a bundle whose executable, resources and embedded CLI need not be from the same
/// version, and nothing here can put that back. What the wrong measurement actually cost is
/// recorded on ``quitForUpdate(_:)`` — it was the excuse for treating the quit as something
/// that could not fail.
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
    ///
    /// `brewOwnership` is written *inside* the call rather than computed into a local because
    /// `route`'s `brew` parameter is an `@autoclosure`: the location question is free and is
    /// asked first, so a copy outside the two Applications directories never pays the 8 s
    /// login-shell probe or the 20 s `brew list --cask` at all.
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
        case .selfInstall(let asset, _, let version):
            Diagnostics.log("update: Homebrew does not own this bundle — offering to install"
                            + " \(version) from \(asset.name) (\(asset.size) bytes)")
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
    ///
    /// **Cancellation is honoured all the way to the handoff**, which it was not: the staging
    /// step was a bare `withCheckedThrowingContinuation` that nothing could interrupt, so 取消
    /// pressed after the last byte was accepted by the UI, did nothing for up to the summed
    /// hdiutil/codesign/ditto/xattr bounds, and then installed the bundle the user had just
    /// said no to. Three checks now stand between the download and the quit, and the last of
    /// them removes the staging directory so a cancelled install leaves nothing behind.
    static func installAndRelaunch(
        asset: ReleaseAsset,
        sha256: String,
        version: String,
        onProgress: @Sendable @escaping (SelfUpdate.Progress) -> Void
    ) async throws {
        let dmg = try await SelfUpdate.download(asset: asset, sha256: sha256,
                                                onProgress: onProgress)
        // Registered for the quit, which runs no `defer` at all: the user can ask to leave at any
        // point between here and the handoff, and until 0.20.1 could not — AppKit refused every
        // termination while the update sheet was attached, which is the whole time this runs.
        SelfUpdate.holdDownload(dmg.url)
        // Removed on every path out of here — a staged copy is what gets installed, so keeping
        // five megabytes of disk image afterwards serves nobody. `defer` alone was not "either
        // way" as it claimed: the success path ends in `exit()`, so the `defer` never ran and
        // every successful install leaked the image until the next launch's sweep, ≥24 h later.
        // Hence the explicit removal below as well.
        defer {
            try? FileManager.default.removeItem(at: dmg.url)
            SelfUpdate.releaseDownload(dmg.url)
        }

        // Cancellation between the hash and the mount. `download` already deletes its own
        // partial file, so there is nothing else to undo here.
        try Task.checkCancellation()

        let target = Bundle.main.bundleURL
        let cancelled = CancellationFlag()
        let staged: SelfUpdate.Staged = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                probeQueue.async {
                    cont.resume(with: Result {
                        // `probeQueue` is serial and shared with the upgrade-path probe, so
                        // this block can sit behind a 20 s `brew list --cask` before it runs.
                        // Nothing has been mounted at this point, so a 取消 that arrived in the
                        // meantime costs nothing at all.
                        if cancelled.isSet { throw CancellationError() }
                        // `stage` reads this between its own steps — the attach, the version
                        // gate, the signature check, the copy — so a 取消 during a slow `ditto`
                        // stops there and unwinds, instead of completing a whole staging
                        // sequence for the check below to throw away. A closure and not the
                        // value, because it has to be read at each of those points rather
                        // than once here; `CancellationFlag` locks, so reading it from
                        // `GitPicCore`'s thread is safe.
                        return try SelfUpdate.stage(dmg: dmg, expectedVersion: version,
                                                    replacing: target,
                                                    isCancelled: { cancelled.isSet })
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
        try? FileManager.default.removeItem(at: dmg.url)
        SelfUpdate.releaseDownload(dmg.url)

        // The last moment cancellation can mean anything, and the only one with something to
        // undo: a bundle-sized staging directory beside the app. After the handoff below the
        // script is a detached process this cannot recall.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: staged.directory)
            _ = SelfUpdate.claimStaged(staged.directory)
            Diagnostics.log("update: cancelled after staging — removed \(staged.directory.path)")
            throw CancellationError()
        }

        // The staging directory changes hands here: from this process, which would delete it on
        // the way out, to the script, which needs it to still be there. Claimed *before* the
        // spawn and not after, because the gap between the two is where a quit would delete the
        // bundle the script is about to move — leaving `installScript` to log that the staged
        // bundle is gone and its `trap reopen EXIT` to put the old one back. A quit that lost
        // that race would read as a silent rollback of a successful install.
        //
        // `false` means the quit got there first and the directory is already going, so there is
        // nothing left to hand off. Nothing will show this: `undoInFlightWork` only runs from the
        // single `exit(0)`, so losing the claim means the process is already leaving.
        guard SelfUpdate.claimStaged(staged.directory) else {
            Diagnostics.log("update: quitting mid-install, so the staged bundle was reclaimed"
                            + " instead of handed off")
            throw SelfUpdate.InstallFailure.cancelled
        }
        let script = try SelfUpdate.handOff(staged: staged, dryRun: dryRun)
        if dryRun {
            Diagnostics.log("update: DRY RUN — staged at \(staged.bundle.path),"
                            + " script at \(script.path), not quitting")
            // Everything the real quit does except leaving. `GITPIC_APP_DRY_RUN=1` used to
            // `return` from here, which is exactly how 0.20.0 shipped an app that would not
            // quit: not one line below this had ever been executed by a test or by a dry
            // run, so the only thing that could have caught it was a real install, and no
            // real install was run before the release. The untestable surface is now the
            // single `exit` in ``quitForUpdate(_:)`` — see `scripts/check-self-update.sh`
            // for what covers that.
            prepareToQuit()
            return
        }
        quitForUpdate("the install script is waiting for this pid to exit")
    }

    /// The one piece of shutdown that outlives this process if it is skipped.
    ///
    /// `gitpic auth login` is a **child process**: it polls GitHub until the device code
    /// expires a quarter of an hour later, and `exit()` reaps nothing. So a user who left a
    /// login half-finished and then took an update would have had it keep polling on behalf of
    /// a bundle that no longer exists. ``AppModel/cancelLogin()`` cancels the task whose
    /// `AsyncStream` `onTermination` terminates that child, and is a no-op when no login is
    /// running.
    ///
    /// Honest about how far that is verified: a device-flow login cannot be driven unattended,
    /// so this half is reasoned rather than measured. It is not weaker than what it replaces —
    /// `NSApp.terminate` reached this same call through `windowWillClose`, which AppKit only
    /// runs *after* `applicationWillTerminate` and immediately before its own `exit()`, so the
    /// cancellation got no more of a turn there than it gets here.
    ///
    /// The activation policy is deliberately **not** touched. `windowWillClose` also calls
    /// `AppActivationPolicy.leave()`, and the comment this fix replaced treated that as
    /// cleanup worth keeping the normal shutdown for — it is not. An activation policy is
    /// per-process state that dies with the process, and `Main.main()` sets `.accessory`
    /// before `run()` on every launch, so the bundle the script reopens comes back a
    /// menu-bar app either way. `scripts/check-self-update.sh` asserts that rather than
    /// leaving it as an argument.
    private static func prepareToQuit() {
        AppModel.shared.cancelLogin()
    }

    /// Leave now, so the staged bundle — or brew — can replace the one this is running from.
    ///
    /// **`exit()` and not `NSApp.terminate`, and that is a measurement rather than a
    /// preference.** `NSApp.terminate(nil)` is what 0.20.0 shipped on both update paths, and
    /// it never quit. AppKit aborts termination *before* it asks the delegate anything when
    /// any of the app's windows has an attached sheet, and says so in its own log
    /// (`log show --predicate 'process == "GitPic"' --debug --info`):
    ///
    ///     [AppKit:Application] terminate:
    ///     [AppKit:Application] Attempting sudden termination (1st attempt)
    ///     [AppKit:Application] Checking whether app should terminate
    ///     [AppKit:Application] App termination blocked by modal sheet
    ///     [AppKit:Application] Termination aborted
    ///
    /// Reproduced on 0.20.0's own code with no download at all: open 设置, 检查更新 until the
    /// update sheet is up, then 退出 GitPic. The process survives, and every later quit is
    /// refused the same way for as long as the sheet is attached.
    ///
    /// **Three things follow, and each one closes off a fix that looks plausible.**
    ///
    /// - Implementing `applicationShouldTerminate` and returning `.terminateNow` would have
    ///   changed nothing: it is never consulted. Measured — a probe build logged nothing from
    ///   it on the failing run, while the same probe fired on the succeeding ones.
    /// - The activation policy is not the culprit either. Measured on the same build: with the
    ///   settings window open and no sheet, the app is `.regular` and `windowWillClose` still
    ///   calls `setActivationPolicy(.accessory)` *inside* the shutdown, and the process exits
    ///   normally. Only the sheet refuses.
    /// - Dismissing the sheet first and then terminating would work only if the dismissal
    ///   completed before `terminate:` ran, which is a SwiftUI animation this code cannot
    ///   wait on — and it would leave the next sheet anyone adds to reintroduce the bug
    ///   silently. This path *always* has a sheet up: the install is started from a button
    ///   inside the update sheet, and that sheet is what draws the progress bar.
    ///
    /// `Never` on purpose, so that the compiler holds the invariant that failed rather than a
    /// comment: 0.20.0 logged 「quitting so the bundle can be replaced」 and then went back to
    /// serving events. Nothing may return from here.
    private static func quitForUpdate(_ reason: String) -> Never {
        quit("update: \(reason)")
    }

    /// The way out for everything in this app that decides to leave.
    ///
    /// Why this is centralised rather than left at each call site: 0.20.0 shipped
    /// `NSApp.terminate` on three paths, the fix changed one of them, and the two the user
    /// actually clicks — 「退出 GitPic」 in the status menu and ⌘Q — kept the defect for two
    /// releases. The mechanism is not specific to updating: AppKit refuses termination
    /// whenever any window has an attached sheet, so 图床's 「把这个配置文件移开？」 alert and
    /// the update sheet both made the app unquittable. See ``quitForUpdate(_:)`` for the
    /// measurement, including why `applicationShouldTerminate` cannot be the fix.
    ///
    /// **Not every route out of the process comes through here, and the earlier claim that it did
    /// was wrong.** The Dock icon's contextual-menu Quit and the Apple Event a logout or restart
    /// sends are synthesised by AppKit and still arrive as `terminate:`, so they are still refused
    /// while a sheet is attached — and the app has a Dock icon precisely when the settings window
    /// is up (`AppActivationPolicy.enter`), which is the only way to get a sheet in the first
    /// place. What is true is narrower and is what the tripwire checks: every affordance *this
    /// code owns* ends here. Closing the rest means
    /// `NSWindow.preventsApplicationTerminationWhenModal = false` on the sheet window, which
    /// defaults to `true`; it is not done here because nothing has measured it yet.
    ///
    /// `QuitPathContractTests` asserts that no `NSApplication.terminate` selector comes back
    /// into `GitPicApp/`, so the next person to add a quit affordance cannot reintroduce it
    /// quietly.
    static func quit(_ reason: String) -> Never {
        prepareToQuit()
        // `exit(0)` runs no `defer`, so an install still staging would leave an attached disk
        // image, a bundle-sized staging directory beside the app and the download behind it — for
        // a day, until a launch sweep. Undone here rather than in `prepareToQuit()` because that
        // one has two callers that return instead of exiting: the `GITPIC_APP_DRY_RUN` branches.
        // A destructive drain there would delete an install the app is still running.
        SelfUpdate.undoInFlightWork()
        // `exit()` skips AppKit's ordinary shutdown, so anything that saves at quit would be
        // lost here. Almost nothing does: settings are mirrored into `UserDefaults` on every
        // change rather than at the end (`AppModel.swift:864-914`). The exception is the window
        // frame — `SettingsWindowController` sets a frame autosave name, and AppKit writes that
        // through `UserDefaults` too, so the flush below covers it. The flush is worth one line
        // because the store writes back asynchronously and `exit()` can outrun it: the setting
        // that would be lost is the one toggled a moment before quitting.
        UserDefaults.standard.synchronize()
        Diagnostics.log("quitting now — \(reason)")
        // 0 because this is a deliberate exit, not a failure. On the update path nothing reads
        // the status either: the script waits for the pid to disappear, not for a code.
        exit(0)
    }

    /// The user asked to leave — the status menu's 「退出 GitPic」 or ⌘Q.
    static func quitByUser() -> Never {
        quit("user asked to quit")
    }

    /// Quit, upgrade, reopen.
    ///
    /// Returns only if the handoff itself failed; on success this process is on its way
    /// out — see ``quitForUpdate(_:)``, which is `Never` for exactly that reason. The caller
    /// has already confirmed with the user — see `UpdateSheet` — because this closes their
    /// window and takes the menu-bar icon away for as long as the download takes.
    ///
    /// The quit here had the same defect as the install path's and for the same reason: it is
    /// reached from a button inside an alert on the update sheet, so `NSApp.terminate` was
    /// refused here too. Untested against a real Homebrew-managed bundle, because this machine
    /// has none at a path the app runs from; the code path is shared, and the one thing that
    /// differs — the script — is the same shape.
    static func upgradeAndRelaunch(brew: URL) throws {
        let script = try writeScript(brew: brew)
        if dryRun {
            Diagnostics.log("update: DRY RUN — script written to \(script.path),"
                            + " not spawned, not quitting")
            // The same reason as the install path: everything but the `exit`.
            prepareToQuit()
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

        Diagnostics.log("update: handed off to \(script.path) (pid \(task.processIdentifier))")
        quitForUpdate("brew will replace the bundle once this pid is gone")
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

        # Wait for GitPic to exit so brew is not replacing a running bundle. Bounded at
        # 60 s: the app calls `exit(0)` immediately after spawning this script — see
        # `Updater.quitForUpdate` — so the wait is normally a fraction of a second, and an
        # app still here after a minute is in a state nothing in this script can mend.
        #
        # After the bound brew is allowed to try anyway. The reason is *not* that a
        # surviving process is stopped by the move: this file used to claim that, citing
        # `Killed: 9`, and the claim is false — re-measured twice, a `mv` of the bundle
        # directory leaves the process running from the moved-aside copy, which is how
        # 0.20.0's failed quit turned into `open -a` merely reactivating the old build.
        # The reason is that the alternative is worse: bailing out here leaves an
        # .accessory app with no upgrade and no explanation, whereas trying gets the user
        # the new version and a log line either way. A brew that cannot complete the move
        # reports non-zero and the old bundle stays.
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
    /// Called at launch. A refusal is not worth a word to the *user* — this is tidying — but it
    /// is worth a line in the log, because one of these entries can refuse forever: a
    /// `gitpic-mount-*` directory that is still an attached disk image cannot be unlinked at
    /// all. Measured: `removeItem` on an attached mount point throws
    /// `NSCocoaErrorDomain 512` wrapping `NSPOSIXErrorDomain 16 "Resource busy"`, and after
    /// `hdiutil detach` the very same call succeeds. So the failure was silent *and* permanent,
    /// which is the combination that hides a bug for months.
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
                // A still-attached mount point cannot be unlinked: `removeItem` fails with
                // `POSIX 16 Resource busy`, and worse, it walks the mounted read-only volume
                // trying to delete the image's contents. So the same entry failed on every
                // launch, forever, while `-nobrowse` kept it invisible in Finder.
                // `SelfUpdate.detachMount(at:)` owns that rule — retry, then `-force`, then
                // remove — because `ChildProcess` is internal to `GitPicCore` and `hdiutil` has
                // no business being spawned from here. It removes the directory itself on
                // success, and logs why when it cannot, so there is nothing to do afterwards
                // either way. Guarded on the prefix: the other two things this sweep matches
                // are a script and a disk image, both plain files.
                if url.lastPathComponent.hasPrefix("gitpic-mount-") {
                    if SelfUpdate.detachMount(at: url) { swept += 1 }
                    continue
                }
                do {
                    try FileManager.default.removeItem(at: url)
                    swept += 1
                } catch {
                    Diagnostics.log("update: could not sweep \(url.lastPathComponent):"
                                    + " \((error as NSError).localizedDescription)"
                                    + " — \(String(describing: error))")
                }
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
    ///
    /// The bundle-sized leftovers — `.GitPic-update-*` staging directories and `.GitPic-old-*`
    /// backups, beside wherever the app is installed — are deliberately **not** listed here.
    /// `SelfUpdate.sweepLeftovers` owns that rule, and it is the one that has to be careful
    /// about not deleting a bundle something is still running from. Two copies of a rule whose
    /// mistakes are measured in whole applications is one too many.
    private static func isStaleArtefactName(_ name: String) -> Bool {
        guard name.hasPrefix("gitpic-update-") || name.hasPrefix("gitpic-install-")
                || name.hasPrefix("gitpic-mount-") else { return false }
        return name.hasSuffix(".sh") || name.hasSuffix(".dmg")
            || name.hasPrefix("gitpic-mount-")
    }
}

/// A one-way "the user pressed 取消" flag, readable from a `DispatchQueue` block.
///
/// `NSLock` over a `Bool`, following `SelfUpdate`'s `DownloadDelegate` and `Auth`'s `LoginChild`:
/// the setter runs in `withTaskCancellationHandler`'s `onCancel`, which can fire on any thread,
/// while the reader is a block on `Updater.probeQueue`. `Synchronization.Mutex` would be the
/// modern answer and is macOS 15; this package targets macOS 14 (`Package.swift`).
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
