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

/// The prefixes an Apple Silicon and an Intel Homebrew use, plus `HOMEBREW_PREFIX` when it is
/// set. The first two are independent installations with independent Caskrooms, so both are
/// searched rather than one being derived from the other.
///
/// `HOMEBREW_PREFIX` matters much more here than it does to the app: `brew shellenv` exports it,
/// so a terminal that can run `brew` at a non-default prefix almost always has it, whereas a
/// Finder-launched bundle has never sourced anything.
fn default_prefixes() -> Vec<PathBuf> {
    let mut prefixes = vec![PathBuf::from("/opt/homebrew"), PathBuf::from("/usr/local")];
    if let Some(declared) = std::env::var_os("HOMEBREW_PREFIX") {
        let declared = PathBuf::from(declared);
        if declared.is_absolute() && !prefixes.contains(&declared) {
            prefixes.push(declared);
        }
    }
    prefixes
}

/// Where `cargo install` puts a binary for the user running this one: `CARGO_HOME` if set,
/// otherwise the platform's home directory plus `.cargo`.
///
/// Read at runtime and not baked in, because the question is where *this* file sits, and the
/// answer that matters is the one `cargo install --force` would write to now.
///
/// `USERPROFILE` as well as `HOME`, because this CLI ships for Windows and `HOME` is usually
/// unset there. Getting it wrong is not a crash — `cargo_root` returns `None`, nothing matches,
/// and the answer degrades to [`InstallSource::Unknown`] and the release page — but `Cargo` is
/// the one source of the five that means anything on Windows at all, the other four being
/// Homebrew and macOS bundles, so it is the one worth resolving there.
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
        Ok(exe) => classify(&exe, &default_prefixes(), cargo_root().as_deref()),
        Err(_) => InstallSource::Unknown,
    }
}

