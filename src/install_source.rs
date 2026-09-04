//! Where this `gitpic` came from, and therefore which one upgrade command to print.
//!
//! `gitpic update` reports and never installs, because a `gitpic` on `PATH` can have arrived
//! more than one way and each way wants a different sentence. It used to print two commands and
//! leave the reader to pick — including the reader for whom neither was right. This module picks.
//!
//! **`current_exe()` on its own is not enough, and the way it fails is silent.** The app's
//! *install the command-line tool* button links `~/.local/bin/gitpic` at the copy inside the app
//! bundle, so the commonest install of all is invoked *through a symlink*. On Apple platforms
//! `current_exe()` is `_NSGetExecutablePath` with no canonicalisation, and that returns the link
//! rather than its target — measured on macOS 26.6 against a binary invoked through a
//! same-directory symlink, which reported the symlink's own path and not the target's.
//! `std::env::current_exe`'s own documentation declines to promise either behaviour ("some
//! platforms will return the path of the symbolic link and other platforms will return the path
//! of the symbolic link's target"), so the answer is not to depend on which one you get:
//! [`detect`] canonicalises.
//!
//! Without that step `~/.local/bin/gitpic` is inside neither a bundle nor a `CARGO_HOME`, so it
//! falls to [`InstallSource::Unknown`] and prints the release page — for the one install that
//! needs no action whatsoever, because it updates itself every time the app does. Covered by the
//! `~/.local/bin` row in `paths_map_to_the_source_that_installed_them`, which states the wrong
//! answer `classify` gives on its own.
//!
//! std's Security section warns against trusting `current_exe()` where it matters. What it
//! decides here is which sentence to print. Nothing is executed from it and no privilege turns
//! on it.

use std::path::{Path, PathBuf};

/// Where `cargo install` puts a binary for the user running this one: `CARGO_HOME` if set,
/// otherwise the platform's home directory plus `.cargo`.
///
/// Read at runtime and not baked in, because the question is where *this* file sits, and the
/// answer that matters is the one `cargo install --force` would write to now.
///
/// `USERPROFILE` as well as `HOME`, because this CLI ships for Windows and `HOME` is usually
/// unset there. Getting it wrong is not a crash — `cargo_root` returns `None`, nothing matches,
/// and the answer degrades to [`InstallSource::Unknown`] and the release page — but `Cargo` is
/// the one source of the three that means anything on Windows at all, the other two being a
/// macOS app bundle and the fallback, so it is the one worth resolving there.
fn cargo_root() -> Option<PathBuf> {
    if let Some(home) = std::env::var_os("CARGO_HOME") {
        let home = PathBuf::from(home);
        if home.is_absolute() {
            return Some(home);
        }
    }
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(|h| PathBuf::from(h).join(".cargo"))
}

/// How this copy of `gitpic` was installed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallSource {
    /// Inside a `GitPic.app`. The app updates itself and this command comes along with it —
    /// including when it is reached through `~/.local/bin/gitpic`, which the app links *into*
    /// the bundle rather than copying beside it, precisely so that it never goes stale.
    App,
    /// Built by `cargo install`. Not on crates.io, so the only spelling that works is the
    /// `--git` one; a bare `cargo install gitpic` fails with "does not exist".
    Cargo,
    /// An unpacked tarball, a `cargo build` target directory, or anywhere else. This is what
    /// this repository's own working copy reports, and it is the honest answer rather than a
    /// guess: nothing about the path says how it got there.
    Unknown,
}

impl InstallSource {
    /// The one line `gitpic update` prints under the release URL.
    ///
    /// [`InstallSource::Unknown`] deliberately points at the page rather than naming a
    /// command: there is no command that is right for an arbitrary path, and inventing one is
    /// how the reader ends up running something that fails.
    pub fn upgrade_hint(self) -> String {
        match self {
            Self::App => {
                "this command ships inside GitPic.app — update the app and it comes with it"
                    .to_string()
            }
            Self::Cargo => format!(
                "upgrade with `cargo install --force --git {} gitpic`",
                env!("CARGO_PKG_REPOSITORY")
            ),
            Self::Unknown => "download the new build from the page above".to_string(),
        }
    }
}

