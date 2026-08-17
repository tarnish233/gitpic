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

/// Ceiling for the history file. Past this it is trimmed, oldest first.
///
/// The file is append-only and `read_recent` parses all of it, so without a
/// ceiling every `gitpic list` eventually pays for years of uploads. At a few
/// hundred bytes per record this holds several thousand of them.
const MAX_BYTES: usize = 2 * 1024 * 1024;

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
    // One `write_all` of record-plus-newline, not `writeln!`. `writeln!` goes
    // through `write_fmt`, which emits the body and the newline as two separate
    // `write` calls: `O_APPEND` makes each one atomic but not the pair, so a second
    // process appending concurrently can land its record between them. The result
    // is two records merged onto one line, which `parse_recent` then skips without
    // a word — records silently missing from `gitpic list`. Two `gitpic` processes
    // is not exotic: an agent batching uploads, or `xargs -P`, does it.
    let mut buf = Vec::with_capacity(line.len() + 1);
    buf.extend_from_slice(line.as_bytes());
    buf.push(b'\n');
    f.write_all(&buf)
        .map_err(|e| AppError::general(format!("write history: {e}")))?;
    drop(f);

    // Only the cheap metadata call happens on a normal append; the file is read
    // and rewritten just on the rare occasion it has grown past the ceiling.
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() as usize > MAX_BYTES {
            trim_file(&path, MAX_BYTES);
        }
    }
    Ok(())
}

