//! Where this `gitpic` came from, and therefore which one upgrade command to print.
//!
//! `gitpic update` reports and never installs, because a `gitpic` on `PATH` can have arrived
//! four different ways that want four different commands. It used to print two of them and
//! leave the reader to pick — including the reader for whom neither was right. This module
//! picks.
//!
//! **`current_exe()` on its own is not enough, and the way it fails is silent.** The cask
//! links `HOMEBREW_PREFIX/bin/gitpic` at the copy inside the app bundle, so the commonest
//! install of all is invoked *through a symlink*. On Apple platforms `current_exe()` is
//! `_NSGetExecutablePath` with no canonicalisation, and that returns the link rather than its
//! target — measured on macOS 26.6 against a binary invoked through a same-directory symlink,
//! which reported the symlink's own path and not the target's. `std::env::current_exe`'s own
//! documentation declines to promise either behaviour ("some platforms will return the path of
//! the symbolic link and other platforms will return the path of the symbolic link's target"),
//! so the answer is not to depend on which one you get: [`detect`] canonicalises.
//!
//! Without that step `/opt/homebrew/bin/gitpic` is neither inside a bundle nor under a Cellar,
//! and both answers it could fall to are wrong ones — [`InstallSource::Unknown`], which prints
//! the same unhelpful thing as before and buys nothing, or [`InstallSource::Formula`], which
//! prints `brew upgrade gitpic_cli` and fails with "no available formula". That second one is
//! the exact mistake the old two-command note existed to avoid.
//!
//! std's Security section warns against trusting `current_exe()` where it matters. What it
//! decides here is which sentence to print. Nothing is executed from it and no privilege turns
//! on it.
//!
//! **Why a cask check lives here as well as in the app.** `GitPicCore`'s `CaskOwnership` asks
//! "is *my bundle* cask-managed" so the update sheet knows whether to hand the user a command;
//! this asks "where did *this binary* come from" so the terminal prints the right one. They
//! are different questions with different answers — a hand-installed `GitPic.app` and a
//! cask-installed one are the same bundle shape and want different commands — and the shared
//! sub-question, whether a Caskroom entry points at a given bundle, is twenty lines in each
//! language. Sharing it would cost a subprocess on the app's sheet-open path, which is the
//! cost `bb07783` was written to delete.

use std::path::{Path, PathBuf};

/// One spelling of each, shared with the tap lookup that echoes the cask token back to the
/// app — see [`crate::release::CASK`].
use crate::release::{CASK, FORMULA};

/// The two prefixes an Apple Silicon and an Intel Homebrew use. Independent installations with
/// independent Caskrooms, so both are searched rather than one being derived from the other.
fn default_prefixes() -> Vec<PathBuf> {
    vec![PathBuf::from("/opt/homebrew"), PathBuf::from("/usr/local")]
}

/// How this copy of `gitpic` was installed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallSource {
    /// Inside a `GitPic.app` that a Homebrew cask owns. The cask links its `bin/gitpic` into
    /// the bundle, so upgrading the app upgrades this command — which is why the command to
    /// print is the cask's and not something aimed at the CLI.
    CaskApp,
    /// Inside a `GitPic.app` that Homebrew does not manage: a DMG someone installed by hand.
    /// The app updates itself, and this command comes along with it.
    App,
    /// Homebrew's `gitpic_cli` formula — a real file under a Cellar, no app involved.
    Formula,
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
            Self::CaskApp => format!("upgrade with `brew upgrade --cask {CASK}`"),
            Self::App => {
                "this command ships inside GitPic.app — update the app and it comes with it"
                    .to_string()
            }
            Self::Formula => format!("upgrade with `brew upgrade {FORMULA}`"),
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
        Ok(exe) => classify(&exe, &default_prefixes()),
        Err(_) => InstallSource::Unknown,
    }
}

/// The pure half, so the table can be tested without installing anything.
///
/// `exe` is expected to be canonical — [`detect`] guarantees it. The order of the tests is not
/// arbitrary: an app bundle is checked first because a cask's bundle sits in an Applications
/// directory with no Cellar above it, while a Cellar path never contains a bundle, so only the
/// bundle case needs the Caskroom lookup to refine it.
fn classify(exe: &Path, prefixes: &[PathBuf]) -> InstallSource {
    if let Some(bundle) = app_bundle(exe) {
        return if cask_owns(bundle, prefixes) {
            InstallSource::CaskApp
        } else {
            InstallSource::App
        };
    }
    let components: Vec<_> = exe.components().map(|c| c.as_os_str()).collect();
    if components.iter().any(|c| *c == "Cellar") {
        return InstallSource::Formula;
    }
    // `CARGO_HOME` can move this, in which case the answer is `Unknown` and the page gets
    // printed. Reading the variable would be guessing about the environment of whoever built
    // the binary, not the one running it.
    if components.iter().any(|c| *c == ".cargo") {
        return InstallSource::Cargo;
    }
    InstallSource::Unknown
}

/// The innermost `.app` ancestor of `exe`, which for this layout is the bundle root:
/// `…/GitPic.app/Contents/Resources/gitpic` has exactly one.
fn app_bundle(exe: &Path) -> Option<&Path> {
    exe.ancestors()
        .find(|p| p.extension().is_some_and(|e| e == "app"))
}

