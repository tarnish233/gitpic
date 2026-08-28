import Foundation
import Testing

/// There is exactly one way out of the app, and it is not `NSApplication.terminate`.
///
/// A source scan rather than a behavioural test, because the behaviour cannot be reached from
/// `swift test`: the refusal lives in AppKit and only happens with a real sheet attached to a
/// real window. That is precisely how this bug survived two releases — 0.20.0 shipped
/// `NSApp.terminate` on three paths, the fix changed the updater's one, and the two the user
/// clicks every day (「退出 GitPic」 and ⌘Q) kept it with nothing to notice.
///
/// So this suite checks the property that *can* be checked mechanically: that the selector is
/// absent from the app sources. `Updater.quit(_:)` carries the measurement for why.
///
/// **Being honest about what a grep can and cannot hold.** It cannot see whether `quitByUser`
/// is *reachable* — a cleared target, a reordered menu, a `validateMenuItem` returning false
/// would all leave this green. That half is `scripts/check-self-update.sh`'s two 「退出 GitPic」
/// phases, which drive the real menu item on a real app: once with the update sheet attached,
/// which is verbatim the 0.20.0 repro, and once during a real install. ⌘Q is not driven even
/// there — `keystroke` needs the app frontmost and making it so poisons the accessibility tree
/// for the rest of the run — so ⌘Q rests on sharing one selector with the menu item, which is
/// what `bothAffordancesRouteToTheOnePath` below checks. What the scan is genuinely good for is
/// the half that has already gone wrong twice: a spelling of `terminate` coming back into a file
/// nobody re-read.
@Suite("Quit path contract")
struct QuitPathContractTests {

    /// Every spelling of the selector that AppKit would accept.
    ///
    /// A list and not one literal, because the guard this replaces looked for
    /// `NSApplication.terminate` — which does **not** match `NSApp.terminate(nil)`, the exact
    /// form 0.20.0 shipped, and the form `Updater.swift` names five times when explaining the
    /// defect. The single most likely way for this to be reintroduced sailed straight past the
    /// tripwire whose whole purpose was to catch it.
    ///
    /// Anchored on the receiver (`NSApp` / `NSApplication`) or on the selector's colon, never on
    /// the bare word `terminate`. The original motive was the generated Homebrew upgrade script in
    /// `Updater.swift`, which carried `SIGTERM` and `SIGKILL` inside string literals — that script
    /// is gone, and the anchoring is kept because the other reasons never depended on it:
    /// `AppModel` speaks of "terminates the `gitpic` child", `LoginChild.terminate()` is a
    /// legitimate thing to call on a `Process`, and `SelfUpdateInstall`'s swap script is still
    /// shell text generated in Swift.
    static let forbidden = [
        "NSApplication.terminate",
        "NSApplication.shared.terminate",
        "NSApp.terminate",
        "terminate:",
    ]

