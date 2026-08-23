import Testing
import Foundation
import AppKit
@testable import GitPicCore

/// End-to-end tests against the real `gitpic` binary and real GitHub.
///
/// Gated behind `GITPIC_LIVE=1` because they perform a network upload. Everything
/// else in this suite is offline.
///
/// The test image is **deterministic** on purpose: the first run creates one
/// commit, and every run after that hits the CLI's content dedup and creates
/// nothing. That keeps re-running these tests free rather than accumulating
/// commits in the image-host repository.
@Suite("Live CLI contract", .enabled(if: ProcessInfo.processInfo.environment["GITPIC_LIVE"] == "1"))
struct LiveContractTests {

    /// A fixed 8×8 opaque PNG. Same bytes every run → same sha → dedup.
    static func fixedPNG() throws -> Data {
        let w = 8, h = 8
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)
        else { throw TestError.cannotMakeImage }
        guard let plane = rep.bitmapData else { throw TestError.cannotMakeImage }
        // Fixed pattern: a recognisable checker so the uploaded artefact is
        // obviously a test fixture if anyone opens it.
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let on = ((x / 2) + (y / 2)) % 2 == 0
                plane[i + 0] = on ? 0x33 : 0xEE
                plane[i + 1] = on ? 0x88 : 0xEE
                plane[i + 2] = on ? 0xCC : 0xEE
                plane[i + 3] = 0xFF
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw TestError.cannotMakeImage
        }
        return png
    }

    enum TestError: Error { case cannotMakeImage, noGitpic }

    static func runner() throws -> GitpicRunner {
        // Prefer the bundle built by scripts/build-app.sh, since that is the exact
        // binary users would run.
        let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist-app/GitPic.app/Contents/Resources")
        let paths = ToolDiscovery.resolve(bundleResourceURL: bundled)
            ?? ToolDiscovery.resolve(bundleResourceURL: nil)
        guard let paths else { throw TestError.noGitpic }
        return GitpicRunner(tools: paths)
    }

    @Test("doctor reports a usable credential through the app's own childPATH")
    func liveDoctor() async throws {
        let r = try await Self.runner().doctor()
        #expect(r.configOK == true)
        #expect(r.tokenValid == true,
                "no usable credential — run `gitpic auth login`: \(r.detail ?? "no detail")")
        #expect(r.error == nil)
    }

    @Test("one upload yields every syntax × address combination, and re-uploading the same bytes dedups")
    func liveUploadAndDedup() async throws {
        let runner = try Self.runner()
        let png = try Self.fixedPNG()

        let first = try await runner.upload(pngData: png, basename: "gitpic-app-selftest")
        guard case .success(let items) = first.outcome, let a = items.first else {
            Issue.record("first upload did not succeed: \(first.outcome)")
            return
        }
        // The claim the whole form switcher rests on, against the live config: both
        // addresses resolve, and every combination of the two dimensions produces a
        // snippet without a second upload.
        let link = UploadedLink(a, config: try await runner.loadConfig())
        for syntax in LinkSyntax.allCases {
            for target in LinkTarget.allCases {
                let form = LinkForm(syntax: syntax, target: target)
                #expect(link.snippet(form)?.isEmpty == false, "\(form.label) snippet was empty")
            }
        }
        // The two the CLI built itself must agree with the app's port of link.rs,
        // for whichever address `upload.link_kind` selected.
        #expect([LinkTarget.cdn, .raw].contains {
            link.snippet(LinkForm(syntax: .markdown, target: $0)) == a.markdown
        }, "no address reproduced the CLI's own markdown: \(a.markdown)")
        #expect([LinkTarget.cdn, .raw].contains {
            link.snippet(LinkForm(syntax: .html, target: $0)) == a.html
        }, "no address reproduced the CLI's own html: \(a.html)")

        #expect(a.url.hasPrefix("https://"))
        #expect(a.rawURL.contains("raw.githubusercontent.com"))
        #expect(a.markdown.contains(a.url) || a.markdown.contains(a.rawURL))
        #expect(a.html.contains("<img"))
        #expect(a.size > 0)
        #expect(a.sha.count >= 7)
        #expect(a.path.hasSuffix(".png"))

        // Same bytes again: content dedup must recognise it, so this costs no commit.
        let second = try await runner.upload(pngData: png, basename: "gitpic-app-selftest")
        guard case .success(let items2) = second.outcome, let b = items2.first else {
            Issue.record("second upload did not succeed: \(second.outcome)")
            return
        }
        #expect(b.deduped, "identical bytes should dedup; got a fresh upload instead")
        #expect(b.sha == a.sha)
        #expect(b.path == a.path)
    }

    @Test("a missing file yields NOT_FOUND with exit-code 6 semantics, not a crash")
    func liveNotFound() async throws {
        let runner = try Self.runner()
        let missing = URL(fileURLWithPath: "/tmp/gitpic-does-not-exist-\(UUID().uuidString).png")
        let env = try await runner.upload(paths: [missing])
        guard case .failure(let err) = env.outcome else {
            Issue.record("expected .failure, got \(env.outcome)"); return
        }
        #expect(err.code == "NOT_FOUND")
        #expect(GitpicErrorCode(wire: err.code)?.rawValue == 6)
    }
}

@Suite("Live config and history",
       .enabled(if: ProcessInfo.processInfo.environment["GITPIC_LIVE"] == "1"))
struct LiveConfigTests {
    @Test("config get --json decodes against the real binary")
    func liveConfig() async throws {
        let cfg = try await LiveContractTests.runner().loadConfig()
        #expect(!cfg.github.owner.isEmpty)
        #expect(!cfg.github.repo.isEmpty)
        #expect(!cfg.github.branch.isEmpty)
        #expect((0...100).contains(cfg.upload.quality))
        // Every settable key must be readable, or the settings pane would show blanks.
        for k in ConfigKey.allCases { #expect(!k.value(in: cfg).isEmpty) }
    }

    @Test("list --json decodes against the real binary")
    func liveHistory() async throws {
        let recs = try await LiveContractTests.runner().history(limit: 5)
        for r in recs {
            #expect(r.date != nil, "unparsable timestamp: \(r.time)")
            #expect(!r.sha.isEmpty)
        }
    }

    @Test("writing an unchanged config issues no `config set` at all")
    func liveNoopWrite() async throws {
        let runner = try LiveContractTests.runner()
        let cfg = try await runner.loadConfig()
        let written = try await runner.applyConfig(from: cfg, to: cfg)
        #expect(written.isEmpty, "a no-op save must not touch the config file")
    }
}
