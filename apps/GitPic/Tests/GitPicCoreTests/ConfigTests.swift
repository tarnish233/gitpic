import Testing
import Foundation
@testable import GitPicCore

private func decode<T: Decodable>(_ s: String, _ t: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(s.utf8))
}

@Suite("Config decoding and diffing")
struct ConfigTests {
    /// Captured from `gitpic config get --json`.
    static let live = """
    {
      "ok": true,
      "config": {
        "github": { "owner": "tarnish233", "repo": "picture_of_notes", "branch": "main" },
        "upload": {
          "path_template": "images/{year}/{month}/{hash8}-{name}.{ext}",
          "link_kind": "cdn",
          "dedup": true,
          "auto_copy": true,
          "compress": false,
          "max_width": 0,
          "quality": 82
        }
      }
    }
    """

    @Test("the live envelope decodes with native types, not strings")
    func decodeLive() throws {
        let env: ConfigEnvelope = try decode(Self.live)
        #expect(env.ok)
        #expect(env.config.github.owner == "tarnish233")
        #expect(env.config.github.repo == "picture_of_notes")
        #expect(env.config.upload.dedup == true)      // a real Bool, not "true"
        #expect(env.config.upload.quality == 82)      // a real Int, not "82"
        #expect(env.config.upload.maxWidth == 0)
        #expect(env.config.upload.pathTemplate.contains("{hash8}"))
    }

    @Test("every one of the ten settable keys can be read back out of a config")
    func keyCoverage() throws {
        let c = try decode(Self.live, ConfigEnvelope.self).config
        #expect(ConfigKey.allCases.count == 10)
        for k in ConfigKey.allCases {
            #expect(!k.value(in: c).isEmpty, "\(k.rawValue) produced no value")
        }
        #expect(ConfigKey.dedup.value(in: c) == "true")
        #expect(ConfigKey.quality.value(in: c) == "82")
        #expect(ConfigKey.maxWidth.value(in: c) == "0")
    }

    @Test("an unchanged config writes nothing")
    func noopDiff() throws {
        let c = try decode(Self.live, ConfigEnvelope.self).config
        #expect(changedKeys(from: c, to: c).isEmpty)
    }

    @Test("only genuinely changed keys are written, which is what limits the lost-update window")
    func minimalDiff() throws {
        let a = try decode(Self.live, ConfigEnvelope.self).config
        var b = a
        b.upload.quality = 90
        b.github.branch = "gh-pages"
        let keys = changedKeys(from: a, to: b)
        #expect(Set(keys) == Set([.quality, .branch]))
        #expect(keys.count == 2)
        // Stable order, so a UI showing "writing N keys" is reproducible.
        #expect(keys == ConfigKey.allCases.filter { keys.contains($0) })
    }

    @Test("a bool flip is expressed the way `config set` parses it")
    func boolFormatting() throws {
        var b = try decode(Self.live, ConfigEnvelope.self).config
        b.upload.compress = true
        #expect(ConfigKey.compress.value(in: b) == "true")
        b.upload.compress = false
        #expect(ConfigKey.compress.value(in: b) == "false")
    }
}

@Suite("History records")
struct HistoryTests {
    /// Captured from `gitpic list --json` right after the live upload test ran.
    static let live = """
    {
      "ok": true,
      "results": [
        {
          "time": "2026-08-19T23:00:22.230025+08:00",
          "name": "gitpic-app-selftest",
          "path": "images/2026/08/0e25bc02-gitpic-app-selftest.png",
          "url": "https://cdn.jsdelivr.net/gh/tarnish233/picture_of_notes@main/images/2026/08/0e25bc02-gitpic-app-selftest.png",
          "sha": "358150f9c96fef0676cefcaef63312509d757865",
          "size": 195,
          "deduped": true
        }
      ]
    }
    """

    @Test("history decodes, including the fractional-second timestamp")
    func decodeLive() throws {
        let env: HistoryEnvelope = try decode(Self.live)
        let r = try #require(env.results.first)
        #expect(r.name == "gitpic-app-selftest")
        #expect(r.size == 195)
        #expect(r.deduped)
        #expect(r.date != nil, "RFC 3339 with fractional seconds failed to parse")
    }

    @Test("a timestamp without fractional seconds still parses")
    func timestampFallback() throws {
        let r: HistoryRecord = try decode("""
        { "time": "2026-08-19T23:00:22+08:00", "name": "x", "path": "a/b.png",
          "url": "https://e/x", "sha": "abc", "size": 1, "deduped": false }
        """)
        #expect(r.date != nil)
    }

    @Test("raw URL is rebuilt from the configured target, since history omits it")
    func rawURLDerivation() throws {
        let cfg = try decode(ConfigTests.live, ConfigEnvelope.self).config
        let r = try #require(try decode(Self.live, HistoryEnvelope.self).results.first)
        #expect(r.rawURL(config: cfg)
                == "https://raw.githubusercontent.com/tarnish233/picture_of_notes/main/images/2026/08/0e25bc02-gitpic-app-selftest.png")
    }

    @Test("path separators survive percent-encoding; spaces do not stay literal")
    func encoding() throws {
        let cfg = try decode(ConfigTests.live, ConfigEnvelope.self).config
        let r: HistoryRecord = try decode("""
        { "time": "2026-08-19T23:00:22+08:00", "name": "n", "path": "images/a b/c.png",
          "url": "https://e/x", "sha": "s", "size": 1, "deduped": false }
        """)
        let raw = r.rawURL(config: cfg)
        #expect(raw.hasSuffix("/images/a%20b/c.png"))
        #expect(raw.contains("/main/images/"))
    }
}
