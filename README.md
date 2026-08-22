# gitpic

**简体中文** | [English](./README.en.md)

把本地或剪贴板里的图片上传到 GitHub 仓库（当图床），一键生成 Markdown 链接，并自动复制到剪贴板。

命令行交互对人友好，加 `--json` 后也便于脚本和 AI 助手调用。程序本体为单个二进制文件，认证统一交给 GitHub CLI（`gh`）。

## 演示

```console
$ gitpic init
gitpic init — configure your GitHub image host

Credentials come from `gh auth token`.
Run `gh auth login` once if you have not already.

Target repo (owner/name): your-name/img
Branch [main]:
Link kind (cdn|raw) [cdn]:

✓ saved config to /Users/you/.config/gitpic/config.toml

$ gitpic ~/Desktop/shot.png
✓ uploaded shot
![shot](https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png)

$ pbpaste                       # 剪贴板里已是上面的 Markdown

$ gitpic list
2026-07-23  shot
  https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png
```

## 安装

命令行工具和菜单栏应用是两件东西，名字也是分开的：CLI 的 formula 叫 **`gitpic_cli`**，
App 叫 **GitPic.app**（见下）。装的是 `gitpic_cli`，用的命令仍然是 `gitpic`。

**Homebrew（推荐，自动加入 PATH 并安装命令行补全）**

```bash
brew install tarnish233/tap/gitpic_cli
```

> 这个 formula 原来叫 `gitpic`。旧名字仍然能装（tap 里留了一份 rename 映射），已经装了的由
> `brew update` / `brew upgrade` 迁移过去，也可以直接跑 `brew migrate gitpic`。迁移只改 Cellar
> 里的目录名 —— 命令、补全脚本和 `/opt/homebrew/bin/gitpic` 这个软链都不变。

**下载预编译二进制**

