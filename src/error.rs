//! Unified error type with stable error codes and process exit codes.
//! Agents rely on both `exit code` and the `error.code` string.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ErrorCode {
    /// generic / unexpected
    General = 1,
    /// bad CLI usage / arguments
    Usage = 2,
    /// configuration missing (no credential / repo)
    ConfigMissing = 3,
    /// GitHub authentication failed
    AuthFailed = 4,
    /// network failure (retryable)
    Network = 5,
    /// input file not found / unreadable
    NotFound = 6,
    /// authenticated, but the token cannot perform the requested action
    PermissionDenied = 7,
    /// GitHub repository, branch, or remote path not found
    RemoteNotFound = 8,
    /// GitHub API rate limit reached
    RateLimited = 9,
    /// the config file exists but cannot be used (bad syntax, unknown key)
    ///
    /// Distinct from `ConfigMissing`: that one means "nothing is configured yet"
    /// and its remedy is `gitpic auth login` / `gitpic config set`, which would be the
    /// wrong advice — and for an agent, a loop — when the real problem is a typo
    /// in a file that is already there. The remedy here is to edit that file, so
    /// the message carries its path.
    ConfigInvalid = 10,
}

impl ErrorCode {
    /// Process exit status. The variant's discriminant *is* the exit code, so
    /// the number lives in exactly one place.
    pub fn exit_code(self) -> u8 {
        self as u8
    }

    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::General => "GENERAL",
            ErrorCode::Usage => "USAGE",
            ErrorCode::ConfigMissing => "CONFIG_MISSING",
            ErrorCode::AuthFailed => "AUTH_FAILED",
            ErrorCode::Network => "NETWORK",
            ErrorCode::NotFound => "NOT_FOUND",
            ErrorCode::PermissionDenied => "PERMISSION_DENIED",
            ErrorCode::RemoteNotFound => "REMOTE_NOT_FOUND",
            ErrorCode::RateLimited => "RATE_LIMITED",
            ErrorCode::ConfigInvalid => "CONFIG_INVALID",
        }
    }
}

#[derive(Debug)]
pub struct AppError {
    pub code: ErrorCode,
    pub message: String,
}

impl AppError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
    pub fn general(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::General, msg)
    }
    pub fn config_missing(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::ConfigMissing, msg)
    }
    pub fn auth(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::AuthFailed, msg)
    }
    pub fn network(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::Network, msg)
    }
    pub fn not_found(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::NotFound, msg)
    }
    pub fn usage(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::Usage, msg)
    }
    pub fn permission_denied(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::PermissionDenied, msg)
    }
    pub fn remote_not_found(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::RemoteNotFound, msg)
    }
    pub fn rate_limited(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::RateLimited, msg)
    }
    pub fn config_invalid(msg: impl Into<String>) -> Self {
        Self::new(ErrorCode::ConfigInvalid, msg)
    }
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for AppError {}

pub type Result<T> = std::result::Result<T, AppError>;

#[cfg(test)]
mod tests {
    use super::*;

    /// Locks the documented contract (`skills/gitpic/SKILL.md` + both READMEs).
    /// Agents key off both numbers and strings, so changing either is breaking —
    /// and now that `exit_code()` returns the discriminant, merely reordering the
    /// variants would do it silently.
    #[test]
    fn exit_codes_and_wire_strings_are_the_documented_contract() {
        for (code, exit, s) in [
            (ErrorCode::General, 1u8, "GENERAL"),
            (ErrorCode::Usage, 2, "USAGE"),
            (ErrorCode::ConfigMissing, 3, "CONFIG_MISSING"),
            (ErrorCode::AuthFailed, 4, "AUTH_FAILED"),
            (ErrorCode::Network, 5, "NETWORK"),
            (ErrorCode::NotFound, 6, "NOT_FOUND"),
            (ErrorCode::PermissionDenied, 7, "PERMISSION_DENIED"),
            (ErrorCode::RemoteNotFound, 8, "REMOTE_NOT_FOUND"),
            (ErrorCode::RateLimited, 9, "RATE_LIMITED"),
            (ErrorCode::ConfigInvalid, 10, "CONFIG_INVALID"),
        ] {
            assert_eq!(code.exit_code(), exit, "exit code for {s}");
            assert_eq!(code.as_str(), s, "wire string for {s}");
        }
    }
}
