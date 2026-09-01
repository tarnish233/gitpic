import Foundation

/// The credential side of the CLI, as the window needs it: `auth status`, `auth
/// logout`, `repos`, and the one streaming command — `auth login --json`.
///
/// Every type here mirrors what `src/commands/auth_cmd.rs` and
/// `src/commands/repos.rs` print. They all declare `ok` plus optional payload and an
/// optional `error`, which is what lets a not-logged-in run — `{ok:false,error:…}`,
/// exit 3 — decode as *data* rather than arriving as `RunFailure.undecodable`. "No
/// credential yet" is a state the window has to render, not a fault.

/// `gitpic auth status --json`.
public struct AuthStatusReport: Codable, Sendable {
    public let ok: Bool
    public let tokenValid: Bool?
    public let login: String?
    public let expiresAt: String?
    public let path: String?
    public let detail: String?
    public let error: ErrorBody?

    // `client_id` is deliberately not decoded. The report carries it and `gitpic auth
    // status` prints it, which is the right surface for a twenty-character opaque
    // string: someone who has pointed `GITPIC_CLIENT_ID` at another app is debugging in
    // a terminal. In the window it was a constant next to the account name, and the one
    // thing a different app actually changes — token expiration being on — arrives as
    // `expires_at`, which *is* rendered. Unknown keys are ignored by `Decodable`, so
    // dropping the property costs nothing at the wire.
    enum CodingKeys: String, CodingKey {
        case ok
        case tokenValid = "token_valid"
        case expiresAt = "expires_at"
        case login, path, detail, error
    }
}

/// One row of `gitpic repos --json`.
public struct RepoCandidate: Codable, Sendable, Hashable, Identifiable {
    public let owner: String
    public let name: String
    public let isPrivate: Bool
    public let defaultBranch: String
    public let canPush: Bool

    enum CodingKeys: String, CodingKey {
        case owner, name
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case canPush = "can_push"
    }

    /// `owner/name` — the id, the label, and exactly what `github.repo` accepts.
    public var spec: String { "\(owner)/\(name)" }
    public var id: String { spec }

    /// A picker may offer only repositories that can both accept a write and serve
    /// the resulting unauthenticated public link.
    public var canBeImageHost: Bool { canPush && !isPrivate }
}

/// `gitpic repos --json`.
public struct ReposReport: Codable, Sendable {
    public let ok: Bool
    public let repos: [RepoCandidate]?
    /// False when the listing hit its page ceiling. Optional so an older CLI that did
    /// not report it reads as "no reason to doubt the list".
    public let complete: Bool?
    public let error: ErrorBody?
}

/// One row of `gitpic branches --json`.
public struct BranchCandidate: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    /// Reported, never filtered on: protection does not mean unwritable — the rules may
    /// permit this account — so a protected branch stays a legitimate choice. It is the
    /// usual explanation for a 409/422 when every other check passed, which is worth
    /// saying next to the name.
    public let protected: Bool

    public var id: String { name }
}

/// `gitpic branches --json`.
public struct BranchesReport: Codable, Sendable {
    public let ok: Bool
    public let branches: [BranchCandidate]?
    /// False when the listing hit its page ceiling.
    public let complete: Bool?
    public let error: ErrorBody?

    // `repo` and `configured` are in the envelope and deliberately not decoded, for the
    // same reason `client_id` is not: nothing here would read them. The window edits a
    // *draft*, so the branch it must display is the draft's — which is what 保存 will
    // write — and not the CLI's view of the saved file. Whether the draft's branch is one
    // of `branches` is the question that matters, and that is answered locally.
}

/// `gitpic auth logout --json`.
public struct LogoutReport: Codable, Sendable {
    public let ok: Bool
    public let removed: Bool?
    public let error: ErrorBody?
}

/// Where the login stands, as one value.
///
/// One enum rather than a handful of booleans because the states are genuinely
/// exclusive and the interesting ones carry data: a pending login *is* its code, and a
/// signed-in session *is* its account. Two flags plus two optionals would permit
/// "waiting for a code we do not have", which is the shape that renders a blank
/// dialogue with a spinner in it.
///
/// In `GitPicCore` rather than beside the view, because [`AuthStatusReport/state`] — the
/// rule that decides which report means *logged out* and which means *rejected* — is a
/// decision worth a test, and the executable target cannot be imported by one.
public enum AuthState: Sendable, Equatable {
    /// Not asked yet.
    case unknown
    case checking
    /// Nobody has logged in. The detail is the CLI's own message, when there is one.
    case loggedOut(detail: String?)
    /// A code is on screen and the CLI is polling GitHub.
    case awaitingCode(userCode: String, url: URL)
    case loggedIn(login: String?, expiresAt: String?)
    /// A credential exists, and GitHub would not accept it just now.
    case broken(detail: String)
}

