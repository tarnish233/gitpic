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
        dmg: URL,
        expectedVersion: String,
        replacing target: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Staged {
        try stopIfCancelled(isCancelled)
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-mount-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        // `-mountpoint` rather than letting it land in `/Volumes`: the name there is chosen
        // from the volume label and gets a numeric suffix when it collides, so the path this
        // reads from would be decided by whatever else happens to be mounted.
        let attach = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            args: ["attach", dmg.path, "-nobrowse", "-readonly",
                   "-mountpoint", mount.path],
            timeout: 120)
        // The detach is installed before the guard on purpose. A timed-out `attach` is not a
        // failed one: `ChildProcess` terminates and then `SIGKILL`s the `hdiutil` it spawned,
        // and the attach the kernel had already committed to survives that — so the one path
        // that must not skip the detach is the one that failed. `detachMount` is a no-op plus
        // an `rmdir` when nothing is mounted, so it costs nothing on the ordinary refusals.
        defer { detachMount(at: mount) }
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
        var staged = false
        defer { if !staged { try? FileManager.default.removeItem(at: directory) } }

        let bundle = directory.appendingPathComponent("GitPic.app")
        // `ditto`, not `cp -R`: `man ditto` says it preserves resource forks, extended
        // attributes and ACLs, and an ad-hoc signature lives in extended attributes — `cp -R`
        // would break it. `--noqtn` because the same page says quarantine bits are preserved
        // too, and a quarantined ad-hoc bundle is one Gatekeeper refuses outright.
        let copy = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            args: ["--noqtn", source.path, bundle.path],
            timeout: 300)
        guard let copy, copy.status == 0, !copy.timedOut else {
            throw InstallFailure.staging("复制新版本失败："
                + (copy?.timedOut == true ? "超时" : "ditto 退出码 \(copy?.status ?? -1)"))
        }
        try stopIfCancelled(isCancelled)
        // Belt and braces over `--noqtn`: a nested file could carry the attribute even when
        // the top level does not, and one quarantined item inside the bundle is enough.
        // Ignored on failure — there is usually nothing to remove, and `xattr` exits non-zero
        // when there is not.
        _ = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            args: ["-dr", "com.apple.quarantine", bundle.path],
            timeout: 60)

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
    /// Six things here are the direct result of finding them wrong first:
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
    /// 3. **The reopen is confirmed and the outcome logged either way.** Since `open -a`'s
    ///    status is not evidence, the status alone was not worth branching on — the old code
    ///    did not even read it, and `reopen`'s last branch was a bare `echo`, so a total
    ///    failure to relaunch returned 0 and looked like success. Now every outcome names
    ///    itself in the log, and `whence` records *which* bundle came up, because the
    ///    by-name fallback resolves through LaunchServices — which holds registrations for
    ///    copies under `.GitPic-update-*` too, seen in `lsregister -dump` — so "a GitPic is
    ///    running" and "the new GitPic is running" are different claims.
    /// 4. **The reopen is in a `trap … EXIT`**, not on the success path. GitPic is
    ///    `.accessory`: once it has quit there is no Dock icon and no menu-bar icon, so a
    ///    script that dies before reopening costs the user the entire app.
    /// 5. **`PATH` is set explicitly.** Not a root-safety measure — nothing here runs
    ///    elevated — but the app's own PATH has a Homebrew prefix prepended, and a swap script
    ///    has no business resolving `mv` through a user-writable directory.
    /// 6. **`launch`, `running` and `whence` are one-liners.** Everything this script does to
    ///    the outside world beyond `mv` goes through them, so a test can replace exactly
    ///    those three lines: a test must never really launch an application, and both sides
    ///    of the confirmation have to be reachable from one.
    ///
    /// Every interpolation goes through `q()`, including `staged.version`. It is constrained
    /// today — `stage` only ever passes the version it matched against the image's
    /// `Info.plist` — but the value is written into `echo` lines that end up in a shell, and
    /// "safe because of a check thirty lines away in another function" is not a property worth
    /// depending on for the sake of two quotes.
    static func installScript(staged: Staged, pid: Int32, log: URL) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // Adjacent to the target and on its filesystem, so the rename cannot cross devices.
        let backup = staged.target.deletingLastPathComponent()
            .appendingPathComponent(".GitPic-old-\(UUID().uuidString)").path

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
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) install $version ==="

        # The three things this script does to the world outside its own directory, one line
        # each so a test can replace them. See point 6 in the doc comment.
        launch() { open -a "$1"; }
        running() { pgrep -x GitPic >/dev/null 2>&1; }
        whence() { ps -Awwo pid=,comm= | grep -F /Contents/MacOS/GitPic; }

        # Ask, do not assume. `open -a` exits 0 when LaunchServices accepts the request, not
        # when the app runs. Bounded at ten seconds: this is the log's evidence, never a
        # licence to delete anything, so being wrong here costs a misleading line and nothing
        # else.
        confirm() {
          n=0
          while [ "$n" -lt 20 ]; do
            running && return 0
            n=$((n + 1))
            sleep 0.5
          done
          return 1
        }

        # Whatever happens below, GitPic comes back. It is .accessory, so once it has quit
        # there is no icon anywhere to click — a script that dies before this has taken the
        # app away with it.
        reopen() {
          launch "$target"
          rc=$?
          if [ "$rc" -eq 0 ] && confirm; then
            echo "reopened $target; running:"
            whence
            return 0
          fi
          if [ "$rc" -eq 0 ]; then
            echo "reopen: LaunchServices accepted $target but no GitPic process appeared"
            echo "within 10s — the new bundle may not be launchable"
          else
            echo "reopen: open -a $target failed (status $rc)"
          fi
          # By name, as a last resort, and worth having even though it can resolve to a
          # leftover copy rather than the installed bundle: an old GitPic in the menu bar
          # beats no GitPic at all, and nothing below deletes what it finds. `whence` says
          # which one it was.
          launch GitPic
          if [ $? -eq 0 ] && confirm; then
            echo "reopened by name, not by path; running:"
            whence
            return 0
          fi
          echo "could not reopen GitPic — open $target by hand"
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
    /// Returns what it removed, for the log and for the test.
    @discardableResult
    public static func sweepLeftovers(
        in directories: [URL] = defaultInstallDirs,
        olderThan cutoff: Date = Date().addingTimeInterval(-86_400),
        running: URL? = Bundle.main.bundleURL
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
