import AppKit
import GitPicCore

/// Installing a newer GitPic: a disk image this process downloads and verifies, then a script
/// that swaps the bundle once this process is gone.
///
/// **One path now, for every install.** There used to be two: `brew upgrade --cask gitpic` when
/// Homebrew owned the bundle, and this download when it did not. The argument for that split was
/// sound — replacing a cask-managed bundle behind brew's back leaves its manifest describing a
/// version that is no longer on disk, and the next `brew upgrade` fights it — but what brew users
/// actually got was the worse half of it. The app had to quit *before* brew was spawned, so the
/// tap refresh and the whole download happened with an `.accessory` app's menu-bar icon already
/// gone: no progress, nothing to cancel, and a 900 s watchdog as the only bound on an upgrade
/// that wedged. Worse, when the tap lagged the Release — dispatch plus a six-hourly cron, and
/// AGENTS.md records that the dispatch token has expired before — `brew upgrade` exited **0**
/// with "the latest version is already installed", the script logged that as success and
/// reopened the same build. A user who lost their app for nothing and was then offered the
/// identical update again.
///
/// What resolved the split is a stanza the cask was missing, not a change of mind about the
/// danger: `auto_updates true` tells Homebrew the artifact updates itself, and current Homebrew
/// then decides by reading the *installed bundle's* `Info.plist` rather than its own receipt. So
/// `brew upgrade` still upgrades a GitPic that is genuinely behind, and correctly does nothing
/// once this installer has moved it on. `SelfUpdate.route`'s header carries the full argument
/// with citations; the stanzas themselves live in `tarnish233/homebrew-tap`.
///
/// **Why the install cannot happen in this process.** The thing being replaced is the bundle this
/// code is executing from, so the work is handed to a detached script that waits for this process
/// to exit first, and the app quits. Everything else follows: the script cannot report into a UI
/// that no longer exists, so it logs; and it reopens the app whichever way the install went,
/// because the alternative is a user left with no GitPic and no explanation.
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
/// **What the trust root is, and is not.** This file once argued that self-update was unsafe here
/// at all, because an ad-hoc signature gives no chain to verify a download against. That is true,
/// and it was equally true of the Homebrew path: a cask's `sha256` is likewise a hash fetched
/// over TLS from GitHub, and brew has no signature chain either. The installer verifies the
/// SHA-256 that `api.github.com` reports for the asset, so the trust root is the one already
/// shipped rather than a new, lower one. Neither survives a compromised GitHub account; the only
/// real improvement is a Developer ID plus notarisation, which is out of reach for both. See
/// `SelfUpdate` for the full statement.
@MainActor
enum Updater {

    /// Its own queue rather than `Task.detached`: staging blocks on `hdiutil`, `codesign` and
    /// `ditto`, bounded at 120 s, 120 s and 300 s, and a cooperative thread parked that long is
    /// one fewer for everything else in the app. Same reason `AppDelegate` gives tool discovery a
    /// `discoveryQueue` instead of running it on the pool.
    ///
    /// It was `probeQueue`, labelled `brew-probe`, and it was shared with the Homebrew ownership
    /// probe — which is why ``installAndRelaunch`` still explains that staging could sit behind
    /// somebody else's 20 s `brew list --cask` before it started. That probe is gone, so the
    /// queue has one user and the name says which.
    private nonisolated static let stagingQueue =
        DispatchQueue(label: "dev.gitpic.app.staging")

