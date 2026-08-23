import Testing
import Foundation
@testable import GitPicCore

/// Fixtures captured from a real `gitpic 0.5.1` run, not hand-written from the
/// docs. If the CLI's wire format drifts, these are what catch it.
enum Fixture {
    /// `gitpic --json nonexistent-file-xyz.png` → exit 6
    static let notFound = """
    {
      "ok": false,
      "error": {
        "code": "NOT_FOUND",
        "message": "file not found: nonexistent-file-xyz.png"
      }
    }
    """

    /// `gitpic doctor --json` with a stored credential → exit 0
    static let doctorHealthy = """
    {
      "ok": true,
      "config_ok": true,
      "token_valid": true,
      "repo_writable": true,
      "branch_protected": false,
      "login": "tarnish233"
    }
    """

    /// The same binary before anyone has run `gitpic auth login` → exit 3. It is
    /// the one credential failure there is, so keeping it as a fixture keeps the
    /// GUI's handling of it honest.
    static let doctorNoCredential = """
    {
      "ok": false,
      "config_ok": true,
      "token_valid": false,
      "repo_writable": false,
      "branch_protected": false,
      "detail": "no GitHub credential: run `gitpic auth login`",
      "error": {
        "code": "CONFIG_MISSING",
        "message": "no GitHub credential: run `gitpic auth login`"
      }
    }
    """

    /// Field names mirror `src/output.rs:31-43`; `raw_url` is the only key that is
    /// not already Swift-shaped.
    ///
    /// The snippets are **internally consistent** with `url`: `markdown` and `html`
    /// are what `src/link.rs` builds from `url`, and `url` is the CDN form because
    /// that is what the default `link_kind = "cdn"` selects. That consistency is what
    /// lets `LinkTests` assert the Swift port of `link.rs` reproduces the CLI's own
    /// output byte for byte.
    static func item(name: String, deduped: Bool = false) -> String {
        """
        {
          "name": "\(name)",
          "url": "https://cdn.jsdelivr.net/gh/o/r@main/images/2026/08/abc-\(name).png",
          "raw_url": "https://raw.githubusercontent.com/o/r/main/images/2026/08/abc-\(name).png",
          "markdown": "![\(name)](https://cdn.jsdelivr.net/gh/o/r@main/images/2026/08/abc-\(name).png)",
          "html": "<img src=\\"https://cdn.jsdelivr.net/gh/o/r@main/images/2026/08/abc-\(name).png\\" alt=\\"\(name)\\">",
          "path": "images/2026/08/abc-\(name).png",
          "sha": "deadbeef\(name.count)",
          "size": 1234,
          "deduped": \(deduped),
          "output": "![\(name)](https://cdn.jsdelivr.net/gh/o/r@main/images/2026/08/abc-\(name).png)"
        }
        """
    }

    static func success(_ names: [String]) -> String {
        "{ \"ok\": true, \"results\": [\(names.map { item(name: $0) }.joined(separator: ","))] }"
    }

    /// `PartialEnvelope`: some files landed, then one failed. The presence of
    /// `results` alongside `error` is the documented discriminator
    /// (`src/commands/upload.rs:249-255`).
    static func partial(_ names: [String]) -> String {
        """
        { "ok": false,
          "results": [\(names.map { item(name: $0) }.joined(separator: ","))],
          "error": { "code": "NETWORK", "message": "b.png: connection reset" } }
        """
    }
}

private func decode<T: Decodable>(_ s: String, _ t: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(s.utf8))
}

@Suite("Upload envelope decoding")
struct UploadEnvelopeTests {

    @Test("total failure decodes to .failure and never invents results")
    func totalFailure() throws {
        let env: UploadEnvelope = try decode(Fixture.notFound)
        guard case .failure(let err) = env.outcome else {
            Issue.record("expected .failure, got \(env.outcome)"); return
        }
        #expect(err.code == "NOT_FOUND")
        #expect(GitpicErrorCode(wire: err.code) == .notFound)
        // The exit code and the discriminant are the same number by contract.
        #expect(GitpicErrorCode(wire: err.code)?.rawValue == 6)
        #expect(env.results == nil)
    }

    @Test("success carries both addresses, so switching form needs no re-upload")
    func success() throws {
        let env: UploadEnvelope = try decode(Fixture.success(["shot"]))
        guard case .success(let items) = env.outcome, let r = items.first else {
            Issue.record("expected .success, got \(env.outcome)"); return
        }
        #expect(r.name == "shot")
        #expect(r.rawURL.hasPrefix("https://raw.githubusercontent.com/"))

        // The raw address comes out of the envelope; the CDN one is rebuilt, because
        // a raw-configured host emits no jsDelivr URL at all.
        let link = UploadedLink(r, config: LinkTests.config)
        #expect(link.url(.raw) == r.rawURL)
        #expect(link.url(.cdn) == r.url)

        // Every one of the six combinations is reachable and non-empty, which is
        // what makes zero-retransmit switching real.
        for syntax in LinkSyntax.allCases {
            for target in LinkTarget.allCases {
                let s = link.snippet(LinkForm(syntax: syntax, target: target))
                #expect(s?.isEmpty == false, "\(syntax.label) · \(target.label) was empty")
            }
        }
        // And the two the CLI also built are byte-identical to the CLI's own.
        #expect(link.snippet(LinkForm(syntax: .markdown, target: .cdn)) == r.markdown)
        #expect(link.snippet(LinkForm(syntax: .html, target: .cdn)) == r.html)
    }

