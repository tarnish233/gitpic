import Testing
import Foundation
@testable import GitPicCore

/// `gitpic auth login --json` is the one command in this CLI whose `--json` is a
/// *stream*, and this is where that contract is checked.
///
/// The flow itself cannot be exercised: it needs a browser and up to fifteen minutes.
/// Every line it can emit can be, and those lines are what the settings window drives
/// its whole login UI from — so a tag it stops recognising, or a URL it hands to
/// `NSWorkspace` unchecked, would both surface here first.
@Suite("Login stream")
struct LoginStreamTests {

    /// Copied verbatim out of a real `gitpic auth login --json` run, not hand-written.
    ///
    /// The hand-written fixtures below all passed while the CLI was pretty-printing every
    /// event across seven lines — because they asserted the *shape* the decoder wanted
    /// rather than the bytes it would actually receive. This one is the bytes.
    static let capturedCodeLine =
        #"{"event":"code","user_code":"CDD9-4FC3","verification_uri":"https://github.com/login/device","interval_seconds":5,"expires_in_seconds":899}"#

    @Test("a line captured from a real run decodes, and is one line")
    func realCapturedLine() throws {
        #expect(!Self.capturedCodeLine.contains("\n"),
                "the stream is newline-delimited; an event spanning lines is unparseable")
        let event = try #require(LoginStream.event(from: Self.capturedCodeLine))
        guard case let .code(userCode, url, expiresIn) = event else {
            Issue.record("expected a code event, got \(event)")
            return
        }
        #expect(userCode == "CDD9-4FC3")
        #expect(url.absoluteString == "https://github.com/login/device")
        #expect(expiresIn == 899)
    }

    @Test("the code line carries what the window has to display")
    func codeEvent() throws {
        let line = """
        {"event":"code","user_code":"D5F9-4823",\
        "verification_uri":"https://github.com/login/device",\
        "interval_seconds":5,"expires_in_seconds":900}
        """
        let event = try #require(LoginStream.event(from: line))
        guard case let .code(userCode, url, expiresIn) = event else {
            Issue.record("expected a code event, got \(event)")
            return
        }
        #expect(userCode == "D5F9-4823")
        #expect(url.absoluteString == "https://github.com/login/device")
        #expect(expiresIn == 900)
    }

    @Test("a code line whose URL is not GitHub over TLS is dropped, not opened")
    func codeEventURLIsChecked() {
        // This value arrives over a pipe and ends up at `NSWorkspace.open`. The CLI
        // checks it too; both check, because either one being the only guard makes the
        // other side's bug an app that opens an arbitrary scheme.
        for uri in ["http://github.com/login/device",
                    "https://github.example.com/login/device",
                    "file:///etc/passwd",
                    "javascript:alert(1)"] {
            let line = """
            {"event":"code","user_code":"D5F9-4823","verification_uri":"\(uri)"}
            """
            #expect(LoginStream.event(from: line) == nil, "\(uri) must not yield an event")
        }
    }

    @Test("expires_in defaults rather than dropping an otherwise usable code")
    func codeEventWithoutExpiry() throws {
        // The code is what the user needs; a missing timing is not worth refusing it
        // over. GitHub's own value is 900.
        let event = try #require(LoginStream.event(from: """
        {"event":"code","user_code":"AAAA-BBBB","verification_uri":"https://github.com/login/device"}
        """))
        guard case let .code(_, _, expiresIn) = event else {
            Issue.record("expected a code event")
            return
        }
        #expect(expiresIn == 900)
    }

    @Test("the outcome lines are what the window waits on")
    func outcomeEvents() throws {
        let done = try #require(LoginStream.event(from: """
        {"event":"done","ok":true,"login":"octocat","client_id":"Ov23liX","path":"/tmp/auth.toml"}
        """))
        #expect(done == .done(login: "octocat"))

        // `login` is absent when the post-login `/user` probe did not answer. The
        // credential is still stored, so this is a success with a name missing — not a
        // failure.
        #expect(try #require(LoginStream.event(from: #"{"event":"done","ok":true,"path":"/x"}"#))
                == .done(login: nil))

        let failed = try #require(LoginStream.event(from: """
        {"event":"error","ok":false,"code_was_issued":true,\
        "error":{"code":"AUTH_FAILED","message":"the login was cancelled in the browser"}}
        """))
        #expect(failed == .failed(ErrorBody(code: "AUTH_FAILED",
                                           message: "the login was cancelled in the browser")))
    }

    @Test("an error line with no error body still ends the stream")
    func errorEventWithoutBody() throws {
        // A UI that waits for an outcome must get one. Inventing a `GENERAL` here is
        // better than yielding nothing and leaving the spinner up forever.
        let event = try #require(LoginStream.event(from: #"{"event":"error","ok":false}"#))
        guard case let .failed(body) = event else {
            Issue.record("expected a failure, got \(event)")
            return
        }
        #expect(body.code == "GENERAL")
    }

    @Test("noise between events is skipped rather than treated as a violation")
    func unrecognisedLines() {
        // A blank line, a tag from a later CLI, and text that is not JSON at all. None
        // is an outcome, and none may be reported as one: the caller distinguishes
        // "still waiting" from "finished" purely by which events arrive.
        #expect(LoginStream.event(from: "") == nil)
        #expect(LoginStream.event(from: "   \n") == nil)
        #expect(LoginStream.event(from: #"{"event":"progress","polls":3}"#) == nil)
        #expect(LoginStream.event(from: "not json at all") == nil)
        // An envelope with no `event` at all — what `main` would print if the stream
        // ever regressed to a plain error envelope.
        #expect(LoginStream.event(from: #"{"ok":false,"error":{"code":"USAGE","message":"x"}}"#) == nil)
    }
}

@Suite("Credential state")
struct AuthStateTests {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("a working credential is logged in, named by the account it belongs to")
    func loggedIn() throws {
        // `client_id` is in the JSON and not in the state: an unknown key must decode
        // rather than throw, because the CLI is free to report more than the window
        // shows. It used to be a row in 图床 — a constant string next to the account
        // name — and `gitpic auth status` is where it belongs.
        let report: AuthStatusReport = try decode("""
        {"ok":true,"token_valid":true,"login":"tarnish233",\
        "client_id":"Ov23lixXJLMVM3WBedvm","path":"/Users/x/.config/gitpic/auth.toml"}
        """)
        #expect(report.state == .loggedIn(login: "tarnish233", expiresAt: nil))
    }

    @Test("no credential decodes as data, not as a failure")
    func loggedOut() throws {
        // `auth status` exits 3 and prints this. If it arrived as an error the one pane
        // whose job is to offer a login would have nothing to render.
        let report: AuthStatusReport = try decode("""
        {"ok":false,"error":{"code":"CONFIG_MISSING",\
        "message":"no GitHub credential: run `gitpic auth login`"}}
        """)
        #expect(report.state == .loggedOut(
            detail: "no GitHub credential: run `gitpic auth login`"))
    }

    @Test("a credential GitHub would not accept is not the same as having none")
    func broken() throws {
        // The distinction that matters: this one may need nothing done at all. A
        // NETWORK detail means `/user` was unreachable and the credential is very
        // likely fine, so "log in again" must not be the only thing offered.
        let report: AuthStatusReport = try decode("""
        {"ok":false,"token_valid":false,\
        "error":{"code":"NETWORK","message":"network: connection reset"},\
        "detail":"network: connection reset"}
        """)
        guard case let .broken(detail) = report.state else {
            Issue.record("expected broken, got \(report.state)")
            return
        }
        #expect(detail.contains("NETWORK"))
    }

    @Test("an expiring token is carried through so the window can show it")
    func expiringToken() throws {
        // Normally absent, because gitpic's own app has token expiration switched off.
        // It reappears if `GITPIC_CLIENT_ID` points at an app that has it on, and
        // silently dropping it would leave the user with no warning at all.
        let report: AuthStatusReport = try decode("""
        {"ok":true,"token_valid":true,"login":"octocat",\
        "expires_at":"2026-08-23T18:46:45+08:00"}
        """)
        #expect(report.state == .loggedIn(login: "octocat",
                                          expiresAt: "2026-08-23T18:46:45+08:00"))
    }
}

@Suite("Repository listing")
struct ReposReportTests {

    @Test("a repo row decodes every field the picker shows")
    func decodesRows() throws {
        let report = try JSONDecoder().decode(ReposReport.self, from: Data("""
        {"ok":true,"complete":true,"repos":[
          {"owner":"tarnish233","name":"picture_of_notes","private":false,
           "default_branch":"main","can_push":true},
          {"owner":"tarnish233","name":"GitPic-legacy","private":false,
           "default_branch":"master","can_push":true}]}
        """.utf8))
        let repos = try #require(report.repos)
        #expect(repos.count == 2)
        #expect(repos[0].spec == "tarnish233/picture_of_notes")
        // `private` is a Swift keyword, so the mapping is hand-written and worth
        // asserting rather than assuming.
        #expect(repos[0].isPrivate == false)
        #expect(repos[0].canPush)
        // The reason `default_branch` is read at all: assuming `main` here would send
        // every upload to a ref this repository does not have.
        #expect(repos[1].defaultBranch == "master")
        #expect(report.complete == true)
    }

    @Test("a truncated listing says so, and an older CLI's silence does not read as truncated")
    func completeness() throws {
        let truncated = try JSONDecoder().decode(ReposReport.self, from: Data(
            #"{"ok":true,"complete":false,"repos":[]}"#.utf8))
        #expect(truncated.complete == false)

        // Absent means "no reason to doubt the list" — the picker's fallback is `true`.
        let silent = try JSONDecoder().decode(ReposReport.self, from: Data(
            #"{"ok":true,"repos":[]}"#.utf8))
        #expect(silent.complete == nil)
    }

    @Test("no credential decodes as data here too")
    func noCredential() throws {
        let report = try JSONDecoder().decode(ReposReport.self, from: Data("""
        {"ok":false,"error":{"code":"CONFIG_MISSING","message":"no GitHub credential"}}
        """.utf8))
        #expect(report.repos == nil)
        #expect(report.error?.code == "CONFIG_MISSING")
    }
}

@Suite("Branch listing")
struct BranchesReportTests {

    @Test("a branch row decodes both fields the picker shows")
    func decodesRows() throws {
        let report = try JSONDecoder().decode(BranchesReport.self, from: Data("""
        {"ok":true,"repo":"octocat/pics","configured":"main","complete":true,"branches":[
          {"name":"main","protected":true},
          {"name":"images","protected":false}]}
        """.utf8))
        let branches = try #require(report.branches)
        #expect(branches.map(\.name) == ["main", "images"])
        // Reported so the picker can label it, never filtered on: protection does not
        // mean unwritable, and hiding a protected branch would remove a real choice.
        #expect(branches[0].protected)
        #expect(!branches[1].protected)
        #expect(report.complete == true)
    }

    @Test("a branch the configuration names but the repository lacks is representable")
    func aConfiguredBranchCanBeAbsentFromTheList() throws {
        // The state this listing exists to surface. `GitPic-legacy` has `master` and no
        // `main`, so a config carried over from another repository targets a ref that is
        // not there — and GitHub answers 404 for a missing ref exactly as it does for a
        // missing repository, which is why nothing else in the app can tell them apart.
        //
        // The envelope's own `repo` and `configured` are not decoded, so the mismatch is
        // decided here the way the picker decides it: against the draft's branch.
        let report = try JSONDecoder().decode(BranchesReport.self, from: Data("""
        {"ok":true,"repo":"octocat/legacy","configured":"main","complete":true,
         "branches":[{"name":"master","protected":false}]}
        """.utf8))
        let branches = try #require(report.branches)
        // Undecoded keys must not make the whole report unreadable — a CLI that reports
        // more than the window shows has to keep working.
        #expect(branches.count == 1)
        #expect(!branches.contains { $0.name == "main" })
    }

    @Test("an empty repository lists nothing and is not a failure")
    func emptyRepository() throws {
        // A repository with no commits has no branches, and the first upload creates the
        // ref. `ok` stays true, so this must not be rendered as an error.
        let report = try JSONDecoder().decode(BranchesReport.self, from: Data(
            #"{"ok":true,"repo":"octocat/new","configured":"main","branches":[],"complete":true}"#.utf8))
        // An empty list with no error is the state the pane has to explain rather than
        // render as a broken picker: `[]` and `nil` mean different things here.
        #expect(report.branches?.isEmpty == true)
        #expect(report.error == nil)
    }

    @Test("no credential decodes as data here too")
    func noCredential() throws {
        let report = try JSONDecoder().decode(BranchesReport.self, from: Data("""
        {"ok":false,"error":{"code":"CONFIG_MISSING","message":"no GitHub credential"}}
        """.utf8))
        #expect(report.branches == nil)
        #expect(report.error?.code == "CONFIG_MISSING")
        // Absent rather than defaulted: an older CLI's silence must not read as
        // "truncated".
        #expect(report.complete == nil)
    }
}