    /// Located from `#filePath`, not the working directory — `swift test` runs both from the
    /// repository root (`--package-path apps/GitPic`) and from inside the package, and a path
    /// that guessed wrong would leave this suite silently passing over an empty file list,
    /// which is the one outcome a tripwire must not have.
    ///
    /// **Throwing, and recursive, and both are the point.** This used to be
    /// `try? … ?? []`, which turned a failed directory read into zero `#expect` calls and a
    /// green run; and `contentsOfDirectory`, which sees one level, so grouping the SwiftUI panes
    /// into a `Panes/` subdirectory would have dropped every file in it out of the scan while
    /// the count check below still passed on what stayed at the top level. `enumerator` walks
    /// the tree, and a read that fails now fails the test.
    static func appSources() throws -> [URL] {
        var root = URL(fileURLWithPath: #filePath)
        // 3 components: …/Tests/GitPicCoreTests/<this file> → the `apps/GitPic` package root.
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("Sources/GitPicApp")
        let walker = try #require(
            FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil),
            "cannot walk \(dir.path)")
        let found = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        // The precondition, asserted where the scan actually runs rather than in a sibling
        // `@Test`: `swift test --filter noTerminateSelector` runs that one alone, so a
        // precondition living in another test is no precondition at all.
        return try #require(found.isEmpty ? nil : found, "found no sources under \(dir.path)")
    }

    /// The precondition, asserted rather than assumed. If the layout moves and the scan below
    /// starts reading nothing, this fails first and says so.
    @Test("the app sources are where the scan expects them")
    func sourcesExist() throws {
        let sources = try Self.appSources()
        #expect(sources.count > 5, "expected the GitPicApp sources, found \(sources.count)")
        #expect(sources.contains { $0.lastPathComponent == "MainMenu.swift" })
        #expect(sources.contains { $0.lastPathComponent == "GitPicApp.swift" })
        #expect(sources.contains { $0.lastPathComponent == "Updater.swift" })
    }

    /// The tripwire. Any new quit affordance has to go through ``Updater/quitByUser()``.
    @Test("no source reaches for NSApplication.terminate")
    func noTerminateSelector() throws {
        for url in try Self.appSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                guard !Self.isComment(line) else { continue }
                for spelling in Self.forbidden where line.contains(spelling) {
                    Issue.record("""
                        \(url.lastPathComponent):\(offset + 1) names \(spelling). AppKit refuses \
                        termination while a sheet is attached, so the app becomes unquittable — \
                        use Updater.quitByUser() instead. If this line is an explanation rather \
                        than a call, make it a whole-line comment.
                        """)
                }
            }
        }
    }

    /// Whether the line is nothing but a comment.
    ///
    /// Comments are allowed to name the selector — `Updater.swift` explains at length why it
    /// cannot be used, and that explanation is the reason this property holds.
    ///
    /// Deliberately "the line *starts* with `//`" and not "everything after the first `//` is a
    /// comment". The version this replaces split on a single `/` and took `.first`, which failed
    /// in both directions: any earlier slash on the line — a path literal, a division, a
    /// bilingual menu title like `"退出/Quit"` — hid the real code after it, and because `split`
    /// omits empty subsequences by default a column-0 `///` yielded the comment *body*, so a
    /// pure documentation edit could turn this suite red. (`Updater.swift`'s file-header block is
    /// at column 0 and is exactly where every explanation of this selector lives.) Erring toward
    /// scanning too much is the right direction for a tripwire: a trailing comment that names the
    /// selector fails, and the fix is to move it to its own line.
    static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// The other half: the replacement genuinely exists and is reachable from both call sites.
    /// `MainMenu`'s item is built with no target, so it can only land if the selector is
    /// non-`private` on `AppDelegate`.
    @Test("both quit affordances route to quitByUser")
    func bothAffordancesRouteToTheOnePath() throws {
        let mainMenu = try Self.read("MainMenu.swift")
        #expect(mainMenu.contains("#selector(AppDelegate.quitByUser)"))

        let app = try Self.read("GitPicApp.swift")
        #expect(app.contains("#selector(quitByUser)"))
        // Non-private, or the responder-chain route from MainMenu cannot name it.
        #expect(app.contains("@objc func quitByUser()"))

        let updater = try Self.read("Updater.swift")
        #expect(updater.contains("static func quitByUser() -> Never"))
    }

    /// The quit undoes an install that was still staging.
    ///
    /// `exit(0)` runs no `defer`, so a quit taken while `SelfUpdate.stage` is between its
    /// `hdiutil attach` and its return would otherwise leave an attached image, a bundle-sized
    /// staging directory beside the installed app, and the disk image — reclaimed only by a
    /// sweep on a launch more than a day later. Before the two affordances above were fixed,
    /// AppKit's sheet refusal was accidentally the only thing preventing that: the install is
    /// started from a button inside the update sheet, and that sheet stays attached for the whole
    /// sequence, so every quit during an install was refused.
    ///
    /// **Asserted against `quit(_:)` and deliberately *not* against `prepareToQuit()`.** The
    /// latter has two callers that do not exit — the `GITPIC_APP_DRY_RUN` branches of
    /// `installAndRelaunch` and `upgradeAndRelaunch`, which call it and then `return` — so a
    /// destructive drain there would run while the app keeps going. It is only the `exit(0)` in
    /// `quit` that makes undoing this work necessary, so that is where it belongs.
    ///
    /// This is a grep, and a grep is the weaker half — what the drain *does* is covered
    /// behaviourally in `SelfUpdateInstallTests`, which can import `GitPicCore`. What only a
    /// grep can hold is that `Updater` still calls it, since `GitPicApp` is an `executableTarget`
    /// tests cannot import.
    @Test("the quit path undoes work an install left in flight")
    func quitUndoesInFlightWork() throws {
        let updater = try Self.read("Updater.swift")
        let body = try #require(Self.body(of: "static func quit(_ reason: String) -> Never",
                                          in: updater),
                                "cannot find quit's body")
        #expect(body.contains("SelfUpdate.undoInFlightWork()"),
                """
                quit(_:) does not call SelfUpdate.undoInFlightWork(). exit(0) runs no defer, so \
                a quit during staging leaks an attached disk image and a staging directory. \
                Body was: \(body)
                """)
        // Ordering, not just presence: the undo has to happen before the process goes away.
        // Compared on the code alone — the comment above the call names `exit(0)` too, and a
        // plain search over the body finds that first.
        let code = body.components(separatedBy: "\n")
            .filter { !Self.isComment($0) }.joined(separator: "\n")
        let undo = try #require(code.range(of: "SelfUpdate.undoInFlightWork()"))
        let leave = try #require(code.range(of: "exit(0)"))
        #expect(undo.lowerBound < leave.lowerBound, "the undo must run before exit(0)")

        let prepare = try #require(Self.body(of: "private static func prepareToQuit()",
                                             in: updater),
                                   "cannot find prepareToQuit's body")
        #expect(prepare.contains("cancelLogin()"),
                "prepareToQuit() must still reap the login child")
        // It has two callers that return instead of exiting, so a destructive drain must not
        // live here.
        #expect(!prepare.contains("undoInFlightWork"),
                """
                prepareToQuit() must not drain: the GITPIC_APP_DRY_RUN branches call it and then \
                return, so the app would delete an install it is still running.
                """)
    }

    /// The routes AppKit synthesises are closed from both ends, or from neither.
    ///
    /// The Dock icon's contextual-menu Quit and the Apple Event a logout sends arrive as
    /// `terminate:`, which a sheet refuses — so with the update sheet up the app used to block
    /// the user logging out, with Force Quit the only way past it. Closing that takes two
    /// changes that are only correct together:
    ///
    /// - `Updater.allowTerminationWithSheets()` clears
    ///   `preventsApplicationTerminationWhenModal` on every sheet, so `terminate:` stops being
    ///   refused;
    /// - `AppDelegate.applicationShouldTerminate` sends what now gets through to
    ///   `Updater.quitByUser()`.
    ///
    /// Either one alone is a defect rather than half a fix. The first without the second lets
    /// AppKit tear the process down its own way, running neither `prepareToQuit()` nor the
    /// staging undo — the leak 0.20.1 shipped to close, reopened through a different door. The
    /// second without the first is dead code, because a sheet's refusal happens before the
    /// delegate is consulted. So this asserts them as a pair, and deleting either half fails
    /// here rather than in a release.
    ///
    /// A grep again, and again the weaker half: whether AppKit actually stops refusing is
    /// AppKit's behaviour with a real sheet on a real window, which `swift test` cannot reach at
    /// all. `scripts/check-self-update.sh`'s 「quit Apple Event」 phase measures that by sending
    /// the same event a logout sends, mid-install.
    @Test("the terminate: routes are closed from both ends")
    func appKitRoutesReachTheOneQuitPath() throws {
        let app = try Self.read("GitPicApp.swift")
        let updater = try Self.read("Updater.swift")

        let shouldTerminate = try #require(
            Self.body(of: "func applicationShouldTerminate(_ sender: NSApplication)", in: app),
            """
            AppDelegate does not implement applicationShouldTerminate. Without it a logout or a \
            Dock-menu Quit lets AppKit exit without prepareToQuit() or the staging undo.
            """)
        #expect(shouldTerminate.contains("Updater.quitByUser()"),
                """
                applicationShouldTerminate must route into Updater.quitByUser(), not return \
                .terminateNow — AppKit's own teardown runs neither the login-child reap nor \
                SelfUpdate.undoInFlightWork(). Body was: \(shouldTerminate)
                """)

        let launch = try #require(
            Self.body(of: "func applicationDidFinishLaunching", in: app),
            "cannot find applicationDidFinishLaunching's body")
        #expect(launch.contains("Updater.allowTerminationWithSheets()"),
                """
                applicationDidFinishLaunching must install allowTerminationWithSheets(), and \
                before any window can open — it works by watching sheets begin, so a sheet it \
                never saw begin keeps AppKit's refusal and applicationShouldTerminate stays \
                unreachable.
                """)

        let allow = try #require(
            Self.body(of: "static func allowTerminationWithSheets()", in: updater),
            "cannot find allowTerminationWithSheets's body")
        #expect(allow.contains("preventsApplicationTerminationWhenModal = false"),
                "allowTerminationWithSheets must clear the flag that refuses termination")
        // Every sheet, not one named window: five sheet-shaped presentations exist today and
        // the point of doing this centrally is the sixth someone adds.
        #expect(allow.contains("willBeginSheetNotification"),
                """
                allowTerminationWithSheets must observe willBeginSheetNotification rather than \
                fix one sheet at its call site, or the next sheet added reintroduces the bug.
                """)
    }

    /// The text between a declaration's opening `{` and the first `}` at the declaration's own
    /// indentation — enough to tell "inside this function" from "somewhere in this file", without
    /// pretending to be a Swift parser.
    static func body(of declaration: String, in source: String) -> String? {        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return nil }
        let indent = String(lines[start].prefix { $0 == " " })
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == indent + "}" })
        else { return nil }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    /// Internal, not private: ``WindowFocusContractTests`` scans the same sources for a
    /// different property and there is no reason for a second copy of this.
    static func read(_ name: String) throws -> String {
        let byName = Dictionary(grouping: try appSources()) { $0.lastPathComponent }
        let url = try #require(byName[name]?.first, "missing \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
