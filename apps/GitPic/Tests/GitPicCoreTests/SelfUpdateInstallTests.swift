import CryptoKit
import Foundation
import Testing
@testable import GitPicCore

/// The install mechanism, end to end, against a disk image this test builds.
///
/// **Why it builds its own image instead of using the published one.** The dangerous part of
/// self-update is not the download — that is covered offline in `ReleaseAssetTests` — it is
/// mounting something and then renaming a bundle out from under an application. That deserves
/// a test that actually runs, everywhere, rather than one gated on a file somebody remembered
/// to download. `hdiutil create` is the same tool `release.yml` uses to build the real image,
/// so the layout under test is the layout that ships.
///
/// It was also run once against the real 0.19.0 image while this was written, which is where
/// the `ditto`-preserves-the-signature and no-quarantine-survives assertions come from.
///
/// `.serialized` because each test mounts a disk image, and the mount table is machine-wide.
@Suite("Bundle install", .serialized)
struct SelfUpdateInstallTests {

    /// A minimal but real `.app`: a bundle with an `Info.plist` carrying `version`, a
    /// stand-in executable and CLI, ad-hoc signed the way `build-app.sh` signs the real one.
    private static func makeApp(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.gitpic.app.test",
            "CFBundleName": "GitPic",
            "CFBundleExecutable": "GitPic",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        for exe in ["MacOS/GitPic", "Resources/gitpic"] {
            let path = contents.appendingPathComponent(exe)
            try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                 ofItemAtPath: path.path)
        }
        // Ad-hoc, as `build-app.sh` does by default. The staged copy is checked against
        // `codesign --verify` afterwards, which is what catches a copy made with `cp -R`.
        let signed = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            args: ["--force", "--sign", "-", url.path], timeout: 120)
        guard signed.status == 0 else {
            throw FixtureError.signing(String(decoding: signed.stderr, as: UTF8.self))
        }
    }

    enum FixtureError: Error {
        case signing(String)
        case image(String)
        /// A line the test needs to stub is no longer in the generated script.
        case stub(String)
        /// The stand-in for the app was spawned and was not running a moment later.
        case probe(String)
    }

    /// A real, long-lived process executing a real binary inside `bundle`, standing in for the
    /// running app. Returned so the caller can terminate it; nothing is left running.
    ///
    /// **It has to be a real Mach-O, and it has to be signed.** Measured: a shell script's
    /// `lsof` `txt` image is `/bin/sh` and not the script, so a script cannot show the property
    /// under test at all; and a plain `cp` of `/bin/sleep` is killed the instant it is exec'd,
    /// while `codesign --force --sign -` on the copy — the same ad-hoc signature ``makeApp``
    /// gives the fixture bundles — runs.
    ///
    /// It replaces the bundle's own executable, so the bundle's seal no longer verifies
    /// afterwards. No test that uses this asserts on that bundle's signature.
    private static func probe(executing bundle: URL, seconds: Int = 30) throws -> Process {
        let exe = bundle.appendingPathComponent("Contents/MacOS/GitPic")
        try? FileManager.default.removeItem(at: exe)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: exe)
        let signed = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            args: ["--force", "--sign", "-", exe.path], timeout: 120)
        guard signed.status == 0 else {
            throw FixtureError.signing(String(decoding: signed.stderr, as: UTF8.self))
        }
        let process = Process()
        process.executableURL = exe
        process.arguments = ["\(seconds)"]
        try process.run()
        // `run()` returns once `posix_spawn` succeeded, which is before the kernel has decided
        // whether the image may execute. A moment's wait makes the check below about the
        // signature rather than about the timing.
        Thread.sleep(forTimeInterval: 0.3)
        guard process.isRunning else { throw FixtureError.probe(exe.path) }
        return process
    }

    /// A read-only `UDZO` image with the app at its root, exactly as `release.yml:216-220`
    /// builds the real one.
    private static func makeDMG(containing app: URL, at dmg: URL) throws {
        let root = dmg.deletingLastPathComponent().appendingPathComponent("dmgroot")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: root.appendingPathComponent("GitPic.app"))
        let made = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            args: ["create", "-volname", "GitPic", "-srcfolder", root.path,
                   "-ov", "-format", "UDZO", dmg.path],
            timeout: 300)
        guard made.status == 0 else {
            throw FixtureError.image(String(decoding: made.stderr, as: UTF8.self))
        }
        try FileManager.default.removeItem(at: root)
    }

    /// One 0.19.0 image, built once for the whole suite.
    ///
    /// `hdiutil create` costs several seconds and every test here wants the same image, so
    /// building it per test added most of a minute to the run for nothing. Safe as a `static`
    /// because the suite is `.serialized` and the image is only ever read.
    ///
    /// **Two constraints that pull against each other, and the name has to satisfy both.**
    ///
    /// *Fixed, not per-run.* Swift Testing has no suite-level teardown, so a unique name per
    /// run leaks one signed bundle plus a disk image into the temporary directory every time
    /// the suite executes — measured, after four runs, four directories. A fixed name means at
    /// most one exists, and `hdiutil create -ov` overwrites it. Anything derived from a pid or
    /// a clock brings that leak straight back.
    ///
    /// *Scoped to this checkout, not to the machine.* `$TMPDIR` is per-user, so a globally
    /// fixed name puts two worktrees' test runs in the same directory. Measured, with two
    /// checkouts running `swift test` at once: five failures in this suite with
    /// `NSCocoaErrorDomain Code=4 "dmgroot couldn't be removed"`, and one image attached by one
    /// process while the other tried to attach the same file, which `hdiutil` refuses with
    /// `资源暂时不可用`. `#filePath` is the discriminator: stable across runs of one checkout,
    /// different between checkouts, and needs no environment variable to be set up.
    private static let sharedImage: Result<URL, Error> = {
        do {
            let scope = SHA256.hash(data: Data(#filePath.utf8))
                .prefix(4).map { String(format: "%02x", $0) }.joined()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitpic-install-test-image-\(scope)")
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = dir.appendingPathComponent("GitPic.app")
            try makeApp(at: source, version: "0.19.0")
            let dmg = dir.appendingPathComponent("GitPic-0.19.0-macos-arm64.dmg")
            try makeDMG(containing: source, at: dmg)
            try FileManager.default.removeItem(at: source)
            return .success(dmg)
        } catch {
            return .failure(error)
        }
    }()

    /// A scratch directory, plus a signed 0.19.0 image and an "installed" 0.18.0 bundle in it.
    private struct Fixture {
        let root: URL
        let target: URL
        let dmg: SelfUpdate.VerifiedImage
        /// The stand-in for `/Applications`: the directory the swap and the sweep work in.
        var apps: URL { target.deletingLastPathComponent() }
    }

    /// A `VerifiedImage` for a file on disk, without going through a download.
    ///
    /// `stage` takes a `VerifiedImage` so that no unverified path can reach it in production —
    /// see the type's own comment. These suites are the legitimate exception: they build their
    /// image locally, so its digest is not in question, and what they exercise is everything
    /// `stage` does *after* the identity check. `measured` therefore records the identity the
    /// file actually has, which is what makes the check pass here and fail in
    /// `refusesAnImageSwappedAfterVerification`, where the file is swapped on purpose.
    ///
    /// `lstat` and not `stat`, to match what `confirmUnchanged` asks: for a regular file the two
    /// are identical, and `refusesAnImageBehindASymlink` is the case where they are not.
    private static func measured(_ url: URL) throws -> SelfUpdate.VerifiedImage {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        return SelfUpdate.VerifiedImage(
            url: url, sha256: try SelfUpdate.sha256OfFile(at: url),
            dev: info.st_dev, ino: info.st_ino)
    }

    /// Register into the process-wide registry the way `stage` does, at the current generation.
    ///
    /// The generation is read here rather than passed in because these tests are standing in for
    /// a `stage` that has just started; a test that needs the *stale* generation asks for it
    /// explicitly — see `refusesToRegisterAfterADrain`.
    private static func register(staging: URL) {
        #expect(SelfUpdate.inFlightWork.hold(staging: staging,
                                             since: SelfUpdate.inFlightWork.generation),
                "registering at the current generation must succeed")
    }

    private static func register(mount: URL) {
        #expect(SelfUpdate.inFlightWork.hold(mount: mount,
                                             since: SelfUpdate.inFlightWork.generation),
                "registering at the current generation must succeed")
    }

    private static func fixture(installed: String = "0.18.0") throws -> Fixture {
        let dmg = try Self.sharedImage.get()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-install-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The bundle standing in for the installed one.
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let target = apps.appendingPathComponent("GitPic.app")
        try makeApp(at: target, version: installed)
        return Fixture(root: root, target: target, dmg: try Self.measured(dmg))
    }

    /// Names in a directory starting with `prefix`.
    private static func entries(in dir: URL, prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// The mount points staging has left in the temporary directory.
    ///
    /// Compared before and after rather than asserted to be empty, so a mount some other
    /// suite left cannot make this one fail — and so a leaked one here cannot hide in it.
    /// A leak is invisible in Finder (`-nobrowse`) and survives until reboot, so it is worth
    /// asserting on every path through `stage`.
    private static func mountLeftovers() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory.path
        return Set(((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [])
            .filter { $0.hasPrefix("gitpic-mount-") })
    }

    /// The digest has to cover the bytes that get mounted, not a path that once held them.
    ///
    /// `download` hashes through one descriptor and `hdiutil` opens the path again, with a
    /// `Task.checkCancellation` and a hop onto a serial queue shared with a 20 s
    /// `brew list --cask` in between — so this window is tens of seconds wide, not instants.
    /// Before the identity check existed, the image swapped in here is the one that would have
    /// been copied to `/Applications`, de-quarantined and launched, with `codesign --verify`
    /// passing on it because anyone can ad-hoc sign a bundle.
    ///
    /// The swap is by `replaceItem`, i.e. a rename — a new inode at the same path, which is how
    /// this is actually done. Rewriting the same inode in place is deliberately *not* caught;
    /// see `confirmUnchanged`.
    ///
    /// **The substitute is a byte-identical copy of the image, and that is the whole point.** It
    /// used to be 31 bytes of ASCII, which made this test prove nothing at all: `hdiutil attach`
    /// refuses garbage on its own, with the same `InstallFailure.image` case, so the test passed
    /// verbatim with `confirmUnchanged` deleted — assertion for assertion identical to
    /// `refusesGarbage` below. A valid image makes the guard load-bearing: remove it and the
    /// attach succeeds, the version gate passes, `ditto` runs and the assertions below about
    /// nothing having been staged are what fail. Byte-identical rather than merely valid because
    /// it is the strongest premise available — the digest cannot tell the two files apart, so the
    /// only thing that can is the inode, which is exactly the property under test.
    @Test("an image swapped after verification is refused, not installed")
    func refusesAnImageSwappedAfterVerification() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mountsBefore = Self.mountLeftovers()

        // A private copy, because `fixture()` hands every test in this suite the *same* image
        // (`sharedImage`) and this test is going to destroy the one it is given.
        let mine = f.root.appendingPathComponent("GitPic-0.19.0-macos-arm64.dmg")
        try FileManager.default.copyItem(at: f.dmg.url, to: mine)
        let verified = try Self.measured(mine)

        // Now something else takes its place at that path, keeping the name. Same bytes, so the
        // digest still matches; different inode, which is all the guard has to go on.
        let impostor = f.root.appendingPathComponent("impostor.dmg")
        try FileManager.default.copyItem(at: f.dmg.url, to: impostor)
        _ = try FileManager.default.replaceItemAt(verified.url, withItemAt: impostor)
        // Same path, different inode — the premise of the test.
        var now = stat()
        #expect(lstat(verified.url.path, &now) == 0)
        #expect(now.st_ino != verified.ino, "the swap did not change the inode")

        do {
            _ = try SelfUpdate.stage(dmg: verified, expectedVersion: "0.19.0",
                                     replacing: f.target)
            Issue.record("a swapped image must be refused, not installed")
        } catch let failure as SelfUpdate.InstallFailure {
            // The exact case, not just the type: a valid substitute would otherwise install, and
            // an invalid one throws the same case from `hdiutil` for an unrelated reason.
            #expect(failure == .image("下载的磁盘映像在校验之后被替换过，已中止安装"),
                    "expected the identity refusal, got \(failure)")
        }

        // Nothing was installed: the target is still the 0.18.0 bundle the fixture put there,
        // and no staging directory was left beside it.
        #expect(Self.entries(in: f.apps, prefix: ".GitPic-update-").isEmpty)
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
        // And the refusal happened before the attach, so there is no mount to clean up.
        #expect(Self.mountLeftovers() == mountsBefore)
    }

    /// A symlink at the download path is a substitution too, and `stat` cannot see it.
    ///
    /// `stat` follows symlinks, so against it the check proves only that the path *resolves to*
    /// the verified inode. But a symlink does not replace the file, it replaces the **name** —
    /// and the name is what `hdiutil` is handed. Measured before the fix: move the verified image
    /// aside and leave a symlink to it at the download path, and the compare passes, because a
    /// rename preserves the inode the digest was taken from. That turns the check's subject into
    /// an indirection someone else controls, so only re-pointing the link has to land inside the
    /// race window rather than the whole substitution.
    ///
    /// `lstat` reports the link's own inode and refuses. Reverting `confirmUnchanged` to `stat`
    /// fails exactly here.
    @Test("an image reached through a symlink is refused")
    func refusesAnImageBehindASymlink() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mountsBefore = Self.mountLeftovers()

        let mine = f.root.appendingPathComponent("GitPic-0.19.0-macos-arm64.dmg")
        try FileManager.default.copyItem(at: f.dmg.url, to: mine)
        let verified = try Self.measured(mine)

        // The bytes move aside — a rename, so they keep the inode the digest was taken from —
        // and the path the installer will use becomes a link to them.
        let real = f.root.appendingPathComponent("really-here.dmg")
        try FileManager.default.moveItem(at: mine, to: real)
        try FileManager.default.createSymbolicLink(at: mine, withDestinationURL: real)

        // The premise: `stat` cannot tell this apart from the honest case, `lstat` can.
        var followed = stat(), link = stat()
        #expect(stat(mine.path, &followed) == 0)
        #expect(followed.st_ino == verified.ino, "the rename should have kept the inode")
        #expect(lstat(mine.path, &link) == 0)
        #expect(link.st_ino != verified.ino, "the symlink has an inode of its own")

        do {
            _ = try SelfUpdate.stage(dmg: verified, expectedVersion: "0.19.0",
                                     replacing: f.target)
            Issue.record("an image behind a symlink must be refused")
        } catch let failure as SelfUpdate.InstallFailure {
            #expect(failure == .image("下载的磁盘映像在校验之后被替换过，已中止安装"),
                    "expected the identity refusal, got \(failure)")
        }

        #expect(Self.entries(in: f.apps, prefix: ".GitPic-update-").isEmpty)
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
        #expect(Self.mountLeftovers() == mountsBefore)
    }

    @Test("staging copies the image's app beside the target, signature and all")
    func stages() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mountsBefore = Self.mountLeftovers()

        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)

        // Beside the target, so the swap is a rename and not a copy across devices — and so
        // that creating it was the permission check.
        #expect(staged.directory.deletingLastPathComponent().path == f.apps.path)
        #expect(staged.directory.lastPathComponent.hasPrefix(".GitPic-update-"))
        #expect(SelfUpdate.bundleVersion(of: staged.bundle) == "0.19.0")
        // `ditto` was used rather than `cp -R` precisely so this passes: an ad-hoc signature
        // lives in extended attributes, which `cp -R` does not carry across. This is also the
        // check `stage` itself now makes, and on this same object — it used to make it against
        // the mounted image, before any copy existed to check.
        let check = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            args: ["--verify", "--deep", "--strict", staged.bundle.path], timeout: 120)
        #expect(check.status == 0, "the staged copy failed codesign — was it copied with cp?")
        // Nothing has touched the installed bundle yet.
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
        // The image was detached and its mount point removed.
        #expect(Self.mountLeftovers() == mountsBefore)
    }

    /// The check that used to run on the wrong object, tested directly on both answers.
    ///
    /// Worth its own test because `stage` cannot show the difference: an image whose bundle is
    /// broken fails either way. What this pins is that the function answers about the bundle it
    /// is handed, which is what moving the call from the mount to the copy was for.
    @Test("the signature check follows the bundle it is given")
    func verifiesTheBundleItIsGiven() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        #expect(SelfUpdate.signatureIsIntact(at: f.target))
        // The same damage a `ditto` that exited 0 with a dropped extended attribute would
        // leave: the seal no longer matches what is inside.
        let exe = f.target.appendingPathComponent("Contents/MacOS/GitPic")
        try Data("#!/bin/sh\necho tampered\n".utf8).write(to: exe)
        #expect(!SelfUpdate.signatureIsIntact(at: f.target))
        // Not a bundle at all is also a "no", not a crash.
        #expect(!SelfUpdate.signatureIsIntact(at: f.root.appendingPathComponent("nothing")))
    }

    /// The swap itself, by running the generated script.
    @Test("the script swaps the bundles, reopens, and keeps the old bundle for rollback")
    func swaps() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root)

        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.19.0", "log: \(output)")
        #expect(output.contains("installed 0.19.0"), "log: \(output)")
        // The relaunch ran, and it was confirmed rather than assumed — and confirmed of the
        // *new* bundle, which is a claim about a pid and the image that pid is executing.
        #expect(output.contains("WOULD REOPEN \(f.target.path)"),
                "the app was never reopened: \(output)")
        #expect(output.contains("reopened \(f.target.path) (by path), pid 4242"),
                "not confirmed: \(output)")
        #expect(output.contains("0.19.0 is running: its executing image is"),
                "the confirmation did not say what it confirmed: \(output)")
        // **The old bundle is still there.** The script used to `rm -rf` it right after
        // `open -a` returned, which is not the same event as the new version working; the
        // delete belongs to a later launch of the app instead. A new build that fails on
        // first run has this to go back to.
        let backups = Self.entries(in: f.apps, prefix: ".GitPic-old-")
        #expect(backups.count == 1, "the rollback material was destroyed: \(backups)")
        if let backup = backups.first {
            let url = f.apps.appendingPathComponent(backup)
            #expect(SelfUpdate.bundleVersion(of: url) == "0.18.0",
                    "the backup is not a working bundle")
            #expect(SelfUpdate.signatureIsIntact(at: url),
                    "the backup would be refused by Gatekeeper")
            #expect(output.contains("kept for rollback: \(url.path)"), "log: \(output)")
        }
        // The staging directory is empty once its bundle has moved out, and `rmdir` takes it.
        #expect(Self.entries(in: f.apps, prefix: ".GitPic-update-").isEmpty,
                "staging left: \(Self.entries(in: f.apps, prefix: ".GitPic-update-"))")
    }

    /// The reopen that is accepted and then does not happen — the case `open -a`'s exit status
    /// cannot tell you about, and the case that used to return 0 from a bare `echo`.
    @Test("a reopen that never comes up says so, and still keeps the old bundle")
    func reportsAReopenThatNeverRuns() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root,
                                        reopen: .nothing)

        #expect(output.contains("installed 0.19.0"), "log: \(output)")
        // Both attempts were made — by path, then by name — and both are on the record, with
        // the evidence they were decided on.
        #expect(output.contains("no process executing that bundle"), "log: \(output)")
        #expect(output.contains("(no process named GitPic is running)"), "log: \(output)")
        #expect(output.contains("could not reopen GitPic"), "log: \(output)")
        #expect(!output.contains("reopened \(f.target.path)"), "log: \(output)")
        #expect(!output.contains("0.19.0 is running"), "log: \(output)")
        // The new version is in place and the old one is still recoverable, which is the
        // entire point of not deleting it here: this is what "the update does not launch"
        // looks like from the script's side.
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.19.0", "log: \(output)")
        #expect(Self.entries(in: f.apps, prefix: ".GitPic-old-").count == 1, "log: \(output)")
    }

    /// A launch request that is refused outright, as opposed to accepted and dropped.
    @Test("a refused reopen logs the status it was refused with")
    func reportsARefusedReopen() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root,
                                        reopen: .refused)

        #expect(output.contains("open -a \(f.target.path) failed (status 1)"), "log: \(output)")
        #expect(output.contains("could not reopen GitPic"), "log: \(output)")
    }

    /// **The bug that shipped in 0.20.0.** The app is asked to quit and does not; the bounded
    /// wait expires; the renames go ahead underneath it; and `open -a "$target"` then activates
    /// that surviving instance, because it is what LaunchServices has registered for the bundle
    /// identifier. The script called that a success, because its evidence was "a process is
    /// running at `$target`" and `ps` reports the path a process was launched from rather than
    /// the inode it is executing.
    ///
    /// Nothing about the mechanism is faked. The stand-in for the app is a real process
    /// executing a real binary inside the installed bundle, and the script's `image()` line is
    /// the real `lsof`, so the two facts the refusal turns on are produced by the kernel here:
    /// `mv` on the parent directory of a running executable does not kill it, and `lsof` follows
    /// that rename. What is stubbed is only the part no test can ask for — LaunchServices
    /// answering `open -a` with the surviving instance instead of a new one — and it is stubbed
    /// by handing `candidates` that one pid, which is exactly what `pgrep` returned on the real
    /// install.
    @Test("an app that never quit is not mistaken for the reopened new version")
    func refusesTheAppThatNeverQuit() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)
        let app = try Self.probe(executing: f.target)
        defer { if app.isRunning { app.terminate() } }
        let pid = app.processIdentifier

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root,
                                        pid: pid, reopen: .realProcess(pid: pid))

        // The swap still happened. A quit that never comes must not cost the user the update.
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.19.0", "log: \(output)")
        #expect(output.contains("installed 0.19.0"), "log: \(output)")
        // **And it is not called a reopen.** These two are what fail against 0.20.0's script,
        // which logged `reopened <target>; running:` followed by a `ps` line naming this very
        // pid at this very path.
        #expect(!output.contains("reopened \(f.target.path)"),
                "the surviving old process was counted as the reopen: \(output)")
        #expect(!output.contains("0.19.0 is running"), "log: \(output)")
        // The expired wait is on the record as the anomaly it is, instead of passing in
        // silence, and the reopen names the cause and what the user should do about it.
        #expect(output.contains("ANOMALY: pid \(pid) is still running after 60s"),
                "the expired wait was not recorded: \(output)")
        #expect(output.contains("NOT reopened: pid \(pid) never exited"), "log: \(output)")
        #expect(output.contains("quit the running GitPic"),
                "the log does not say what to do about it: \(output)")
        // The stand-in really did survive the rename — if it had died, this test would be
        // pinning nothing — and the log names the image it is really executing, inside the
        // backup. Asserted as a suffix because the log carries the *physical* path
        // (/private/var/folders/…) while the fixture only knows the logical one, which is the
        // whole reason the script resolves it.
        #expect(app.isRunning, "the rename killed the stand-in; this is not the shipped bug")
        let backups = Self.entries(in: f.apps, prefix: ".GitPic-old-")
        #expect(backups.count == 1, "\(backups)")
        if let backup = backups.first {
            #expect(output.contains("pid \(pid) is executing "),
                    "the refused candidate is not in the log: \(output)")
            #expect(output.contains("/Applications/\(backup)/Contents/MacOS/GitPic"),
                    "the log does not name the image it was refused for: \(output)")
        }
    }

    /// The other half of the same rule, with the pid coincidence taken away: a process that is
    /// *not* the one the script waited on, executing something that is not the new bundle. That
    /// is what `open -a` produces whenever LaunchServices resolves the request to a copy other
    /// than the installed one — and here it is the old bundle at the backup path, which is what
    /// the process it activated on the real install turned out to be executing. Only the image
    /// can refuse this one, so this is the test that pins that half of `isnew`.
    @Test("a process that is not executing the new bundle is refused")
    func refusesAProcessThatIsNotTheNewBundle() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)
        // Executing the *old* bundle, which the swap renames to the backup underneath it.
        let other = try Self.probe(executing: f.target)
        defer { if other.isRunning { other.terminate() } }
        let pid = other.processIdentifier

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root,
                                        reopen: .realProcess(pid: pid))

        #expect(output.contains("installed 0.19.0"), "log: \(output)")
        #expect(!output.contains("reopened \(f.target.path)"),
                "a process executing the old bundle was counted: \(output)")
        #expect(!output.contains("0.19.0 is running"), "log: \(output)")
        // Not the "never exited" branch: the pid the script waited on is long gone, so what it
        // has is a launch that was accepted and produced nothing from the new bundle.
        #expect(!output.contains("never exited"), "log: \(output)")
        #expect(output.contains("no process executing that bundle"), "log: \(output)")
        #expect(output.contains("could not reopen GitPic"), "log: \(output)")
        // And the refusal is legible: the candidate is listed with the image it is executing.
        #expect(output.contains("pid \(pid) is executing "), "log: \(output)")
    }

    /// The confirmation that should be given, on the same real machinery: a pid that is not the
    /// app's, executing the bundle that was just installed.
    ///
    /// The process is started from the staged copy before the script runs, and the swap renames
    /// that copy to `$target` underneath it — so by the time the script asks, `lsof` reports it
    /// executing an image inside the installed bundle. Nothing here is stubbed except `launch`,
    /// and the fact under test is produced by the kernel: this is the same rename-following
    /// `refusesTheAppThatNeverQuit` relies on, seen from the other direction.
    @Test("a process executing the newly installed bundle is what counts as reopened")
    func confirmsAProcessExecutingTheNewBundle() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)
        let new = try Self.probe(executing: staged.bundle)
        defer { if new.isRunning { new.terminate() } }
        let pid = new.processIdentifier

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root,
                                        reopen: .realProcess(pid: pid))

        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.19.0", "log: \(output)")
        #expect(output.contains("reopened \(f.target.path) (by path), pid \(pid)"),
                "a real process executing the new bundle was refused: \(output)")
        #expect(output.contains("0.19.0 is running: its executing image is "), "log: \(output)")
        // The image it named is inside the installed bundle. A suffix, for the reason given in
        // `refusesTheAppThatNeverQuit`: the log has the physical path and the fixture does not.
        #expect(output.contains("/Applications/GitPic.app/Contents/MacOS/GitPic"),
                "log: \(output)")
        // No second attempt was needed — the by-name fallback echoes the bare name, and no
        // fixture path starts with it — and no anomaly: the pid the script waited on had gone.
        #expect(!output.contains("WOULD REOPEN GitPic"), "log: \(output)")
        #expect(!output.contains("ANOMALY"), "log: \(output)")
    }

    /// **The failure that must not lose the user's app.** With the new bundle unmovable, the
    /// script has to put the old one back — and the old one has to still be a working bundle,
    /// not the wrapper directory a fixed backup name would have produced.
    @Test("a failed swap rolls the old bundle back")
    func rollsBack() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)
        // `0o500`, and the execute bit is the whole trick. This test used to use `0o000`,
        // which also defeats the script's own `[ ! -d "$staged" ]` guard three lines before
        // the renames — `test -d` on a path inside a `0o000` directory fails on traversal — so
        // the script exited at "the staged bundle is gone" and **neither `mv` ever ran**. Both
        // assertions below then passed because nothing had happened at all, and deleting the
        // rollback line from the script left the test green. Measured, with the execute bit on:
        //
        //     chmod 500 stagedir
        //     [ -d stagedir/GitPic.app ]     -> true
        //     mv stagedir/GitPic.app apps/   -> "Permission denied"
        //
        // because `rename(2)` needs write permission on the *source's* parent to remove the
        // entry. It has to be the source side: both renames share the target's parent, so any
        // permission that stops the second one from the destination side stops the first one
        // too, and then the rollback is never reached either.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                             ofItemAtPath: staged.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: staged.directory.path)
        }

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root)

        // It really got past the guard and into the renames, which is what this test did not
        // do before: the first `mv` moved the old bundle aside and the second one refused.
        #expect(output.contains("could not put the new bundle in place"), "log: \(output)")
        // ...and the rollback really ran. Deleting `mv "$backup" "$target"` from the script
        // turns this red now; it did not before.
        #expect(output.contains("rolled back to the old bundle"), "log: \(output)")
        #expect(!output.contains("ROLLBACK FAILED"), "log: \(output)")
        // The reopen runs from the trap here, with the swap undone — so the same confirmation
        // means something different and has to say so. A process executing something inside
        // `$target` is the new version *only* if the second `mv` succeeded, and it did not.
        #expect(output.contains("the update did not happen, so this is the bundle that was"),
                "log: \(output)")
        #expect(!output.contains("0.19.0 is running"),
                "the trap's reopen claimed a version that was never installed: \(output)")

        // Whatever happened, the user still has a working 0.18.0 at the original path.
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0",
                "the old bundle was not restored: \(output)")
        // And it is the real bundle, not a directory containing one — the `mv a a.old` trap.
        #expect(!FileManager.default.fileExists(
            atPath: f.target.appendingPathComponent("GitPic.app").path),
            "the rollback restored a wrapper directory instead of the bundle")
        #expect(SelfUpdate.signatureIsIntact(at: f.target),
                "the restored bundle would be refused by Gatekeeper")
        // The rollback consumed the backup, so there is nothing left under that name.
        #expect(Self.entries(in: f.apps, prefix: ".GitPic-old-").isEmpty,
                "a backup survived a successful rollback")
    }

    /// The branch below the branch: the swap failed *and* the rollback failed. Nothing the
    /// filesystem can do provokes this — both renames use the same parent directory — so the
    /// test shadows `mv` on `PATH` for exactly the rollback call.
    @Test("a failed rollback leaves the old bundle findable and says how to restore it")
    func reportsAFailedRollback() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                             ofItemAtPath: staged.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: staged.directory.path)
        }
        // Fails only when asked to move the backup, so the first `mv` still moves the old
        // bundle aside and the second still refuses on the `0o500` directory above.
        let stub = f.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        let mv = stub.appendingPathComponent("mv")
        try Data("""
        #!/bin/bash
        case "$1" in
          */.GitPic-old-*) exit 1 ;;
        esac
        exec /bin/mv "$@"
        """.utf8).write(to: mv)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                             ofItemAtPath: mv.path)

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root,
                                        pathPrefix: stub.path)

        #expect(output.contains("ROLLBACK FAILED"), "log: \(output)")
        // The old bundle is where the log says it is, and the log says what to type. This is
        // the message the user acts on, and acting on it is what used to make the *next*
        // launch's sweep delete the bundle it was running from.
        let backups = Self.entries(in: f.apps, prefix: ".GitPic-old-")
        #expect(backups.count == 1, "the old bundle is gone: \(output)")
        if let backup = backups.first {
            let url = f.apps.appendingPathComponent(backup)
            #expect(output.contains("the old GitPic is at \(url.path)"), "log: \(output)")
            #expect(output.contains("to restore it by hand: mv \(url.path) \(f.target.path)"),
                    "log: \(output)")
            #expect(SelfUpdate.bundleVersion(of: url) == "0.18.0", "not a working bundle")
            #expect(SelfUpdate.signatureIsIntact(at: url), "would be refused by Gatekeeper")
        }
        // Nothing is at the install path — which is exactly why the message has to be right.
        #expect(!FileManager.default.fileExists(atPath: f.target.path))
    }

    @Test("an image holding the wrong version is refused before anything is staged")
    func refusesTheWrongVersion() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mountsBefore = Self.mountLeftovers()

        #expect(throws: SelfUpdate.InstallFailure.self) {
            _ = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.99.0",
                                     replacing: f.target)
        }
        let rest = try FileManager.default.contentsOfDirectory(atPath: f.apps.path)
        #expect(rest == ["GitPic.app"], "a refused image left something behind: \(rest)")
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
        #expect(Self.mountLeftovers() == mountsBefore, "a refusal left the image attached")
    }

    /// The writability answer, which is also the permission probe: staging is done by really
    /// creating the directory, so this is what "cannot install here" means.
    @Test("an unwritable parent directory is refused with advice, not an errno")
    func refusesAnUnwritableParent() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                             ofItemAtPath: f.apps.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: f.apps.path)
        }

        do {
            _ = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0", replacing: f.target)
            Issue.record("an unwritable parent must be refused")
        } catch let failure as SelfUpdate.InstallFailure {
            guard case .staging(let message) = failure else {
                Issue.record("expected .staging, got \(failure)")
                return
            }
            // Names the situation and the one thing the user can actually do about it. The
            // privileged alternative was considered and dropped: /Applications is
            // group-writable by admin, so an admin never needs it, and for a standard user an
            // elevation prompt an admin cannot inspect is a privilege-escalation primitive.
            #expect(message.contains("~/Applications"), "no usable advice: \(message)")
        }
    }

    @Test("a file that is not a disk image is refused")
    func refusesGarbage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-install-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountsBefore = Self.mountLeftovers()
        let notAnImage = root.appendingPathComponent("GitPic-0.19.0-macos-arm64.dmg")
        try Data("this is not a disk image".utf8).write(to: notAnImage)

        #expect(throws: SelfUpdate.InstallFailure.self) {
            _ = try SelfUpdate.stage(dmg: Self.measured(notAnImage), expectedVersion: "0.19.0",
                                     replacing: root.appendingPathComponent("GitPic.app"))
        }
        // Nothing was mounted, so the mount point was removed by the plain `rmdir` path — no
        // `hdiutil detach` was needed and none of it recursed into a volume.
        #expect(Self.mountLeftovers() == mountsBefore)
    }

    // MARK: - Quitting mid-install

    /// `exit(0)` runs no `defer`, so the quit has to undo staging itself.
    ///
    /// This is the behavioural half of `QuitPathContractTests.quitUndoesInFlightWork`, which can
    /// only grep: `Updater` lives in `GitPicApp`, an `executableTarget` tests cannot import, so
    /// what the drain *does* is asserted here and that `quit` still calls it is asserted there.
    @Test("the drain removes the staging directory and the download")
    func undoRemovesStagingAndDownload() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // Shaped like the real ones: a staging directory with a bundle inside it, beside the
        // target, and a disk image in the temporary directory.
        let staging = f.apps.appendingPathComponent(".GitPic-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.makeApp(at: staging.appendingPathComponent("GitPic.app"), version: "0.19.0")
        let download = f.root.appendingPathComponent("gitpic-update-\(UUID().uuidString).dmg")
        try FileManager.default.copyItem(at: f.dmg.url, to: download)

        Self.register(staging: staging)
        SelfUpdate.holdDownload(download)
        SelfUpdate.undoInFlightWork()

        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "the staging directory survived the quit")
        #expect(!FileManager.default.fileExists(atPath: download.path),
                "the disk image survived the quit")
        // The target is untouched — the drain undoes an install, it does not roll one back.
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
        // And the registry is empty, so a second quit has nothing to do.
        #expect(SelfUpdate.inFlightWork.drain().isEmpty)
    }

    /// The drain detaches a real image, and does not block waiting for it.
    ///
    /// Fire-and-forget, so the assertion has to poll: what is being checked is that the detach
    /// actually happens, not when. `detachMount` is deliberately *not* used on the quit path —
    /// it decides from `isMountPoint` and would unlink the mount point out from under an attach
    /// that had not landed yet, which is unrecoverable rather than merely leaked.
    @Test("the drain detaches an image the install had mounted")
    func undoDetachesTheMount() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mountsBefore = Self.mountLeftovers()

        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            args: ["attach", f.dmg.url.path, "-nobrowse", "-readonly", "-mountpoint", mount.path],
            timeout: 120)
        try #require(attach.status == 0 && !attach.timedOut,
                     "could not attach the fixture image: \(String(decoding: attach.stderr, as: UTF8.self))")
        // If the drain does not get it, this does — a leaked mount survives until reboot.
        defer { SelfUpdate.detachMount(at: mount) }
        try #require(FileManager.default.fileExists(
            atPath: mount.appendingPathComponent("GitPic.app").path), "nothing got mounted")

        Self.register(mount: mount)
        SelfUpdate.undoInFlightWork()

        // The background `sh` retries for up to ~2 s of its own, so allow more than that.
        var gone = false
        for _ in 0..<100 where !gone {
            gone = !FileManager.default.fileExists(atPath: mount.path)
            if !gone { Thread.sleep(forTimeInterval: 0.1) }
        }
        #expect(gone, "the mount point is still there, so the image is still attached")
        #expect(Self.mountLeftovers() == mountsBefore)
    }

    /// The handover to the install script and the quit cannot both win.
    ///
    /// The dangerous ordering is the second half: if a quit takes the staging directory while
    /// `installAndRelaunch` goes on to spawn the script anyway, the script finds no staged bundle
    /// and its `trap reopen EXIT` puts the *old* bundle back — a successful install turned into a
    /// silent rollback. So the claim has to be the atomic step, and `false` has to mean "do not
    /// hand off".
    @Test("the staged bundle goes to the script or to the quit, never to both")
    func stagedBundleHasOneOwner() throws {
        let apps = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-owner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: apps) }
        let staging = apps.appendingPathComponent(".GitPic-update-\(UUID().uuidString)")

        // The script wins: it claims, so the quit afterwards finds nothing to delete.
        Self.register(staging: staging)
        #expect(SelfUpdate.claimStaged(staging), "the first claim must succeed")
        #expect(SelfUpdate.inFlightWork.drain().staging == nil,
                "a claimed directory must not still be drainable")

        // The quit wins: it drained first, so the claim fails and the caller must not hand off.
        Self.register(staging: staging)
        #expect(SelfUpdate.inFlightWork.drain().staging == staging)
        #expect(!SelfUpdate.claimStaged(staging),
                "claiming after a drain would hand the script a directory being deleted")

        // And a claim only ever matches the directory it was given.
        Self.register(staging: staging)
        #expect(!SelfUpdate.claimStaged(apps.appendingPathComponent(".GitPic-update-other")))
        #expect(SelfUpdate.claimStaged(staging))
    }

    /// The mount path reaches the detach as an argument, never as script text.
    ///
    /// A shape assertion rather than a behaviour one, and it is here because the alternative is a
    /// quoting bug in generated shell: `$1` cannot be broken by a path, an interpolated
    /// `\(mount.path)` can. Absolute command paths for the same class of reason — the drain runs
    /// with whatever `PATH` the app inherited.
    @Test("the detach script takes its path as an argument, not as text")
    func detachScriptIsQuotingProof() {
        let script = SelfUpdate.detachScript
        #expect(script.contains("\"$1\""), "the path must arrive as a quoted positional argument")
        #expect(script.contains("/usr/bin/hdiutil"), "hdiutil must be absolute")
        #expect(script.contains("/bin/rmdir"), "rmdir must be absolute")
        #expect(!script.contains("gitpic-mount-"),
                "no path may be interpolated into the script text")
        #expect(script.contains("-force"),
                "a polite detach exits 16 on a busy mount — see detachMount's measurement")
    }

    /// A registration made after the drain has already been and gone must be refused.
    ///
    /// This is the bug `quitDuringStagingLeavesNothing` caught when the registrations were plain
    /// setters. The drain took the mount, `stage` carried on — it had no way to know — created its
    /// staging directory, registered it into a table nothing would read again, copied a whole
    /// bundle into it and returned successfully. Nothing ever removed it.
    ///
    /// It is not a test-only window. `quit` runs a blocking `UserDefaults.synchronize()` between
    /// the drain and `exit(0)`, which is ample time for `createDirectory` to land. So registering
    /// and asking "has a quit happened" have to be one atomic step, and the answer has to be
    /// something `stage` acts on.
    @Test("nothing new may be registered once a quit has drained")
    func refusesToRegisterAfterADrain() {
        let stale = SelfUpdate.inFlightWork.generation
        _ = SelfUpdate.inFlightWork.drain()

        let mount = URL(fileURLWithPath: "/tmp/gitpic-mount-never-created")
        let staging = URL(fileURLWithPath: "/tmp/.GitPic-update-never-created")
        #expect(!SelfUpdate.inFlightWork.hold(mount: mount, since: stale),
                "a mount registered after the drain would never be detached")
        #expect(!SelfUpdate.inFlightWork.hold(staging: staging, since: stale),
                "a staging directory registered after the drain would never be removed")
        // Nothing was recorded, so a later drain has nothing to act on.
        #expect(SelfUpdate.inFlightWork.drain().isEmpty)
        // And the current generation still works — the refusal is per-generation, not a latch.
        // A latch would poison every later test in this process, since the registry is
        // process-wide and `swift test` runs one process.
        #expect(SelfUpdate.inFlightWork.hold(mount: mount,
                                            since: SelfUpdate.inFlightWork.generation))
        SelfUpdate.inFlightWork.release(mount: mount)
    }

    /// The real race: a quit landing while `stage` is copying.
    ///
    /// Everything above registers by hand. This one drives `stage` on another thread, waits until
    /// it has actually mounted the image, and drains from underneath it — which is what
    /// 「退出 GitPic」 during an install does. `stage` then unwinds through its own `defer`s at the
    /// same time, so the two cleanups converge on the same paths; the assertion is about the end
    /// state, because that convergence is the design and not a hazard.
    @Test("a quit during staging leaves nothing behind")
    func quitDuringStagingLeavesNothing() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mountsBefore = Self.mountLeftovers()

        let done = DispatchSemaphore(value: 0)
        let target = f.target
        let dmg = f.dmg
        DispatchQueue.global().async {
            // Throws or returns — either is a legitimate outcome of being drained mid-flight, and
            // which one depends on where the SIGKILL lands. The end state is what matters.
            _ = try? SelfUpdate.stage(dmg: dmg, expectedVersion: "0.19.0", replacing: target)
            done.signal()
        }

        // Wait for it to reach the window this is about, rather than sleeping a guessed interval.
        var mounted: URL?
        for _ in 0..<600 where mounted == nil {
            mounted = SelfUpdate.inFlightWork.mountInFlight
            if mounted == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        try #require(mounted, "stage never registered a mount, so nothing was exercised")

        SelfUpdate.undoInFlightWork()
        #expect(done.wait(timeout: .now() + 120) == .success, "stage never finished unwinding")

        // Give the fire-and-forget detach its retries.
        var settled = false
        for _ in 0..<100 where !settled {
            settled = Self.mountLeftovers() == mountsBefore
            if !settled { Thread.sleep(forTimeInterval: 0.1) }
        }
        #expect(settled, "a mount was left attached: \(Self.mountLeftovers())")
        #expect(Self.entries(in: f.apps, prefix: ".GitPic-update-").isEmpty,
                "a staging directory was left beside the target")
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0",
                "the installed bundle must be untouched")
        #expect(SelfUpdate.inFlightWork.drain().isEmpty, "the registry was left dirty")
    }

    // MARK: - Cancellation

    /// "Cancel on the Nth question", so a test can land the cancellation between two chosen
    /// steps of `stage`. Locked because the closure is `@Sendable` and `stage` is documented
    /// as callable off the main actor.
    private final class CancelFrom: @unchecked Sendable {
        private let lock = NSLock()
        private let nth: Int
        private var asked = 0
        init(_ nth: Int) { self.nth = nth }
        /// How many times `stage` asked, which is how the test knows it asked at all.
        var count: Int { lock.lock(); defer { lock.unlock() }; return asked }
        var callback: @Sendable () -> Bool {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                asked += 1
                return asked >= nth
            }
        }
    }

    @Test("cancelling between two steps stages nothing and mounts nothing",
          arguments: [1, 2, 3, 4, 5])
    func cancels(atQuestion nth: Int) throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let mountsBefore = Self.mountLeftovers()
        let cancel = CancelFrom(nth)

        do {
            _ = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                     replacing: f.target, isCancelled: cancel.callback)
            Issue.record("staging continued after the user cancelled")
        } catch let failure as SelfUpdate.InstallFailure {
            // Its own case, so the sheet can tell "you stopped this" from "this broke".
            #expect(failure == .cancelled, "expected .cancelled, got \(failure)")
        }

        #expect(cancel.count == nth, "the check was not reached in order")
        // Unwound through the same two `defer`s a failure uses: image detached, mount point
        // gone, staging directory gone, installed bundle untouched.
        #expect(Self.mountLeftovers() == mountsBefore, "a cancel left the image attached")
        let rest = try FileManager.default.contentsOfDirectory(atPath: f.apps.path)
        #expect(rest == ["GitPic.app"], "a cancel left something behind: \(rest)")
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
    }

    @Test("the default never cancels, so an existing caller still stages")
    func stagesWithoutACancelCallback() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // The default argument is what keeps every current call site compiling, so it is worth
        // one assertion that it means "carry on" rather than "stop".
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)
        #expect(SelfUpdate.bundleVersion(of: staged.bundle) == "0.19.0")
    }

    // MARK: - Sweeping leftovers

    /// Two leftovers in the shapes an install really produces: the backup *is* a bundle
    /// (`mv GitPic.app .GitPic-old-x` renames the bundle itself), and the staging directory
    /// *contains* one.
    private static func leftovers(in apps: URL) throws -> (backup: URL, staging: URL) {
        let backup = apps.appendingPathComponent(".GitPic-old-\(UUID().uuidString)")
        try makeApp(at: backup, version: "0.18.0")
        let staging = apps.appendingPathComponent(".GitPic-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try makeApp(at: staging.appendingPathComponent("GitPic.app"), version: "0.19.0")
        return (backup, staging)
    }

    /// **The path that could leave the machine with no GitPic at all.** The script hits
    /// `ROLLBACK FAILED`, the user follows the log and starts the app from the backup, and the
    /// sweep at that launch matched its own bundle's prefix and deleted the directory it was
    /// running from. Structural, so no cutoff can reopen it: the cutoff here is in the future,
    /// which makes every leftover eligible on age.
    @Test("the sweep never deletes the bundle it is running from")
    func sweepProtectsTheRunningBundle() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let everythingIsOldEnough = Date().addingTimeInterval(60)

        // Launched from the backup: `Bundle.main.bundleURL` is the backup directory itself,
        // because the bundle root is what holds `Contents/MacOS/GitPic`.
        var (backup, staging) = try Self.leftovers(in: f.apps)
        var swept = SelfUpdate.sweepLeftovers(in: [f.apps], olderThan: everythingIsOldEnough,
                                             running: backup)
        #expect(swept.map(\.lastPathComponent) == [staging.lastPathComponent],
                "swept: \(swept.map(\.lastPathComponent))")
        #expect(SelfUpdate.bundleVersion(of: backup) == "0.18.0",
                "the sweep deleted the bundle it was running from")

        // Launched from a staged copy, which is what the by-name reopen fallback can bring up:
        // there the running bundle is one level inside the leftover directory.
        try FileManager.default.removeItem(at: backup)
        (backup, staging) = try Self.leftovers(in: f.apps)
        swept = SelfUpdate.sweepLeftovers(
            in: [f.apps], olderThan: everythingIsOldEnough,
            running: staging.appendingPathComponent("GitPic.app"))
        #expect(swept.map(\.lastPathComponent) == [backup.lastPathComponent],
                "swept: \(swept.map(\.lastPathComponent))")
        #expect(SelfUpdate.bundleVersion(of: staging.appendingPathComponent("GitPic.app"))
                == "0.19.0", "the sweep deleted the directory it was running from")

        // A name that is a string prefix of the running bundle's but not a path prefix is not
        // protected by it.
        let lookalike = f.apps.appendingPathComponent(staging.lastPathComponent + "-old")
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        swept = SelfUpdate.sweepLeftovers(
            in: [f.apps], olderThan: everythingIsOldEnough,
            running: staging.appendingPathComponent("GitPic.app"))
        #expect(swept.map(\.lastPathComponent).contains(lookalike.lastPathComponent),
                "swept: \(swept.map(\.lastPathComponent))")
    }

    /// The *default* `running:` must be the image the caller is actually executing, not the
    /// path it was launched from. The two differ because the swap renames the bundle
    /// directory and that does not stop a running process (measured twice in this feature),
    /// so a caller the swap happened underneath executes from `.GitPic-old-<uuid>` while
    /// `Bundle.main.bundleURL` still says `$target`. A guard pointed at the launch path
    /// protects nothing the process executes and leaves the backup — the only other copy of
    /// the app — unprotected.
    ///
    /// Uses a real process and the real `lsof` line because the two sides of the comparison
    /// arrive in different spellings: `contentsOfDirectory` reports `/var/folders/…` while
    /// `lsof` reports `/private/var/folders/…`, and the question of whether `contains`
    /// reconciles them is exactly what this test exists to answer.
    @Test("the sweep protects the image it executes, not where it was launched")
    func sweepProtectsTheExecutingImage() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // A real Mach-O process running from the fixture's bundle, then the swap happens
        // underneath it.
        let app = try Self.probe(executing: f.target)
        defer { if app.isRunning { app.terminate() } }
        let backup = f.apps.appendingPathComponent(".GitPic-old-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: f.target, to: backup)
        // Moving it is what makes this a survivor: the executable is no longer at the
        // launched-from path, but the process is still running from it.
        #expect(app.isRunning)
        let image = try Self.lsofImage(pid: app.processIdentifier)
        #expect(image.path.contains(".GitPic-old-"),
                "the probe is not executing from the backup: \(image.path)")

        // An unoccupied backup must still go — the protection has to be per-directory, not
        // per-name.
        let unoccupied = f.apps.appendingPathComponent(".GitPic-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unoccupied, withIntermediateDirectories: true)

        let swept = SelfUpdate.sweepLeftovers(
            in: [f.apps], olderThan: Date().addingTimeInterval(60), running: image)
        #expect(swept.map(\.lastPathComponent) == [unoccupied.lastPathComponent],
                "swept: \(swept.map(\.lastPathComponent))")
        #expect(FileManager.default.fileExists(atPath: backup.path),
                "the sweep deleted the backup its process is executing from")
    }

    /// The `lsof` line the default uses, for a given pid — in the test so the *test* decides
    /// which process is guarded rather than relying on the code under test to agree with
    /// itself.
    private static func lsofImage(pid: Int32) throws -> URL {
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            args: ["-a", "-p", "\(pid)", "-d", "txt", "-Fn"], timeout: 10)
        guard out.status == 0,
              let line = String(decoding: out.stdout, as: UTF8.self)
                  .split(separator: "\n").first(where: { $0.hasPrefix("n/") })
        else { throw FixtureError.probe("lsof pid \(pid)") }
        return URL(fileURLWithPath: String(line.dropFirst()))
    }

    /// The one-day floor, on the only clock that measures what it claims to.
    ///
    /// The fixture cannot fabricate staleness — `touch` moves mtime, and measured, it does not
    /// move ctime, which is the point — so the cutoff is injected instead. This is the half of
    /// `SelfUpdateRouteTests.sweepsOnlyStaleLeftovers` that belongs here, next to the code.
    @Test("a leftover is aged from when it was created, not from the build time it inherited")
    func sweepAgesFromCtimeNotMtime() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let (backup, staging) = try Self.leftovers(in: f.apps)
        // What every real update looks like: `mv` does not touch mtime and `ditto` preserves
        // it, so a backup's mtime is the *build* time of the release it came from — months
        // old on the day it is created. Under the old rule that was instantly past a one-day
        // floor, so the backup was gone before the new version had ever launched.
        let buildTime = Date().addingTimeInterval(-86_400 * 200)
        for url in [backup, staging] {
            try FileManager.default.setAttributes([.modificationDate: buildTime],
                                                 ofItemAtPath: url.path)
        }

        #expect(SelfUpdate.sweepLeftovers(in: [f.apps], running: nil).isEmpty,
                "a leftover created moments ago was swept on its inherited mtime")
        #expect(FileManager.default.fileExists(atPath: backup.path))

        // Both go once the cutoff is past the time they were actually created.
        let swept = SelfUpdate.sweepLeftovers(in: [f.apps],
                                             olderThan: Date().addingTimeInterval(60),
                                             running: nil)
        #expect(Set(swept.map(\.lastPathComponent))
                == [backup.lastPathComponent, staging.lastPathComponent],
                "swept: \(swept.map(\.lastPathComponent))")
    }

    @Test("the sweep only ever touches the two names it owns")
    func sweepLeavesEverythingElseAlone() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Something that merely looks similar, a real app, and a real app of someone else's.
        let bystanders = ["GitPic.app", ".GitPicSomethingElse", "Other.app"]
        for name in bystanders where name != "GitPic.app" {
            try FileManager.default.createDirectory(
                at: f.apps.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let swept = SelfUpdate.sweepLeftovers(in: [f.apps],
                                             olderThan: Date().addingTimeInterval(60),
                                             running: nil)
        #expect(swept.isEmpty, "swept: \(swept.map(\.lastPathComponent))")
        for name in bystanders {
            #expect(FileManager.default.fileExists(
                atPath: f.apps.appendingPathComponent(name).path), "\(name) must not be swept")
        }
    }

    // MARK: - Running the generated script

    /// Replace one line of the generated script, refusing to run if it is no longer there.
    ///
    /// The stubs are the only reason this suite can run the real script at all, so a reworded
    /// line must not quietly turn one into a no-op. A stub that silently stopped applying is
    /// how `rollsBack` came to assert nothing.
    private static func stub(_ script: String, _ line: String, with replacement: String) throws
        -> String {
        guard script.contains(line) else {
            throw FixtureError.stub("the generated script no longer contains: \(line)")
        }
        return script.replacingOccurrences(of: line, with: replacement)
    }

    /// The `lsof` line, quoted once. Every test either replaces it or asserts it is still there,
    /// so a rewording cannot quietly turn one of them into a test of something else.
    private static let imageLine =
        #"image() { lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n '/^n[/]/{s/^n//;p;q;}'; }"#

    /// What the stubbed outside world does when the script goes looking for the app.
    ///
    /// A value rather than the two booleans this used to take: the confirmation now reads two
    /// things about a candidate process — its pid, and the image it is really executing — so
    /// "does the app come up" is no longer a yes or no.
    private enum Reopen {
        /// A pid that is not the app's, executing something inside `$target`. Faked at both
        /// lines, because all a real process adds *here* is that `lsof` answers at all, and the
        /// three `realProcess` tests spend a real one on exactly that.
        case theNewBundle
        /// LaunchServices accepts the request and nothing ever appears.
        case nothing
        /// LaunchServices refuses.
        case refused
        /// A real, already-running process, handed to `candidates` by pid with the script's own
        /// `lsof` line left alone — the only way to test the thing the fix turns on.
        ///
        /// Started before the script rather than by the `launch` stub because the script cannot
        /// tell the difference: it calls `launch` and then polls. Keeping the process in the
        /// test's hands is what makes sure none of them outlives the test.
        case realProcess(pid: Int32)
    }

    /// Run the generated script with the three lines that reach outside its own directory
    /// stubbed — the one thing a test must not do is launch an application.
    ///
    /// - Parameters:
    ///   - pid: the pid the script waits on and refuses to accept as evidence. The default has
    ///     already exited, so the wait falls straight through; a live one is how
    ///     ``refusesTheAppThatNeverQuit`` makes the wait expire.
    ///   - reopen: what the stubs answer. See ``Reopen``.
    ///   - pathPrefix: prepended to the script's own `PATH`, which is otherwise fixed on
    ///     purpose. The only way to make one specific `mv` fail.
    private static func runScript(
        staged: SelfUpdate.Staged, log: URL, root: URL,
        pid: Int32 = 999_999, reopen: Reopen = .theNewBundle, pathPrefix: String? = nil
    ) throws -> String {
        var script = SelfUpdate.installScript(staged: staged, pid: pid, log: log)
        let launchBody: String
        // No candidate at all, unless one of the cases below produces one.
        var candidatesBody = "candidates() { :; }"
        var imageBody: String?
        switch reopen {
        case .theNewBundle:
            launchBody = #"launch() { echo "WOULD REOPEN $1"; }"#
            candidatesBody = "candidates() { echo 4242; }"
            imageBody = #"image() { echo "$realtarget/Contents/MacOS/GitPic"; }"#
        case .nothing:
            launchBody = #"launch() { echo "WOULD REOPEN $1"; }"#
        case .refused:
            // Measured on the real thing: `open -a` exits 0 when LaunchServices accepts the
            // request, which is not the same as the app running — so a non-zero status is the
            // one thing it says that *is* worth believing.
            launchBody = #"launch() { echo "WOULD REOPEN $1"; return 1; }"#
        case .realProcess(let live):
            launchBody = #"launch() { echo "WOULD REOPEN $1"; }"#
            candidatesBody = "candidates() { echo \(live); }"
        }
        script = try stub(script, #"launch() { open -a "$1"; }"#, with: launchBody)
        script = try stub(script, "candidates() { pgrep -x GitPic 2>/dev/null; }",
                          with: candidatesBody)
        if let imageBody {
            script = try stub(script, Self.imageLine, with: imageBody)
        } else if !script.contains(Self.imageLine) {
            throw FixtureError.stub("the generated script no longer contains: \(Self.imageLine)")
        }
        // Both polls flattened, always. The wait for the app to quit is 120 ticks and each
        // confirmation is 20, so at the real half-second any test that expects one of them to
        // expire would sit there for a minute. Nothing asserts on the interval.
        script = try stub(script, "sleep 0.5", with: "sleep 0")
        if let pathPrefix {
            script = try stub(script, "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                              with: "PATH=\(pathPrefix):/usr/bin:/bin:/usr/sbin:/sbin")
        }
        let file = root.appendingPathComponent("install-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        _ = try ChildProcess.run(executable: URL(fileURLWithPath: "/bin/bash"),
                                 args: [file.path], timeout: 120)
        return (try? String(contentsOf: log, encoding: .utf8)) ?? "<no log>"
    }
}
