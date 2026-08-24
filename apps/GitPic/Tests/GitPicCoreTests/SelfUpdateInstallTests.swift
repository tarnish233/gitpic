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
    /// **A fixed directory, not a per-run UUID.** Swift Testing has no suite-level teardown, so
    /// a unique name per run leaks one signed bundle plus a disk image into the temporary
    /// directory every time the suite executes — measured, after four runs, four directories.
    /// A fixed name means at most one exists, and `hdiutil create -ov` overwrites it.
    private static let sharedImage: Result<URL, Error> = {
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitpic-install-test-image")
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
        let dmg: URL
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
        return Fixture(root: root, target: target, dmg: dmg)
    }

    @Test("staging copies the image's app beside the target, signature and all")
    func stages() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)

        // Beside the target, so the swap is a rename and not a copy across devices — and so
        // that creating it was the permission check.
        #expect(staged.directory.deletingLastPathComponent().path
                == f.target.deletingLastPathComponent().path)
        #expect(staged.directory.lastPathComponent.hasPrefix(".GitPic-update-"))
        #expect(SelfUpdate.bundleVersion(of: staged.bundle) == "0.19.0")
        // `ditto` was used rather than `cp -R` precisely so this passes: an ad-hoc signature
        // lives in extended attributes, which `cp -R` does not carry across.
        let check = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            args: ["--verify", "--deep", "--strict", staged.bundle.path], timeout: 120)
        #expect(check.status == 0, "the staged copy failed codesign — was it copied with cp?")
        // Nothing has touched the installed bundle yet.
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
    }

    /// The swap itself, by running the generated script.
    @Test("the script swaps the bundles, reopens, and leaves nothing behind")
    func swaps() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let staged = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.19.0",
                                         replacing: f.target)

        let log = f.root.appendingPathComponent("install.log")
        let output = try Self.runScript(staged: staged, log: log, root: f.root)

        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.19.0", "log: \(output)")
        #expect(output.contains("installed 0.19.0"), "log: \(output)")
        // The relaunch ran, and it ran *before* the leftovers were removed.
        #expect(output.contains("WOULD REOPEN"), "the app was never reopened: \(output)")
        let rest = try FileManager.default.contentsOfDirectory(
            atPath: f.target.deletingLastPathComponent().path)
        #expect(!rest.contains { $0.hasPrefix(".GitPic-update-") }, "staging left: \(rest)")
        #expect(!rest.contains { $0.hasPrefix(".GitPic-old-") }, "backup left: \(rest)")
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
        // Make the second `mv` fail by removing what it would move.
        try FileManager.default.removeItem(at: staged.bundle)
        // ...but leave the staging directory, so the script gets past its existence check and
        // into the renames. A directory where a bundle is expected is what fails the move.
        try FileManager.default.createDirectory(at: staged.bundle,
                                               withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                             ofItemAtPath: staged.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: staged.directory.path)
        }

        let log = f.root.appendingPathComponent("install.log")
        _ = try Self.runScript(staged: staged, log: log, root: f.root)

        // Whatever happened, the user still has a working 0.18.0 at the original path.
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? "<no log>"
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0",
                "the old bundle was not restored: \(logged)")
        // And it is the real bundle, not a directory containing one — the `mv a a.old` trap.
        #expect(!FileManager.default.fileExists(
            atPath: f.target.appendingPathComponent("GitPic.app").path),
            "the rollback restored a wrapper directory instead of the bundle")
    }

    @Test("an image holding the wrong version is refused before anything is staged")
    func refusesTheWrongVersion() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        #expect(throws: SelfUpdate.InstallFailure.self) {
            _ = try SelfUpdate.stage(dmg: f.dmg, expectedVersion: "0.99.0",
                                     replacing: f.target)
        }
        let rest = try FileManager.default.contentsOfDirectory(
            atPath: f.target.deletingLastPathComponent().path)
        #expect(rest == ["GitPic.app"], "a refused image left something behind: \(rest)")
        #expect(SelfUpdate.bundleVersion(of: f.target) == "0.18.0")
    }

    /// The writability answer, which is also the permission probe: staging is done by really
    /// creating the directory, so this is what "cannot install here" means.
    @Test("an unwritable parent directory is refused with advice, not an errno")
    func refusesAnUnwritableParent() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let apps = f.target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                             ofItemAtPath: apps.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: apps.path)
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
        let notAnImage = root.appendingPathComponent("GitPic-0.19.0-macos-arm64.dmg")
        try Data("this is not a disk image".utf8).write(to: notAnImage)

        #expect(throws: SelfUpdate.InstallFailure.self) {
            _ = try SelfUpdate.stage(dmg: notAnImage, expectedVersion: "0.19.0",
                                     replacing: root.appendingPathComponent("GitPic.app"))
        }
    }

    /// Run the generated script with the reopen stubbed out — the one thing a test must not do
    /// is launch an application — and with a pid that has already exited so the wait loop
    /// falls straight through.
    private static func runScript(staged: SelfUpdate.Staged, log: URL, root: URL) throws
        -> String {
        var script = SelfUpdate.installScript(staged: staged, pid: 999_999, log: log)
        script = script.replacingOccurrences(
            of: "open -a \"$target\" 2>/dev/null && return 0",
            with: "echo \"WOULD REOPEN $target\"; return 0")
        let file = root.appendingPathComponent("install-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        _ = try ChildProcess.run(executable: URL(fileURLWithPath: "/bin/bash"),
                                 args: [file.path], timeout: 120)
        return (try? String(contentsOf: log, encoding: .utf8)) ?? "<no log>"
    }
}
