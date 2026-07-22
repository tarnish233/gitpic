# gitpic

Upload local or clipboard images to a GitHub repository (used as an image host)
and get a Markdown link — instantly copied to your clipboard.

Human-friendly on the terminal, machine-friendly (`--json`) for scripts and AI
agents. Single static binary, no runtime required.

## Install

```bash
cargo install --path .
# or after building:
cargo build --release && cp target/release/gitpic ~/.local/bin/
```

## Setup

Interactive:

```bash
gitpic init
```

Or via environment variables (nothing written to disk):

```bash
export GITPIC_TOKEN="github_pat_xxx"   # fine-grained token, Contents: Read/Write
export GITPIC_REPO="your-name/img"     # owner/name
export GITPIC_BRANCH="main"            # optional (default: main)
export GITPIC_LINK="cdn"               # optional: cdn (jsDelivr) | raw
```

Config lives at (platform dependent, e.g. macOS):
`~/Library/Application Support/gitpic/config.toml`

## Usage

```bash
gitpic screenshot.png            # upload, print markdown, copy to clipboard
gitpic a.png b.png               # batch upload
gitpic paste                     # upload the image on your clipboard
cat img.png | gitpic --stdin --name shot.png
gitpic doctor                    # verify token + repo access
gitpic list                      # show recent uploads (local history)
gitpic completion zsh            # print shell completion script

# output control
gitpic photo.jpg -q -f url       # only print the URL
gitpic photo.jpg --json          # structured JSON (for scripts / agents)
gitpic photo.jpg --link raw      # use raw.githubusercontent.com

# compression / resizing
gitpic big.png --compress                    # compress before upload
gitpic big.png --compress --max-width 1600   # resize so width <= 1600
gitpic big.jpg --compress --quality 80       # JPEG quality
```

## Config keys

```bash
gitpic config path
gitpic config get
gitpic config set github.repo owner/name
gitpic config set upload.link_kind raw
gitpic config set upload.compress true
gitpic config set upload.max_width 1600
gitpic config set upload.quality 82
```

## Shell completion

```bash
gitpic completion zsh  > ~/.zfunc/_gitpic     # then autoload
gitpic completion bash > /etc/bash_completion.d/gitpic
gitpic completion fish > ~/.config/fish/completions/gitpic.fish
```

## Downloads

Prebuilt binaries for macOS (Apple Silicon + Intel), Linux, and Windows are
attached to each [GitHub Release](../../releases) (built by CI on `v*` tags).

`path_template` placeholders: `{year} {month} {day} {hash} {hash8} {name} {ext}`

## Exit codes

`0` ok · `2` usage · `3` config missing · `4` auth failed · `5` network · `6` file not found

## Agent integration

See [`SKILL.md`](./SKILL.md). Always call with `--json --no-copy`.

## License

MIT
