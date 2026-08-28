import Foundation

/// Mirrors the `config get --json` envelope (`src/commands/config_cmd.rs:25-29`).
///
/// Note the CLI has two disagreeing shapes here: `config get` (no key) emits
/// native JSON types, while `config get <key>` stringifies everything
/// (`get_key` returns `String`). This app only ever reads the whole config, so it
/// gets the typed form.
public struct ConfigEnvelope: Codable, Sendable {
    public let ok: Bool
    public let config: GitpicConfig
}

/// `config path` / `config edit` (`src/commands/config_cmd.rs`).
public struct PathEnvelope: Codable, Sendable {
    public let ok: Bool
    public let path: String
}

/// Why the window has no config to show, in the form it has to be presented.
///
/// The distinction that earns a type is not failed-vs-not but whether there is a
/// way *out*. A config file that exists and cannot be parsed is the one read
/// failure the window can clear by itself, and it is the one people actually hit:
/// `github.token` stopped being accepted in 0.5.0, so every machine upgraded from
/// before that still has a line in the file that makes the whole of it
/// `CONFIG_INVALID`.
public enum ConfigFailure: Sendable, Equatable {
    /// The CLI refused and named its reason. Shown verbatim — it already names the
    /// file and the offending key, and says nothing about the file's *contents*
    /// (`src/config.rs` has a test pinning that a removed `token` is rejected
    /// without echoing its value).
    case cli(ErrorBody)
    /// Something below the CLI's error contract: it never ran, or answered with
    /// something that was not an envelope. Also shown verbatim — inventing a
    /// friendlier story for this is how the real cause gets buried.
    case other(String)

    public init(_ error: Error) {
        if case RunFailure.cli(_, let body) = error {
            self = .cli(body)
        } else if let failure = error as? RunFailure {
            // Through ``RunFailure/message`` rather than `String(describing:)`, which printed
            // the enum: `.spawnFailed` reached the window as `spawnFailed("…")` and
            // `.undecodable` as `undecodable(status: 2, raw: "…")`. The existing test for
            // this asserted `contains`, so it stayed green either way.
            self = .other(failure.message)
        } else {
            self = .other(String(describing: error))
        }
    }

    public var code: String? {
        if case .cli(let e) = self { return e.code }
        return nil
    }

    public var message: String {
        switch self {
        case .cli(let e):   return e.message
        case .other(let s): return s
        }
    }

    /// Whether moving the file aside is a remedy for this.
    ///
    /// `CONFIG_INVALID` means the file exists and its text is the problem, which a
    /// rename fixes. Every other code — a `gitpic` that would not spawn, output
    /// that was not an envelope — is about something other than the file, and
    /// renaming it would destroy a working config to fix nothing.
    public var isFileUnusable: Bool { code.flatMap(GitpicErrorCode.init(wire:)) == .configInvalid }

    public var headline: String {
        isFileUnusable ? "配置文件无法解析" : "读取配置失败"
    }
}

public struct GitpicConfig: Codable, Sendable, Equatable {
    public var github: GitHub
    public var upload: Upload

    public struct GitHub: Codable, Sendable, Equatable {
        public var owner: String
        public var repo: String
        public var branch: String
    }

    public struct Upload: Codable, Sendable, Equatable {
        public var pathTemplate: String
        /// `upload.format` — the snippet syntax, `md` | `html` | `url`. Declared next
        /// to `linkKind` because the two are the two halves of one question.
        public var format: String
        public var linkKind: String
        public var dedup: Bool
        public var autoCopy: Bool
        public var compress: Bool
        public var maxWidth: Int
        public var quality: Int

        enum CodingKeys: String, CodingKey {
            case pathTemplate = "path_template"
            case format
            case linkKind = "link_kind"
            case dedup
            case autoCopy = "auto_copy"
            case compress
            case maxWidth = "max_width"
            case quality
        }
    }
}

