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

# output control
gitpic photo.jpg -q -f url       # only print the URL
gitpic photo.jpg --json          # structured JSON (for scripts / agents)
gitpic photo.jpg --link raw      # use raw.githubusercontent.com
```

## Config keys

```bash
gitpic config path
gitpic config get
gitpic config set github.repo owner/name
gitpic config set upload.link_kind raw
```

`path_template` placeholders: `{year} {month} {day} {hash} {hash8} {name} {ext}`

## Exit codes

`0` ok · `2` usage · `3` config missing · `4` auth failed · `5` network · `6` file not found

## Agent integration

See [`SKILL.md`](./SKILL.md). Always call with `--json --no-copy`.

## License

MIT
