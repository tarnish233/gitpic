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
        crate::output::print_json(&env);
        return Ok(());
    }
    // `--quiet` is documented as "only print the resulting link/URL (script
    // friendly)", which is what the upload path already does with it. It used to
    // print the full human listing, and on an empty history even printed the "no
    // uploads recorded yet" prose — output a script would have to filter out.
    if mode.is_quiet() {
        for r in &recs {
            crate::output::line(&r.url);
        }
        return Ok(());
    }
    if recs.is_empty() {
        crate::output::line("no uploads recorded yet");
        return Ok(());
    }
    for r in &recs {
        let date = r.time.split('T').next().unwrap_or(&r.time);
        let date = date.if_supports_color(Stream::Stdout, |t| t.dimmed().to_string());
        let name = r
            .name
            .if_supports_color(Stream::Stdout, |t| t.bold().to_string());
        // Build the tag as a (possibly empty) suffix so there is one layout
        // string to keep correct instead of two.
        let tag = if r.deduped {
            " (deduped)"
                .if_supports_color(Stream::Stdout, |t| t.yellow().to_string())
                .to_string()
        } else {
            String::new()
        };
        crate::output::line(&format!("{date}  {name}{tag}"));
        crate::output::line(&format!("  {}", r.url));
    }
    Ok(())
}
