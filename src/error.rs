//! Unified error type with stable error codes and process exit codes.
//! Agents rely on both `exit code` and the `error.code` string.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    /// 1 - generic / unexpected
    General,
    /// 2 - bad CLI usage / arguments
    Usage,
    /// 3 - configuration missing (no token / repo)
    ConfigMissing,
    /// 4 - GitHub authentication failed
    AuthFailed,
    /// 5 - network failure (retryable)
    Network,
    /// 6 - input file not found / unreadable
    NotFound,
    /// 7 - authenticated but not permitted (e.g. no push access to the repo)
    PermissionDenied,
}

impl ErrorCode {
    pub fn exit_code(self) -> u8 {
        match self {
            ErrorCode::General => 1,
            ErrorCode::Usage => 2,
            ErrorCode::ConfigMissing => 3,
            ErrorCode::AuthFailed => 4,
            ErrorCode::Network => 5,
            ErrorCode::NotFound => 6,
            ErrorCode::PermissionDenied => 7,
        }
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
        }
    }
}

#[derive(Debug)]
pub struct AppError {
    pub code: ErrorCode,
    pub message: String,
    /// Set when the command already wrote its own diagnostics. `main` then skips
    /// the error envelope, so JSON mode still emits exactly one object.
    pub reported: bool,
}

impl AppError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            reported: false,
        }
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

    /// Mark the diagnostics as already printed by the command itself.
    pub fn mark_reported(mut self) -> Self {
        self.reported = true;
        self
    }
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for AppError {}

impl From<anyhow::Error> for AppError {
    fn from(e: anyhow::Error) -> Self {
        AppError::new(ErrorCode::General, e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, AppError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permission_denied_has_stable_code_and_exit_status() {
        assert_eq!(ErrorCode::PermissionDenied.exit_code(), 7);
        assert_eq!(ErrorCode::PermissionDenied.as_str(), "PERMISSION_DENIED");
    }

    /// Exit codes are part of the agent contract; pin the whole set so a
    /// reordering of the enum cannot silently renumber them.
    #[test]
    fn exit_codes_are_stable() {
        for (code, want) in [
            (ErrorCode::General, 1u8),
            (ErrorCode::Usage, 2),
            (ErrorCode::ConfigMissing, 3),
            (ErrorCode::AuthFailed, 4),
            (ErrorCode::Network, 5),
            (ErrorCode::NotFound, 6),
            (ErrorCode::PermissionDenied, 7),
        ] {
            assert_eq!(code.exit_code(), want, "{code:?} changed exit code");
        }
    }

    #[test]
    fn errors_are_unreported_until_marked() {
        assert!(!AppError::auth("nope").reported);
        assert!(AppError::auth("nope").mark_reported().reported);
    }
}
