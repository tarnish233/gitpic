//! `gitpic list` — show recent uploads from local history.

use crate::error::Result;
use crate::history;
use crate::output::Mode;
use owo_colors::OwoColorize;
use serde::Serialize;

#[derive(Serialize)]
struct ListEnvelope<'a> {
    ok: bool,
    results: &'a [history::Record],
}

pub fn run(limit: usize, mode: Mode) -> Result<()> {
    let recs = history::read_recent(limit)?;
    if mode.is_json() {
        let env = ListEnvelope {
            ok: true,
            results: &recs,
        };
        println!("{}", serde_json::to_string_pretty(&env).unwrap_or_default());
        return Ok(());
    }
    if recs.is_empty() {
        println!("no uploads recorded yet");
        return Ok(());
    }
    for r in &recs {
        let date = r.time.split('T').next().unwrap_or(&r.time);
        let tag = if r.deduped {
            " (dedup)".yellow().to_string()
        } else {
            String::new()
        };
        println!("{}  {}{}", date.dimmed(), r.name.bold(), tag);
        println!("  {}", r.url);
    }
    Ok(())
}