/// The eleven keys `config set` accepts (`src/commands/config_cmd.rs`).
/// Anything else is a `USAGE` error, and a Rust test derives this list from
/// `Config` itself so the arms cannot drift.
public enum ConfigKey: String, Sendable, CaseIterable {
    case owner        = "github.owner"
    case repo         = "github.repo"
    case branch       = "github.branch"
    case pathTemplate = "upload.path_template"
    case format       = "upload.format"
    case linkKind     = "upload.link_kind"
    case dedup        = "upload.dedup"
    case autoCopy     = "upload.auto_copy"
    case compress     = "upload.compress"
    case maxWidth     = "upload.max_width"
    case quality      = "upload.quality"

    /// Reads the current value out of a loaded config, as the string `config set`
    /// would take. Keeping read and write symmetrical is what lets the UI diff
    /// old against new and issue only the keys that actually changed.
    public func value(in c: GitpicConfig) -> String {
        switch self {
        case .owner:        return c.github.owner
        case .repo:         return c.github.repo
        case .branch:       return c.github.branch
        case .pathTemplate: return c.upload.pathTemplate
        case .format:       return c.upload.format
        case .linkKind:     return c.upload.linkKind
        case .dedup:        return String(c.upload.dedup)
        case .autoCopy:     return String(c.upload.autoCopy)
        case .compress:     return String(c.upload.compress)
        case .maxWidth:     return String(c.upload.maxWidth)
        case .quality:      return String(c.upload.quality)
        }
    }
    /// Copies one key's value from one config into another — the mirror of
    /// `value(in:)`, and deliberately field-to-field rather than through the string
    /// form so `dedup`/`max_width` need no parsing back.
    ///
    /// Read and write live side by side for the reason the comment above gives: the
    /// UI has to rebuild a config one key at a time after a save, because
    /// `config set` normalises `github.repo` and what landed differs from what was
    /// typed. A second copy of this mapping in the UI layer is exactly how the two
    /// drift apart.
    public func copy(from source: GitpicConfig, into target: inout GitpicConfig) {
        switch self {
        case .owner:        target.github.owner = source.github.owner
        case .repo:         target.github.repo = source.github.repo
        case .branch:       target.github.branch = source.github.branch
        case .pathTemplate: target.upload.pathTemplate = source.upload.pathTemplate
        case .format:       target.upload.format = source.upload.format
        case .linkKind:     target.upload.linkKind = source.upload.linkKind
        case .dedup:        target.upload.dedup = source.upload.dedup
        case .autoCopy:     target.upload.autoCopy = source.upload.autoCopy
        case .compress:     target.upload.compress = source.upload.compress
        case .maxWidth:     target.upload.maxWidth = source.upload.maxWidth
        case .quality:      target.upload.quality = source.upload.quality
        }
    }
}

/// Which keys differ between two configs, in a stable order.
public func changedKeys(from old: GitpicConfig, to new: GitpicConfig) -> [ConfigKey] {
    ConfigKey.allCases.filter { $0.value(in: old) != $0.value(in: new) }
}

/// Merge a freshly-read config into an in-progress draft, key by key.
///
/// Field by field rather than all-or-nothing on the whole struct, because comparing
/// whole structs forces a choice between two wrong answers. Replace the draft and
/// edits typed while the read was in flight are lost. Keep it and every key the CLI
/// normalised is stranded: a `repo` typed as `me/pics` is stored as
/// `owner=me repo=pics`, so the typed form never equals the file again and the form
/// reports it unsaved forever — with `revert()` the only way out and nothing in the
/// UI saying so.
///
/// `baseline` is what the draft was diffed against before the round trip, so a key
/// where `current` still equals `baseline` is one the user never touched and the
/// file's value can be adopted. `keys` narrows that to a subset: after a partly
/// failed save only the keys the file actually moved on may be adopted, or the
/// values whose writes failed would be overwritten with the old ones the user still
/// needs in the form to retry.
public func reconcile(
    draft current: GitpicConfig,
    toward fresh: GitpicConfig,
    untouchedSince baseline: GitpicConfig,
    keys: [ConfigKey] = ConfigKey.allCases
) -> GitpicConfig {
    var merged = current
    for key in keys where key.value(in: current) == key.value(in: baseline) {
        key.copy(from: fresh, into: &merged)
    }
    return merged
}