    @Test("partial success stays partial and is not flattened either way")
    func partial() throws {
        let env: UploadEnvelope = try decode(Fixture.partial(["a"]))
        guard case .partial(let items, let err) = env.outcome else {
            Issue.record("expected .partial, got \(env.outcome)"); return
        }
        #expect(items.count == 1)
        #expect(err.code == "NETWORK")
        #expect(env.ok == false)
    }

    @Test("unrecognised shapes surface as .malformed rather than being guessed at")
    func malformed() throws {
        let a: UploadEnvelope = try decode(#"{ "ok": true }"#)
        #expect(a.outcome == .malformed("ok:true with no results"))
        let b: UploadEnvelope = try decode(#"{ "ok": false }"#)
        #expect(b.outcome == .malformed("ok:false with no error body"))
    }

    @Test("multi-file results keep input order, the only way to map them back")
    func ordering() throws {
        let env: UploadEnvelope = try decode(Fixture.success(["one", "two", "three"]))
        guard case .success(let items) = env.outcome else { Issue.record("not success"); return }
        #expect(items.map(\.name) == ["one", "two", "three"])
    }

    @Test("deduped is carried through so the UI can say the file already existed")
    func deduped() throws {
        let env: UploadEnvelope = try decode("{ \"ok\": true, \"results\": [\(Fixture.item(name: "x", deduped: true))] }")
        guard case .success(let items) = env.outcome else { Issue.record("not success"); return }
        #expect(items[0].deduped)
    }
}

@Suite("Doctor report decoding")
struct DoctorTests {
    @Test("healthy report")
    func healthy() throws {
        let r: DoctorReport = try decode(Fixture.doctorHealthy)
        #expect(r.ok)
        #expect(r.tokenValid == true)
        #expect(r.repoWritable == true)
        #expect(r.login == "tarnish233")
        #expect(r.error == nil)   // error is present exactly when ok is false
    }

    @Test("no-credential report carries an inline error, unlike other subcommands")
    func noCredential() throws {
        let r: DoctorReport = try decode(Fixture.doctorNoCredential)
        #expect(!r.ok)
        #expect(r.tokenValid == false)
        #expect(r.error?.code == "CONFIG_MISSING")
        #expect(r.login == nil)
        // The message is what the GUI shows, so it has to name the one command that
        // fixes this and nothing the app no longer depends on.
        let message = r.error!.message
        #expect(message.contains("gitpic auth login"))
        #expect(!message.contains("gh auth"))
    }
}

@Suite("Error code table")
struct ErrorCodeTests {
    @Test("wire strings and exit codes round-trip for all ten")
    func roundTrip() {
        #expect(GitpicErrorCode.allCases.count == 10)
        for c in GitpicErrorCode.allCases {
            #expect(GitpicErrorCode(wire: c.wire) == c)
        }
        // Locked by src/error.rs:124-140 on the Rust side; asserted here so a
        // drift breaks the Swift build too.
        #expect(GitpicErrorCode.general.rawValue == 1)
        #expect(GitpicErrorCode.usage.rawValue == 2)
        #expect(GitpicErrorCode.configMissing.rawValue == 3)
        #expect(GitpicErrorCode.authFailed.rawValue == 4)
        #expect(GitpicErrorCode.network.rawValue == 5)
        #expect(GitpicErrorCode.notFound.rawValue == 6)
        #expect(GitpicErrorCode.permissionDenied.rawValue == 7)
        #expect(GitpicErrorCode.remoteNotFound.rawValue == 8)
        #expect(GitpicErrorCode.rateLimited.rawValue == 9)
        #expect(GitpicErrorCode.configInvalid.rawValue == 10)
    }

    @Test("unknown wire strings are rejected, not coerced")
    func unknown() {
        #expect(GitpicErrorCode(wire: "TEAPOT") == nil)
    }

}

@Suite("Tool discovery")
struct ToolDiscoveryTests {
    @Test("the child gets the minimal Finder PATH, explicitly rather than inherited")
    func childPATH() {
        // It used to prepend gh's directory, because the CLI spawned `gh` to get a
        // credential. It holds its own now, so the minimal set is the whole answer.
        #expect(ToolPaths.childPATH == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// The banner for a run that produced no links has to carry the *message*.
    ///
    /// `CONFIG_MISSING` is why: the message is the entire remedy, and the GUI has no
    /// re-probe left to reconstruct one with. A future edit that trims this back to
    /// the code alone would leave the user with "CONFIG_MISSING：" and no next step —
    /// and nothing pinned that while the string lived in the executable target.
    @Test("a credential failure's banner carries the remedy, not just the code")
    func failureSummaryCarriesTheRemedy() {
        let body = ErrorBody(code: "CONFIG_MISSING",
                             message: "no GitHub credential: run `gitpic auth login`")
        let summary = UploadPresentation.failureSummary(body)
        #expect(summary.contains("CONFIG_MISSING"))
        #expect(summary.contains("gitpic auth login"))
        // No failure at all still says something, rather than an empty banner.
        #expect(UploadPresentation.failureSummary(nil) == "上传没有返回任何结果")
    }

    @Test("a hung child is killed rather than blocking forever")
    func processTimeout() throws {
        let out = try ChildProcess.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            args: ["10"],
            timeout: 0.3)
        #expect(out.timedOut)
        #expect(out.status != 0)
    }
}
