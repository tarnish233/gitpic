<p align="center">
  <img src="./docs/assets/icon.png" alt="GitPic" width="128">
</p>

<h1 align="center">gitpic</h1>

<p align="center">
  把本地或剪贴板里的图片传到 GitHub 仓库当图床，生成 Markdown 链接并复制到剪贴板。
</p>

<p align="center">
  <strong>简体中文</strong> · <a href="./README.en.md">English</a>
</p>

菜单栏 App 和命令行是同一个东西的两个界面，同版本、共用配置和上传历史。认证统一交给
GitHub CLI（`gh`），配置文件里**不保存任何密钥**。

## GitPic.app（macOS 菜单栏）

```bash
brew install gh && gh auth login        # 前置，一次即可
brew install tarnish233/tap/gitpic      # App + 终端命令
```

从菜单里选文件上传，或上传剪贴板里的图 —— 链接直接进剪贴板，成功与失败都走
系统通知。**也可以在 Finder 里选中图片按右键，点「GitPic 上传至图床」**（App 没在运行会被
拉起来；不想要这一项的话，「上传」页的「Finder 右键」开关可以关掉它）。设置窗口有四页：图床
（仓库、连通性测试）、上传（路径模板、链接形态、压缩、Finder 右键）、历史
（带缩略图，一键复制）、关于。

第一次用打开设置窗口填 owner / repo / branch 就行，也可以在终端跑 `gitpic init`。

