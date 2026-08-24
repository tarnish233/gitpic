import Testing
import Foundation
@testable import GitPicCore

/// Two rules with teeth, both about *not* misreporting an update.
///
/// The decoder is checked against a literal payload rather than a round-trip: the CLI's
/// field names are a wire contract (`src/release.rs`), and a test that encoded with the
/// same `CodingKeys` it then decodes with would pass through a rename on the Rust side.
@Suite("Update check")
struct UpdateCheckTests {

    /// Verbatim from `gitpic update check --json`, captured against real GitHub.
    private static let payload = Data("""
    {
      "ok": true,
      "current": "0.19.0",
      "latest": "0.20.0",
      "tag": "v0.20.0",
      "update_available": true,
      "ahead": false,
      "name": "gitpic v0.20.0 — 更新检查",
      "notes": "### 更新检查\\n\\n- 新增检查更新。\\n\\n## GitPic.app\\n\\n`GitPic-<version>-macos-arm64.dmg` 是 App。\\n拖到 Applications 即可。\\n\\n```sh\\nxattr -dr com.apple.quarantine /Applications/GitPic.app\\n```\\n",
      "url": "https://github.com/tarnish233/gitpic/releases/tag/v0.20.0",
      "published_at": "2026-08-24T01:02:03Z"
    }
    """.utf8)

    @Test("the CLI's field names decode as written")
    func decodesTheContract() throws {
        let r = try JSONDecoder().decode(UpdateReport.self, from: Self.payload)
        #expect(r.ok)
        #expect(r.current == "0.19.0")
        #expect(r.latest == "0.20.0")
        #expect(r.tag == "v0.20.0")
        // The two snake_case keys, which are the ones a rename would silently break.
        #expect(r.updateAvailable)
        #expect(!r.ahead)
        #expect(r.publishedAt == "2026-08-24T01:02:03Z")
        // `name` was the one field this test skipped, and it is the only one whose loss is
        // silent: it and `publishedAt` are the two optionals, so a rename on the Rust side
        // leaves this suite green while the sheet's title disappears — and `summary` strips
        // the `### <theme>` line precisely *because* `name` is shown above it, so the theme
        // would vanish from both places at once.
        #expect(r.name == "gitpic v0.20.0 — 更新检查")
    }

    /// The trim exists because `release.yml` appends install instructions for someone who
    /// downloaded the DMG — drag it to Applications, clear the quarantine flag — and the
    /// reader of this sheet already has the app open. Fifteen lines of setup under "what
    /// changed" is a dialog nobody finishes.
    ///
    /// The leading `### 更新检查` goes for a different reason: `release.yml` publishes that
    /// same line as the Release *title*, which the sheet already shows above the body, so
    /// keeping it printed the sentence twice. Both were caught by looking at the rendered
    /// sheet, not by reading the code.
    @Test("the DMG appendix and the duplicated title are left out of the sheet")
    func summaryStopsAtTheFirstH2() throws {
        let r = try JSONDecoder().decode(UpdateReport.self, from: Self.payload)
        #expect(r.summary == "- 新增检查更新。")
        // The parts that must not survive into the dialog.
        #expect(!r.summary.contains("GitPic.app"))
        #expect(!r.summary.contains("quarantine"))
        // Not twice: `name` already carries it.
        #expect(!r.summary.contains("更新检查"))
        // And the change itself must.
        #expect(r.summary.contains("新增检查更新"))
    }

    /// Keyed on the heading *level*, not on the words "GitPic.app": that title lives in a
    /// workflow file this code cannot see, so matching it would stop trimming the day
    /// someone rewords it.
    @Test("any h2 ends the summary, whatever it is called")
    func summaryIsLevelBased() {
        let r = Self.report(notes: "- one\n- two\n\n## Anything At All\n\nnoise\n")
        #expect(r.summary == "- one\n- two")
    }

