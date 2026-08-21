import Foundation

/// Mirrors `ItemResult` in `src/output.rs:31-43`.
///
/// Field names are the Rust field names verbatim — the struct carries no
/// `#[serde(rename_all)]`, so `raw_url` is the only key that differs from a
/// Swift-idiomatic spelling.
public struct ItemResult: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let url: String
    public let rawURL: String
    public let markdown: String
    public let html: String
    public let path: String
    public let sha: String
    public let size: Int
    public let deduped: Bool
    /// The snippet the CLI selected per `--format`.
    public let output: String

    /// `sha` is content-addressed but two inputs can dedup to the same blob,
    /// so pair it with the remote path for a stable identity.
    public var id: String { "\(sha):\(path)" }

    enum CodingKeys: String, CodingKey {
        case name, url
        case rawURL = "raw_url"
        case markdown, html, path, sha, size, deduped, output
    }
}

/// Mirrors `ErrorBody` in `src/output.rs`.
public struct ErrorBody: Codable, Sendable, Hashable {
    public let code: String
    public let message: String
}

/// The `{ ok: false, error: {…} }` envelope *any* subcommand emits when it
/// refuses — `ErrorEnvelope` in `src/output.rs`.
///
/// Kept apart from the per-command payload types rather than folded into them.
/// `config get` and `list` declare their payload non-optional, which is the honest
/// shape of a success; making it optional to accommodate a refusal would push
/// "which of the two is this" into every call site instead. The payload decode is
/// tried first and this is the fallback (``GitpicRunner/failure(_:)``), so a
/// refusal arrives as a typed ``RunFailure/cli(status:error:)`` carrying the CLI's
/// own code and message.
public struct ErrorEnvelope: Codable, Sendable {
    public let ok: Bool
    public let error: ErrorBody
}

/// The three envelope shapes the CLI can emit on stdout under `--json`,
/// collapsed into one decodable type.
///
/// `src/output.rs` defines them separately — `SuccessEnvelope { ok, results }`,
/// `PartialEnvelope { ok, results, error }`, `ErrorEnvelope { ok, error }` — but
/// they are distinguished on the wire only by which optional keys are present,
/// so one struct plus `outcome` is the honest decoding.
public struct UploadEnvelope: Codable, Sendable {
    public let ok: Bool
    public let results: [ItemResult]?
    public let error: ErrorBody?

    public enum Outcome: Sendable, Equatable {
        case success([ItemResult])
        /// Some files landed, then one failed. `src/commands/upload.rs:248-254`
        /// makes the presence of `results` the partial-vs-total discriminator.
        case partial([ItemResult], ErrorBody)
        case failure(ErrorBody)
        /// Shape we do not recognise — never guessed at, always surfaced.
        case malformed(String)
    }

    public var outcome: Outcome {
        switch (ok, results, error) {
        case (true, let r?, _):        return .success(r)
        case (false, let r?, let e?):  return .partial(r, e)
        case (false, nil, let e?):     return .failure(e)
        case (true, nil, _):
            return .malformed("ok:true with no results")
        case (false, _, nil):
            return .malformed("ok:false with no error body")
        }
    }
}

/// Mirrors `DoctorReport` in `src/commands/doctor.rs:11-39`.
///
/// `doctor` is the one subcommand that prints its report instead of an error
/// envelope when unhealthy, so `error` is present exactly when `ok` is false.
public struct DoctorReport: Codable, Sendable {
    public let ok: Bool
    public let configOK: Bool?
    public let tokenValid: Bool?
    public let repoWritable: Bool?
    public let branchProtected: Bool?
    public let tokenSource: String?
    public let login: String?
    public let detail: String?
    public let error: ErrorBody?

    enum CodingKeys: String, CodingKey {
        case ok
        case configOK = "config_ok"
        case tokenValid = "token_valid"
        case repoWritable = "repo_writable"
        case branchProtected = "branch_protected"
        case tokenSource = "token_source"
        case login, detail, error
    }
}
