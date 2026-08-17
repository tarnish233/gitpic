# gitpic

**简体中文** | [English](./README.en.md)

把本地或剪贴板里的图片上传到 GitHub 仓库（当图床），一键生成 Markdown 链接，并自动复制到剪贴板。

命令行交互对人友好，加 `--json` 后也便于脚本和 AI 助手调用。程序为单个静态二进制文件，无需额外运行时。

## 演示

```console
$ gitpic init
✓ saved config to ~/.config/gitpic/config.toml

$ gitpic ~/Desktop/shot.png
✓ uploaded shot  📋 已复制到剪贴板
![shot](https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png)

$ pbpaste                       # 剪贴板里已是上面的 Markdown

$ gitpic list
2026-07-23  shot
  https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png
```

## 安装

**Homebrew（推荐，自动加入 PATH 并安装命令行补全）**

```bash
brew install tarnish233/tap/gitpic
```

**下载预编译二进制**

到 [发布页](https://github.com/tarnish233/gitpic-cli/releases) 下载对应平台的压缩包，解压得到 `gitpic`。macOS 首次运行需解除隔离：

```bash
tar -xzf gitpic-aarch64-apple-darwin.tar.gz     # Apple Silicon
xattr -d com.apple.quarantine ./gitpic 2>/dev/null
chmod +x ./gitpic && mv ./gitpic ~/.local/bin/  # 确保 ~/.local/bin 在 PATH
```

> Intel Mac 用 `x86_64-apple-darwin`，Linux 用 `x86_64-unknown-linux-gnu`，Windows 是 `.zip`（解压得到 `gitpic.exe`）。

**从源码**

```bash
cargo install --path .
```

## 初始化与设置

凭据默认取自 [GitHub CLI](https://cli.github.com)，配置文件里**不保存任何密钥**：

```bash
gh auth login          # 一次即可，token 存在系统 keyring 里
gitpic init            # token 一项留空
```

`gitpic` 按以下顺序取凭据，第一个可用的生效：

| 顺序 | 来源 | 用途 |
|---|---|---|
| 1 | `GITPIC_TOKEN` 环境变量 | CI / 容器 / 没装 `gh` 的机器 |
| 2 | 配置文件里的 `github.token` | 遗留方式，仍然可用 |
| 3 | `gh auth token` | 默认，配置文件零密钥 |

配置里写了 `token` 时它会压过 `gh` —— 显式配置优先于自动探测，升级 gitpic 不会静默换掉你上传用的账号。想改用 `gh`，删掉那一行即可；`gitpic doctor` 会显示当前实际用的是哪一个。

> **权限范围提醒**：`gh` 那枚 OAuth token 的 scope 通常是 `gist, read:org, repo, workflow`，比"只往图床仓库写文件"所需的权限**更宽**。这个方案解决的是「密钥不落盘到会被同步的文件里」，并不缩小权限范围。若你要的是最小权限，请改用限定单仓库 `Contents: Read/Write` 的细粒度令牌，通过 `GITPIC_TOKEN` 传入。

`~/.config/gitpic/config.toml`（遵循 `$XDG_CONFIG_HOME`）也可以手写 —— 注意其中没有 `token` 项，所以这个文件可以安全地纳入 dotfiles 同步：

```toml
[github]
owner  = "your-name"
repo   = "img"
branch = "main"

[upload]
path_template = "images/{year}/{month}/{hash8}-{name}.{ext}"
link_kind     = "cdn"   # cdn (jsDelivr) | raw
dedup         = true
auto_copy     = true
compress      = false
max_width     = 0        # 0 = 不缩放
quality       = 82       # 压缩时的 JPEG 质量（1-100）
```

或用环境变量（不落盘，优先级最高）：

```bash
export GITPIC_TOKEN="github_pat_xxx"   # 细粒度令牌，Contents: Read/Write
export GITPIC_REPO="your-name/img"     # owner/name
export GITPIC_BRANCH="main"            # 可选
export GITPIC_LINK="cdn"               # 可选：cdn | raw
```

上传历史保存在 `~/.local/share/gitpic/history.jsonl`（遵循 `$XDG_DATA_HOME`）。

## 使用

```bash
gitpic screenshot.png            # 上传 → 打印 Markdown → 复制到剪贴板
gitpic a.png b.png               # 批量上传
gitpic paste                     # 上传剪贴板里的图片（截图后直接用）
cat img.png | gitpic --stdin --name shot.png
gitpic doctor                    # 检查访问令牌与仓库权限
gitpic list                      # 查看最近上传（本地历史）
gitpic completion zsh            # 打印命令行补全脚本
gitpic skill install             # 安装 AI 助手技能（见下文）

# 输出控制
gitpic photo.jpg -q -f url       # 只打印 URL
gitpic photo.jpg --json          # 结构化 JSON（脚本 / AI 助手）
gitpic photo.jpg --link raw      # 用 raw.githubusercontent.com

# 压缩 / 缩放
gitpic big.png --compress                    # 上传前压缩
gitpic big.png --compress --max-width 1600   # 缩放到宽度 <= 1600
gitpic big.jpg --compress --quality 80       # JPEG 质量
```

## 设置管理

```bash
gitpic config path                       # 打印配置文件路径
gitpic config get                        # 查看全部设置（访问令牌会被隐藏）
gitpic config set github.repo owner/name # 修改某项
gitpic config set upload.link_kind raw
gitpic config set upload.compress true
gitpic config set upload.max_width 1600
gitpic config edit                       # 用 $EDITOR 打开配置文件
```

`path_template` 占位符：`{year} {month} {day} {hash} {hash8} {name} {ext}`

## 命令行补全

用 Homebrew 安装时会自动安装 bash、zsh 和 fish 的补全脚本（zsh 用户重新打开终端即可生效）。也可以通过以下命令手动生成：

```bash
gitpic completion zsh  > ~/.zfunc/_gitpic
gitpic completion bash > /etc/bash_completion.d/gitpic
gitpic completion fish > ~/.config/fish/completions/gitpic.fish
```

## 退出码

`0` 成功 · `2` 参数错误 · `3` 缺少设置 · `4` 认证失败 · `5` 网络错误 · `6` 本地文件不存在 · `7` 权限不足 · `8` 远端资源不存在 · `9` 请求过于频繁

## AI 助手集成

`gitpic` 自带一份 [Agent Skill](./skills/gitpic/SKILL.md)，告诉 Claude Code、Codex
等助手该怎么调用它。三种安装方式任选其一。

**用 CLI 安装（适用于任意助手）**

技能文档已编入二进制，所以装上的版本永远与你正在运行的 `gitpic` 一致；
`brew upgrade gitpic` 之后重跑一次即可同步：

```bash
gitpic skill install                 # 从检测到的助手中选择
gitpic skill install --agent codex   # 或指定某一家
gitpic skill install --dir DIR       # 或指定任意 skills 目录
gitpic skill path                    # 查看会写到哪里
gitpic skill print                   # 把文档打到 stdout
```

会自动检测 `~/.claude/skills` 与 `~/.codex/skills`（同时尊重
`CLAUDE_CONFIG_DIR` / `CODEX_HOME`），写入前先询问。脚本和 CI 里请加
`--yes`、`--agent` 或 `--dir` —— 没有终端时它会报错而不是替你猜。

**作为 Claude Code 插件**

```
/plugin marketplace add tarnish233/gitpic-cli
/plugin install gitpic@gitpic
```

**作为 Codex 插件**

```bash
codex plugin marketplace add tarnish233/gitpic-cli
codex plugin add gitpic@gitpic
```

助手调用 `gitpic` 时请始终带上 `--json --no-copy`。

`gitpic doctor` 在任一检查失败时返回非零退出码；脚本仍应解析 JSON 中的
`config_ok`、`token_valid` 和 `repo_writable`。参数解析错误在 `--json` 模式下
也会使用统一的 `{ "ok": false, "error": ... }` 结构。

## 更新日志

见 [中文更新日志](./CHANGELOG.zh-CN.md)；英文版见 [CHANGELOG.md](./CHANGELOG.md)。

## 许可证

MIT
