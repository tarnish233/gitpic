//! `gitpic list` — show recent uploads from local history.

use crate::error::Result;
use crate::history;
use crate::output::Mode;
use owo_colors::{OwoColorize, Stream};
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
        let date = date.if_supports_color(Stream::Stdout, |t| t.dimmed().to_string());
        let name = r
            .name
            .if_supports_color(Stream::Stdout, |t| t.bold().to_string());
        if r.deduped {
            let tag = " (dedup)".if_supports_color(Stream::Stdout, |t| t.yellow().to_string());
            println!("{date}  {name}{tag}");
        } else {
            println!("{date}  {name}");
        }
        println!("  {}", r.url);
    }
    Ok(())
}
