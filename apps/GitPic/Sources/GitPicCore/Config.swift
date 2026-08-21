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
        public var linkKind: String
        public var dedup: Bool
        public var autoCopy: Bool
        public var compress: Bool
        public var maxWidth: Int
        public var quality: Int

        enum CodingKeys: String, CodingKey {
            case pathTemplate = "path_template"
            case linkKind = "link_kind"
            case dedup
            case autoCopy = "auto_copy"
            case compress
            case maxWidth = "max_width"
            case quality
        }
    }
}

/// The ten keys `config set` accepts (`src/commands/config_cmd.rs:126-170`).
/// Anything else is a `USAGE` error, and a Rust test derives this list from
/// `Config` itself so the arms cannot drift.
public enum ConfigKey: String, Sendable, CaseIterable {
    case owner        = "github.owner"
    case repo         = "github.repo"
    case branch       = "github.branch"
    case pathTemplate = "upload.path_template"
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
/// Deliberately smaller than `ItemResult`: history stores only `url`, so the
/// markdown/HTML/raw forms have to be derived rather than read back. That is why
/// the UI keeps freshly-uploaded `ItemResult`s in memory instead of re-reading
/// history for the format switcher.
public struct HistoryRecord: Codable, Sendable, Hashable, Identifiable {
    public let time: String
    public let name: String
    public let path: String
    public let url: String
    public let sha: String
    public let size: Int
    public let deduped: Bool

    public var id: String { "\(time):\(sha)" }

    /// `time` is RFC 3339 with an offset, e.g. `2026-08-19T23:00:22.230025+08:00`.
    public var date: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: time) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: time)
    }

    /// The raw.githubusercontent form, rebuilt from the configured target.
    ///
    /// One formula, in ``LinkURL`` — the app needs the same two URLs for a freshly
    /// uploaded item, and a second copy of the template here is how the two drift.
    public func rawURL(config c: GitpicConfig) -> String {
        LinkURL.raw(owner: c.github.owner, repo: c.github.repo,
                    branch: c.github.branch, path: path)
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
}
