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
}

/// Which keys differ between two configs, in a stable order.
public func changedKeys(from old: GitpicConfig, to new: GitpicConfig) -> [ConfigKey] {
    ConfigKey.allCases.filter { $0.value(in: old) != $0.value(in: new) }
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
    /// Percent-encoding matches `naming::encode_path`, which preserves `/`.
    public func rawURL(config: GitpicConfig) -> String {
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "https://raw.githubusercontent.com/\(config.github.owner)/"
             + "\(config.github.repo)/\(config.github.branch)/\(encoded)"
    }

    public func markdown(config: GitpicConfig) -> String { "![\(name)](\(url))" }
}

public struct HistoryEnvelope: Codable, Sendable {
    public let ok: Bool
    public let results: [HistoryRecord]
}