/// Rewrite the history down to its retained tail.
///
/// Best-effort by design: this runs after the record is already safely on disk,
/// and losing the *trim* must never turn into losing the *upload*. Written to a
/// sibling temp file and renamed, so an interrupted trim cannot leave a
/// half-written history behind. The temp name carries the pid, so two processes
/// trimming at once cannot write the same file — they still race on the rename and
/// one snapshot wins, which is acceptable for a best-effort trim, but neither ends
/// up reading the other's half-written bytes.
///
/// `max_bytes` is a parameter rather than a direct read of `MAX_BYTES` so the
/// rename-and-replace can be tested against a small file.
fn trim_file(path: &std::path::Path, max_bytes: usize) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    let Some(kept) = trimmed(&text, max_bytes) else {
        return;
    };
    let tmp = path.with_extension(format!("jsonl.{}.tmp", std::process::id()));
    if std::fs::write(&tmp, kept).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    } else {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// The retained tail of `text`, or `None` when it is small enough to leave alone.
///
/// Keeps the **newest** records: `read_recent` reports newest-first, so those are
/// the ones anyone actually looks at. Cuts back to half the ceiling rather than
/// exactly to it, so the rewrite is amortised over many later appends instead of
/// running again on the very next one.
fn trimmed(text: &str, max_bytes: usize) -> Option<String> {
    if text.len() <= max_bytes {
        return None;
    }
    let target = max_bytes / 2;
    let mut kept: Vec<&str> = Vec::new();
    let mut total = 0usize;
    for line in text.lines().rev().filter(|l| !l.trim().is_empty()) {
        // +1 for the newline each retained line gets back. The newest record is
        // kept unconditionally: without that, a single record longer than the
        // budget would fit nothing, and returning an empty string here means the
        // caller writes an empty file — wiping the whole history to enforce a
        // size limit. Bounding the file at "one record" is the honest floor.
        if !kept.is_empty() && total + line.len() + 1 > target {
            break;
        }
        total += line.len() + 1;
        kept.push(line);
    }
    kept.reverse();
    let mut out = String::with_capacity(total);
    for l in kept {
        out.push_str(l);
        out.push('\n');
    }
    Some(out)
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

    #[test]
    fn a_small_history_is_left_completely_alone() {
        let text = format!("{}\n{}\n", line("a"), line("b"));
        assert!(trimmed(&text, 1024).is_none(), "no trim is due");
        // Exactly at the ceiling is still not over it.
        assert!(trimmed(&text, text.len()).is_none());
    }

    #[test]
    fn trimming_keeps_the_newest_records_and_drops_the_oldest() {
        // 20 records, ceiling small enough to force a trim.
        let text: String = (0..20)
            .map(|i| format!("{}\n", line(&i.to_string())))
            .collect();
        let one = text.len() / 20;
        let kept = trimmed(&text, one * 10).expect("must trim");
        let names: Vec<String> = parse_recent(&kept, 100)
            .into_iter()
            .map(|r| r.name)
            .collect();
        // newest-first, so the highest indices survive and "0" is gone
        assert_eq!(names.first().map(String::as_str), Some("19"));
        assert!(!names.contains(&"0".to_string()), "oldest must be dropped");
        // Cut back to about half the ceiling, not to the ceiling itself, so the
        // next append does not immediately trigger another rewrite.
        assert!(kept.len() <= one * 5, "kept {} bytes", kept.len());
        assert!(!kept.is_empty());
    }

    #[test]
    fn the_trimmed_result_is_still_valid_jsonl() {
        let text: String = (0..30)
            .map(|i| format!("{}\n", line(&i.to_string())))
            .collect();
        let kept = trimmed(&text, text.len() / 3).expect("must trim");
        assert!(kept.ends_with('\n'), "must stay line-oriented");
        // Every retained line must parse — a trim that sliced mid-record would
        // silently corrupt the history.
        let n = kept.lines().count();
        assert_eq!(parse_recent(&kept, 1000).len(), n, "every line must parse");
    }

    #[test]
    fn blank_lines_do_not_survive_a_trim() {
        // The budget has to be small enough to force a trim yet large enough to
        // keep more than one record, which needs more than a handful of records to
        // arrange. Passing `10` here made `trimmed` keep nothing, so the assertion
        // below held trivially of an empty string and proved nothing.
        let one = line("x").len() + 1;
        let mut text = String::new();
        for i in 0..10 {
            text.push_str(&format!("{}\n", line(&i.to_string())));
            text.push('\n'); // a blank line after every record
        }
        let kept = trimmed(&text, one * 6).expect("must trim");
        assert!(!kept.is_empty(), "a real trim must keep something");
        assert!(kept.lines().count() >= 2, "budget fits several: {kept:?}");
        assert!(!kept.contains("\n\n"), "{kept:?}");
        // Every retained line is a whole record, not a fragment.
        assert_eq!(parse_recent(&kept, 100).len(), kept.lines().count());
    }

    #[test]
    fn a_trim_never_empties_the_history() {
        // Guard on the data-loss path: when not even the newest record fits the
        // budget, keeping nothing would wipe every link the user ever uploaded in
        // order to enforce a size limit. The newest record is kept regardless.
        let text = format!("{}\n{}\n", line("a"), line("b"));
        let kept = trimmed(&text, 4).expect("must trim");
        assert!(!kept.is_empty(), "must never write an empty history");
        let names: Vec<String> = parse_recent(&kept, 10)
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(names, ["b"], "and it must be the newest one");
    }

    #[test]
    fn trim_file_replaces_the_file_in_place_and_leaves_no_temp() {
        // Covers the file half: the rename-and-replace, and that the temp file
        // does not survive. A stray `history.jsonl.tmp` would be litter in the
        // user's data dir on every trim.
        let dir = std::env::temp_dir().join(format!("gitpic-trim-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("history.jsonl");
        let text: String = (0..40)
            .map(|i| format!("{}\n", line(&i.to_string())))
            .collect();
        std::fs::write(&path, &text).unwrap();

        trim_file(&path, text.len() / 4);

        let after = std::fs::read_to_string(&path).unwrap();
        assert!(after.len() < text.len(), "file must shrink");
        let names: Vec<String> = parse_recent(&after, 1000)
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(names.first().map(String::as_str), Some("39"), "newest kept");
        assert!(!names.contains(&"0".to_string()), "oldest dropped");
        // No temp file of any name may survive: a stray `history.jsonl.<pid>.tmp`
        // would be litter in the user's data dir on every trim. Checked by listing
        // rather than by one expected name, so the pid in it cannot hide a leak.
        let leftovers: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.ends_with(".tmp"))
            .collect();
        assert!(
            leftovers.is_empty(),
            "temp files must not survive: {leftovers:?}"
        );

        // A file already under the ceiling must be left byte-identical.
        std::fs::write(&path, &text).unwrap();
        trim_file(&path, text.len() * 10);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);

        std::fs::remove_dir_all(&dir).ok();
    }
}
