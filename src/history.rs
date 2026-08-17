//! Local upload history (append-only JSONL).

use crate::config::Config;
use crate::error::{AppError, Result};
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
            .map_err(|e| AppError::general(format!("mkdir data dir: {e}")))?;
    }
    let line = serde_json::to_string(rec)
        .map_err(|e| AppError::general(format!("serialize record: {e}")))?;
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| AppError::general(format!("open history: {e}")))?;
    writeln!(f, "{line}").map_err(|e| AppError::general(format!("write history: {e}")))?;
    Ok(())
}

/// Read up to the last `limit` records (newest first).
pub fn read_recent(limit: usize) -> Result<Vec<Record>> {
    let path = Config::history_path()?;
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = std::fs::read_to_string(&path)
        .map_err(|e| AppError::general(format!("read history: {e}")))?;
    Ok(parse_recent(&text, limit))
}

/// Newest-first, capped at `limit`.
///
/// Split from the file read so the ordering is testable without touching
/// `XDG_DATA_HOME` (mutating the environment is unsound across the parallel test
/// runner). Reversing *before* truncating is load-bearing: the other order
/// returns the **oldest** `limit` records, which looks plausible and is wrong.
fn parse_recent(text: &str, limit: usize) -> Vec<Record> {
    let mut recs: Vec<Record> = text
        .lines()
        .filter_map(|l| serde_json::from_str::<Record>(l).ok())
        .collect();
    recs.reverse();
    recs.truncate(limit);
    recs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(name: &str) -> String {
        serde_json::to_string(&Record {
            time: format!("2026-08-17T00:00:00+08:00 {name}"),
            name: name.to_string(),
            path: format!("images/{name}.png"),
            url: format!("https://example.test/{name}.png"),
            sha: "deadbeef".to_string(),
            size: 1,
            deduped: false,
        })
        .unwrap()
    }

    #[test]
    fn returns_the_newest_records_first() {
        // Appended oldest-to-newest, so `c` is the most recent.
        let text = format!("{}\n{}\n{}\n", line("a"), line("b"), line("c"));
        let got = parse_recent(&text, 10);
        let names: Vec<&str> = got.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["c", "b", "a"]);
    }

    #[test]
    fn limit_keeps_the_newest_not_the_oldest() {
        // Regression guard: truncating before reversing would yield ["a", "b"].
        let text = format!("{}\n{}\n{}\n", line("a"), line("b"), line("c"));
        let names: Vec<String> = parse_recent(&text, 2).into_iter().map(|r| r.name).collect();
        assert_eq!(names, ["c", "b"]);
    }

    #[test]
    fn unparseable_and_blank_lines_are_skipped() {
        let text = format!("{}\n\n   \nnot json\n{}\n", line("a"), line("b"));
        assert_eq!(parse_recent(&text, 10).len(), 2);
    }
}
