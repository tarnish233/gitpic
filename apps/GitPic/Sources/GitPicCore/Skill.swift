import Foundation

/// An agent understood by `gitpic skill install --agent`.
public enum SkillAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case generic

    public var id: Self { self }
}

/// What installing the bundled skill at one target would do.
///
/// These values are the CLI's wire strings. `updated` means only that the file
/// differs: it may be an older bundled copy or a file the user edited by hand.
public enum SkillWriteAction: String, Codable, Sendable, Hashable {
    case install = "installed"
    case update = "updated"
    case unchanged = "already up to date"
}

/// One target reported by `gitpic skill path --json` or written by
/// `gitpic skill install --json`.
public struct SkillTarget: Codable, Sendable, Hashable, Identifiable {
    public let agents: [String]
    public let action: SkillWriteAction
    public let path: String

    public var id: String { path }
}

/// `gitpic skill path --json`.
public struct SkillPathEnvelope: Codable, Sendable {
    public let ok: Bool
    public let name: String
    public let version: String
    public let targets: [SkillTarget]
}

/// `gitpic skill install --json`.
///
/// A failed multi-target install can still carry rows that landed before the
/// failure, so `error` is data rather than a thrown decoding failure.
public struct SkillInstallEnvelope: Codable, Sendable {
    public let ok: Bool
    public let name: String
    public let version: String
    public let installed: [SkillTarget]
    public let error: ErrorBody?
}