/// Mirrors one `history::Record` as returned by `list --json`.
///
/// Newer lines carry `owner`/`repo`/`branch` — the target the upload used — so both
/// addresses can be rebuilt without guessing from today's config. Older lines have
/// only `url`; ``LinkURL/parse(_:path:)`` recovers the target from that, and
/// today's config is the last resort when even that fails.
public struct HistoryRecord: Codable, Sendable, Hashable, Identifiable {
    public let time: String
    public let name: String
    public let path: String
    public let url: String
    public let sha: String
    public let size: Int
    public let deduped: Bool
    public let owner: String?
    public let repo: String?
    public let branch: String?

    public var id: String { "\(time):\(sha)" }

    public init(time: String, name: String, path: String, url: String, sha: String,
                size: Int, deduped: Bool,
                owner: String? = nil, repo: String? = nil, branch: String? = nil) {
        self.time = time
        self.name = name
        self.path = path
        self.url = url
        self.sha = sha
        self.size = size
        self.deduped = deduped
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }

    /// `time` is RFC 3339 with an offset, e.g. `2026-08-19T23:00:22.230025+08:00`.
    public var date: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: time) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: time)
    }

    /// The repository this row was uploaded to, if it can be known without guessing.
    ///
    /// The persisted fields win; the stored URL is parsed next. `nil` means the
    /// line is too old or too odd to recover, and the caller may fall back to
    /// today's config — that is the guess this type exists to stop making first.
    public var resolvedTarget: UploadTarget? {
        if let owner, let repo, let branch,
           !owner.isEmpty, !repo.isEmpty, !branch.isEmpty {
            return UploadTarget(owner: owner, repo: repo, branch: branch)
        }
        return LinkURL.parse(url, path: path)
    }

    /// The raw.githubusercontent form for this row.
    ///
    /// Built from the upload's own target when that is known. The config argument
    /// is the last resort for a line that cannot be parsed, not the default.
    public func rawURL(config c: GitpicConfig) -> String {
        let t = resolvedTarget ?? UploadTarget(owner: c.github.owner,
                                               repo: c.github.repo,
                                               branch: c.github.branch)
        return LinkURL.raw(owner: t.owner, repo: t.repo, branch: t.branch, path: path)
    }
}

public struct HistoryEnvelope: Codable, Sendable {
    public let ok: Bool
    public let results: [HistoryRecord]
}

/// Percent-encoding that matches `naming::encode_path` (`src/naming.rs`).
///
/// Foundation's `.urlPathAllowed` leaves `+` intact, which is not what the CLI
/// emits and is not what GitHub's raw URL needs. Unreserved characters and `/`
/// stay literal; every other byte is `%XX`.
public enum GitHubEncoding {
    public static func encodePath(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            switch b {
            case 0x2F, // /
                 0x41...0x5A, 0x61...0x7A, // A-Z a-z
                 0x30...0x39, // 0-9
                 0x2D, 0x2E, 0x5F, 0x7E: // - . _ ~
                out.append(Character(UnicodeScalar(b)))
            default:
                out.append(String(format: "%%%02X", b))
            }
        }
        return out
    }

    /// Inverse of ``encodePath``. Bytes that are not a `%XX` pair stay literal, so
    /// a truncated escape cannot swallow the rest of the string.
    public static func decodePath(_ s: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count)
        let u = s.utf8
        var i = u.startIndex
        while i < u.endIndex {
            if u[i] == 0x25,
               let n1 = u.index(i, offsetBy: 1, limitedBy: u.endIndex),
               let n2 = u.index(i, offsetBy: 2, limitedBy: u.endIndex),
               n2 < u.endIndex,
               let hi = hexNibble(u[n1]), let lo = hexNibble(u[n2]) {
                bytes.append(hi << 4 | lo)
                i = u.index(after: n2)
            } else {
                bytes.append(u[i])
                i = u.index(after: i)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? s
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }
}