/// Whether any `Caskroom/gitpic/*/GitPic.app` under `prefixes` resolves to `bundle`.
///
/// This is the reverse of the test Claude Code can use on itself. Its binary really lives in
/// the Caskroom, so `execPath()` contains `/Caskroom/`; GitPic's cask uses an `app` stanza,
/// which *moves* the bundle to an Applications directory and leaves a symlink pointing back at
/// it. So the evidence is a link that resolves to us, and the check works at any `--appdir`
/// because the link follows wherever the bundle went.
fn cask_owns(bundle: &Path, prefixes: &[PathBuf]) -> bool {
    prefixes.iter().any(|prefix| {
        let versions = prefix.join("Caskroom").join(CASK);
        let Ok(entries) = std::fs::read_dir(&versions) else {
            return false;
        };
        entries.flatten().any(|entry| {
            entry
                .path()
                .join("GitPic.app")
                .canonicalize()
                .is_ok_and(|target| target == bundle)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The case the un-canonicalised version gets wrong, stated as a path table. Each row is a
    /// real shape: the cask's symlink target, the formula's Cellar file, a cargo bin, a build
    /// directory.
    #[test]
    fn paths_map_to_the_source_that_installed_them() {
        // No Caskroom in these prefixes, so a bundle is a hand-installed one.
        let none = vec![PathBuf::from("/nonexistent-prefix")];
        for (path, want) in [
            (
                "/Applications/GitPic.app/Contents/Resources/gitpic",
                InstallSource::App,
            ),
            (
                "/opt/homebrew/Cellar/gitpic_cli/0.20.9/bin/gitpic",
                InstallSource::Formula,
            ),
            (
                "/usr/local/Cellar/gitpic_cli/0.20.9/bin/gitpic",
                InstallSource::Formula,
            ),
            ("/Users/x/.cargo/bin/gitpic", InstallSource::Cargo),
            (
                "/Users/x/src/gitpic/target/release/gitpic",
                InstallSource::Unknown,
            ),
            ("/usr/local/bin/gitpic", InstallSource::Unknown),
        ] {
            assert_eq!(classify(Path::new(path), &none), want, "{path}");
        }
    }

    /// A bundle in a user's own Applications directory, or at a custom `--appdir`, is still a
    /// bundle. The cask supports both and the app's own installer accepts both.
    #[test]
    fn a_bundle_is_a_bundle_wherever_it_was_installed() {
        let none = vec![PathBuf::from("/nonexistent-prefix")];
        for path in [
            "/Users/x/Applications/GitPic.app/Contents/Resources/gitpic",
            "/Users/x/Apps/GitPic.app/Contents/Resources/gitpic",
        ] {
            assert_eq!(
                classify(Path::new(path), &none),
                InstallSource::App,
                "{path}"
            );
        }
    }

    /// The distinction the hint turns on, built as the real two-part shape: a bundle, and a
    /// `Caskroom/gitpic/<version>/GitPic.app` symlink resolving to it. Without the link the
    /// same bundle is `App`, and printing a cask command for it would fail with
    /// "Cask 'gitpic' is not installed".
    #[test]
    fn a_caskroom_link_is_what_makes_a_bundle_the_casks() {
        let root = std::env::temp_dir().join(format!("gitpic-src-{}", std::process::id()));
        let bundle = root.join("Applications/GitPic.app");
        let exe = bundle.join("Contents/Resources/gitpic");
        let caskroom = root.join("prefix/Caskroom/gitpic/0.20.9");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::create_dir_all(&caskroom).unwrap();
        std::fs::write(&exe, "").unwrap();
        let prefixes = vec![root.join("prefix")];

        // `classify` needs a canonical path, which is what `detect` hands it.
        let exe = exe.canonicalize().unwrap();
        let bundle = bundle.canonicalize().unwrap();
        assert_eq!(classify(&exe, &prefixes), InstallSource::App);

        std::os::unix::fs::symlink(&bundle, caskroom.join("GitPic.app")).unwrap();
        assert_eq!(classify(&exe, &prefixes), InstallSource::CaskApp);

        // A link that points somewhere else is not evidence about this bundle.
        std::fs::remove_file(caskroom.join("GitPic.app")).unwrap();
        let other = root.join("Applications/Other.app");
        std::fs::create_dir_all(&other).unwrap();
        std::os::unix::fs::symlink(&other, caskroom.join("GitPic.app")).unwrap();
        assert_eq!(classify(&exe, &prefixes), InstallSource::App);

        std::fs::remove_dir_all(&root).ok();
    }

    /// Every source names something the reader can act on, and only the ones that have a
    /// command name one. `Unknown` pointing at a command would be inventing it.
    #[test]
    fn every_hint_is_actionable_and_only_some_are_commands() {
        for source in [
            InstallSource::CaskApp,
            InstallSource::App,
            InstallSource::Formula,
            InstallSource::Cargo,
            InstallSource::Unknown,
        ] {
            let hint = source.upgrade_hint();
            assert!(!hint.is_empty(), "{source:?}");
            assert!(!hint.contains("  "), "{source:?} is doubly spaced");
        }
        assert!(InstallSource::CaskApp
            .upgrade_hint()
            .contains("--cask gitpic"));
        assert!(InstallSource::Formula.upgrade_hint().contains("gitpic_cli"));
        // Not on crates.io, so the bare spelling would fail: the hint has to carry `--git`.
        assert!(InstallSource::Cargo.upgrade_hint().contains("--git"));
        assert!(!InstallSource::Unknown.upgrade_hint().contains('`'));
        assert!(!InstallSource::App.upgrade_hint().contains("brew"));
    }
}
