#!/usr/bin/env bash
# Give one agent its own worktree: one agent, one directory, one branch.
#
# `git checkout` is per-*directory* state. Several agents sharing one checkout
# means any one of them switching branches changes the files under all the others,
# and a `git commit -a` sweeps in whatever the rest had in flight. A worktree gives
# each agent its own HEAD and index over the same object store — and git refuses to
# check out one branch in two worktrees, so the mutual exclusion is enforced rather
# than merely agreed between agents.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
usage: scripts/new-worktree.sh <branch> [dir] [--base <ref>] [--seed-config]

  <branch>        Branch to work on. Reused if it already exists locally or on
                  origin; otherwise created from --base.
  [dir]           Where to put it. Default: ../gitpic-<branch-slug>, a sibling of
                  the primary checkout. Outside the repo on purpose — a worktree
                  nested inside it shows up as untracked files in every other
                  checkout, one `git add -A` away from being committed.

  --base <ref>    Base for a new branch. Default: origin/main, falling back to
                  main when origin has not been fetched.
  --seed-config   Copy the real ~/.config/gitpic/config.toml into the worktree's
                  scratch config. Off by default: without it `gitpic doctor`
                  reports CONFIG_MISSING and owner/repo come back empty, so an
                  experiment cannot accidentally commit to the real image host.
EOF
}

BRANCH=""
DIR=""
BASE=""
SEED_CONFIG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --base)        BASE="${2:-}"; [[ -n "$BASE" ]] || { echo "error: --base needs a ref" >&2; exit 2; }; shift 2 ;;
    --seed-config) SEED_CONFIG=1; shift ;;
    -*)            echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      if   [[ -z "$BRANCH" ]]; then BRANCH="$1"
      elif [[ -z "$DIR"    ]]; then DIR="$1"
      else echo "error: unexpected argument $1" >&2; exit 2
      fi
      shift ;;
  esac
done
[[ -n "$BRANCH" ]] || { usage >&2; exit 2; }

DIR="${DIR:-$(dirname "$ROOT")/gitpic-${BRANCH//\//-}}"
# Absolutise so every path this script prints stays valid from any cwd.
[[ "$DIR" == /* ]] || DIR="$(cd "$(dirname "$DIR")" && pwd)/$(basename "$DIR")"
[[ -e "$DIR" ]] && { echo "error: $DIR already exists" >&2; exit 1; }

# git would reject a double checkout on its own, but its message names the branch
# rather than the directory the other agent is sitting in — which is the part you
# need in order to go ask them.
occupied="$(git -C "$ROOT" worktree list --porcelain \
  | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{w=$2} $0==b{print w}')"
if [[ -n "$occupied" ]]; then
  echo "error: $BRANCH is already checked out at $occupied" >&2
  echo "       that is another agent's worktree — pick a different branch" >&2
  exit 1
fi

if [[ -z "$BASE" ]]; then
  # No `git fetch` here on purpose: this repo reaches GitHub through a local proxy
  # that is not always up, and a failed fetch must not stop you starting work.
  # Pass --base explicitly after fetching if you need the very latest origin/main.
  if git -C "$ROOT" rev-parse --verify --quiet origin/main >/dev/null; then
    BASE=origin/main
  else
    BASE=main
  fi
fi

if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "==> attaching existing local branch $BRANCH"
  git -C "$ROOT" worktree add "$DIR" "$BRANCH"
elif git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "==> tracking origin/$BRANCH"
  git -C "$ROOT" worktree add --track -b "$BRANCH" "$DIR" "origin/$BRANCH"
else
  git -C "$ROOT" rev-parse --verify --quiet "$BASE" >/dev/null \
    || { echo "error: base ref '$BASE' does not exist" >&2; exit 1; }
  echo "==> new branch $BRANCH from $BASE"
  # --no-track, because the base is normally origin/main: git's default would set
  # this feature branch's upstream to origin/main, and `git pull` would then quietly
  # merge main into it. No upstream means the first push must say `-u origin <name>`,
  # which is the explicit act it should be.
  git -C "$ROOT" worktree add --no-track -b "$BRANCH" "$DIR" "$BASE"
fi

mkdir -p "$DIR/.local/config" "$DIR/.local/share"

if (( SEED_CONFIG )); then
  src="${XDG_CONFIG_HOME:-$HOME/.config}/gitpic/config.toml"
  if [[ -f "$src" ]]; then
    mkdir -p "$DIR/.local/config/gitpic"
    cp "$src" "$DIR/.local/config/gitpic/config.toml"
    echo "==> seeded config from $src — uploads from here reach the real image host"
  else
    echo "warning: --seed-config given, but $src does not exist" >&2
  fi
fi

# Written rather than exported: this script runs in its own shell, so it cannot
# change the environment of the one you are typing in.
cat > "$DIR/.local/env.sh" <<EOF
# Source after cd-ing into this worktree:  . .local/env.sh
# Generated by scripts/new-worktree.sh. Every line here is about state that lives
# OUTSIDE the worktree, and would otherwise be shared with every other agent.

# One build cache for all worktrees. 3.7 of target/'s 5.4 GB is dependency
# artifacts that do not vary by branch, so a per-worktree target/ would mostly be
# a copy of the others. cargo takes a file lock on this directory: a second
# concurrent build prints "Blocking waiting for file lock" and waits rather than
# corrupting anything. The price is that concurrent builds serialise, and this
# crate — not its dependencies — recompiles when the cache changes branches.
export CARGO_TARGET_DIR="\${CARGO_TARGET_DIR:-\$HOME/.cache/cargo-target/gitpic}"

# gitpic's own config and history, per worktree. Without this, every agent shares
# ~/.config/gitpic/config.toml and ~/.local/share/gitpic/history.jsonl, and one
# agent's \`gitpic config set\` silently rewrites another's target repo.
#
# Measured: with no config.toml under here, owner/repo come back empty and
# \`gitpic doctor\` reports CONFIG_MISSING — so an experiment cannot accidentally
# commit to the real image host. Re-run with --seed-config if you need real uploads.
export XDG_CONFIG_HOME="$DIR/.local/config"
export XDG_DATA_HOME="$DIR/.local/share"

# gh keeps the real login. Measured: gh finds its token in the system keyring and
# is unaffected by the XDG_CONFIG_HOME above — pinned anyway, so a future gh that
# does honour it cannot silently point this worktree at an empty config.
export GH_CONFIG_DIR="\${GH_CONFIG_DIR:-\$HOME/.config/gh}"
EOF

cat <<EOF

worktree   $DIR
branch     $BRANCH

  cd $DIR
  . .local/env.sh
  claude              # or codex — exactly one agent in this directory

when the work is merged and the agent is done:
  git worktree remove $DIR      # add --force if .local/ makes it refuse
EOF
