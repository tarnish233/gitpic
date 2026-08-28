import Foundation

extension SelfUpdate {

    public enum InstallFailure: Error, Equatable {
        /// The disk image could not be opened, or what is inside is not the app expected.
        case image(String)
        /// The new bundle could not be staged beside the old one. This is also the
        /// writability answer: staging is done by really creating the directory, so a refusal
        /// here is what "cannot install to this location" means.
        case staging(String)
        /// The handoff itself failed, while the app is still alive to say so.
        case handoff(String)
        /// The user asked to stop, between two of staging's steps. Its own case rather than a
        /// `.staging` detail because nothing went wrong: the sheet has no failure to report,
        /// no retry to offer and no disk to blame.
        case cancelled

        public var message: String {
            switch self {
            case .image(let detail): return "磁盘映像有问题：\(detail)"
            case .staging(let detail): return detail
            case .handoff(let detail): return "启动安装失败：\(detail)"
            case .cancelled: return "已取消更新，原来的 GitPic 没有改动。"
            }
        }
    }

    /// A new bundle copied into place beside the one it will replace, ready for the swap.
    public struct Staged: Equatable, Sendable {
        /// The bundle to move into `target`.
        public let bundle: URL
        /// The directory holding it. `rmdir`'d by the install script once the bundle has moved
        /// out of it; left for ``sweepLeftovers`` if anything is still inside.
        public let directory: URL
        /// What is being replaced.
        public let target: URL
        public let version: String
    }

    /// The process-wide registry. One install at a time, guaranteed twice over: `AppModel`
    /// refuses a second while `installTask` is non-`nil`, and `stage` only ever runs on
    /// `Updater.probeQueue`, which is serial.
    static let inFlightWork = InFlightWork()

    /// Undo whatever an install left in flight, because this process is about to leave.
    ///
    /// Called from ``Updater/quit(_:)`` — the single `exit(0)` — and deliberately not from
    /// `prepareToQuit()`, which has two callers that return instead of exiting.
    ///
    /// **What covers this, and what does not.** Each piece is tested for real in
    /// `SelfUpdateInstallTests`: an image is genuinely attached and this genuinely detaches it, a
    /// staging directory and a download are genuinely removed, the handover to the install script
    /// is exercised in both orders, and `quitDuringStagingLeavesNothing` runs `stage` on another
    /// thread and drains from underneath it. That last one is what caught the registrations
    /// needing to be able to answer "has a quit happened" rather than just record — see
    /// ``InFlightWork/hold(mount:since:)``.
    ///
    /// The whole path in one piece — a real install, a real 「退出 GitPic」 half way through it,
    /// nothing left behind — is `scripts/check-self-update.sh`'s 「退出 GitPic」 while an update
    /// is installing, which asserts the absence of the mount, the staging directory and the
    /// download. Two things about it stay true and are worth knowing before trusting it: the
    /// install is a 5 MB download plus a `ditto` of a small bundle, so the quit can land after
    /// the handoff rather than inside staging — the script says which of the two it got instead
    /// of claiming the harder one — and ⌘Q is not driven there at all, because `keystroke` needs
    /// the app frontmost and making it frontmost poisons the accessibility tree for the rest of
    /// the run. ⌘Q and the menu item share one selector and reach here through
    /// ``Updater/quitByUser()``, so the menu item is the half that can be asserted.
    public static func undoInFlightWork() {
        let abandoned = inFlightWork.drain()
        guard !abandoned.isEmpty else { return }
        var reclaimed: [String] = []

        // The child first: `exit(0)` reaps nothing, so a `ditto` mid-copy is reparented to
        // launchd and goes on recreating the directory removed just below. SIGKILL rather than
        // `terminate()`, the same escalation `ChildProcess` ends with.
        //
        // **No wait afterwards, on purpose.** `kill(pid, 0)` cannot tell a live process from a
        // zombie, so polling it would spin its whole bound on an already-dead child; and
        // `waitpid` here would race `Process`'s own reaper. SIGKILL cannot be caught or blocked,
        // so the child stops executing without another turn in user space — at worst one
        // in-flight write lands, and the retry below covers what that can cost.
        if let child = abandoned.child {
            kill(child.processIdentifier, SIGKILL)
            reclaimed.append("killed pid \(child.processIdentifier)")
        }

        // The staging directory before the mount, the order `stage`'s own `defer`s unwind in. The
        // disk image goes with them: it is a file rather than a directory, but it is the same
        // question — something this process made and nothing else will remove.
        for leftover in [abandoned.staging, abandoned.download].compactMap({ $0 }) {
            do {
                try FileManager.default.removeItem(at: leftover)
                reclaimed.append(leftover.lastPathComponent)
            } catch {
                // One retry, for the single write the SIGKILL above may not have beaten.
                Thread.sleep(forTimeInterval: 0.05)
                if (try? FileManager.default.removeItem(at: leftover)) != nil {
                    reclaimed.append(leftover.lastPathComponent)
                } else {
                    Diagnostics.log("quit: could not remove \(leftover.path):"
                                    + " \((error as NSError).localizedDescription)."
                                    + " Left for the launch sweep.")
                }
            }
        }

        if let mount = abandoned.mount {
            detachInBackground(mount)
            reclaimed.append("detaching \(mount.lastPathComponent)")
        }
        // Only when something was actually reclaimed: every failure above has already said so in
        // its own words, and a summary listing nothing would read as if it had worked.
        if !reclaimed.isEmpty {
            Diagnostics.log("quit: undid work an install left in flight — "
                            + reclaimed.joined(separator: ", "))
        }
    }

    /// Register the downloaded disk image, so a quit taken before the install finishes removes it.
    ///
    /// Public because the download's owner is `Updater.installAndRelaunch`, in the app target,
    /// while the registry is internal to this one. Three verbs is all the app needs; the type
    /// itself stays internal so nothing outside can invent a fourth.
    ///
    /// Unlike `stage`'s two registrations this has no epoch to answer against and does not need
    /// one: the image is removed by an explicit `removeItem` *and* a `defer` on every path the app
    /// stays alive for, so the registry is only the belt for the one path that runs neither — the
    /// `exit(0)`. A drain landing in between simply means there is nothing left to register.
    public static func holdDownload(_ url: URL) {
        _ = inFlightWork.hold(download: url, since: inFlightWork.generation)
    }

    /// The disk image is gone or is no longer this process's to remove.
    public static func releaseDownload(_ url: URL) { inFlightWork.release(download: url) }

    /// Take the staging directory out of the registry before handing it to the install script.
    ///
    /// `false` means a quit already claimed it and is deleting it — the caller must not hand off.
    /// See ``InFlightWork/claim(staging:)`` for what spawning the script anyway would cost.
    public static func claimStaged(_ url: URL) -> Bool { inFlightWork.claim(staging: url) }