    /// Which upgrade to offer for this install, if any.
    ///
    /// The decision itself is `SelfUpdate.route`, a pure function in `GitPicCore` so that every
    /// row of it is testable; what is left here is reading the two facts it needs off the running
    /// bundle.
    ///
    /// **This used to be the expensive part of opening the sheet.** It asked whether Homebrew
    /// owned this bundle, which meant up to an 8 s login-shell probe plus a 20 s
    /// `brew list --cask` per Homebrew prefix, serialised on one queue — up to 28 seconds of
    /// 「正在确认升级方式…」 before a button could be drawn. Each of those questions ruled out a
    /// way the old brew branch could do the wrong thing: finding `brew` said nothing about
    /// whether *this* app came from it, and the cask being installed still did not make *this*
    /// bundle the one brew manages, so a copy in `~/Applications` beside a cask in
    /// `/Applications` would have upgraded the other one and been reopened at its own path,
    /// unchanged, still reporting the same update, forever. There is no brew branch to protect
    /// now, so none of it is asked.
    ///
    /// Still `async`, though nothing in it suspends: `UpdateSheet`'s `.task(id:)` awaits it, and
    /// `AppModel.resolveUpgradePath`'s guard against a report landing mid-resolve is worth
    /// keeping whether or not the resolve is instant.
    static func resolve(report: UpdateReport) async -> SelfUpdate.Route {
        let bundle = Bundle.main.bundleURL
        // The bundle's own version, not `report.current` — that one is the CLI's, and this
        // replaces the bundle.
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let route = SelfUpdate.route(
            location: SelfUpdate.location(of: bundle),
            bundleVersion: mine,
            latest: report.latest,
            asset: report.installableAsset())
        switch route {
        case .selfInstall(let asset, _, let version):
            Diagnostics.log("update: offering to install \(version) from \(asset.name)"
                            + " (\(asset.size) bytes)")
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
    /// That ordering is why nothing here needs a watchdog. The path this replaced did: it spawned
    /// brew *after* the app was gone, so a stall cost the user the whole application and only a
    /// timer could end it. Here a stall costs a progress bar that stops moving, next to a 取消
    /// that works.
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
                stagingQueue.async {
                    cont.resume(with: Result {
                        // Checked on entry because dispatching is not instant: a 取消 can land
                        // between the `Task` starting and this block running. It used to be able
                        // to wait much longer than that — this queue was shared with the Homebrew
                        // ownership probe, so staging could sit behind somebody else's 20 s
                        // `brew list --cask` first. Nothing has been mounted at this point, so a
                        // 取消 that arrived in the meantime costs nothing at all.
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

    /// Leave now, so the staged bundle can replace the one this is running from.
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
    /// sends are synthesised by AppKit and still arrive as `terminate:` — and the app has a Dock
    /// icon precisely when the settings window is up (`AppActivationPolicy.enter`), which is the
    /// only way to get a sheet in the first place. Those routes are now closed from both ends:
    /// ``allowTerminationWithSheets()`` stops the sheet refusing them, and
    /// `AppDelegate.applicationShouldTerminate` sends what gets through to ``quitByUser()``, so
    /// they land here after all rather than letting AppKit exit without the staging undo. What
    /// the tripwire checks is still the narrower property — that every affordance *this code
    /// owns* ends here — because a grep cannot see AppKit's behaviour; the
    /// 「quit Apple Event」 phase in `scripts/check-self-update.sh` is what measures that.
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

    /// Stop AppKit refusing to terminate while a sheet is attached.
    ///
    /// ``quit(_:)`` fixed every affordance *this code* owns by never calling `terminate:` at
    /// all. It could do nothing about the routes AppKit synthesises: the Dock icon's
    /// contextual-menu Quit, and the Apple Event a logout or a restart sends. Those still
    /// arrive as `terminate:`, and a sheet still refuses them — so with the update sheet up
    /// the app is not merely awkward to quit, it **blocks the user logging out**, and the only
    /// way past it is Force Quit. The sheet is up for the whole download and staging, and the
    /// app has a Dock icon exactly then, because a sheet needs the settings window
    /// (`AppActivationPolicy.enter`).
    ///
    /// **Why a notification and not five call sites.** There are five sheet-shaped
    /// presentations today — the update `.sheet`, 图床's 「把这个配置文件移开？」, 「升级前需要退出
    /// GitPic」, 「下载并安装」, and the agent-integration `.confirmationDialog` — and
    /// ``quitForUpdate(_:)`` already records why per-sheet fixes are the wrong shape: they
    /// "would leave the next sheet anyone adds to reintroduce the bug silently". One observer
    /// covers the five and the sixth.
    ///
    /// Read a turn later, and across every sheet rather than the notification's own window:
    /// `willBeginSheet` fires *before* AppKit populates `attachedSheet`, and setting the flag
    /// is idempotent, so a loop that may run once too often is worth more than a lookup that
    /// has to name the right window.
    ///
    /// **This half is the plausible fix, not yet the measured one, and the ordering matters.**
    /// Lifting the refusal is only safe because ``AppDelegate/applicationShouldTerminate(_:)``
    /// now routes `terminate:` into ``quitByUser()``: without it AppKit would tear the process
    /// down its own way, running neither ``prepareToQuit()`` nor the staging undo, which is the
    /// 0.20.1 leak reopened through a different door. What no unit test can reach is whether
    /// this actually stops the refusal — `swift test` cannot import `GitPicApp`, and the
    /// behaviour lives in AppKit and needs a real sheet on a real window. That is what
    /// `scripts/check-self-update.sh`'s 「quit Apple Event」 phase measures, by sending the same
    /// event a logout sends while an install is in flight.
    static func allowTerminationWithSheets() {
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isSheet {
                    window.preventsApplicationTerminationWhenModal = false
                }
            }
        }
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
    /// `gitpic-update-*` covers an abandoned `.dmg`, because the download names its file that way;
    /// `gitpic-install-*.sh` is the swap script.
    ///
    /// **`.sh` under `gitpic-update-` is kept deliberately, and nothing writes one any more.**
    /// That was the Homebrew upgrade script, generated by a `writeScript` this version deleted.
    /// A machine upgrading from 0.20.x can still have one sitting in `$TMPDIR` — the script
    /// cannot delete itself and neither can the app it relaunches, so its cleanup always landed
    /// one launch later, which is exactly the launch that may now be running this code. Drop the
    /// suffix and those files are orphaned for good. Removable once no supported version writes
    /// them, which is a version or two away, not now.
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
/// while the reader is a block on `Updater.stagingQueue`. `Synchronization.Mutex` would be the
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