    /// Only the *first* line, and only when it is a heading — a body that opens with a
    /// bullet must keep it.
    @Test("a body that does not open with a heading loses nothing")
    func leadingBulletSurvives() {
        #expect(Self.report(notes: "- kept\n- also kept").summary == "- kept\n- also kept")
        // A second heading further down is not the title and stays.
        #expect(Self.report(notes: "### Theme\n\n- a\n\n### App\n\n- b").summary
                == "- a\n\n### App\n\n- b")
    }

    /// The inline-only renderer the sheet uses does not know `### App` is a heading and
    /// printed the hashes literally — visible in the shipped dialog, which is where this
    /// was caught.
    @Test("headings become bold so the renderer does not print the hashes")
    func headingsBecomeBold() {
        #expect(UpdateReport.displayMarkdown("### App") == "**App**")
        #expect(UpdateReport.displayMarkdown("# One\n## Two\n### Three")
                == "**One**\n**Two**\n**Three**")
        // Bullets and inline syntax are left exactly as written — that is the whole point
        // of the inline-only parser.
        #expect(UpdateReport.displayMarkdown("- a `b` **c**") == "- a `b` **c**")
        // No space after the hashes is not a heading: a shell comment in an indented
        // block, or a hashtag, must survive untouched.
        #expect(UpdateReport.displayMarkdown("#nothashtag") == "#nothashtag")
        #expect(UpdateReport.displayMarkdown("    # a comment") == "    # a comment")
        // A heading with no text collapses rather than becoming empty bold markers, which
        // would render as literal asterisks.
        #expect(UpdateReport.displayMarkdown("###   ") == "")
        // Inside a fence a `# ` is a shell comment or a diff line. Bolding it would rewrite
        // the code being quoted.
        #expect(UpdateReport.displayMarkdown("```sh\n# comment\n```")
                == "```sh\n# comment\n```")
    }

    /// Two halves of one near-miss: what counts as a heading, and where a heading is allowed
    /// to count. ``UpdateReport/summary`` used `hasPrefix("#")` without requiring the space
    /// that ``UpdateReport/displayMarkdown`` did require and documented — so a release
    /// opening `#42 …` lost that line — and neither rule knew about fenced blocks, so a
    /// `## ` inside one ended the notes there and left the fence unterminated.
    @Test("a hash without a space is not a heading, and fences are not scanned for one")
    func summaryKnowsWhatAHeadingIs() {
        // An issue reference, not a theme line. Deleting it dropped a real change.
        #expect(Self.report(notes: "#42 修复剪贴板上传失败\n- 另一条").summary
                == "#42 修复剪贴板上传失败\n- 另一条")
        // A genuine theme line still goes.
        #expect(Self.report(notes: "### 主题\n\n- 一条").summary == "- 一条")
        // An h2 inside a fence is quoted text, not the workflow's appendix: what follows has
        // to survive, and the fence has to come out balanced or the renderer sees an
        // unterminated block.
        let fenced = """
        - 改了 changelog 的写法

        ```md
        ## [0.19.0]
        ```

        - 还有这一条
        """
        let out = Self.report(notes: fenced).summary
        #expect(out.contains("还有这一条"), "a fenced h2 truncated the notes: \(out)")
        #expect(out.components(separatedBy: "```").count == 3, "unbalanced fence: \(out)")
        // The appendix itself, outside any fence, still ends the summary.
        #expect(Self.report(notes: "- 一条\n\n## GitPic.app\n\n拖到 Applications").summary
                == "- 一条")
    }

    @Test("notes with no appendix survive whole, and no notes is empty")
    func summaryPassesThroughAndTolerates() {
        #expect(Self.report(notes: "- only this").summary == "- only this")
        #expect(Self.report(notes: "").summary == "")
        #expect(Self.report(notes: "\n\n  \n").summary == "")
        // An h2 on the very first line leaves nothing, which is correct rather than a
        // reason to fall back to the whole body: a release whose notes are only an
        // appendix has nothing to say about what changed.
        #expect(Self.report(notes: "## GitPic.app\n\nstuff").summary == "")
    }

    /// A first launch must be due. Reading "never checked" as "just checked" would leave
    /// someone who just switched the setting on waiting a day to see it do anything.
    @Test("never having checked is due")
    func nilIsDue() {
        #expect(UpdateSchedule.isDue(lastChecked: nil, now: Date()))
    }

    @Test("due after the interval, not before")
    func dueAfterInterval() {
        let now = Date()
        let interval = UpdateSchedule.interval
        #expect(!UpdateSchedule.isDue(lastChecked: now, now: now))
        #expect(!UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-interval + 60),
                                      now: now))
        #expect(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-interval),
                                     now: now))
        #expect(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(-interval * 7),
                                     now: now))
    }

    /// Not hypothetical: the timestamp is wall-clock, so a machine whose clock ran ahead
    /// and was then corrected — or one restored from a backup — holds a last-check in the
    /// future. Comparing the signed difference would stop checking until real time caught
    /// up with the stored value, which for a clock a month out is a month of silence.
    @Test("a last-check in the future is due, not a month of silence")
    func futureTimestampIsDue() {
        let now = Date()
        #expect(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(UpdateSchedule.interval),
                                     now: now))
        #expect(UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(60 * 60 * 24 * 30),
                                     now: now))
        // Just ahead — a few seconds of clock skew — is not yet a reason to re-check.
        #expect(!UpdateSchedule.isDue(lastChecked: now.addingTimeInterval(5), now: now))
    }

    @Test("the automatic interval is a day")
    func intervalIsDaily() {
        // Pinned because the 通用 pane promises it. The switch itself is now just
        // 「自动更新」, so the promise moved into its caption — 「每天检查一次」 — which is
        // the only place the app still states the cadence. That makes this the test that
        // keeps the caption honest.
        #expect(UpdateSchedule.interval == 24 * 60 * 60)
    }

    private static func report(notes: String) -> UpdateReport {
        UpdateReport(ok: true, current: "0.19.0", latest: "0.20.0", tag: "v0.20.0",
                     updateAvailable: true, ahead: false, name: nil,
                     notes: notes, url: "https://example.invalid", publishedAt: nil)
    }
}
