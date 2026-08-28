import Foundation
import Testing

/// `loginGeneration` has to guard the state it exists to protect, not only the
/// `loginTask` handle.
///
/// A source scan, for the same reason ``QuitPathContractTests`` is one: the wiring
/// lives in `GitPicApp`, an `executableTarget` tests cannot import. The bug this
/// holds closed: the generation was bumped so a cancelled task's `defer` could not
/// nil a newer login's handle, but the `for await` over `loginEvents` did not
/// consult it — so a `.done` or `.failed` already in the pipe still wrote `auth`.
/// `logout` also did not bump `reposGeneration`, so an in-flight listing refilled
/// the picker after the list was cleared. `loadRepos` / `loadBranches` already drop
/// a stale answer this way; the event loop did not.
@Suite("Login generation contract")
struct LoginGenerationContractTests {

    @Test("login events do not apply after the generation has moved")
    func loginEventsConsultGeneration() throws {
        let model = try QuitPathContractTests.read("AppModel.swift")
        let begin = try #require(
            QuitPathContractTests.body(of: "func beginLogin", in: model),
            "cannot find beginLogin's body")
        #expect(begin.contains("for await event in runner.loginEvents"),
                "beginLogin must still consume loginEvents")
        // The generation has to be asked *inside* the loop, or a `.done` already in
        // the pipe still writes `auth` after 取消. Compared on the code after the
        // `for await`, so a check that only the `defer` uses (clearing `loginTask`)
        // cannot satisfy this.
        let loop = try #require(begin.range(of: "for await event"),
                                "beginLogin has no loginEvents loop")
        let after = begin[loop.lowerBound...]
        #expect(after.contains("loginGeneration == generation"),
                """
                beginLogin's event loop does not consult loginGeneration, so a .done or \
                .failed already in the pipe still writes auth after 取消. Body after the \
                loop was: \(after)
                """)
        #expect(after.contains("onlyIfLoginGeneration"),
                """
                .done must re-read auth status through onlyIfLoginGeneration, or the \
                await inside refreshAuth is a window where 取消 has already bumped the \
                generation and a logged-in write still lands. Body after the loop was: \
                \(after)
                """)
    }

    @Test("the history pane is not gated on a config read")
    func historyPaneUsesItsOwnFailure() throws {
        let pane = try QuitPathContractTests.read("HistoryPane.swift")
        let code = pane.components(separatedBy: "\n")
            .filter { !QuitPathContractTests.isComment($0) }
            .joined(separator: "\n")
        #expect(!code.contains("configFailure"),
                """
                HistoryPane still names configFailure. gitpic list never opens config.toml, \
                so a CONFIG_INVALID file must not hide a list that loaded and must not claim \
                the list is empty for a reason that has nothing to do with uploads.
                """)
        #expect(code.contains("historyFailure"),
                "HistoryPane must have its own failure path, not reuse the config one")
    }

    @Test("logout invalidates an in-flight repository listing")
    func logoutBumpsReposGeneration() throws {
        let model = try QuitPathContractTests.read("AppModel.swift")
        let logout = try #require(
            QuitPathContractTests.body(of: "func logout() async", in: model),
            "cannot find logout's body")
        let code = Self.withoutComments(logout)
        #expect(code.contains("reposGeneration"),
                """
                logout must bump reposGeneration so a listing in flight cannot refill \
                the picker after the list was cleared. Body was: \(logout)
                """)
        #expect(code.contains("onlyIfLoginGeneration"),
                """
                logout must pass onlyIfLoginGeneration, or the follow-up auth status \
                writes over a newer login that started once loginTask was cleared. \
                Body was: \(logout)
                """)
    }

    @Test("cancelLogin does not let a follow-up status overwrite a newer login")
    func cancelLoginPassesItsGeneration() throws {
        let model = try QuitPathContractTests.read("AppModel.swift")
        let cancel = try #require(
            QuitPathContractTests.body(of: "func cancelLogin()", in: model),
            "cannot find cancelLogin's body")
        #expect(Self.withoutComments(cancel).contains("onlyIfLoginGeneration"),
                """
                cancelLogin must pass onlyIfLoginGeneration to the follow-up refreshAuth. \
                Passing nil writes auth regardless of generation, and beginLogin only \
                requires loginTask == nil, which cancel already cleared. Body was: \(cancel)
                """)
    }

    @Test("a stale refreshAuth does not start a branch listing after logout")
    func refreshAuthStopsBeforeLoadBranches() throws {
        let model = try QuitPathContractTests.read("AppModel.swift")
        let refresh = try #require(
            QuitPathContractTests.body(of: "private func refreshAuth(onlyIfLoginGeneration",
                                       in: model),
            "cannot find refreshAuth(onlyIfLoginGeneration:)'s body")
        let code = Self.withoutComments(refresh)
        let repos = try #require(code.range(of: "await loadRepos()"),
                                 "refreshAuth must still load repositories when logged in")
        let after = code[repos.upperBound...]
        #expect(after.contains("loginGeneration"),
                """
                refreshAuth must re-check loginGeneration after loadRepos returns. \
                logout bumps reposGeneration so loadRepos returns early, and without \
                this check loadBranches then bumps branchesGeneration itself and \
                refills the picker. Body after loadRepos was: \(after)
                """)
        let gen = try #require(after.range(of: "loginGeneration"),
                               "loginGeneration check after loadRepos")
        let branches = try #require(after.range(of: "await loadBranches()"),
                                    "refreshAuth must still load branches after the repos")
        #expect(gen.lowerBound < branches.lowerBound,
                "the generation check must run before loadBranches, not after it")
    }

    private static func withoutComments(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .filter { !QuitPathContractTests.isComment($0) }
            .joined(separator: "\n")
    }
}
