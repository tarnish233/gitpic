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

        public var message: String {
            switch self {
            case .image(let detail): return "磁盘映像有问题：\(detail)"
            case .staging(let detail): return detail
            case .handoff(let detail): return "启动安装失败：\(detail)"
            }
        }
    }

    /// A new bundle copied into place beside the one it will replace, ready for the swap.
    public struct Staged: Equatable, Sendable {
        /// The bundle to move into `target`.
        public let bundle: URL
        /// The directory holding it, removed after a successful install.
        public let directory: URL
        /// What is being replaced.
        public let target: URL
        public let version: String
    }

    /// Mount `dmg`, check what is inside it, and copy it in beside `target`.
    ///
    /// Blocking — it spawns `hdiutil`, `codesign`, `ditto` and `xattr`. Call it off the main
    /// actor. Everything it does is undoable: on any failure the image is detached and the
    /// staging directory removed, and `target` is untouched throughout.
    ///
    /// **The staging directory is deliberately created inside `target`'s parent.** Two
    /// reasons, both load-bearing. It puts the copy on the same filesystem, so the swap is a
    /// rename and not a copy. And creating it *is* the permission check: `rename(2)` and
    /// `mkdir(2)` both need write permission on that same parent directory, so a staging
    /// directory that could be created is a swap that can happen — no guessing from
    /// `isWritableFile`.
    public static func stage(dmg: URL, expectedVersion: String, replacing target: URL) throws
        -> Staged {
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
        guard let attach, attach.status == 0, !attach.timedOut else {
            try? FileManager.default.removeItem(at: mount)
            let detail = attach?.timedOut == true
                ? "打开磁盘映像超时"
                : String(decoding: attach?.stderr ?? Data(), as: UTF8.self)
                    .split(separator: "\n").first.map(String.init) ?? "无法打开"
            throw InstallFailure.image(detail)
        }
        defer {
            _ = try? ChildProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                args: ["detach", mount.path, "-quiet"], timeout: 60)
            try? FileManager.default.removeItem(at: mount)
        }

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
        // Internal consistency only. It catches a truncated or half-written copy; it proves
        // **nothing** about origin, because it passes for anything anyone ad-hoc signs. The
        // digest checked before this is the only authentication in the whole path.
        let signature = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            args: ["--verify", "--deep", "--strict", source.path],
            timeout: 120)
        guard let signature, signature.status == 0, !signature.timedOut else {
            throw InstallFailure.image("映像里的 GitPic.app 签名校验失败")
        }

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
        // Belt and braces over `--noqtn`: a nested file could carry the attribute even when
        // the top level does not, and one quarantined item inside the bundle is enough.
        // Ignored on failure — there is usually nothing to remove, and `xattr` exits non-zero
        // when there is not.
        _ = try? ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            args: ["-dr", "com.apple.quarantine", bundle.path],
            timeout: 60)

        staged = true
        return Staged(bundle: bundle, directory: directory, target: target,
                      version: expectedVersion)
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
    /// Four things here are the direct result of finding them wrong first:
    ///
    /// 1. **The backup name carries a UUID and its absence is asserted.** `mv a a.old` when
    ///    `a.old` already exists does not fail — it moves `a` *inside* it, giving
    ///    `a.old/a`. Reproduced. With a fixed name, a second attempt would then "roll back" a
    ///    wrapper directory that is not a bundle and delete the real app with the leftovers.
    /// 2. **The app is reopened before the rollback material is deleted**, so a new bundle
    ///    that will not launch still has the old one on disk behind it. The leftovers are
    ///    swept at the next launch, the way stale scripts already are.
    /// 3. **The reopen is in a `trap … EXIT`**, not on the success path. GitPic is
    ///    `.accessory`: once it has quit there is no Dock icon and no menu-bar icon, so a
    ///    script that dies before reopening costs the user the entire app.
    /// 4. **`PATH` is set explicitly.** Not a root-safety measure — nothing here runs
    ///    elevated — but the app's own PATH has a Homebrew prefix prepended, and a swap script
    ///    has no business resolving `mv` through a user-writable directory.
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
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) install \(staged.version) ==="

        target=\(q(staged.target.path))
        staged=\(q(staged.bundle.path))
        backup=\(q(backup))
        stagedir=\(q(staged.directory.path))

        # Whatever happens below, GitPic comes back. It is .accessory, so once it has quit
        # there is no icon anywhere to click — a script that dies before this has taken the
        # app away with it.
        reopen() {
          open -a "$target" 2>/dev/null && return 0
          open -a GitPic 2>/dev/null && return 0
          echo "could not reopen GitPic — open $target by hand"
        }
        trap reopen EXIT

        # The bundle must not be renamed under a running process: measured, that gets the
        # process killed. Bounded, and after the bound the swap is attempted anyway — the
        # renames are the things that can refuse safely.
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
          mv "$backup" "$target" || echo "ROLLBACK FAILED — the old GitPic is at $backup"
          exit 1
        fi
        echo "installed \(staged.version)"

        # Reopen first, delete second. If the new bundle will not launch, the old one is
        # still there to go back to; the leftovers are swept at the next launch.
        reopen
        trap - EXIT
        rm -rf "$backup" "$stagedir"
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
    /// The script cannot remove its own staging directory when it fails part-way, and it
    /// deliberately does not remove the backup until after the new bundle has been reopened —
    /// so a crash in between leaves up to two bundle-sized directories in `/Applications`.
    /// This is where they go, one launch later, with the same one-day age floor
    /// ``Updater.sweepStaleScripts`` uses: far longer than any install, so nothing still in
    /// use can match.
    ///
    /// Returns what it removed, for the log and for the test.
    @discardableResult
    public static func sweepLeftovers(
        in directories: [URL] = defaultInstallDirs,
        olderThan cutoff: Date = Date().addingTimeInterval(-86_400)
    ) -> [URL] {
        var swept: [URL] = []
        for dir in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in entries {
                let name = url.lastPathComponent
                guard name.hasPrefix(".GitPic-update-") || name.hasPrefix(".GitPic-old-")
                else { continue }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                guard let modified, modified < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: url)) != nil { swept.append(url) }
            }
        }
        return swept
    }

    /// The two directories an install can have staged into.
    public static var defaultInstallDirs: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
             .appendingPathComponent("Applications")]
    }
}