extension AuthStatusReport {
    /// Read one report into a state.
    ///
    /// Three outcomes, and the two failing ones must not be merged: *logged out* is
    /// fixed by logging in, while *broken* may need nothing at all — a `NETWORK` detail
    /// means the credential is very likely fine and only `/user` was unreachable.
    /// Offering "log in again" as the sole answer to that is how a working setup gets
    /// thrown away over a dropped packet.
    public var state: AuthState {
        if let error, error.code == "CONFIG_MISSING" {
            return .loggedOut(detail: error.message)
        }
        if tokenValid == true {
            return .loggedIn(login: login, expiresAt: expiresAt)
        }
        let why = error.map { "\($0.code)：\($0.message)" }
            ?? detail
            ?? "GitHub 没有接受这枚凭据"
        return .broken(detail: why)
    }
}

/// One line of `gitpic auth login --json`.
///
/// That command is the single place in this CLI where `--json` is a *stream* rather
/// than one envelope, because the one-time code has to reach the caller minutes
/// before the outcome exists. Every line is a complete JSON object tagged `event`,
/// and the last line is always an outcome — which is the whole reason this window can
/// run the login itself instead of sending the user to a terminal.
public enum LoginEvent: Sendable, Equatable {
    /// The code to type, and where. Arrives seconds in; everything after it is waiting.
    case code(userCode: String, verificationURL: URL, expiresIn: TimeInterval)
    case done(login: String?)
    case failed(ErrorBody)
}

/// Turns one line of that stream into an event.
///
/// Separate from the process that produces it so the parsing is testable without a
/// browser and a fifteen-minute wait — the flow itself cannot be exercised in a test,
/// but every line it can emit can.
public enum LoginStream {
    /// `nil` for anything that is not a recognised event: a blank line, or a tag a
    /// later CLI added. Ignoring an unknown `event` is deliberate — the outcome lines
    /// are what the caller waits on, and a new informational tag must not read as a
    /// protocol violation.
    public static func event(from line: String) -> LoginEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else { return nil }
        switch raw.event {
        case "code":
            guard let code = raw.userCode,
                  let uri = raw.verificationURI,
                  let url = URL(string: uri),
                  // The URL is handed to `NSWorkspace.open`, so the host is checked
                  // here as well as in the CLI: this line arrives over a pipe, and a
                  // caller must not be able to make the app open an arbitrary scheme.
                  url.scheme == "https", url.host == "github.com"
            else { return nil }
            return .code(userCode: code,
                         verificationURL: url,
                         expiresIn: TimeInterval(raw.expiresInSeconds ?? 900))
        case "done":
            return .done(login: raw.login)
        case "error":
            return .failed(raw.error ?? ErrorBody(code: "GENERAL", message: "登录失败"))
        default:
            return nil
        }
    }

    private struct RawEvent: Decodable {
        let event: String
        let userCode: String?
        let verificationURI: String?
        let expiresInSeconds: Int?
        let login: String?
        let error: ErrorBody?

        enum CodingKeys: String, CodingKey {
            case event
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresInSeconds = "expires_in_seconds"
            case login, error
        }
    }
}

/// Holds the login child so cancellation can reach it.
///
/// A device-flow login blocks for as long as the code stays valid — fifteen minutes —
/// and the window that started it can be closed, or the user can press 取消, long
/// before that. Without a handle on the process there is nothing to stop, and the
/// child would sit polling GitHub with nobody listening.
///
/// `@unchecked Sendable` with a lock rather than an actor: the writer is the spawn
/// queue and the reader is whichever task cancels, and an actor cannot be touched from
/// `AsyncStream.onTermination`, which is not async.
final class LoginChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var outcomeSeen = false

    func hold(_ p: Process) {
        lock.lock()
        defer { lock.unlock() }
        // Cancelled before the spawn finished: terminate immediately rather than
        // leaving a child nobody will ever stop.
        if cancelled {
            p.terminate()
        } else {
            process = p
        }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        process?.terminate()
    }

    func noteOutcome() {
        lock.lock()
        defer { lock.unlock() }
        outcomeSeen = true
    }

    var sawOutcome: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcomeSeen
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
