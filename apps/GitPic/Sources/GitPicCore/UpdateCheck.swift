import Foundation

/// Mirrors `UpdateReport` in `src/release.rs` — the payload of
/// `gitpic update check --json`.
///
/// Explicit `CodingKeys` rather than a snake-case decoding strategy, matching every other
/// mirror in this module (see ``DoctorReport``): the CLI's spellings are a contract, and
/// naming them here is what makes a rename on that side a compile error rather than a
/// field that silently decodes to its default.
public struct UpdateReport: Decodable, Equatable, Sendable {
    public let ok: Bool
    /// The running CLI's version.
    public let current: String
    /// The latest release's version, normalised (no `v`).
    public let latest: String
    /// The tag as GitHub spells it.
    public let tag: String
    public let updateAvailable: Bool
    /// This build is *newer* than the latest release — an unreleased local build. Kept
    /// distinct from "no update" so the UI can say so instead of calling a dev build
    /// up to date with something it is ahead of.
    public let ahead: Bool
    public let name: String?
    /// The release notes, verbatim Markdown. Empty rather than absent when there are none.
    public let notes: String
    public let url: String
    public let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case ok, current, latest, tag
        case updateAvailable = "update_available"
        case ahead, name, notes, url
        case publishedAt = "published_at"
    }

    public init(ok: Bool, current: String, latest: String, tag: String,
                updateAvailable: Bool, ahead: Bool, name: String?,
                notes: String, url: String, publishedAt: String?) {
        self.ok = ok
        self.current = current
        self.latest = latest
        self.tag = tag
        self.updateAvailable = updateAvailable
        self.ahead = ahead
        self.name = name
        self.notes = notes
        self.url = url
        self.publishedAt = publishedAt
    }

    /// The part of ``notes`` worth showing to someone updating from inside the app.
    ///
    /// Two structural removals, both of them about what `release.yml` puts in a Release
    /// body rather than about Markdown in general.
    ///
    /// **The `## `-level appendix goes.** The version's own notes come first — the short
    /// summary the changelog keeps above its `release-notes-end` marker, whose own headings
    /// are `### ` or deeper. After them the workflow appends `## `-level sections aimed at
    /// someone who *downloaded the DMG*: how to drag it to Applications, and the
    /// `xattr -dr com.apple.quarantine` line needed because the app is not notarised. None
    /// of that applies to a reader who already has the app open, and fifteen lines of
    /// install instructions under "what changed" is a dialog nobody finishes.
    ///
    /// Matching the heading *level* rather than the literal title is deliberate: the
    /// appendix's wording lives in a workflow file this code cannot see, so keying on
    /// "GitPic.app" would silently stop trimming the day someone rewords it. The failure
    /// mode of this rule is a dialog with extra text in it, never a missing change.
    ///
    /// **The leading `### ` theme line goes too**, and this one was found by looking at the
    /// rendered sheet. `release.yml` takes that very line as the Release *title* — the
    /// published name is `gitpic vX.Y.Z — <theme>` — and ``name`` is already shown above the
    /// body, so keeping it here printed the same sentence twice, once as a heading and once
    /// as a heading marker. Only the *first* line, and only when it is a heading: a body
    /// that happens to open with a bullet is left alone.
    public var summary: String {
        var kept: [String] = []
        for line in notes.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") { break }
            kept.append(line)
        }
        // Leading blank lines first, so the theme line is findable however the awk
        // extraction spaced it.
        while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeFirst()
        }
        if let first = kept.first, first.hasPrefix("#") {
            kept.removeFirst()
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ATX headings rewritten as bold, for a renderer that does not do headings.
    ///
    /// The sheet renders with `AttributedString`'s `.inlineOnlyPreservingWhitespace`, which
    /// resolves `**bold**`, `` `code` `` and links while leaving line breaks and `- `
    /// bullets exactly as written. The full parser is not an option: it *drops* the newlines
    /// and folds every bullet into one paragraph, turning a five-line summary into a wall.
    ///
    /// The price of the inline-only parser is that it does not know `### App` is a heading,
    /// so it printed the hashes literally — visible in the shipped dialog, which is where
    /// this was caught. Rewriting the line to `**App**` gets the emphasis the heading was
    /// for out of a parser that only does inline syntax.
    ///
    /// Requires a space after the hashes, so a line that merely starts with `#` — a shell
    /// comment inside an indented block, a `#hashtag` — is left alone.
    public static func displayMarkdown(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { line -> String in
            let hashes = line.prefix { $0 == "#" }
            guard !hashes.isEmpty, line.dropFirst(hashes.count).hasPrefix(" ") else {
                return line
            }
            let text = line.dropFirst(hashes.count + 1)
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "" : "**\(text)**"
        }
        .joined(separator: "\n")
    }
}

/// When the app last looked for an update, and whether it is time to look again.
///
/// In `GitPicCore` because the rule is worth a test and `GitPicApp` cannot be imported by
/// one. It takes `now` as a parameter for the same reason: a rule that reads the clock
/// itself can only be tested by waiting.
public enum UpdateSchedule {
    /// How long between automatic checks.
    ///
    /// A day, because that is what the setting promises, and because the endpoint is
    /// unauthenticated: `api.github.com` allows 60 requests an hour per address, shared
    /// with everything else on the network. One check a day cannot contribute to
    /// exhausting that; an hourly one on a laptop that sleeps and wakes could.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether an automatic check is due.
    ///
    /// **A `nil` last-check is due**, which is the state of every first launch after this
    /// feature ships. The alternative — treating "never checked" as "just checked" — would
    /// leave a user who switched the setting on waiting a day to find out it works.
    ///
    /// A last-check in the *future* is also due, and that is not a hypothetical: the
    /// timestamp is wall-clock, so a machine whose clock was ahead and then corrected, or
    /// one restored from a backup, would otherwise stop checking until real time caught up
    /// with the stored value. Comparing the elapsed magnitude rather than the signed
    /// difference costs nothing and removes that trap.
    public static func isDue(lastChecked: Date?, now: Date,
                            interval: TimeInterval = interval) -> Bool {
        guard let lastChecked else { return true }
        return abs(now.timeIntervalSince(lastChecked)) >= interval
    }
}