/// Classify the running binary, canonicalising first. Falls back to
/// [`InstallSource::Unknown`] rather than guessing when the path cannot be resolved at all.
pub fn detect() -> InstallSource {
    match std::env::current_exe().and_then(|p| p.canonicalize()) {
        Ok(exe) => classify(&exe, cargo_root().as_deref()),
        Err(_) => InstallSource::Unknown,
    }
}

/// An anchor in the same spelling `exe` arrives in.
///
/// [`detect`] canonicalises the executable, so every comparison in [`classify`] is against a
/// *resolved* path — while the anchor is built straight out of the environment and is not.
/// Comparing the two spellings directly worked only while they happened to agree, and there are
/// two ways they do not:
///
/// - **Windows, unconditionally.** `std::fs::canonicalize` returns an extended-length
///   `\\?\C:\…` path there, so `exe.parent()` can never equal a `C:\Users\x\.cargo\bin` built
///   from `CARGO_HOME` — every ordinary `cargo install` was classified
///   [`InstallSource::Unknown`] and sent to the release page. Documented behaviour rather than
///   something measured here; there is no Windows in this checkout to measure on.
/// - **Any platform, when `CARGO_HOME` is reached through a symlink.** Canonicalising the
///   executable resolves the link while the raw anchor still names it. Measured, on Unix, by
///   `anchors_are_compared_in_the_same_spelling_as_the_exe`.
///
/// Falls back to the path as given when it cannot be resolved, which is the right answer rather
/// than a compromise: an anchor that does not exist cannot have `exe` underneath it, so the
/// comparison should fail — and it does, on the raw spelling, exactly as before. That fallback
/// is also what lets [`classify`]'s table be written against synthesized paths.
fn resolved(path: PathBuf) -> PathBuf {
    path.canonicalize().unwrap_or(path)
}

/// The pure half, so the table can be tested without installing anything.
///
/// `exe` is expected to be canonical — [`detect`] guarantees it. Neither test reads the disk
/// except to resolve the one anchor, so the whole table below can name paths that do not exist.
///
/// **The `.cargo` test is anchored to the exact directory an installer writes, and was not.** It
/// first asked whether `.cargo` appeared *anywhere* in the canonicalised path, which is true of
/// `~/backup/.cargo/bin/gitpic`. Anchoring to the root fixed that but was still one level too
/// loose: the whole of `CARGO_HOME` includes `registry/src` and `git/checkouts` — one buildable
/// source tree per dependency ever fetched. A `target/release/gitpic` built in one of those was
/// reported as a `cargo install`, and `cargo install --force` would have rewritten
/// `CARGO_HOME/bin/gitpic`, a different file from the one running. That prints a command which
/// does not upgrade the binary that printed it, the whole thing this module exists to avoid. A
/// path under no directory an installer actually writes is [`InstallSource::Unknown`], which
/// points at the page.
fn classify(exe: &Path, cargo_root: Option<&Path>) -> InstallSource {
    if in_app_bundle(exe) {
        return InstallSource::App;
    }
    // The `bin` directory itself, not the whole of `CARGO_HOME`. `cargo install` writes exactly
    // one place, and `CARGO_HOME` also holds sources that can be *built* — `registry/src` alone
    // has one unpacked tree per dependency ever fetched, and `git/checkouts` holds clones. A
    // `target/release/gitpic` inside one of those is not something `cargo install --force`
    // replaces: that would rewrite `CARGO_HOME/bin/gitpic`, a different file from the one
    // running. Comparing the parent directory also means the executable's name is not spelled
    // here, so Windows' `gitpic.exe` needs no separate case.
    if cargo_root.is_some_and(|root| exe.parent() == Some(resolved(root.join("bin")).as_path())) {
        return InstallSource::Cargo;
    }
    InstallSource::Unknown
}

