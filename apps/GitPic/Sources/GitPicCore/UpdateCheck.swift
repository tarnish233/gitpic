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
    /// The release's downloadable files, or `nil` from a CLI too old to report them.
    ///
    /// **Optional on purpose, and it is the cheapest insurance in this type.** A
    /// non-Optional property whose key is missing makes the whole decode throw, and
    /// `GitpicRunner.runJSON` swallows that with `try?` and reports 「看不懂 gitpic 的回答」 —
    /// so one absent field would take down the entire update check, not just the install
    /// path. The skew is reachable: `locateGitpic` prefers the CLI inside the bundle but
    /// falls back to PATH for a source build, which is exactly how an app once met a 0.18.x
    /// `gitpic` that had no `update` subcommand at all.
    ///
    /// Read it through ``installableAsset()``, which turns `nil` into a stated reason.
    public let assets: [ReleaseAsset]?

    enum CodingKeys: String, CodingKey {
        case ok, current, latest, tag
        case updateAvailable = "update_available"
        case ahead, name, notes, url
        case publishedAt = "published_at"
        case assets
    }

    public init(ok: Bool, current: String, latest: String, tag: String,
                updateAvailable: Bool, ahead: Bool, name: String?,
                notes: String, url: String, publishedAt: String?,
                assets: [ReleaseAsset]? = nil) {
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
        self.assets = assets
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
    ///
    /// **Both rules skip fenced code blocks, and "heading" means hashes then a space.** The
    /// two together are the spec ``displayMarkdown`` follows and `src/release.rs`'s `summary`
    /// mirrors on the CLI side; each of them was a real defect here:
    ///
    /// - `hasPrefix("#")` without the space deleted any first line merely *starting* with a
    ///   hash. Release notes opening `#42 修复剪贴板上传失败` lost that change silently — while
    ///   ``displayMarkdown`` three lines down required the space and documented why.
    /// - Neither rule knew about ``` fences, so a `## ` inside one — a changelog example, a
    ///   diff excerpt — ended the notes there, dropping every change after it and leaving an
    ///   unterminated fence for the renderer.
    public var summary: String {
        var kept: [String] = []
        var inFence = false
        for line in notes.components(separatedBy: .newlines) {
            if Self.isFenceDelimiter(line) {
                inFence.toggle()
            } else if !inFence, Self.headingLevel(line) == 2 {
                break
            }
            kept.append(line)
        }
        // Leading blank lines first, so the theme line is findable however the extraction
        // spaced it.
        while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeFirst()
        }
        // A fence cannot be the *first* line and also be a heading, so this needs no fence
        // state — but it does need the space, which is the whole of the `#42` bug.
        if let first = kept.first, Self.headingLevel(first) != nil {
            kept.removeFirst()
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The ATX heading level of `line`, or `nil` if it is not a heading.
    ///
    /// One place deciding what a heading is, so ``summary`` and ``displayMarkdown`` cannot
    /// drift again. A heading is one or more `#` followed by a space: that is what
    /// CommonMark says, and it is what keeps `#42` and `#hashtag` out.
    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, line.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
        return hashes.count
    }

    /// Whether `line` opens or closes a fenced code block.
    ///
    /// Three backticks or three tildes at the start of the line, per CommonMark. Info
    /// strings (```` ```swift ````) are fine — only the run of delimiters is looked at.
    static func isFenceDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
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
    /// comment inside an indented block, a `#hashtag` — is left alone. That rule is now
    /// ``headingLevel(_:)``, shared with ``summary``, which did *not* require the space and
    /// was deleting first lines like `#42 修复…` because of it.
    ///
    /// Fenced blocks are left alone too: a `# ` inside ``` is a shell comment or a diff
    /// line, and bolding it would rewrite the code being quoted.
    public static func displayMarkdown(_ s: String) -> String {
        var inFence = false
        return s.components(separatedBy: .newlines).map { line -> String in
            if isFenceDelimiter(line) {
                inFence.toggle()
                return line
            }
            guard !inFence, let level = headingLevel(line) else { return line }
            let text = line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces)
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
