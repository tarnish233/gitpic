import Foundation

/// A Homebrew-shaped install under a scratch root, built to what was measured off a real
/// machine rather than to what seemed likely:
///
///     /opt/homebrew/bin/gitpic                        -> /Applications/GitPic.app/Contents/Resources/gitpic
///     /opt/homebrew/Caskroom/gitpic/0.20.9/GitPic.app -> /Applications/GitPic.app
///
/// Shared by two suites that want the same shape for different reasons: `SelfUpdateInstallTests`
/// asserts a swap leaves both links resolving to the *new* bundle, and `CaskOwnershipTests`
/// asserts the Caskroom link is what makes detection answer "Homebrew's".
///
/// Every destination is absolute and rooted at the caller's own fixture, so the layout is fully
/// relocatable — which is the property that lets detection be pointed at it instead of at the
/// machine's real `/opt/homebrew`. Without that seam the only way to test detection would be to
/// install a cask.
enum HomebrewShape {

    struct Layout {
        /// Stands in for `HOMEBREW_PREFIX`.
        let prefix: URL
        /// `Caskroom/gitpic/<version>/GitPic.app` → the bundle.
        let caskLink: URL
        /// `bin/gitpic` → the CLI inside the bundle.
        let binLink: URL
    }

    /// Build the two links a cask leaves behind, pointing at `bundle`.
    ///
    /// The three shell completions the cask also installs are deliberately not here: they are
    /// real files rather than links, which is exactly why they go stale after a self-update and
    /// why there is nothing about them for either suite to assert.
    @discardableResult
    static func install(
        bundle: URL, under root: URL, version: String, prefixName: String = "homebrew"
    ) throws -> Layout {
        let prefix = root.appendingPathComponent(prefixName)
        let caskroom = prefix.appendingPathComponent("Caskroom/gitpic/\(version)")
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        let binLink = prefix.appendingPathComponent("bin/gitpic")
        let caskLink = caskroom.appendingPathComponent("GitPic.app")
        try FileManager.default.createSymbolicLink(
            at: binLink,
            withDestinationURL: bundle.appendingPathComponent("Contents/Resources/gitpic"))
        try FileManager.default.createSymbolicLink(at: caskLink, withDestinationURL: bundle)
        return Layout(prefix: prefix, caskLink: caskLink, binLink: binLink)
    }

    /// A tap clone where `brew update` would leave one, declaring `version`.
    ///
    /// Written as a whole cask rather than one line, so the parser is exercised against the
    /// shape it will really meet — comments above the stanza included, since the tap's own
    /// `Casks/gitpic.rb` opens with a long one.
    ///
    /// **`repositorySubpath` is what makes the Intel layout expressible**, and it exists because
    /// this fixture used to hardcode `<prefix>/Library/Taps` and so could not have caught the
    /// bug it was covering. Taps hang off `HOMEBREW_REPOSITORY`, which equals the prefix only
    /// when `bin/brew` is a real file: on Intel `/usr/local/bin/brew` links into
    /// `/usr/local/Homebrew`, so the clone is at `/usr/local/Homebrew/Library/Taps` while the
    /// Caskroom stays at `/usr/local/Caskroom`. Pass `"Homebrew"` for that shape.
    ///
    /// `lineEnding` is the other axis a single fixture hid. A clone checked out with
    /// `core.autocrlf` set has CRLF line endings, and Swift treats `"\r\n"` as one `Character`
    /// that does not equal `"\n"` — so a parser splitting on `"\n"` saw the whole file as a
    /// single line and read no version at all, while the Rust parser on the same bytes read it
    /// correctly.
    static func tapClone(
        under prefix: URL,
        declaring version: String,
        repositorySubpath: String? = nil,
        lineEnding: String = "\n"
    ) throws {
        var repository = prefix
        if let repositorySubpath {
            repository = repository.appendingPathComponent(repositorySubpath)
        }
        let casks = repository
            .appendingPathComponent("Library/Taps/tarnish233/homebrew-tap/Casks")
        try FileManager.default.createDirectory(at: casks, withIntermediateDirectories: true)
        let cask = """
            cask "gitpic" do
              # The tap rewrites only the version, sha256 and url lines by targeted sub!.
              version "\(version)"
              sha256 "\(String(repeating: "ab", count: 32))"

              app "GitPic.app"
            end
            """
        let text = lineEnding == "\n"
            ? cask
            : cask.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: lineEnding)
        try text.write(to: casks.appendingPathComponent("gitpic.rb"), atomically: true,
                       encoding: .utf8)
    }

    /// A scratch root with an empty `GitPic.app` directory in an Applications directory.
    ///
    /// `detect` compares paths and never opens the bundle, so a real signed app would be cost
    /// without coverage — but the directory has to *exist*, because a dangling Caskroom link is
    /// deliberately not treated as evidence.
    static func bundle(named appDir: String = "Applications") throws -> (root: URL, bundle: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-cask-test-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent(appDir).appendingPathComponent("GitPic.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        return (root, bundle)
    }
}