> 仅 Apple Silicon，需要 macOS 14+。App 是本机签名、未经 Apple 公证的 —— 用 brew 装时隔离属性由
> brew 解除；若从[发布页](https://github.com/tarnish233/gitpic/releases)下
> `GitPic-<版本>-macos-arm64.dmg` 手动装（打开后把 GitPic 拖到 Applications），**必须**自己解除
> 隔离，否则打不开：
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/GitPic.app
> ```

## 命令行

**装了 App 就已经有命令行了。** cask 会把 App 内嵌的那份 `gitpic` 链接到
`$(brew --prefix)/bin/gitpic`，并生成 bash、zsh、fish 三份补全 —— 终端和 App 用的是同一个文件，
所以升 App 就是升命令，两者不可能版本不一致。配置和历史也是同一份：App 里改了仓库，终端里立刻
生效，反之也一样。

只要命令行，或者用 Linux / Intel Mac / CI：

```bash
brew install tarnish233/tap/gitpic_cli
```

**两个别都装。** 它们抢同一个 `bin/gitpic` 和同三份补全，后装的那个会跳过链接（formula 后装会以
`brew link` 失败结束）。要换先卸掉另一个。

其他方式：从[发布页](https://github.com/tarnish233/gitpic/releases)下对应平台的压缩包解压出
`gitpic`（macOS、Linux、Windows 都有，CI 在 `v*` tag 上构建；macOS 需
`xattr -d com.apple.quarantine ./gitpic`），或者从源码 `cargo install --path .`（需要 Rust 1.88+）。

用 brew 装时三份补全是自动装好的（zsh 重开终端生效）。手动装的话自己生成：
`gitpic completion zsh > ~/.zfunc/_gitpic`，bash、fish 同理。

### 用法

```bash
gitpic screenshot.png            # 上传 → 打印 Markdown → 复制到剪贴板
gitpic a.png b.png               # 批量
gitpic paste                     # 上传剪贴板里的图（截图后直接用）
cat img.png | gitpic --stdin     # 扩展名按字节内容判定
gitpic list                      # 最近上传（本地历史）
gitpic doctor                    # 检查 gh 认证与仓库权限
gitpic completion zsh            # 打印补全脚本
gitpic skill install             # 安装 AI 助手技能（见下）

gitpic photo.jpg -q -f url       # 只打印 URL
gitpic photo.jpg --json          # 结构化输出（脚本 / AI 助手）
gitpic photo.jpg --link raw      # 用 raw.githubusercontent.com 而非 jsDelivr

gitpic big.png --compress                    # 上传前压缩
gitpic big.png --compress --max-width 1600   # 缩放到宽度 <= 1600
gitpic big.jpg --compress --quality 80       # JPEG 质量
```

### 配置

```bash
gitpic init                              # 交互式初始化
gitpic config get                        # 查看全部
gitpic config set github.repo owner/name # 改一项，也可一次多项
gitpic config path                       # 配置文件在哪
gitpic config edit                       # 用 $EDITOR 打开
```

配置在 `~/.config/gitpic/config.toml`（遵循 `$XDG_CONFIG_HOME`），历史在
`~/.local/share/gitpic/history.jsonl`（遵循 `$XDG_DATA_HOME`）。配置里没有 token 项，所以这个
文件可以安全地纳入 dotfiles 同步：

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
auto_copy     = true    # 上传后写剪贴板；App 也遵守（`--json` / `--quiet` 从不写）
compress      = false
max_width     = 0       # 0 = 不缩放
quality       = 82      # 压缩时的 JPEG 质量（1-100）
```

`path_template` 占位符：`{year} {month} {day} {hash} {hash8} {name} {ext}`

上传目标也可以用环境变量覆盖（不含凭据）：`GITPIC_REPO`、`GITPIC_OWNER`、`GITPIC_BRANCH`、
`GITPIC_LINK`。优先级是**命令行参数 > 环境变量 > 配置文件**。

键名是严格校验的：写错的键或段（`dedupe`、`[uplaod]`）会报 `CONFIG_INVALID` 并指出被拒的那个
键，而不是静默忽略。这种情况下 `gitpic config path` / `config edit` 仍然可用，用来把文件改回来。

### 凭据

`gitpic` 每次访问 GitHub 时调用 `gh auth token`，token 存在系统 keyring 里。`GITPIC_TOKEN` 和
配置里的 `github.token` 都已不再支持 —— 从旧版本升上来的话删掉配置里的 `token` 行再跑一次
`gh auth login`，否则会报 `CONFIG_INVALID`。

> `gh` 的 OAuth token 可能比"只往图床仓库写文件"所需的权限更宽。用 `gh auth status` 看当前账号。

### 退出码与 `--json`

`0` 成功 · `1` 其他错误 · `2` 参数错误 · `3` 缺少设置 · `4` 认证失败 · `5` 网络错误 · `6` 本地
文件不存在 · `7` 权限不足 · `8` 远端资源不存在 · `9` 请求过于频繁 · `10` 配置文件无法使用。

`3` 是"还没配"（跑 `gitpic init`），`10` 是"配了但文件有问题"（跑 `gitpic config edit`）——
处理方式不同，所以分开两个码。

`--json` 在每个子命令上都返回带 `ok` 的信封，失败也一样，三个例外：交互式的 `gitpic init`
**拒绝** `--json`；`gitpic completion <shell>` 忽略它、照打 shell 脚本；`gitpic config edit`
把 stdout 交给 `$EDITOR`。参数解析错误在 `--json` 下同样是
`{ "ok": false, "error": … }`。

## AI 助手技能

`gitpic` 自带一份 [Agent Skill](./skills/gitpic/SKILL.md)，告诉 Claude Code、Codex 等助手怎么
调用它。技能文档编进了二进制，所以装上的版本永远和你正在跑的 `gitpic` 一致。

```bash
gitpic skill install                 # 从检测到的助手里选
gitpic skill install --agent codex   # 或指定一家
gitpic skill install --dir DIR       # 或指定任意 skills 目录
gitpic skill print                   # 打到 stdout
```

自动检测 `~/.claude/skills` 与 `~/.codex/skills`（尊重 `CLAUDE_CONFIG_DIR` / `CODEX_HOME`），
写入前先问。脚本和 CI 里请加 `--yes`、`--agent` 或 `--dir` —— 没有终端时它会报错而不是替你猜。

也可以作为插件装：

```
/plugin marketplace add tarnish233/gitpic      # Claude Code
/plugin install gitpic@gitpic
```

```bash
codex plugin marketplace add tarnish233/gitpic  # Codex
codex plugin add gitpic@gitpic
```

**给助手的两条约定**：调用时始终带 `--json`；上传命令加 `--no-copy`。`--no-copy` 只对上传路径
（`gitpic <文件>`、`--stdin`、`paste`）有意义，其余子命令会把它当 `USAGE`（退出码 2）拒掉 ——
`gitpic doctor --json --no-copy` 是会失败的。

`gitpic doctor` 在任一检查失败时返回非零退出码，但脚本仍应解析 JSON 里的 `config_ok`、
`token_valid`、`repo_writable`：不健康的报告会带上与其他子命令同形的 `error` 对象，所以"分支不
存在"（8）和"没有写权限"（7）从 stdout 就能分开，不必依赖退出码 —— 一旦管进 `jq`，退出码就变成
`jq` 自己的了。

## 更新日志

见[中文更新日志](./CHANGELOG.zh-CN.md)；英文版见 [CHANGELOG.md](./CHANGELOG.md)。

## 许可证

MIT