    /// Detach a mount point without waiting for it, on the way out.
    ///
    /// **Fire and forget, and both halves of that are deliberate.**
    ///
    /// *Forget*, because ``detachMount(at:)`` is the wrong tool on this path even bounded down.
    /// It decides what to do from ``isMountPoint(_:)``, and an `hdiutil attach` this quit did not
    /// wait for may not have landed yet — `stage` records at its own `defer` that an attach the
    /// kernel has committed to survives `hdiutil` being killed. `detachMount` would then see no
    /// mount, fall through to `removeItem`, and *unlink the mount point out from under an image
    /// about to arrive on it*: still attached, invisible in Finder because of `-nobrowse`, and no
    /// longer reachable by the `gitpic-mount-` branch of `Updater.sweepStaleScripts`, which can
    /// only enumerate names that still exist. That is strictly worse than the leak this whole
    /// mechanism exists to stop, so the quit path does not call it. The retry loop below covers
    /// the same late arrival instead, and the launch sweep remains the backstop.
    ///
    /// *Fire*, because waiting buys nothing. `hdiutil detach` is bounded at 60 s per attempt in
    /// `detachMount`, and `ChildProcess` adds a 2 s `terminate` and a 1 s SIGKILL on top of any
    /// timeout — seconds of frozen main thread whose failure outcome is identical to not having
    /// waited. A detached child is reparented when this process exits and runs to completion,
    /// which is the same property ``handOff(staged:dryRun:)`` already depends on.
    ///
    /// The path is passed as `$1` and never interpolated into the script text, so no quoting
    /// question arises; both commands are absolute, so `PATH` does not either.
    private static func detachInBackground(_ mount: URL) {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", detachScript, "gitpic-detach", mount.path]
        do {
            try sh.run()
        } catch {
            Diagnostics.log("quit: could not spawn the detach for \(mount.path):"
                            + " \(error.localizedDescription). Left for the launch sweep.")
        }
    }

    /// Quoted once, so the test can assert on the same text that runs.
    static let detachScript = """
        for i in 1 2 3; do /usr/bin/hdiutil detach -force "$1" >/dev/null 2>&1 && break; \
        /bin/sleep 1; done
        /bin/rmdir "$1" 2>/dev/null || true
        """

    /// What an install has in flight, so that a quit can undo it.
    ///
    /// ``Updater/quit(_:)`` ends in `exit(0)`, which runs no `defer`. So everything
    /// ``stage(dmg:expectedVersion:replacing:isCancelled:)`` would have unwound — the attached
    /// image, the bundle-sized staging directory, the disk image — survives a quit taken while
    /// staging is running, invisibly and until a sweep on a launch a day later.
    ///
    /// **This was unreachable until 0.20.1, by accident.** Both user quits went through
    /// `NSApplication.terminate`, which AppKit refuses while any window has a sheet attached —
    /// and the install is started from a button inside the update sheet, which stays attached for
    /// the whole download-mount-copy sequence. So every quit during an install was silently
    /// refused. Routing those two affordances to a real `exit` fixed an app that could not be
    /// quit and, in the same move, made this reachable for the first time.
    ///
    /// Resources are registered as they are created and released as they are unwound, so on
    /// every ordinary path the registry is empty by the time `stage` has returned. The drain is
    /// therefore a no-op unless the process is leaving in the middle of something, which is
    /// exactly the shape wanted: nothing about the ordinary paths changes.
    ///
    /// **Released against the value that was registered, never blindly cleared.** The URLs all
    /// carry a fresh UUID, so the URL *is* the token — the same discipline as
    /// `gate === progressGate` in `AppModel`. It is what stops a release arriving after a drain
    /// from resurrecting a slot, and, more importantly, what makes ``claim(staging:)`` an atomic
    /// handover rather than a check followed by a hope.
    ///
    /// `NSLock` and `@unchecked Sendable` rather than an actor or a `Mutex`: every caller is
    /// non-`async` (`stage` on a serial `DispatchQueue`, the drain on the main actor), and
    /// `Synchronization.Mutex` is macOS 15 while this package targets macOS 14. The same shape as
    /// ``SessionGate``, and for the same reason — two paths reach the cleanup in either order and
    /// only one may act.
    final class InFlightWork: @unchecked Sendable {

        /// What a drain took, to be acted on outside the lock.
        struct Abandoned {
            var child: Process?
            var mount: URL?
            var staging: URL?
            var download: URL?

            var isEmpty: Bool {
                child == nil && mount == nil && staging == nil && download == nil
            }
        }

        private let lock = NSLock()
        private var epoch: UInt64 = 0
        private var child: Process?
        private var mount: URL?
        private var staging: URL?
        private var download: URL?

        /// How many drains have happened. A caller that captured this before it started can tell
        /// whether a quit has intervened.
        ///
        /// Counted rather than latched, because a latch would be permanent: the registry is
        /// process-wide, and `swift test` runs every suite in one process, so a sticky
        /// "we are leaving" flag set by one test would refuse every registration after it.
        var generation: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return epoch
        }

        /// The mount an install is currently working with, if any. For tests: it is how a test
        /// can tell that `stage` has reached the window this mechanism is about.
        var mountInFlight: URL? {
            lock.lock()
            defer { lock.unlock() }
            return mount
        }

        /// Register a resource, unless a quit has already drained since `epoch`.
        ///
        /// **The refusal is the point, and it is why these are not plain setters.** A drain takes
        /// what is registered *at that moment*; anything `stage` created afterwards would be
        /// registered into a table nobody will read again, and then leaked by the `exit(0)` a
        /// moment later. That window is not theoretical — `quit` does a blocking
        /// `UserDefaults.synchronize()` between the drain and the exit, which is easily long
        /// enough for `stage` to create its staging directory. Measured by
        /// `quitDuringStagingLeavesNothing`, which failed exactly this way when these were plain
        /// setters: the drain took the mount, `stage` went on to stage a whole bundle, and nothing
        /// ever removed it.
        ///
        /// So registering and asking "has a quit happened" are one atomic step, and a `false`
        /// answer means the caller must undo what it just made and stop.
        func hold(mount url: URL, since epoch: UInt64) -> Bool {
            claimSlot(epoch) { self.mount = url }
        }

        func hold(staging url: URL, since epoch: UInt64) -> Bool {
            claimSlot(epoch) { self.staging = url }
        }

        func hold(download url: URL, since epoch: UInt64) -> Bool {
            claimSlot(epoch) { self.download = url }
        }

        func hold(child process: Process, since epoch: UInt64) -> Bool {
            claimSlot(epoch) { self.child = process }
        }

        func release(mount url: URL) { under { if self.mount == url { self.mount = nil } } }
        func release(download url: URL) {
            under { if self.download == url { self.download = nil } }
        }

        /// Take the staging directory out of the registry, and say whether it was still there.
        ///
        /// Both the failure unwind and the handover to the install script go through this. The
        /// answer matters only to the handover: `false` means a drain has already taken the
        /// directory and is deleting it, so the caller must **not** spawn the script. Spawning it
        /// anyway is the one way this mechanism could make a *successful* install fail — the
        /// script would find no staged bundle, log that, and its `trap reopen EXIT` would put the
        /// old bundle back, turning every quit that lost this race into a silent rollback.
        func claim(staging url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard staging == url else { return false }
            staging = nil
            return true
        }

        /// Clear the child slot whatever is in it.
        ///
        /// Not compared, unlike the rest, because `ChildProcess.run` reports the live child
        /// through an escaping `onSpawn` and hands nothing back afterwards to compare against.
        /// Safe on the strength of `stage` being strictly sequential — one child at a time — and
        /// the cost if that ever stopped holding is that a quit fails to kill a child, which is
        /// what happened before any of this existed.
        func releaseAnyChild() { under { self.child = nil } }

        /// Take everything, under the lock, and leave the registry empty.
        ///
        /// Snapshot-and-clear rather than acting slot by slot while holding the lock: the drain
        /// goes on to spawn and delete, and `stage`'s unwind must not be stalled behind that.
        /// ``SessionGate/cancel()`` takes its resource out the same way and for the same reason.
        func drain() -> Abandoned {
            lock.lock()
            defer { lock.unlock() }
            let taken = Abandoned(child: child, mount: mount, staging: staging,
                                  download: download)
            (child, mount, staging, download) = (nil, nil, nil, nil)
            epoch += 1
            return taken
        }