/// An anchor in the same spelling `exe` arrives in.
///
/// [`detect`] canonicalises the executable, so every comparison in [`classify`] is against a
/// *resolved* path — while the anchors are built straight out of the environment and are not.
/// Comparing the two spellings directly worked only while they happened to agree, and there are
/// two ways they do not:
///
/// - **Windows, unconditionally.** `std::fs::canonicalize` returns an extended-length
///   `\\?\C:\…` path there, so `exe.parent()` can never equal a `C:\Users\x\.cargo\bin` built
///   from `CARGO_HOME` — every ordinary `cargo install` was classified
///   [`InstallSource::Unknown`] and sent to the release page. Documented behaviour rather than
///   something measured here; there is no Windows in this checkout to measure on.
/// - **Any platform, when a root is reached through a symlink.** Canonicalising the executable
///   resolves the link while the raw anchor still names it. Measured, on Unix, by
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
/// `exe` is expected to be canonical — [`detect`] guarantees it. The order of the tests is not
/// arbitrary: an app bundle is checked first because a cask's bundle sits in an Applications
/// directory with no Cellar above it, while a Cellar path never contains a bundle, so only the
/// bundle case needs the Caskroom lookup to refine it.
///
/// **Both remaining tests are anchored to the exact directory an installer writes, and were
/// not.** They first asked whether `Cellar` or `.cargo` appeared *anywhere* in the canonicalised
/// path, which is true of `/Users/x/Cellar/gitpic` and of `~/backup/.cargo/bin/gitpic`. Anchoring
/// to the roots fixed those but was still one level too loose: `<prefix>/Cellar` matches any
/// formula's keg, and the whole of `CARGO_HOME` includes `registry/src` and `git/checkouts` —
/// one buildable source tree per dependency ever fetched. A `target/release/gitpic` built in one
/// of those was reported as a `cargo install`, and `cargo install --force` would have rewritten
/// `CARGO_HOME/bin/gitpic`, a different file from the one running. Every one of those prints a
/// command that does not upgrade the binary that printed it, which is the whole thing this module
/// exists to avoid. A path under no directory an installer actually writes is
/// [`InstallSource::Unknown`], which points at the page.
fn classify(exe: &Path, prefixes: &[PathBuf], cargo_root: Option<&Path>) -> InstallSource {
    if let Some(bundle) = app_bundle(exe) {
        return if cask_owns(bundle, prefixes) {
            InstallSource::CaskApp
        } else {
            InstallSource::App
        };
    }
    // `Cellar/gitpic_cli`, not `Cellar`: the question is whether *our* formula installed this
    // file, and `brew upgrade gitpic_cli` is only the answer if it did. A `gitpic` sitting under
    // some other formula's Cellar is not ours to upgrade.
    if prefixes
        .iter()
        .any(|prefix| exe.starts_with(resolved(prefix.join("Cellar").join(FORMULA))))
    {
        return InstallSource::Formula;
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
    ///
    /// **The bundle rows are scanned against a prefix that does not exist, and that is not
    /// laziness.** `cask_owns` touches the filesystem, so handing these rows the real Homebrew
    /// prefixes makes the answer depend on the machine: on a developer's Mac that has the cask
    /// installed, `/Applications/GitPic.app` is genuinely `CaskApp` and the row asserting `App`
    /// fails — measured, exactly that way round. Ownership is covered on a synthesized tree in
    /// `a_caskroom_link_is_what_makes_a_bundle_the_casks` instead. The non-bundle rows use the
    /// real prefixes freely, because `starts_with` is path arithmetic and reads no disk.
    #[test]
    fn paths_map_to_the_source_that_installed_them() {
        let unowned = vec![PathBuf::from("/nonexistent-prefix")];
        let brews = vec![PathBuf::from("/opt/homebrew"), PathBuf::from("/usr/local")];
        let cargo = PathBuf::from("/Users/x/.cargo");
        for path in [
            "/Applications/GitPic.app/Contents/Resources/gitpic",
            "/Users/x/Applications/GitPic.app/Contents/Resources/gitpic",
        ] {
            assert_eq!(
                classify(Path::new(path), &unowned, Some(&cargo)),
                InstallSource::App,
                "{path}"
            );
        }
        for (path, want) in [
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
            assert_eq!(
                classify(Path::new(path), &brews, Some(&cargo)),
                want,
                "{path}"
            );
        }
    }

    /// `Cellar` and `.cargo` are only meaningful at the exact directory an installer writes to,
    /// and looser matches said otherwise. Every row here names one of those words while
    /// belonging to a place no installer would replace, and each would otherwise be handed a
    /// command that upgrades some *other* file — or none.
    #[test]
    fn a_familiar_word_in_the_path_is_not_evidence_of_an_installer() {
        let brews = vec![PathBuf::from("/opt/homebrew")];
        let cargo = PathBuf::from("/Users/x/.cargo");
        for path in [
            // Not under any prefix's Cellar.
            "/Users/x/Cellar/gitpic",
            "/Users/x/Downloads/Cellar/gitpic_cli/0.20.9/bin/gitpic",
            // A different Homebrew's Cellar, which this machine cannot upgrade from.
            "/usr/local/Cellar/gitpic_cli/0.20.9/bin/gitpic",
            // Under *a* Cellar, but not our formula's — `brew upgrade gitpic_cli` is not the
            // command that put this here.
            "/opt/homebrew/Cellar/some-other-tool/1.0.0/bin/gitpic",
            // Copied out of a backup: `cargo install --force` would replace a *different* file.
            "/Users/x/backup/.cargo/bin/gitpic",
            "/Users/y/.cargo/bin/gitpic",
            // Built inside CARGO_HOME, which holds one source tree per dependency ever fetched.
            // `cargo install --force` writes `.cargo/bin/gitpic`, not this.
            "/Users/x/.cargo/registry/src/index.crates.io-1949cf8/gitpic-0.20.9/target/release/gitpic",
            "/Users/x/.cargo/git/checkouts/gitpic-abc123/9f8e7d6/target/release/gitpic",
        ] {
            assert_eq!(
                classify(Path::new(path), &brews, Some(&cargo)),
                InstallSource::Unknown,
                "{path}"
            );
        }
    }

    /// **The anchors have to be compared in the same spelling as `exe`, and they were not.**
    ///
    /// [`detect`] canonicalises `exe` and then hands [`classify`] anchors built straight out of
    /// the environment, so every comparison here assumes the two spellings agree. They do not
    /// always agree, and where they diverge the answer is [`InstallSource::Unknown`] and the
    /// release page instead of the command that would actually work.
    ///
    /// This row measures the case that can be measured on a Unix box: a `CARGO_HOME` or a
    /// Homebrew prefix reached through a symlink, where canonicalising the executable resolves
    /// the link and the raw anchor still names it. The motivating case is Windows, where it is
    /// unconditional rather than a configuration — `std::fs::canonicalize` returns an
    /// extended-length `\\?\C:\…` path there, so `exe.parent()` could never equal a
    /// `C:\Users\x\.cargo\bin` built from the environment, and every ordinary
    /// `cargo install` on Windows was classified `Unknown`. Not measured here — there is no
    /// Windows to measure on — but it is the same comparison this row exercises.
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
            classify(&exe, &[], Some(&cargo_link)),
            InstallSource::Cargo,
            "a cargo bin reached through a symlinked CARGO_HOME is still a cargo install"
        );

        // The same for a Homebrew prefix behind a link.
        let brew_real = root.join("real/brew");
        let keg = brew_real.join("Cellar/gitpic_cli/0.20.9/bin");
        std::fs::create_dir_all(&keg).unwrap();
        std::fs::write(keg.join("gitpic"), "").unwrap();
        let brew_link = root.join("brew-link");
        std::os::unix::fs::symlink(&brew_real, &brew_link).unwrap();
        let exe = brew_link
            .join("Cellar/gitpic_cli/0.20.9/bin/gitpic")
            .canonicalize()
            .unwrap();
        assert_eq!(
            classify(&exe, std::slice::from_ref(&brew_link), None),
            InstallSource::Formula,
            "a keg under a symlinked HOMEBREW_PREFIX is still the formula's"
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
    /// how `cargo_root` and `default_prefixes` hand their values over — straight from the
    /// environment, unresolved.
    #[test]
    fn an_anchor_from_the_environment_need_not_be_spelled_canonically() {
        let root = std::env::temp_dir().join(format!("gitpic-spelling-{}", std::process::id()));
        std::fs::remove_dir_all(&root).ok();
        let cargo = root.join("cargo");
        let cargo_bin = cargo.join("bin");
        std::fs::create_dir_all(&cargo_bin).unwrap();
        std::fs::write(cargo_bin.join("gitpic"), "").unwrap();

        // What `detect` hands over: a canonical exe, and an anchor exactly as the environment
        // spelled it.
        let exe = cargo_bin.join("gitpic").canonicalize().unwrap();
        assert_eq!(
            classify(&exe, &[], Some(&cargo)),
            InstallSource::Cargo,
            "exe {} vs anchor {}",
            exe.display(),
            cargo.display()
        );

        let prefix = root.join("brew");
        // Joined a component at a time: this test runs on the Windows runner too, and that is
        // the platform it exists for.
        let keg = prefix
            .join("Cellar")
            .join(FORMULA)
            .join("0.20.9")
            .join("bin");
        std::fs::create_dir_all(&keg).unwrap();
        std::fs::write(keg.join("gitpic"), "").unwrap();
        let exe = keg.join("gitpic").canonicalize().unwrap();
        assert_eq!(
            classify(&exe, std::slice::from_ref(&prefix), None),
            InstallSource::Formula,
            "exe {} vs prefix {}",
            exe.display(),
            prefix.display()
        );

        std::fs::remove_dir_all(&root).ok();
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
                classify(Path::new(path), &none, None),
                InstallSource::App,
                "{path}"
            );
        }
    }

    /// The distinction the hint turns on, built as the real two-part shape: a bundle, and a
    /// `Caskroom/gitpic/<version>/GitPic.app` symlink resolving to it. Without the link the
    /// same bundle is `App`, and printing a cask command for it would fail with
    /// "Cask 'gitpic' is not installed".
    ///
    /// **Unix only, because it creates symlinks.** `std::os::unix::fs::symlink` does not exist
    /// on Windows, so this did not compile there at all — and the CLI is built and tested for
    /// Windows, which is where CI caught it. Gating rather than porting to
    /// `std::os::windows::fs::symlink_dir`: the subject is a macOS cask installing a macOS app
    /// bundle, so there is nothing for the Windows build to learn from it. Everything above is
    /// pure path arithmetic and stays covered on every platform.
    #[cfg(unix)]
    #[test]
    fn a_caskroom_link_is_what_makes_a_bundle_the_casks() {
        let root = std::env::temp_dir().join(format!("gitpic-src-{}", std::process::id()));
        // Cleared going in as well as coming out: the name reuses the pid, and the cleanup at
        // the end is skipped when an assertion panics, so a failed run would otherwise leave a
        // tree that makes the *next* run fail somewhere unrelated.
        std::fs::remove_dir_all(&root).ok();
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
        assert_eq!(classify(&exe, &prefixes, None), InstallSource::App);

        std::os::unix::fs::symlink(&bundle, caskroom.join("GitPic.app")).unwrap();
        assert_eq!(classify(&exe, &prefixes, None), InstallSource::CaskApp);

        // A link that points somewhere else is not evidence about this bundle.
        std::fs::remove_file(caskroom.join("GitPic.app")).unwrap();
        let other = root.join("Applications/Other.app");
        std::fs::create_dir_all(&other).unwrap();
        std::os::unix::fs::symlink(&other, caskroom.join("GitPic.app")).unwrap();
        assert_eq!(classify(&exe, &prefixes, None), InstallSource::App);

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
