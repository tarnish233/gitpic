import Foundation

/// Whether Homebrew owns this bundle, and what its cask currently offers.
///
/// **Why the cheap check is possible at all, and why Claude Code's one-liner does not port.**
/// Claude Code detects a package-managed install with `execPath().includes("/Caskroom/")`, which
/// works because its cask ships a `binary` artifact: the real executable stays in the Caskroom
/// and `HOMEBREW_PREFIX/bin/claude` is a link to it. GitPic's cask uses an `app` stanza, which
/// **moves** the bundle to an Applications directory and leaves a link pointing back at it —
/// measured on a real install:
///
///     /Applications/GitPic.app                          (a real directory)
///     /opt/homebrew/Caskroom/gitpic/0.20.9/GitPic.app -> /Applications/GitPic.app
///
/// So `Bundle.main.bundleURL` never contains `/Caskroom/`, and the evidence has to be read in
/// the other direction: a Caskroom link that resolves *to us*. That also makes the answer
/// correct at any `--appdir`, because the link follows wherever the bundle went.
///
/// **What this deliberately is not.** The implementation `bb07783` deleted asked `brew` itself —
/// a login-shell probe for up to 8 s, then `brew list --cask gitpic` for up to 20 s, per prefix,
/// on a serial queue, every time the sheet opened. `SelfUpdateRoute`'s header records what that
/// cost. Nothing here spawns anything: it is a directory scan and a `readlink`, so the question
/// can be asked on the sheet-open path without the sheet paying for it.
///
/// A side effect worth naming: `scripts/check-self-update.sh` installs its test copy at
/// `~/Applications/GitPic.app`, and a path comparison correctly calls that "not Homebrew's". A
/// `brew list --cask` probe would have answered about the *machine* rather than about that
/// bundle, flipped the test copy onto the Homebrew branch, and broken the script.
public enum CaskOwnership: Equatable, Sendable {

    /// Where a cask keeps its record of an installed bundle, and the two prefixes to look in.
    ///
    /// An Intel and an Apple Silicon Homebrew are independent installations with independent
    /// Caskrooms, so both are searched rather than one being derived from the other. This
    /// mirrors `install_source.rs`'s `default_prefixes` on the Rust side; the two answer
    /// different questions (that one is about a *binary*'s origin, this one about a *bundle*'s
    /// owner) and share only this list.
    public static var defaultPrefixes: [URL] {
        [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]
    }

    /// The cask token, and the tap that defines it as Homebrew lays it out on disk.
    ///
    /// Spelled here as well as in `release.rs` because nothing can share a constant across the
    /// two languages. They have to agree, and the test that pins the Rust side
    /// (`the_release_feed_is_a_compile_time_constant`) has a counterpart here for the same
    /// reason: a version read out of the wrong file would be shown next to a command the user
    /// is being told to run.
    public static let cask = "gitpic"
    static let tapOwner = "tarnish233"
    static let tapRepository = "homebrew-tap"

    /// A cask installation of a particular bundle: which cask, and which prefix recorded it.
    ///
    /// The prefix travels with the answer because the next question — what does the tap offer —
    /// is asked of a file under that same prefix, and a machine with two Homebrews should not
    /// have its cask found under one and its tap read under the other.
    public struct Install: Equatable, Sendable {
        public let cask: String
        public let prefix: URL
    }

    /// Whether any `Caskroom/<cask>/*/GitPic.app` under `prefixes` resolves to `bundle`.
    ///
    /// Conclusive by construction: a directory either holds such a link or it does not, so
    /// there is no third "could not tell" state to propagate. That is what keeps
    /// `SelfUpdate.Route.unavailable`'s `retryable` flag dead — the flag's one former source was
    /// the probe this replaces, which could time out.
    public static func detect(bundle: URL, prefixes: [URL] = defaultPrefixes) -> Install? {
        let bundle = bundle.resolvingSymlinksInPath().standardizedFileURL
        for prefix in prefixes {
            let versions = prefix.appendingPathComponent("Caskroom").appendingPathComponent(cask)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: versions, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let link = entry.appendingPathComponent("GitPic.app")
                guard FileManager.default.fileExists(atPath: link.path) else { continue }
                let target = link.resolvingSymlinksInPath().standardizedFileURL
                if target == bundle {
                    return Install(cask: cask, prefix: prefix)
                }
            }
        }
        return nil
    }

    /// The version the tap's cask declares, read off the clone Homebrew already keeps, or `nil`.
    ///
    /// **A lower bound on what `brew upgrade` would find, never an upper one.** Homebrew clones
    /// a third-party tap rather than serving it from its API, so the file is right there at
    /// `<prefix>/Library/Taps/<owner>/<repo>/Casks/<cask>.rb` and costs nothing to read. But it
    /// is only as fresh as the last `brew update`, and `brew upgrade` auto-updates before it
    /// resolves anything — so this file saying "nothing newer" does not mean the command would
    /// do nothing. It is worth reading first precisely because the *useful* direction is
    /// reliable: if this already names a version newer than the installed bundle, then
    /// `brew upgrade` will certainly find at least that, and no request has to be made at all.
    ///
    /// Returning `nil` therefore means "ask something authoritative", not "up to date".
    public static func localTapVersion(prefix: URL) -> String? {
        let file = prefix
            .appendingPathComponent("Library/Taps")
            .appendingPathComponent(tapOwner)
            .appendingPathComponent(tapRepository)
            .appendingPathComponent("Casks")
            .appendingPathComponent("\(cask).rb")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return declaredVersion(in: text)
    }

    /// The version a cask declares, or `nil` for anything this cannot compare.
    ///
    /// The same rules as `release.rs`'s `cask_version`, and the same reason for being strict
    /// rather than lenient: it takes the first `version` stanza that is a plain quoted literal
    /// parsing as three numbers, and refuses an interpolation, `version :latest`, and
    /// Homebrew's comma-separated `version "1.2,345"` form (`Cask#version.csv`). A cask is Ruby
    /// and this is not a Ruby parser.
    ///
    /// `nil` is the safe answer and a guess is not. It becomes "could not tell", which shows the
    /// upgrade command with a caveat; a version invented out of an unparseable string could
    /// instead show 「已是 Homebrew 提供的最新版本」 over a real update — the one outcome that
    /// hides a pending upgrade behind a reassuring sentence.
    static func declaredVersion(in cask: String) -> String? {
        for line in cask.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("version ") else { continue }
            let rest = trimmed.dropFirst("version ".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("\""), let literal = rest.dropFirst().split(
                separator: "\"", omittingEmptySubsequences: false).first else { return nil }
            let candidate = String(literal)
            return SelfUpdate.Version(candidate) == nil ? nil : candidate
        }
        return nil
    }
}