到 [发布页](https://github.com/tarnish233/gitpic-cli/releases) 下载对应平台的压缩包，解压得到 `gitpic`。macOS 首次运行需解除隔离：

```bash
tar -xzf gitpic-aarch64-apple-darwin.tar.gz     # Apple Silicon
xattr -d com.apple.quarantine ./gitpic 2>/dev/null
chmod +x ./gitpic && mv ./gitpic ~/.local/bin/  # 确保 ~/.local/bin 在 PATH
```

> Intel Mac 用 `x86_64-apple-darwin`，Linux 用 `x86_64-unknown-linux-gnu`，Windows 是 `.zip`（解压得到 `gitpic.exe`）。

**从源码**（需要 Rust 1.88 或更新）

```bash
cargo install --path .
```

### GitPic.app（macOS 菜单栏应用，可选）

每个 [发布](https://github.com/tarnish233/gitpic-cli/releases) 里都有一个
`GitPic-<版本>-macos-arm64.zip`。它和 CLI 同版本，并且内嵌了同一版本的 `gitpic`，所以装了
App 不必再单独装 CLI（反之也不必装 App）。

从菜单栏图标上传剪贴板图片或选文件，链接自动进剪贴板；设置窗口可以改图床仓库和上传选项，看历史。

```bash
unzip GitPic-<版本>-macos-arm64.zip -d /Applications/
# 本机签名、未经 Apple 公证，下载后必须解除隔离才能打开：
xattr -dr com.apple.quarantine /Applications/GitPic.app
```

> 仅 Apple Silicon。仍然需要 GitHub CLI 且已登录：`brew install gh && gh auth login`。

## 初始化与设置

凭据只取自 [GitHub CLI](https://cli.github.com)，配置文件里**不保存任何密钥**：

```bash
gh auth login          # 一次即可，token 存在系统 keyring 里
gitpic init            # 只问仓库/分支/链接类型，不问 token
```

`gitpic` 每次需要访问 GitHub 时调用 `gh auth token --hostname github.com`。`GITPIC_TOKEN`
不再读取，配置文件里的 `github.token` 也不再支持。若从旧版本升级，请删除配置中的
`token` 行并运行一次 `gh auth login`；否则严格配置校验会提示 `CONFIG_INVALID`。

> **权限范围提醒**：`gh` 的 OAuth token 可能比“只往图床仓库写文件”所需的权限更宽。
> 可通过 `gh auth status` 检查当前账号与认证状态。

`~/.config/gitpic/config.toml`（遵循 `$XDG_CONFIG_HOME`）也可以手写 —— 注意其中没有 `token` 项，所以这个文件可以安全地纳入 dotfiles 同步：

```toml
[github]
owner  = "your-name"
repo   = "img"
branch = "main"

[upload]
path_template = "images/{year}/{month}/{hash8}-{name}.{ext}"
format        = "md"    # md | html | url —— `--format` 的默认值
link_kind     = "cdn"   # cdn (jsDelivr) | raw —— `--link` 的默认值
dedup         = true
auto_copy     = true    # 上传后把链接写进剪贴板；App 也遵守（--json / --quiet 从不写）
compress      = false
max_width     = 0        # 0 = 不缩放
quality       = 82       # 压缩时的 JPEG 质量（1-100）
```

上传目标和偏好也可以用环境变量覆盖（不包括凭据；优先级高于配置文件，但低于命令行参数）：

```bash
export GITPIC_REPO="your-name/img"     # owner/name（也可只写 name，沿用现有 owner）
export GITPIC_OWNER="your-name"        # 可选：只覆盖 owner
export GITPIC_BRANCH="main"            # 可选
export GITPIC_LINK="cdn"               # 可选：cdn | raw
```

优先级为**命令行参数 > 环境变量 > 配置文件**，例如 `GITPIC_LINK=raw gitpic a.png --link cdn`
生成的是 cdn 链接。值为空白的环境变量会被忽略（回落到配置文件），前后空格会被去掉。

上传历史保存在 `~/.local/share/gitpic/history.jsonl`（遵循 `$XDG_DATA_HOME`）。

## 使用

```bash
gitpic screenshot.png            # 上传 → 打印 Markdown → 复制到剪贴板
gitpic a.png b.png               # 批量上传
gitpic paste                     # 上传剪贴板里的图片（截图后直接用）
cat img.png | gitpic --stdin          # 扩展名按字节内容判定
gitpic doctor                    # 检查 gh 认证与仓库权限
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
gitpic config get                        # 查看全部设置
gitpic config set github.repo owner/name # 修改某项
gitpic config set upload.link_kind raw
gitpic config set upload.compress true
gitpic config set upload.max_width 1600
gitpic config set upload.quality 82
gitpic config edit                       # 用 $EDITOR 打开配置文件
```

`path_template` 占位符：`{year} {month} {day} {hash} {hash8} {name} {ext}`

`--json` 在每个子命令上都返回带 `ok` 的信封（失败也一样），三个例外：交互式的
`gitpic init` 会直接**拒绝** `--json`；`gitpic completion <shell>` 忽略它、照打
shell 脚本；`gitpic config edit` 忽略它并把 stdout 交给 `$EDITOR`，那不是 JSON。
`--quiet` 只在上传路径和 `gitpic list` 上真正改变输出（每行一个链接）；`gitpic doctor`
和 `gitpic skill install` 收到它仍打人类可读的勾/散文（`config get`、`config path`、
`skill path` 的输出本来就是机器可用的）。

配置文件里的键名是严格校验的：写错的键或段（比如 `dedupe`、`[uplaod]`）会报
`CONFIG_INVALID` 并指出文件名和被拒绝的那个键，而不是被静默忽略（为了不把可能含
凭据的源码行回显出来，不报行号）。这种情况下 `gitpic config path`
和 `gitpic config edit` 仍然可用，用来把文件改回来。

## 命令行补全

用 Homebrew 安装时会自动安装 bash、zsh 和 fish 的补全脚本（zsh 用户重新打开终端即可生效）。也可以通过以下命令手动生成：

```bash
gitpic completion zsh  > ~/.zfunc/_gitpic
gitpic completion bash > /etc/bash_completion.d/gitpic
gitpic completion fish > ~/.config/fish/completions/gitpic.fish
```

## 退出码

`0` 成功 · `1` 其他错误 · `2` 参数错误 · `3` 缺少设置 · `4` 认证失败 · `5` 网络错误 · `6` 本地文件不存在 · `7` 权限不足 · `8` 远端资源不存在 · `9` 请求过于频繁 · `10` 配置文件无法使用

`3` 是"还没配"（跑 `gitpic init`），`10` 是"配了但文件有问题"（跑 `gitpic config edit`）——
两者的处理方式不同，所以用了不同的码。

## AI 助手集成

`gitpic` 自带一份 [Agent Skill](./skills/gitpic/SKILL.md)，告诉 Claude Code、Codex
等助手该怎么调用它。三种安装方式任选其一。

**用 CLI 安装（适用于任意助手）**

技能文档已编入二进制，所以装上的版本永远与你正在运行的 `gitpic` 一致；
`brew upgrade gitpic_cli` 之后重跑一次即可同步：

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

助手调用 `gitpic` 时请始终带上 `--json`，并在上传命令上加 `--no-copy`。
`--no-copy` 只对上传路径（`gitpic <文件>`、`--stdin`、`paste`）有意义，其余子命令
会把它当 `USAGE`（退出码 2）拒掉——`gitpic doctor --json --no-copy` 是会失败的。

`gitpic doctor` 在任一检查失败时返回非零退出码；脚本仍应解析 JSON 中的
`config_ok`、`token_valid` 和 `repo_writable`。不健康的报告还会带上与其他子命令同形的
`error` 对象（`ok` 为 false 时必有、为 true 时必无），所以「分支不存在」（8）和
「没有写权限」（7）从 stdout 就能分开 —— 不必依赖退出码，管到解析器（`… | jq`）会把它
换成解析器自己的。参数解析错误在 `--json` 模式下也会使用统一的
`{ "ok": false, "error": ... }` 结构。

## 更新日志

见 [中文更新日志](./CHANGELOG.zh-CN.md)；英文版见 [CHANGELOG.md](./CHANGELOG.md)。

## 许可证

MIT
