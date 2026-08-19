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

    /// `gitpic doctor --json` with gh reachable → exit 0
    static let doctorHealthy = """
    {
      "ok": true,
      "config_ok": true,
      "token_valid": true,
      "repo_writable": true,
      "branch_protected": false,
      "token_source": "gh",
      "login": "tarnish233"
    }
    """

    /// The same binary under a Finder-launch PATH, where `gh` is unreachable →
    /// exit 3. This is the failure ToolDiscovery exists to prevent, so keeping it
    /// as a fixture keeps the GUI's handling of it honest.
    static let doctorNoCredential = """
    {
      "ok": false,
      "config_ok": true,
      "token_valid": false,
      "repo_writable": false,
      "branch_protected": false,
      "token_source": null,
      "detail": "no GitHub credential: install GitHub CLI and run `gh auth login`",
      "error": {
        "code": "CONFIG_MISSING",
        "message": "no GitHub credential: install GitHub CLI and run `gh auth login`"
      }
    }
    """

    /// Field names mirror `src/output.rs:31-43`; `raw_url` is the only key that is
    /// not already Swift-shaped.
    static func item(name: String, deduped: Bool = false) -> String {
        """
        {
          "name": "\(name)",
          "url": "https://cdn.jsdelivr.net/gh/o/r@main/images/2026/08/abc-\(name).png",
          "raw_url": "https://raw.githubusercontent.com/o/r/main/images/2026/08/abc-\(name).png",
          "markdown": "![\(name)](https://cdn.example/\(name).png)",
          "html": "<img src=\\"https://cdn.example/\(name).png\\" alt=\\"\(name)\\">",
          "path": "images/2026/08/abc-\(name).png",
          "sha": "deadbeef\(name.count)",
          "size": 1234,
          "deduped": \(deduped),
          "output": "![\(name)](https://cdn.example/\(name).png)"
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

    @Test("success decodes every link form, so format switching needs no re-upload")
    func success() throws {
        let env: UploadEnvelope = try decode(Fixture.success(["shot"]))
        guard case .success(let items) = env.outcome, let r = items.first else {
            Issue.record("expected .success, got \(env.outcome)"); return
        }
        #expect(r.name == "shot")
        #expect(r.rawURL.hasPrefix("https://raw.githubusercontent.com/"))
        #expect(LinkFormat.markdown.snippet(r) == r.markdown)
        #expect(LinkFormat.html.snippet(r) == r.html)
        #expect(LinkFormat.cdn.snippet(r) == r.url)
        #expect(LinkFormat.raw.snippet(r) == r.rawURL)
        // All four are non-empty, which is what makes zero-retransmit switching real.
        for f in LinkFormat.allCases { #expect(!f.snippet(r).isEmpty) }
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
        #expect(r.tokenSource == "gh")
        #expect(r.login == "tarnish233")
        #expect(r.error == nil)   // error is present exactly when ok is false
    }

    @Test("no-credential report carries an inline error, unlike other subcommands")
    func noCredential() throws {
        let r: DoctorReport = try decode(Fixture.doctorNoCredential)
        #expect(!r.ok)
        #expect(r.tokenSource == nil)
        #expect(r.tokenValid == false)
        #expect(r.error?.code == "CONFIG_MISSING")
        #expect(r.login == nil)
        // This is the code the GUI must re-diagnose instead of echoing.
        #expect(GitpicErrorCode(wire: r.error!.code)?.needsToolDiagnosis == true)
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

    @Test("only CONFIG_MISSING needs the gh re-probe")
    func diagnosisScope() {
        let needing = GitpicErrorCode.allCases.filter(\.needsToolDiagnosis)
        #expect(needing == [.configMissing])
    }
}

@Suite("Tool discovery")
struct ToolDiscoveryTests {
    @Test("childPATH prepends gh's directory to the minimal Finder PATH")
    func childPATH() {
        let t = ToolPaths(gitpic: URL(fileURLWithPath: "/x/gitpic"),
                          gh: URL(fileURLWithPath: "/opt/homebrew/bin/gh"))
        #expect(t.childPATH == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("with no gh, childPATH is still valid rather than containing an empty entry")
    func childPATHNoGH() {
        let t = ToolPaths(gitpic: URL(fileURLWithPath: "/x/gitpic"), gh: nil)
        #expect(t.childPATH == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(!t.childPATH.contains("::"))
    }

    @Test("gh account is parsed out of gh's prose, and absence is not an error")
    func accountParsing() {
        #expect(GHProbe.account(in: "✓ Logged in to github.com account tarnish233 (keyring)")
                == "tarnish233")
        // Multi-line, the shape gh actually prints.
        #expect(GHProbe.account(in: "github.com\n  ✓ Logged in to github.com account octocat (keyring)\n  - Active account: true")
                == "octocat")
        // Prose merely containing the word must not yield a fabricated login.
        #expect(GHProbe.account(in: "no mention of an account here") == nil)
        #expect(GHProbe.account(in: "You are not logged into any GitHub hosts") == nil)
    }

    @Test("a missing gh binary reports notInstalled rather than throwing")
    func missingGH() {
        #expect(GHProbe.status(gh: nil) == .notInstalled)
    }
}
