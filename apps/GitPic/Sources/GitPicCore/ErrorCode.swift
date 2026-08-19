import Foundation

/// The CLI's `ErrorCode` (`src/error.rs:6-35`). The discriminant *is* the
/// process exit code, and a contract test at `src/error.rs:124-140` locks both
/// the wire strings and the numbers — so this table is safe to depend on.
public enum GitpicErrorCode: UInt8, Sendable, CaseIterable {
    case general          = 1
    case usage            = 2
    case configMissing    = 3
    case authFailed       = 4
    case network          = 5
    case notFound         = 6
    case permissionDenied = 7
    case remoteNotFound   = 8
    case rateLimited      = 9
    case configInvalid    = 10

    public var wire: String {
        switch self {
        case .general:          return "GENERAL"
        case .usage:            return "USAGE"
        case .configMissing:    return "CONFIG_MISSING"
        case .authFailed:       return "AUTH_FAILED"
        case .network:          return "NETWORK"
        case .notFound:         return "NOT_FOUND"
        case .permissionDenied: return "PERMISSION_DENIED"
        case .remoteNotFound:   return "REMOTE_NOT_FOUND"
        case .rateLimited:      return "RATE_LIMITED"
        case .configInvalid:    return "CONFIG_INVALID"
        }
    }

    public init?(wire: String) {
        guard let m = Self.allCases.first(where: { $0.wire == wire }) else { return nil }
        self = m
    }

    /// What the user should be told to *do*. `configMissing` is the one the GUI
    /// must not parrot: the CLI collapses "no gh", "gh not logged in", and "gh
    /// failed" into it (`src/auth.rs:57-60`, `84-86`) with gh's stderr dropped,
    /// so the GUI re-probes gh itself before showing anything.
    public var needsToolDiagnosis: Bool { self == .configMissing }
}