/// Whether `exe` sits inside a `.app` bundle.
///
/// Only the fact is needed, not which bundle: every bundle gets the same sentence, and the one
/// caller that wanted the path back — a Caskroom lookup asking whether Homebrew owned it — went
/// with Homebrew support.
fn in_app_bundle(exe: &Path) -> bool {
    exe.ancestors()
        .any(|p| p.extension().is_some_and(|e| e == "app"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The case the un-canonicalised version gets wrong, stated as a path table. Each row is a
    /// real shape: the bundle, the link that points into it, a cargo bin, a build directory.
    ///
    /// **Nothing here touches the filesystem.** Both of `classify`'s branches are path
    /// arithmetic, so these rows may name paths that do not exist and the answer cannot depend
    /// on what the machine running the test happens to have installed. It used to depend on
    /// exactly that, and the bundle rows had to be aimed at a deliberately absent Homebrew
    /// prefix to keep a developer's own cask from making `App` come out as the cask's.
    #[test]
    fn paths_map_to_the_source_that_installed_them() {
        let cargo = PathBuf::from("/Users/x/.cargo");
        for (path, want) in [
            (
                "/Applications/GitPic.app/Contents/Resources/gitpic",
                InstallSource::App,
            ),
            (
                "/Users/x/Applications/GitPic.app/Contents/Resources/gitpic",
                InstallSource::App,
            ),
            ("/Users/x/.cargo/bin/gitpic", InstallSource::Cargo),
            (
                "/Users/x/src/gitpic/target/release/gitpic",
                InstallSource::Unknown,
            ),
            ("/usr/local/bin/gitpic", InstallSource::Unknown),
            // The command-line link *as written*, which is the answer this module exists to
            // avoid printing: `~/.local/bin/gitpic` points into the bundle, so the honest source
            // is `App`, and `classify` alone cannot see that. Only `detect`'s canonicalisation
            // turns this path into the bundle path two rows up — this row is what makes the
            // header's claim about it a measured one rather than an assertion.
            ("/Users/x/.local/bin/gitpic", InstallSource::Unknown),
        ] {
            assert_eq!(classify(Path::new(path), Some(&cargo)), want, "{path}");
        }
    }

    /// `.cargo` is only meaningful at the exact directory an installer writes to, and looser
    /// matches said otherwise. Every row here names the word while belonging to a place no
    /// installer would replace, and each would otherwise be handed a command that upgrades some
    /// *other* file.
    #[test]
    fn a_familiar_word_in_the_path_is_not_evidence_of_an_installer() {
        let cargo = PathBuf::from("/Users/x/.cargo");
        for path in [
            // Copied out of a backup: `cargo install --force` would replace a *different* file.
            "/Users/x/backup/.cargo/bin/gitpic",
            "/Users/y/.cargo/bin/gitpic",
            // Built inside CARGO_HOME, which holds one source tree per dependency ever fetched.
            // `cargo install --force` writes `.cargo/bin/gitpic`, not this.
            "/Users/x/.cargo/registry/src/index.crates.io-1949cf8/gitpic-0.20.9/target/release/gitpic",
            "/Users/x/.cargo/git/checkouts/gitpic-abc123/9f8e7d6/target/release/gitpic",
        ] {
            assert_eq!(
                classify(Path::new(path), Some(&cargo)),
                InstallSource::Unknown,
                "{path}"
            );
        }
    }

    /// **The anchor has to be compared in the same spelling as `exe`, and it was not.**
    ///
    /// [`detect`] canonicalises `exe` and then hands [`classify`] an anchor built straight out of
    /// the environment, so the comparison there assumes the two spellings agree. They do not
    /// always agree, and where they diverge the answer is [`InstallSource::Unknown`] and the
    /// release page instead of the command that would actually work.
    ///
    /// This row measures the case that can be measured on a Unix box: a `CARGO_HOME` reached
    /// through a symlink, where canonicalising the executable resolves the link and the raw
    /// anchor still names it. The motivating case is Windows, where it is unconditional rather
    /// than a configuration — `std::fs::canonicalize` returns an extended-length `\\?\C:\…` path
    /// there, so `exe.parent()` could never equal a `C:\Users\x\.cargo\bin` built from the
    /// environment, and every ordinary `cargo install` on Windows was classified `Unknown`. Not
    /// measured here — there is no Windows to measure on — but it is the same comparison this
    /// row exercises.
    #[cfg(unix)]
    #[test]
    fn anchors_are_compared_in_the_same_spelling_as_the_exe() {
        let root = std::env::temp_dir().join(format!("gitpic-anchor-{}", std::process::id()));
        std::fs::remove_dir_all(&root).ok();
        std::fs::create_dir_all(&root).unwrap();

        // `CARGO_HOME=<root>/cargo-link`, with the real tree at `<root>/real/cargo`.
        let cargo_real = root.join("real/cargo");
        std::fs::create_dir_all(cargo_real.join("bin")).unwrap();
        std::fs::write(cargo_real.join("bin/gitpic"), "").unwrap();
        let cargo_link = root.join("cargo-link");
        std::os::unix::fs::symlink(&cargo_real, &cargo_link).unwrap();
        let exe = cargo_link.join("bin/gitpic").canonicalize().unwrap();
        assert_eq!(
            classify(&exe, Some(&cargo_link)),
            InstallSource::Cargo,
            "a cargo bin reached through a symlinked CARGO_HOME is still a cargo install"
        );

        std::fs::remove_dir_all(&root).ok();
    }

    /// The same property, on **every** platform including the one it matters most for.
    ///
    /// The symlink row above is `cfg(unix)`, so it never ran on the Windows runner — where the
    /// divergence is unconditional and the whole `Cargo` case was broken. This needs no symlink
    /// and no `cfg`, because `std::env::temp_dir()` is already spelled non-canonically on two of
    /// the three platforms CI builds: measured, macOS returns `/var/folders/…` which canonicalises
    /// to `/private/var/folders/…`, and Windows canonicalises to an extended-length `\\?\C:\…`
    /// while the environment gives a plain `C:\…`. On Linux `/tmp` is usually already canonical,
    /// so there it asserts the ordinary case still holds.
    ///
    /// Using `temp_dir()` *as the anchor without canonicalising it* is the point: that is exactly
    /// how `cargo_root` hands its value over — straight from the environment, unresolved.
    #[test]
    fn an_anchor_from_the_environment_need_not_be_spelled_canonically() {
        let root = std::env::temp_dir().join(format!("gitpic-spelling-{}", std::process::id()));
        std::fs::remove_dir_all(&root).ok();
        let cargo = root.join("cargo");
        // Joined a component at a time: this test runs on the Windows runner too, and that is
        // the platform it exists for.
        let cargo_bin = cargo.join("bin");
        std::fs::create_dir_all(&cargo_bin).unwrap();
        std::fs::write(cargo_bin.join("gitpic"), "").unwrap();

        // What `detect` hands over: a canonical exe, and an anchor exactly as the environment
        // spelled it.
        let exe = cargo_bin.join("gitpic").canonicalize().unwrap();
        assert_eq!(
            classify(&exe, Some(&cargo)),
            InstallSource::Cargo,
            "exe {} vs anchor {}",
            exe.display(),
            cargo.display()
        );

        std::fs::remove_dir_all(&root).ok();
    }

    /// A bundle in a user's own Applications directory, or at a custom install location, is
    /// still a bundle. The app's own installer accepts both.
    #[test]
    fn a_bundle_is_a_bundle_wherever_it_was_installed() {
        for path in [
            "/Users/x/Applications/GitPic.app/Contents/Resources/gitpic",
            "/Users/x/Apps/GitPic.app/Contents/Resources/gitpic",
        ] {
            assert_eq!(
                classify(Path::new(path), None),
                InstallSource::App,
                "{path}"
            );
        }
    }

    /// Every source names something the reader can act on, and only the ones that have a
    /// command name one. `Unknown` pointing at a command would be inventing it.
    #[test]
    fn every_hint_is_actionable_and_only_some_are_commands() {
        for source in [
            InstallSource::App,
            InstallSource::Cargo,
            InstallSource::Unknown,
        ] {
            let hint = source.upgrade_hint();
            assert!(!hint.is_empty(), "{source:?}");
            assert!(!hint.contains("  "), "{source:?} is doubly spaced");
            // Homebrew is retired, so no source has a `brew` command any more — and two of them
            // used to. Asserted over the whole set rather than the two that changed, because
            // what has to stay true is that *none* of them reaches for brew again.
            assert!(!hint.contains("brew"), "{source:?} names brew");
        }
        // Not on crates.io, so the bare spelling would fail: the hint has to carry `--git`.
        assert!(InstallSource::Cargo.upgrade_hint().contains("--git"));
        assert!(!InstallSource::Unknown.upgrade_hint().contains('`'));
    }
}
