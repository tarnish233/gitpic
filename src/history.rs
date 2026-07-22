//! Local upload history (append-only JSONL).

use crate::config::Config;
use crate::error::{AppError, ErrorCode, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Record {
    pub time: String,
    pub name: String,
    pub path: String,
    pub url: String,
    pub sha: String,
    pub size: usize,
    pub deduped: bool,
}

/// Append a record; failures here must never break an upload, so errors are
/// swallowed by the caller when desired.
pub fn append(rec: &Record) -> Result<()> {
    let path = Config::history_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| AppError::new(ErrorCode::General, format!("mkdir data dir: {e}")))?;
    }
    let line = serde_json::to_string(rec)
        .map_err(|e| AppError::new(ErrorCode::General, format!("serialize record: {e}")))?;
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| AppError::new(ErrorCode::General, format!("open history: {e}")))?;
    writeln!(f, "{line}")
        .map_err(|e| AppError::new(ErrorCode::General, format!("write history: {e}")))?;
    Ok(())
}

/// Read up to the last `limit` records (newest first).
pub fn read_recent(limit: usize) -> Result<Vec<Record>> {
    let path = Config::history_path()?;
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = std::fs::read_to_string(&path)
        .map_err(|e| AppError::new(ErrorCode::General, format!("read history: {e}")))?;
    let mut recs: Vec<Record> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<Record>(l).ok())
        .collect();
    recs.reverse();
    recs.truncate(limit);
    Ok(recs)
}