/// What `gitpic update cask --json` reports.///
/// A `Decodable` mirror of `release.rs`'s `TapCask`, and its field spellings are a contract
/// between the two in the same way `UpdateReport`'s are. All three are single words, so unlike
/// `UpdateReport` there is nothing here for `CodingKeys` to translate.
///
/// `version` is `nil` for a cask that was *read* and declares nothing comparable. A thrown
/// error is the other way the answer can be missing: the cask was not read at all. Those are
/// different facts that happen to have the same consequence, so nothing here merges them —
/// the caller decides once, in one place.
public struct TapCask: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let cask: String
    public let version: String?
}

extension CaskOwnership {

    /// What `SelfUpdate.route` is told about Homebrew — the whole answer, already computed.
    ///
    /// A value rather than a closure the route calls, which is the shape the deleted
    /// `brew: @autoclosure () -> BrewOwnership` parameter had. That one existed so a bundle
    /// outside the two Applications directories could refuse *without paying* for a 28-second
    /// probe. Nothing here is expensive enough to defer, and making the route pure again is
    /// worth more: every row of the decision table can be exercised by naming its inputs.
    public enum Verdict: Equatable, Sendable {
        /// No cask claims this bundle. The app installs its own updates, as it does for
        /// everyone who did not use Homebrew.
        case notHomebrews
        /// A cask owns it, and this is what the cask has to offer.
        case homebrews(cask: String, offers: Offer)
    }

    /// What the tap declares, or why that could not be established.
    public enum Offer: Equatable, Sendable {
        case version(String)
        /// User-facing and therefore **Chinese**, and deliberately not the underlying error:
        /// a network message or a command line rendered in a caption at 480 pt is the bug
        /// `refusalsAreWrittenForTheWindow` exists to catch. The real error is logged.
        case unknown(reason: String)
    }

    /// The whole Homebrew question, asked in the order that costs least.
    ///
    /// Three steps, and the second is the one worth explaining. Detection is free. Then the
    /// tap's *local* clone is consulted, and if it already names something newer than the
    /// installed bundle the answer is settled with no request at all — because that direction
    /// is the reliable one: `brew upgrade` auto-updates before it resolves, so it will find at
    /// least whatever the stale clone already knows about. Only when the clone cannot prove
    /// that is `askTap` spent, since a clone saying "nothing newer" is indistinguishable from
    /// a clone that has not been updated in a week.
    ///
    /// `askTap` is injected rather than reached for so that all three outcomes are testable
    /// without a subprocess or a socket. In the app it is `GitpicRunner.tapCask`.
    ///
    /// `@Sendable` because this is `nonisolated` and the closure is awaited across an isolation
    /// boundary — the app's caller is `@MainActor` and the runner it captures is an actor, so
    /// there is nothing non-`Sendable` for it to close over.
    ///
    /// Every failure becomes `Offer.unknown`, never a refusal. A brew user whose network is
    /// down still gets the command — that is Claude Code's behaviour too, and the alternative
    /// is a dead end for someone whose upgrade path is fine.
    public static func verdict(
        bundle: URL,
        prefixes: [URL] = defaultPrefixes,
        bundleVersion: String?,
        askTap: @Sendable () async throws -> TapCask
    ) async -> Verdict {
        guard let install = detect(bundle: bundle, prefixes: prefixes) else {
            return .notHomebrews
        }
        let mine = bundleVersion.flatMap(SelfUpdate.Version.init)
        if let local = localTapVersion(prefix: install.prefix),
           let offered = SelfUpdate.Version(local), let mine, mine < offered {
            return .homebrews(cask: install.cask, offers: .version(local))
        }
        do {
            let tap = try await askTap()
            guard let version = tap.version else {
                return .homebrews(
                    cask: install.cask,
                    offers: .unknown(reason: "Homebrew 的 cask 里没有可比较的版本号"))
            }
            return .homebrews(cask: install.cask, offers: .version(version))
        } catch {
            return .homebrews(
                cask: install.cask,
                offers: .unknown(reason: "暂时读不到 Homebrew 提供的版本"))
        }
    }
}
