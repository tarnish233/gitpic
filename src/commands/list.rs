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
            crate::output::untrusted_line(&r.url);
        }
        return Ok(());
    }
    if recs.is_empty() {
        crate::output::line("no uploads recorded yet");
        return Ok(());
    }
    for r in &recs {
        let date = r.time.split('T').next().unwrap_or(&r.time);
        let safe_date = crate::output::terminal_safe(date);
        let safe_date_ref = safe_date.as_ref();
        let date = safe_date_ref.if_supports_color(Stream::Stdout, |t| t.dimmed().to_string());
        let safe_name = crate::output::terminal_safe(&r.name);
        let safe_name_ref = safe_name.as_ref();
        let name = safe_name_ref.if_supports_color(Stream::Stdout, |t| t.bold().to_string());
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
        crate::output::line(&format!("  {}", crate::output::terminal_safe(&r.url)));
    }
    Ok(())
}