        private func claimSlot(_ expected: UInt64, _ body: () -> Void) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard epoch == expected else { return false }
            body()
            return true
        }

        private func under(_ body: () -> Void) {
            lock.lock()
            body()
            lock.unlock()
        }
    }

    /// Mount `dmg`, check what is inside it, and copy it in beside `target`.
    ///
    /// Blocking — it spawns `hdiutil`, `ditto`, `xattr` and `codesign`. Call it off the main
    /// actor. Everything it does is undoable: on any failure the image is detached and the
    /// staging directory removed, and `target` is untouched throughout.
    ///
    /// **The staging directory is deliberately created inside `target`'s parent.** Two
    /// reasons, both load-bearing. It puts the copy on the same filesystem, so the swap is a
    /// rename and not a copy. And creating it *is* the permission check: `rename(2)` and
    /// `mkdir(2)` both need write permission on that same parent directory, so a staging
    /// directory that could be created is a swap that can happen — no guessing from
    /// `isWritableFile`.
    ///
    /// - Parameter isCancelled: asked between the steps, and only there: each one is a child
    ///   process this cannot interrupt from outside without killing it mid-write. That is a
    ///   real bound on how fast 取消 lands, and a small one — `ditto` of the shipped bundle is
    ///   the long step and it is a few megabytes on the same filesystem. A cancel unwinds
    ///   exactly like a failure, through the same two `defer`s: image detached, staging
    ///   directory gone, installed bundle untouched.
    public static func stage(
        dmg: VerifiedImage,
        expectedVersion: String,
        replacing target: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Staged {
        try stopIfCancelled(isCancelled)
        // Captured before anything exists to clean up, so that every registration below can ask
        // one question atomically: "has a quit drained since I started?" A `false` from any of
        // them means this process is on its way out and nothing new may be left behind.
        let epoch = inFlightWork.generation
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-mount-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        // Registered before the attach for the same reason the detach below is installed before
        // it, and released inside that same `defer` rather than on the way out of the success
        // path: `defer`s run *after* the last statement, so releasing it at `staged = true` would
        // leave a window in which a quit could see no mount to detach.
        guard inFlightWork.hold(mount: mount, since: epoch) else {
            try? FileManager.default.removeItem(at: mount)
            throw InstallFailure.cancelled
        }
        // The detach is installed before the attach — and before the identity check below — on
        // purpose. A timed-out `attach` is not a failed one: `ChildProcess` terminates and then
        // `SIGKILL`s the `hdiutil` it spawned, and the attach the kernel had already committed
        // to survives that — so the one path that must not skip the detach is the one that
        // failed. `detachMount` is a no-op plus an `rmdir` when nothing is mounted, so it costs
        // nothing on the ordinary refusals, and it is what removes the directory just created
        // when this returns before ever attaching.
        defer {
            detachMount(at: mount)
            inFlightWork.release(mount: mount)
        }
        // The digest was taken through one descriptor; `hdiutil` is about to open the path
        // again. Between those two opens sits a `Task.checkCancellation` and a hop onto
        // `probeQueue`, which is serial and shared with a 20 s `brew list --cask` — so the
        // window is not instants, it is tens of seconds. Without this the digest would prove
        // something about bytes that are never installed.
        //
        // Placed as late as possible, immediately before the attach, because everything this
        // rules out is a race: the less code between the check and the use, the less there is
        // to race with.
        try confirmUnchanged(dmg)
        // `-mountpoint` rather than letting it land in `/Volumes`: the name there is chosen
        // from the volume label and gets a numeric suffix when it collides, so the path this
        // reads from would be decided by whatever else happens to be mounted.
        //
        // **Retried, because "attach failed" is not always a fact about the image.** Measured on
        // a GitHub `macos-latest` runner: seventeen seconds into a suite that attaches and
        // detaches repeatedly, every remaining `hdiutil attach` started returning
        // `hdiutil: attach failed - Resource temporarily unavailable` within 0.07 s and went on
        // doing so for the rest of the run. That is the kernel declining one more attach, not a
        // corrupt download — and the user on a machine in that state was shown
        // 「磁盘映像有问题：hdiutil: attach failed - Resource temporarily unavailable」 and left
        // with a failed update and nothing to do about it.
        //
        // **Only a fast non-zero exit is retried, never a timeout.** A timed-out attach may have
        // landed anyway — the `defer` above is installed before this line for that exact reason —
        // so a second attach could mount the same image twice. `stderr` is deliberately *not*
        // pattern-matched to decide what is transient: that spelling is one of several the kernel
        // and `hdiutil` can produce, and a list of them is a list to get wrong. The attempt count
        // is what bounds the cost instead, so an image that really is unreadable is refused about
        // two seconds later than it used to be. Same three-attempts-one-second shape as
        // ``detachMount(at:)``, which retries for the mirror-image reason.
        var attach: ProcessOutcome?
        var attempt = 0
        while attempt < 3 {
            attempt += 1
            try stopIfCancelled(isCancelled)
            attach = try? ChildProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                args: ["attach", dmg.url.path, "-nobrowse", "-readonly",
                       "-mountpoint", mount.path],
                timeout: 120)
            if let attach, attach.status == 0, !attach.timedOut { break }
            // A timeout is the one failure that must not be tried again.
            if attach?.timedOut == true { break }
            if attempt < 3 {
                Diagnostics.log("update: hdiutil attach failed, retrying"
                                + " (\(attempt)/3): \(reason(accepted: false, out: attach))")
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard let attach, attach.status == 0, !attach.timedOut else {
            let detail = attach?.timedOut == true
                ? "打开磁盘映像超时"
                : String(decoding: attach?.stderr ?? Data(), as: UTF8.self)
                    .split(separator: "\n").first.map(String.init) ?? "无法打开"
            throw InstallFailure.image(detail)
        }
        try stopIfCancelled(isCancelled)

        let source = mount.appendingPathComponent("GitPic.app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw InstallFailure.image("映像里没有 GitPic.app")
        }
        // The version inside has to be the one that was asked for. Without this, a
        // mismatched or renamed asset installs a version nothing ever checked — and the
        // digest only proves the bytes are the ones GitHub published, not which version
        // they are.
        let inside = bundleVersion(of: source)
        guard inside == expectedVersion else {
            throw InstallFailure.image(
                "映像里是 \(inside ?? "未知版本")，不是预期的 \(expectedVersion)")
        }
        try stopIfCancelled(isCancelled)

        let directory = target.deletingLastPathComponent()
            .appendingPathComponent(".GitPic-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory,
                                                   withIntermediateDirectories: false)
        } catch {
            // The permission answer. Worded for the four real causes rather than as an errno,
            // because they need different things from the user.
            throw InstallFailure.staging(
                "无法在 \(target.deletingLastPathComponent().path) 里写入，"
                    + "所以不能在这里替换 GitPic。"
                    + "常见原因：这个目录需要管理员权限、被 MDM 收紧过，"
                    + "或 GitPic.app 带了不可变标志。"
                    + "可以改为把 GitPic 装在 ~/Applications，那里不需要额外权限。")
        }
        // Registered as soon as it exists, and — unlike the mount — *not* released on the success
        // path here. A staged bundle outlives `stage`: the caller hands it to the install script,
        // and only that handover ends this function's claim on it. See
        // ``InFlightWork/claim(staging:)``.
        //
        // A refusal here is a quit that drained while the directory was being created. Removing
        // it and stopping is the whole reason the registration answers rather than just records:
        // the drain has already been and gone, so anything left now is left for good.
        guard inFlightWork.hold(staging: directory, since: epoch) else {
            try? FileManager.default.removeItem(at: directory)
            throw InstallFailure.cancelled
        }
        var staged = false
        defer {
            if !staged {
                try? FileManager.default.removeItem(at: directory)
                _ = inFlightWork.claim(staging: directory)
            }
        }

        let bundle = directory.appendingPathComponent("GitPic.app")
        // `ditto`, not `cp -R`: `man ditto` says it preserves resource forks, extended
        // attributes and ACLs, and an ad-hoc signature lives in extended attributes — `cp -R`
        // would break it. `--noqtn` because the same page says quarantine bits are preserved
        // too, and a quarantined ad-hoc bundle is one Gatekeeper refuses outright.
        let copy: ProcessOutcome?
        do {
            copy = try runWritingStep(
                "/usr/bin/ditto", ["--noqtn", source.path, bundle.path],
                timeout: 300, epoch: epoch)
        } catch InstallFailure.cancelled {
            throw InstallFailure.cancelled
        } catch {
            copy = nil
        }
        guard let copy, copy.status == 0, !copy.timedOut else {
            throw InstallFailure.staging("复制新版本失败："
                + (copy?.timedOut == true ? "超时" : "ditto 退出码 \(copy?.status ?? -1)"))
        }
        try stopIfCancelled(isCancelled)
        // Belt and braces over `--noqtn`: a nested file could carry the attribute even when
        // the top level does not, and one quarantined item inside the bundle is enough.
        // Ignored on failure — there is usually nothing to remove, and `xattr` exits non-zero
        // when there is not. A quit that drained while `xattr` was spawning is not a
        // failure of that kind: the child is already dead and this must stop.
        do {
            _ = try runWritingStep(
                "/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path],
                timeout: 60, epoch: epoch)
        } catch InstallFailure.cancelled {
            throw InstallFailure.cancelled
        } catch {
            // Ignored: there is usually nothing to remove.
        }

        // Verified *here*, on the copy, and last — after `ditto` made it and after `xattr`
        // mutated it. This used to run against the read-only mount thirty lines above, where
        // it could only re-prove what `SelfUpdate.download` had already proven by hashing the
        // whole image against GitHub's digest, and where the bundle that actually gets
        // renamed into place did not exist yet. What it adds on the copy is an
        // internal-consistency check of the thing that ships: a `ditto` that exited 0 having
        // dropped an extended attribute, or a quarantine removal that damaged the seal, is
        // caught before the swap rather than by Gatekeeper after it.
        //
        // It proves **nothing** about origin — it passes for anything anyone ad-hoc signs,
        // which is what GitPic's own releases are. The image's SHA-256 is the only
        // authentication in this whole path.
        guard signatureIsIntact(at: bundle) else {
            throw InstallFailure.staging(
                "新版本复制后签名校验失败，可能是这次复制出了问题，"
                    + "也可能是这个发布包本身有问题。已放弃安装，原来的 GitPic 没有改动。")
        }
        try stopIfCancelled(isCancelled)

        staged = true
        return Staged(bundle: bundle, directory: directory, target: target,
                      version: expectedVersion)
    }

    /// `throw`s ``InstallFailure/cancelled`` when the caller says the user asked to stop.
    ///
    /// A function rather than five copies of the same `if`, so every step's check reads the
    /// same and none of them can quietly leave out the throw.
    private static func stopIfCancelled(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw InstallFailure.cancelled }
    }

    /// `ChildProcess.run` for a staging step that *writes into* the staging directory.
    ///
    /// The only thing this adds is registering the live child, so a quit can SIGKILL it before
    /// deleting what it is writing into: `exit(0)` reaps nothing, so a `ditto` half way through a
    /// copy is reparented to launchd and goes on recreating the directory the quit just removed.
    ///
    /// Used for `ditto` and `xattr`, and deliberately for neither of the other two spawns in
    /// `stage`. `hdiutil attach` must **not** be killed — ``undoInFlightWork()`` and
    /// ``detachInBackground(_:)`` carry why at length: an attach the kernel has committed to
    /// outlives the process that asked for it, and racing it produces a mount nothing can find
    /// again. `codesign` only reads, so deleting the directory under it is already safe and it
    /// exits on its own once this process is gone.
    ///
    /// `epoch` is the one captured at the start of ``stage``: a `false` from
    /// ``holdWritingChild(_:since:)`` means a quit drained while this child was spawning, so
    /// the process is already SIGKILLed and this step is cancelled rather than a failed copy.
    private static func runWritingStep(
        _ executable: String, _ args: [String], timeout: TimeInterval, epoch: UInt64
    ) throws -> ProcessOutcome {
        var refused = false
        defer { inFlightWork.releaseAnyChild() }
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: executable),
            args: args,
            timeout: timeout,
            onSpawn: { refused = !holdWritingChild($0, since: epoch) })
        if refused { throw InstallFailure.cancelled }
        return out
    }

    /// Register `process` as the writing child, or SIGKILL it if a quit already drained.
    ///
    /// The two outcomes have to be one function: a `false` from
    /// ``InFlightWork/hold(child:since:)`` means the registry will never see this process, so
    /// ``undoInFlightWork()`` will never kill it. Returning without killing is the leak
    /// `hold(child:)` as a plain setter used to be — a `ditto` spawned in the
    /// `UserDefaults.synchronize()` window between drain and `exit(0)` was reparented to
    /// launchd and recreated the staging directory just deleted.
    ///
    /// Internal so the refusal-kills-the-child half is testable without going through
    /// `ChildProcess.run`.
    static func holdWritingChild(_ process: Process, since epoch: UInt64) -> Bool {
        if inFlightWork.hold(child: process, since: epoch) { return true }
        kill(process.processIdentifier, SIGKILL)
        return false
    }

    /// `codesign --verify --deep --strict` on a bundle, as a yes or no.
    ///
    /// Split out because it is the one check whose *subject* was the bug — it ran on the
    /// mounted image instead of the copy — and a named function makes the subject the
    /// argument at the call site. It is also directly testable without building an image.
    static func signatureIsIntact(at bundle: URL) -> Bool {
        let signature = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            args: ["--verify", "--deep", "--strict", bundle.path],
            timeout: 120)
        guard let signature else { return false }
        return signature.status == 0 && !signature.timedOut
    }

    /// Detach the disk image mounted at `mount`, then remove the mount point directory.
    /// Returns whether the volume is gone.
    ///
    /// **Nothing is deleted while the volume is still mounted.**
    /// `FileManager.removeItem` on a live mount point does not unlink a directory: it walks
    /// the mounted volume and tries to delete the image's contents one at a time, on a
    /// read-only filesystem. A probe doing exactly that died at exit 137.
    ///
    /// Measured against a mount held by one open descriptor, which is what `mds` and
    /// QuickLook routinely do to a just-attached image:
    ///
    /// - `hdiutil detach <mountpoint>` exits **16**, stderr `couldn't unmount "disk7" -
    ///   Resource busy`. The old code dropped that status on the floor with `_ = try?` and
    ///   logged nothing, so three failed installs left three images attached — invisible in
    ///   Finder because of `-nobrowse`, and unfixable by the launch sweep, which can only try
    ///   `removeItem` and cannot unlink a mount point.
    /// - `hdiutil detach <mountpoint> -force` on the *same* busy mount exits **0**,
    ///   `"disk6" ejected.`
    /// - after either success the mount point directory we created is still there and empty,
    ///   so removing it is a plain `rmdir`.
    ///
    /// Hence: ask politely twice, a second apart, because the transient holder usually lets
    /// go; then force, because an image nobody detaches is worse than an unmount over
    /// someone else's open file — the volume is read-only and holds nothing of ours to flush.
    /// `-quiet` is deliberately not passed: its only effect here would be to throw away the
    /// stderr line that says which disk refused and why.
    ///
    /// **What decides the outcome is the mount table, not the exit code.** The first version of
    /// this trusted `hdiutil`'s status and leaked a mount point directory on *every* staging
    /// failure — thirteen of them after one test run, which is how it was caught. The cause was
    /// not `hdiutil`: it was asking `URL.resourceValues(forKeys: [.volumeIdentifierKey])` twice
    /// on the same `URL`, which answered the second time from a cache and reported a volume
    /// that had already gone (see ``isMountPoint``). Measured after fixing that, over eleven
    /// detaches in one run: the volume was always already gone on the first look, zero polls.
    /// The wait below therefore costs nothing in practice and stays anyway, because the thing
    /// it guards is a `removeItem` that walks a mounted read-only volume when it is wrong.
    @discardableResult
    public static func detachMount(at mount: URL) -> Bool {
        var attempt = 0
        while isMountPoint(mount), attempt < 3 {
            attempt += 1
            let forced = attempt == 3
            let out = try? ChildProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                args: ["detach", mount.path] + (forced ? ["-force"] : []),
                timeout: 60)
            let accepted = out.map { $0.status == 0 && !$0.timedOut } ?? false
            if accepted, waitUntilUnmounted(mount) { break }
            if forced {
                Diagnostics.log("update: could not detach \(mount.path) even with -force:"
                                + " \(reason(accepted: accepted, out: out))."
                                + " The image is still attached; leaving the mount point in"
                                + " place, because removing it would walk the mounted volume"
                                + " instead of unlinking a directory.")
            } else {
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard !isMountPoint(mount) else { return false }
        try? FileManager.default.removeItem(at: mount)
        return true
    }

    /// Why a detach did not take, in one clause, for the log.
    private static func reason(accepted: Bool, out: ProcessOutcome?) -> String {
        if accepted { return "hdiutil accepted the eject but the volume is still mounted" }
        if out?.timedOut == true { return "hdiutil timed out" }
        let stderr = String(decoding: out?.stderr ?? Data(), as: UTF8.self)
        return stderr.split(separator: "\n").first.map(String.init)
            ?? "hdiutil exit \(out?.status ?? -1)"
    }

    /// Wait up to two seconds for `mount` to stop being a mount point, and say whether it did.
    ///
    /// Measured, it has never needed a single poll: `hdiutil detach` has finished unmounting by
    /// the time it exits. The bound exists because the alternative to observing the state is
    /// believing an exit code, and being wrong that way means deleting into a mounted volume.
    private static func waitUntilUnmounted(_ mount: URL) -> Bool {
        for _ in 0..<20 {
            if !isMountPoint(mount) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !isMountPoint(mount)
    }

    /// Whether `url` is still some volume's mount point.
    ///
    /// `lstat(2)` and a device-number comparison with the parent directory, which is the
    /// textbook test and, more to the point here, the only one that cannot answer from a cache.
    /// The first version asked `URL.resourceValues(forKeys: [.volumeIdentifierKey])` on the
    /// same `URL` the caller had already asked with, and kept getting the *image's* volume
    /// identifier after the unmount had completed — so the wait below timed out, two more
    /// detaches ran against a path that was no longer mounted, and every following
    /// `hdiutil attach` of that image failed with `资源暂时不可用` for the rest of the test
    /// run. A path that does not exist answers `false`, which is the answer that sends the
    /// caller straight to the `rmdir`.
    private static func isMountPoint(_ url: URL) -> Bool {
        var here = stat(), parent = stat()
        guard lstat(url.path, &here) == 0,
              lstat(url.deletingLastPathComponent().path, &parent) == 0
        else { return false }
        return here.st_dev != parent.st_dev
    }

    /// `CFBundleShortVersionString` out of a bundle's `Info.plist`.
    static func bundleVersion(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let any = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dict = any as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// The script that swaps the bundles once this process is gone.
    ///
    /// Generated as text so it can be read after the fact — the log names the path — and so
    /// its shape can be asserted in a test, which is the only way anything about it is checked
    /// before it runs for real.
    ///
    /// Eight things here are the direct result of finding them wrong first:
    ///
    /// 1. **The backup name carries a UUID and its absence is asserted.** `mv a a.old` when
    ///    `a.old` already exists does not fail — it moves `a` *inside* it, giving
    ///    `a.old/a`. Reproduced. With a fixed name, a second attempt would then "roll back" a
    ///    wrapper directory that is not a bundle and delete the real app with the leftovers.
    /// 2. **Nothing in this script deletes the rollback material.** It used to reopen the app
    ///    and then `rm -rf` the backup, on the theory that a reopen proves the new bundle
    ///    works. It proves much less than that. Measured: `open -a` exits 0 when
    ///    LaunchServices *accepts* the request — a build whose `main()` calls `abort()`
    ///    immediately still gives exit 0 — and the crashed process is *still listed by
    ///    `pgrep` two seconds later*, because macOS holds a crashed process while ReportCrash
    ///    samples it, disappearing a few seconds after that. So no poll this script can
    ///    afford distinguishes "launched" from "launched and died". The one process entitled
    ///    to delete the old bundle is a *later launch of the app itself*
    ///    (``sweepLeftovers``), which by existing proves the new version starts. This also
    ///    removes the race the old ordering had with that sweep: two deleters, one of them
    ///    the app the script had just reopened.
    /// 3. **Only the *newly installed* bundle running counts as a reopen.** This is the second
    ///    false witness found in this one function, and the reason `confirm` reads two things
    ///    about a process instead of counting them. The first was `open -a`'s exit status
    ///    (point 2). Its replacement — "some process is running at `$target`" — failed the same
    ///    way in the shipped 0.20.0, measured twice on a real install: the app did not exit
    ///    when asked, renaming the parent directory of a running executable does not kill it,
    ///    `open -a "$target"` therefore found a process with the same bundle identifier already
    ///    registered and **activated that surviving old instance**, and `ps -Awwo comm=` still
    ///    printed `$target` for it, because `ps` shows the path a process was launched from and
    ///    not the inode it is executing. So the evidence was satisfied by the very process
    ///    whose failure to quit was the bug. `lsof` does answer the right question — the same
    ///    pid's `txt` image had followed the rename to `…/.GitPic-old-<uuid>/Contents/MacOS/`
    ///    `GitPic` — so `isnew` requires a pid that is *not* the one this script waited on and
    ///    an executing image *inside* `$target`. There is deliberately no separate "not under
    ///    `$backup`" test: `$backup` is a sibling of `$target`, so an image under it cannot
    ///    match `$target/*` at all.
    /// 4. **Every outcome names itself in the log, and there are five of them**: the new
    ///    version confirmed running; the old process never exited so the swap happened
    ///    underneath it; `open` accepted and nothing executing that bundle appeared; `open`
    ///    refused; and a confirmation on a path where the swap did *not* happen, which is the
    ///    bundle that was already there and not `$version`. `reopen` also runs from the trap
    ///    after a rollback, so that last distinction is the difference between a true line and
    ///    a false one. `saw` prints the candidates and their real images on every outcome that
    ///    is not a confirmation, because that list is the evidence the branch was chosen from.
    /// 5. **The reopen is in a `trap … EXIT`**, not on the success path. GitPic is
    ///    `.accessory`: once it has quit there is no Dock icon and no menu-bar icon, so a
    ///    script that dies before reopening costs the user the entire app.
    /// 6. **`PATH` is set explicitly.** Not a root-safety measure — nothing here runs
    ///    elevated — but the app's own PATH has a Homebrew prefix prepended, and a swap script
    ///    has no business resolving `mv` through a user-writable directory. `lsof` lives in
    ///    `/usr/sbin`, which is already on it.
    /// 7. **`launch`, `candidates` and `image` are one-liners.** Everything this script does to
    ///    the outside world beyond `mv` goes through them, so a test can replace exactly those
    ///    three lines: a test must never really launch an application, and every outcome above
    ///    has to be reachable from one. `image` is the line the tests usually leave alone —
    ///    what it answers is the whole fix, so `lsof` runs for real there against real
    ///    processes. `candidates` is stubbed because it cannot be deterministic: measured,
    ///    `pgrep -x GitPic` on this machine lists the developer's own running copy too.
    /// 8. **An expired wait is logged as the anomaly it is.** Proceeding is still right — a
    ///    quit that never happens must not cost the user the update — but it passed in silence,
    ///    so the log of the update that failed this way read like the log of one that worked.
    ///
    /// Every interpolation goes through `q()`, including `staged.version`. It is constrained
    /// today — `stage` only ever passes the version it matched against the image's
    /// `Info.plist` — but the value is written into `echo` lines that end up in a shell, and
    /// "safe because of a check thirty lines away in another function" is not a property worth
    /// depending on for the sake of two quotes. The exception is `pid`, an `Int32` that cannot
    /// carry a quote; `kill -0 \(pid)` is the form
    /// `SelfUpdateRouteTests.scriptIsValidAndOrdered` pins.
    static func installScript(staged: Staged, pid: Int32, log: URL) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // Adjacent to the target and on its filesystem, so the rename cannot cross devices.
        let apps = staged.target.deletingLastPathComponent()
        let backup = apps.appendingPathComponent(".GitPic-old-\(UUID().uuidString)").path

        return """
        #!/bin/bash
        # Written by GitPic's in-app installer. Safe to delete.
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        exec >>\(q(log.path)) 2>&1

        target=\(q(staged.target.path))
        staged=\(q(staged.bundle.path))
        backup=\(q(backup))
        stagedir=\(q(staged.directory.path))
        version=\(q(staged.version))
        # $target's parent — the one directory both renames below happen in, and $backup's
        # parent too — and $target's last component, which the next two lines need on its own.
        apps=\(q(apps.path))
        leaf=\(q(staged.target.lastPathComponent))
        # What a running process's executing image gets compared against. `lsof` names the
        # *physical* path of the file a process is executing, so this has to be physical too:
        # measured, a process started from /tmp/x/GitPic.app is reported at
        # /private/tmp/x/GitPic.app, and $TMPDIR — where the tests build their fixtures — is
        # /var/folders/... reached through the /var symlink.
        #
        # Only the parent is resolved, and the leaf is kept exactly as written: after the swap
        # the leaf is a real directory `mv` has just made, so resolving it would follow a
        # symlinked GitPic.app — a brew cask's, pointing into the Caskroom — to a path the new
        # bundle will never be at. Two bash builtins rather than doing it in the generator,
        # because Foundation answers the wrong question: measured,
        # `URL.resolvingSymlinksInPath()` returns /tmp for /private/tmp, the *logical* path and
        # the opposite of what lsof prints, and leaves /var/folders untouched.
        realapps=$(cd "$apps" 2>/dev/null && pwd -P) || realapps=$apps
        realtarget="$realapps/$leaf"
        # Set by exactly one line, a second `mv` that succeeded, and read by `reopen`: a process
        # executing something inside $target is the new version only if the swap happened.
        # `reopen` also runs from the trap after a rollback, where $target is the old bundle.
        installed=0
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) install $version ==="

        # The three things this script does to the world outside its own directory, one line
        # each so a test can replace them. See point 7 in the doc comment.
        launch() { open -a "$1"; }
        candidates() { pgrep -x GitPic 2>/dev/null; }
        image() { lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n '/^n[/]/{s/^n//;p;q;}'; }

        # Is pid $1, executing image $2, the bundle this script just installed? See point 3:
        # both halves are here because both halves were false witnesses in a shipped release.
        #
        # `-a` in `image` is load-bearing and easy to lose: lsof ORs its selectors, so
        # `lsof -p "$1" -d txt` means "that pid, or anything with a txt fd" and dumps every
        # process on the machine. Measured. The first `n` line of what comes back is the main
        # executable — measured on a real GitPic and on a stand-in binary, where the second was
        # /usr/lib/dyld one time and a logging cache the other, so only the first is relied on.
        isnew() {
          [ "$1" != \(pid) ] || return 1
          case "$2" in "$realtarget"/*) return 0 ;; esac
          return 1
        }

        # What satisfied `isnew`, for the log.
        newpid=
        newimage=

        # Ask, do not assume, and ask about the new bundle specifically. Bounded at ten
        # seconds: this is the log's evidence, never a licence to delete anything, so being
        # wrong here costs a misleading line and nothing else.
        confirm() {
          n=0
          while [ "$n" -lt 20 ]; do
            for p in $(candidates); do
              i=$(image "$p")
              if isnew "$p" "$i"; then
                newpid=$p
                newimage=$i
                return 0
              fi
            done
            n=$((n + 1))
            sleep 0.5
          done
          return 1
        }

        # Every GitPic process and the image it is really executing. Printed on every outcome
        # that is not a confirmation, because that list is what the branch was decided from —
        # and because a listing like it, taken from `ps`, is what made the shipped failure read
        # as a success.
        saw() {
          found=0
          for p in $(candidates); do
            found=1
            echo "  pid $p is executing $(image "$p")"
          done
          [ "$found" -eq 1 ] || echo "  (no process named GitPic is running)"
        }

        # A confirmation, said once for both call sites. $1 is how it was found.
        confirmed() {
          echo "reopened $target ($1), pid $newpid"
          if [ "$installed" -eq 1 ]; then
            echo "$version is running: its executing image is $newimage"
          else
            echo "the update did not happen, so this is the bundle that was already there and"
            echo "not $version; its executing image is $newimage"
          fi
        }

        # Whatever happens below, GitPic comes back. It is .accessory, so once it has quit
        # there is no icon anywhere to click — a script that dies before this has taken the
        # app away with it.
        reopen() {
          launch "$target"
          rc=$?
          if confirm; then
            confirmed "by path"
            return 0
          fi
          # **The case that shipped in 0.20.0**, measured twice on a real install: the app was
          # asked to quit, closed its windows and stayed in its run loop; the renames went
          # ahead underneath it; `open -a "$target"` then activated that same instance, because
          # it is what LaunchServices has registered for this bundle identifier. There is
          # nothing further to try — the GitPic the user can see is already up, so a second
          # `launch` would activate it again and spend another ten seconds failing to confirm
          # it. Not SIGKILLed either: it may be mid-upload, and ending a process nobody asked
          # to end is not this script's business. The app quitting when told to is.
          if kill -0 \(pid) 2>/dev/null; then
            echo "NOT reopened: pid \(pid) never exited, so $version was installed underneath it"
            echo "that surviving process is the GitPic in the menu bar, still executing the"
            echo "bundle it started from, which this script renamed to $backup"
            echo "nothing is lost: $version is installed at $target — quit the running GitPic"
            echo "and start it again, and the update is done"
            saw
            return 1
          fi
          if [ "$rc" -eq 0 ]; then
            echo "reopen: LaunchServices accepted $target but no process executing that bundle"
            echo "appeared within 10s — the new bundle may not be launchable"
          else
            echo "reopen: open -a $target failed (status $rc)"
          fi
          saw
          # By name, as a last resort, and worth having even though it can resolve to a
          # leftover copy rather than the installed bundle: an old GitPic in the menu bar
          # beats no GitPic at all, and nothing below deletes what it finds. It has to clear
          # the same bar to count, because LaunchServices holds registrations for copies under
          # `.GitPic-update-*` too, seen in `lsregister -dump`.
          launch GitPic
          if [ $? -eq 0 ] && confirm; then
            confirmed "by name, not by path"
            return 0
          fi
          echo "could not reopen GitPic from $target — open it by hand"
          saw
          return 1
        }
        trap reopen EXIT

        # The bundle must not be renamed under a running process, and not because the rename
        # would refuse — measured, `mv` on the parent directory of a running executable exits 0
        # and the kernel lets it through, and a self-contained probe binary went on running
        # from the moved directory to completion. It is the app that pays: GitPic loads
        # frameworks and resources out of its bundle by path after launch, so the real one dies
        # with `Killed: 9` when it next needs something that is no longer where it was mapped
        # from. That is the whole reason the app quits first and this script runs detached.
        #
        # Bounded, and the swap is attempted anyway once the bound passes. What the renames
        # *are* is atomic and local — one filesystem, no half-copied state, undoable by a
        # second rename, which is what makes the rollback below a real option. That is a
        # different property from refusing while the bundle is busy, and it is the one that
        # holds.
        for _ in $(seq 1 120); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.5
        done
        # An expired bound is not a neutral event, and this is where the shipped bug starts: it
        # means GitPic was asked to quit and did not. Measured twice on a real 0.20.0 install.
        # It used to pass in silence, so the log of an update that failed this way was
        # indistinguishable from the log of one that worked.
        if kill -0 \(pid) 2>/dev/null; then
          echo "ANOMALY: pid \(pid) is still running after 60s — GitPic did not quit when asked"
          echo "installing anyway: abandoning the update here would cost the user the new"
          echo "version for nothing, and both renames are atomic, local and undoable whether or"
          echo "not it is running. What it does cost is the relaunch — see the reopen below."
        fi

        if [ ! -d "$staged" ]; then
          echo "the staged bundle is gone, nothing to install"
          exit 1
        fi
        # `mv a b` where b exists as a directory moves a *into* b. Asserting the name is free
        # and the alternative is a rollback that restores a wrapper directory.
        if [ -e "$backup" ]; then
          echo "refusing to install: $backup already exists"
          exit 1
        fi

        if ! mv "$target" "$backup"; then
          echo "could not move the old bundle aside — an immutable flag (schg/uchg), an ACL,"
          echo "or no write permission on the parent directory"
          exit 1
        fi
        if ! mv "$staged" "$target"; then
          echo "could not put the new bundle in place; rolling back"
          if mv "$backup" "$target"; then
            echo "rolled back to the old bundle at $target"
          else
            echo "ROLLBACK FAILED — the old GitPic is at $backup"
            echo "to restore it by hand: mv $backup $target"
          fi
          exit 1
        fi
        installed=1
        echo "installed $version"

        # The backup stays. See point 2: nothing this script can observe proves the new
        # bundle works, so the delete belongs to a later launch of the app.
        echo "kept for rollback: $backup"
        # Moves the new bundle aside rather than deleting it: advice that destroys something is
        # worse advice, and this way a user who tries it can change their mind again.
        echo "to go back by hand: mv $target $target.new && mv $backup $target"
        reopen
        trap - EXIT
        # `rmdir`, and deliberately not a recursive delete: the staging directory is empty now —
        # its bundle is the one that just moved into place — and `rmdir` refuses a directory
        # with anything in it. So in the one case where the contents still matter, a second
        # `mv` that failed and left the new bundle sitting there, the tidy-up fails harmlessly
        # instead of deleting it. Nothing in this script recurses; `scriptIsValidAndOrdered`
        # asserts that by searching for the string, so this comment does not spell it.
        rmdir "$stagedir" 2>/dev/null || echo "not empty, left for the sweep: $stagedir"
        exit 0
        """
    }

    /// Write the swap script and start it detached. The caller quits immediately after.
    ///
    /// Returns the script's path, which the log names so a failed install can be read
    /// afterwards. Throws only if the handoff itself failed — in which case this process is
    /// still alive and owes the user a message.
    ///
    /// `dryRun` writes the script and stops, honouring `GITPIC_APP_DRY_RUN` for the reason
    /// `Updater` gives: an action that replaces the running application is at least as
    /// consequential as an upload, and a dry run that silently does the real thing from one
    /// path is worse than having none.
    public static func handOff(staged: Staged, dryRun: Bool) throws -> URL {
        let log = Diagnostics.logURL.deletingLastPathComponent()
            .appendingPathComponent("GitPic-update.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = installScript(staged: staged, pid: pid, log: log)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-install-\(UUID().uuidString).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw InstallFailure.handoff((error as NSError).localizedDescription)
        }
        if dryRun {
            Diagnostics.log("update: DRY RUN — install script written to \(url.path),"
                            + " not spawned, not quitting")
            return url
        }
        // Detached on purpose: the child is reparented when this process exits and keeps
        // running, which is the whole point — its first job is to wait for that exit.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [url.path]
        // `/bin/bash` and not the `sh` that `do shell script` would give: `sh` exits on a
        // failed `exec` redirection where bash carries on, so an unwritable log would kill the
        // script at line five and take the relaunch with it.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolPaths.childPATH
        task.environment = env
        do {
            try task.run()
        } catch {
            throw InstallFailure.handoff((error as NSError).localizedDescription)
        }
        Diagnostics.log("update: handed off to \(url.path) (pid \(task.processIdentifier));"
                        + " quitting so the bundle can be replaced")
        return url
    }

    /// Delete staging and backup directories left behind by a past install.
    ///
    /// This is the **only** thing that deletes an install's rollback material: the swap script
    /// deliberately leaves `.GitPic-old-<uuid>` behind (see ``installScript``, point 2), so
    /// this runs one launch later — and by running at all it proves what the script could not,
    /// that the installed bundle starts.
    ///
    /// Two rules, and the first one is the one that matters.
    ///
    /// **1. Never delete the bundle this process is running from, or anything containing it.**
    /// Structural, not timed. The reachable path it closes: the script hits `ROLLBACK FAILED`,
    /// the user follows the log to `/Applications/.GitPic-old-<uuid>` and starts *that* — now
    /// the sweep at launch matches its own bundle's prefix, and the old code deleted the
    /// directory it was executing from, leaving no GitPic anywhere on the machine once it
    /// quit. A time bound cannot close this: any bound eventually expires while the app is
    /// still running from that directory. `running` is compared by path components against
    /// each candidate, so `.GitPic-old-abc` does not protect `.GitPic-old-abcdef`.
    ///
    /// **2. An age floor, measured from `st_ctime`.** The floor is the same day
    /// ``Updater.sweepStaleScripts`` uses, but the clock is not the one this used to read.
    /// Measured at second resolution:
    ///
    /// ```
    /// mkdir dir; touch -t 202501011200 dir   m=12:00:00 b=12:00:00 c=21:30:35
    /// (4s later) mv dir .GitPic-old-x        m=12:00:00 b=12:00:00 c=21:30:39
    /// ditto src dst                          m=12:00:00 b=12:00:00 c=21:30:42
    /// touch -t 202501011200 dst              c unchanged
    /// ```
    ///
    /// So `mv` leaves mtime alone and `ditto` preserves it too — an installed bundle's mtime
    /// is its *build* time — which is why the old one-day floor lasted zero seconds for anyone
    /// updating from a release older than a day, i.e. everyone. Birthtime is inherited
    /// through both as well, so `.creationDateKey` is exactly as wrong as
    /// `.contentModificationDateKey`; the third line above is there because that is the fix
    /// the next reader will reach for first. `st_ctime` — `.attributeModificationDateKey` — is
    /// the only one of the three that says when the leftover came into being *here*: the
    /// rename time for a backup, the copy time for a staging directory. The last line is why
    /// a test cannot fabricate staleness and passes a cutoff instead.
    ///
    /// ctime also moves forward on any later attribute change, so a genuinely stale leftover
    /// can look fresher than it is and survive a while longer. That is the direction to be
    /// wrong in — it keeps a copy of the app the user might still need — and it is the reason
    /// not to "tighten" this back to mtime.
    ///
    /// **The cost, stated rather than discovered.** Every match old enough goes in one pass —
    /// the loop has no early exit — but nothing bounds how many can pile up *inside* the
    /// window, because the script no longer deletes its own backup: one update leaves one
    /// `.GitPic-old-<uuid>`, and a user who updates three times in a day has three. Measured,
    /// `/Applications/GitPic.app` is 7.5 MB, so that is about 7.5 MB per update held for a day
    /// and then swept at the next launch. It is a deliberate trade against the alternative,
    /// which was deleting the only copy of a working GitPic on the machine.
    ///
    /// The process guarding this sweep: the image it is actually executing, not
    /// the path it was launched from.
    ///
    /// **The two differ, measurably.** The swap happens by renaming the bundle
    /// directory, and that does not stop a running process — measured twice — so
    /// a process the swap happened underneath keeps running from
    /// `.GitPic-old-<uuid>` while `Bundle.main.bundleURL`, which is only a
    /// launch-time path, still says `$target`. A sweep guarded by the launch
    /// path then protects a directory that process is not executing and leaves
    /// the one it is executing unprotected — the same failure as no guard, in
    /// the direction that deletes the only other copy of the app.
    ///
    /// `lsof` reports the executing image; `-a` is load-bearing (without it the
    /// selectors are OR-ed and lsof dumps the `txt` of *every* process —
    /// measured, 2.4 MB starting at `loginwindow`), and `-F n` is the format
    /// whose first `n/…` line is the image. Falls back to the launch path rather
    /// than to nothing: an unguarded sweep is strictly worse than a misdirected
    /// one.
    public static func currentImage() -> URL? {
        let out = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            args: ["-a", "-p", "\(ProcessInfo.processInfo.processIdentifier)",
                   "-d", "txt", "-Fn"],
            timeout: 10)
        guard let out, out.status == 0 else { return nil }
        for line in String(decoding: out.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("n/") {
                return URL(fileURLWithPath: String(line.dropFirst()))
            }
        }
        return nil
    }

    /// Returns what it removed, for the log and for the test.
    @discardableResult
    public static func sweepLeftovers(
        in directories: [URL] = defaultInstallDirs,
        olderThan cutoff: Date = Date().addingTimeInterval(-86_400),
        running: URL? = currentImage() ?? Bundle.main.bundleURL
    ) -> [URL] {
        var swept: [URL] = []
        for dir in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.attributeModificationDateKey])) ?? []
            for url in entries {
                let name = url.lastPathComponent
                guard name.hasPrefix(".GitPic-update-") || name.hasPrefix(".GitPic-old-")
                else { continue }
                if let running, contains(url, running) { continue }
                let created = try? url.resourceValues(
                    forKeys: [.attributeModificationDateKey]).attributeModificationDate
                guard let created, created < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { swept.append(url) }
            }
        }
        return swept
    }

    /// Refuse unless the path still names the inode whose bytes were hashed.
    ///
    /// What this catches is the practical attack: anything that *replaces* the file — a
    /// `rename` over it, an unlink and recreate — gives the path a new inode, and the compare
    /// fails. What it does not catch is a process rewriting the same inode in place. That is
    /// deliberate and worth stating rather than implying: `$TMPDIR` is mode 0700 for this user
    /// and the name carries a fresh UUID, so a process able to rewrite that file in place is
    /// already running as this user — and can write `/Applications` directly, without any of
    /// this. So the honest claim is narrow: the digest now covers the bytes that get mounted.
    ///
    /// Origin is a separate question this does not answer, and cannot: the release is ad-hoc
    /// signed and unnotarised, so there is no identity to pin. `codesign --verify` below proves
    /// the bundle is internally intact, not who made it. The digest is the only authentication
    /// on this path, which is exactly why it has to actually bind.
    ///
    /// **`lstat` and not `stat`, and that is the difference between the claim above being true
    /// and being decorative.** `stat` follows symlinks, so against it this proves only "the path
    /// *resolves to* this inode" — and a symlink is not a replacement of the file, it is a
    /// replacement of the *name*, which is the thing `hdiutil` is handed. Measured: move the
    /// verified image aside and drop a symlink at the download path pointing at it, and `stat`
    /// reports the target's `dev`/`ino` so the compare **passes**; `lstat` reports the link's own
    /// and it fails. Passing turns the check's subject into an indirection someone else controls
    /// and `hdiutil` will follow, so the half of the race that has to be set up in advance
    /// becomes free and only re-pointing the link has to land inside the window. `lstat` is
    /// strictly stronger here and costs nothing: `fetch` builds the destination itself as
    /// `temporaryDirectory/gitpic-update-<UUID>.dmg` and the delegate creates it with
    /// `moveItem`, so on the honest path the last component is always a regular file. The
    /// sibling ``isMountPoint(_:)`` already uses raw `lstat` for the same reason.
    private static func confirmUnchanged(_ dmg: VerifiedImage) throws {
        var now = stat()
        guard lstat(dmg.url.path, &now) == 0 else {
            throw InstallFailure.image("下载的磁盘映像已经不在原处")
        }
        guard now.st_dev == dmg.dev, now.st_ino == dmg.ino else {
            throw InstallFailure.image("下载的磁盘映像在校验之后被替换过，已中止安装")
        }
    }

    /// Whether `inner` is `outer` or sits inside it.
    ///
    /// By path components, not by string prefix: `/Applications/.GitPic-old-abc` is a prefix
    /// of the *string* `/Applications/.GitPic-old-abcdef` but not of the path. Symlinks are
    /// resolved first, because the two sides come from different places — one from
    /// `contentsOfDirectory`, one from `Bundle.main` — and on this machine `/tmp` and
    /// `/var/folders` are both reached through symlinks.
    private static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let a = outer.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let b = inner.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard a.count <= b.count else { return false }
        return Array(b.prefix(a.count)) == a
    }

    /// The two directories an install can have staged into.
    public static var defaultInstallDirs: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
             .appendingPathComponent("Applications")]
    }
}
