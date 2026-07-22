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
        Self { code, message: message.into() }
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
