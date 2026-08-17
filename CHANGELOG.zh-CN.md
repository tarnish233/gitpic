# 更新日志

本项目的所有重要变更都会记录在此文件中。格式参考
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 凭据不再需要存在配置文件里

`config.toml` 里存着明文 GitHub token，这让它无法安全地纳入 dotfiles 同步 ——
而 scope 为 `repo` 的 classic PAT 对账号可访问的**每一个仓库**都有读写权限，且默认永不过期。

### 变更
- 凭据按以下顺序解析：`GITPIC_TOKEN` 环境变量 → 配置文件里的 `github.token` →
  `gh auth token`。只要 `gh` 已登录，`config.toml` 里就不需要任何密钥，可以安全同步。
- 配置里已有的 `github.token` 继续可用，并且优先级高于 `gh` —— 升级不会静默换掉
  你上传用的账号。想切到 `gh`，删掉那一行即可。
- `gitpic doctor` 新增报告 `token_source`（`env` / `config` / `gh`），可以确认当前
  实际使用的是哪一个凭据。
- 凭据改为惰性解析，只在真要发请求前才取，因此不再存入 `Config`（后者 derive 了
  `Debug`，此前 `{:?}` 能把 token 打出来）。取不到凭据现在表现为
  `token_valid: false`，而不是 `config_ok: false`。
- `gitpic init` 不再一上来就索要 token；该项留空即使用 `gh`。

注意：`gh` 那枚 OAuth token 的 scope 通常是 `gist, read:org, repo, workflow`，
比"只往一个图床仓库写文件"所需的权限**更宽**。本次改动解决的是「密钥不落盘到会被
同步的文件里」，并不缩小权限范围。若需要最小权限，请通过 `GITPIC_TOKEN` 传入限定
单仓库的细粒度令牌。

### 修复
- `gitpic paste --name shot.jpg` 不再把 PNG 字节发布到 `.jpg` 路径。剪贴板截图
  一律编码为 PNG，所以扩展名现在由此推导，而不是照抄 `--name` —— 此前 GitHub 与
  jsDelivr 会把这些上传按 `image/jpeg` 提供。
- `gitpic config set upload.link_kind` 与 `gitpic init` 的提示现在拒绝除
  `cdn`/`raw` 以外的值。此前写错会显示成功，然后因为读取端回落到 `cdn` 而永久
  静默产出 CDN 链接。
- `GITPIC_OWNER`、`GITPIC_BRANCH`、`GITPIC_LINK`、`GITPIC_REPO` 为空白时，现在
  回落到配置文件，而不是用空白覆盖它。此前 `GITPIC_OWNER=" "` 能通过配置检查，
  然后向 `/repos/%20/repo` 发请求 —— 得到一个莫名的 404 而非可操作的错误。
- `gitpic list` 现在把去重的上传标记为 `(deduped)`，与上传输出里已用的措辞一致。

### 移除
- 删除未使用的 `anyhow` 与 `thiserror` 依赖，以及不可达的 `image/webp` 和未使用的
  `tokio/fs`、`tokio/io-std`、`clap/env` 这几个 cargo feature。构建图少了三个 crate。

### CI
- 发布流程改为上传 `gitpic-<target>.*` 并设 `fail_on_unmatched_files: true`。
  此前列了四个归档名、其中两个在任何平台上都不存在，这迫使该检查关闭 —— 于是一个
  **什么产物都没上传**的 release 也会显示成功。
- `cargo fmt --check` 只在 Linux 上跑（rustfmt 的判定与平台无关），并移除冗余的
  `cargo build` —— `clippy --all-targets` 已类型检查同一份 cfg，`cargo test` 会链接
  出真实可执行文件、跑通每个原生依赖。

## [0.1.8] - 2026-08-14

### 修复
- 用 `.gitattributes` 把 `SKILL.md` 钉成 LF。Windows 上 `include_str!` 会把 CRLF 编进二进制，
  导致 `gitpic skill install` 永远把已安装的副本判成过期。

## [0.1.7] - 2026-08-14

### AI 助手技能的安装方式

此前 `SKILL.md` 只躺在仓库根目录，没有任何安装路径 —— 但 Claude Code 和 Codex 都只从
`<skills-dir>/<名称>/SKILL.md` 发现技能，根目录那份永远不会被加载。用户只能手抄，抄完就开始
和仓库版本脱节（实际发生过：有副本停留在 0.1.5，缺少多图部分成功的说明）。

### 新增
- 新增 `gitpic skill` 子命令：`install` / `print` / `path`。技能文档通过 `include_str!`
  编入二进制，所以装上的副本永远与所运行的 `gitpic` 版本一致。
- `gitpic skill install` 会检测 `~/.claude/skills` 与 `~/.codex/skills`（尊重
  `CLAUDE_CONFIG_DIR` / `CODEX_HOME`），写入前先询问；`--agent`、`--dir`、`--yes`
  可跳过交互。若两家的 skills 目录软链到同一处，会合并为一个目标而不会重复写入。
  没有终端（脚本 / CI / 助手调用）时返回 `USAGE` 错误，不会挂住也不会擅自写入。
- 新增 Claude Code 插件市场清单，可用 `/plugin marketplace add tarnish233/gitpic-cli`
  安装。
- 新增 Codex 插件清单，可用 `codex plugin marketplace add tarnish233/gitpic-cli` 安装。

### 变更
- `SKILL.md` 移到 `skills/gitpic/SKILL.md`。这是两家插件格式共同的落点，因此三条分发渠道
  共用同一个源文件，不存在副本。CI 新增校验，确保各清单的版本号与 `Cargo.toml` 一致。

## [0.1.6] - 2026-08-04

### 链接正确性与凭据安全
- 修复会生成失效链接的路径与文件名处理问题。
- 为网络请求添加超时，避免命令无限等待。
- 输出重定向到管道或文件时不再混入终端颜色码。
- 多图上传中途失败时，保留此前已成功上传的图片链接。

### 修复
- `{ext}` 占位符现在与 `{name}` 一样做安全清洗：`a.p#ng` 之类的文件名不再生成被
  截断的远端路径或失效链接。
- 为 GitHub 客户端添加请求超时和连接超时。此前连接被挂起时命令会无限等待，而不是
  返回可重试的 `NETWORK` 错误。
- 输出被重定向到管道或文件时不再写入 ANSI 颜色转义码，并支持 `NO_COLOR` 与
  `CLICOLOR_FORCE`。
- 同一次调用中后续图片上传失败时，保留此前已成功上传的图片链接。`--json` 通过新的
  结构同时返回 `results` 和 `error`；若没有任何图片上传成功，则仍沿用原有的错误结构。
- 对 API 请求和生成的链接中的远端路径做百分号编码，因此包含空格或非 ASCII 字符的
  路径模板也能生成有效链接。
- 对 Markdown 和 HTML 输出中的替代文本做转义：`a]b.png` 不再生成损坏的 Markdown，
  引号也无法逃出 HTML 的 `alt` 属性。
- 拒绝含多余路径段的仓库参数（如 `a/b/c`），此前会静默地把仓库名设为 `b/c`。
- `--quality` 在解析阶段即校验 1-100 范围，与 `config set upload.quality` 保持一致。
  此前 `--quality 0` 会被静默修正为 1。
- 拒绝 `--stdin` 与文件参数同时使用，以及 `--stdin` 与 `paste` 同时使用，此前会静默
  忽略其中一个输入源。
- 使用 jsDelivr CDN 链接且分支名包含 `/` 时给出警告，此时分支与路径的边界不明确。

### 变更
- 本地历史记录写入失败时，在 `-v` 详细模式下给出提示。

### 性能
- 未启用压缩时不再复制图片数据。
- 构造上传请求体时不再经过中间的 `serde_json::Value`，省去一份 base64 数据的复制。
- 哈希转十六进制字符串时不再逐字节分配内存。

## [0.1.5] - 2026-07-28

### 凭据安全与自动化可靠性
- 防止已配置的 GitHub 访问令牌意外出现在终端或 AI 助手输出中。
- 让健康检查、JSON 错误和退出码在脚本及 AI 助手调用中保持确定性。

### 修复
- `config get` 和交互式提示不再显示 GitHub 访问令牌。
- 配置文件损坏时不再静默覆盖原文件。
- 远端路径已存在时，通过 Git blob 哈希确认内容相同后才判定为重复上传。
- 使用 `--json` 时，参数解析错误也会输出统一的 JSON 结构。
- `doctor` 检查失败时返回非零退出码。
- 区分认证失败、权限不足、远端资源不存在、请求限流和可重试的服务器错误。

## [0.1.4] - 2026-07-25

### 升级 GitHub Actions 运行环境
- 将 `actions/checkout` 升级到 v5、`softprops/action-gh-release` 升级到 v3，
  使用 Node.js 24 运行环境并消除 Node.js 20 弃用警告。

## [0.1.3] - 2026-07-25

### 严格校验 JPEG 压缩质量
- `gitpic config set upload.quality` 现在只接受 `1-100`，不再保存超出范围的值。

## [0.1.2] - 2026-07-23

### 修复上传参数与图片处理
- `--link`、`--format`、`--no-copy`、`--name`、`--stdin`、`--path`、
  `--repo`、`--compress`、`--max-width` 和 `--quality` 现在都是全局参数，
  放在子命令后也能正常使用。
- `--verbose` 和 `-v` 会把进度信息输出到标准错误，不再是无效参数。
- 即使重新编码后的文件没有变小，`--max-width` 指定的缩放结果也会保留。
- 纯非 ASCII 文件名会回退到内容哈希，避免不同图片生成相同远端名称。

### 测试
- 新增子命令后参数解析、非 ASCII 文件名和图片缩放的回归测试。

## [0.1.1] - 2026-07-23

### 遵循 XDG 目录规范
- 配置文件迁移到 `~/.config/gitpic/config.toml`，并遵循 `$XDG_CONFIG_HOME`。
- 上传历史迁移到 `~/.local/share/gitpic/history.jsonl`，并遵循 `$XDG_DATA_HOME`。
- 移除 `directories` 依赖。

### 打包
- Homebrew 公式会自动安装 bash、zsh 和 fish 的补全脚本。
- 新增默认中文 README 和英文 README。

## [0.1.0] - 2026-07-22

### 首次发布
- 把本地图片上传到 GitHub 图床仓库并输出 Markdown 链接。
- 支持文件路径、标准输入和剪贴板图片。
- 支持 Markdown、HTML 和纯 URL 输出，以及 jsDelivr CDN 与 GitHub 原始文件链接。
- 人类可读模式下自动把结果复制到剪贴板。
- 支持内容哈希去重和可配置的远端路径模板。
- 支持图片压缩、缩放和本地上传历史。
- 支持 bash、zsh 和 fish 命令行补全。
- 提供 `doctor`、`init`、`config` 等管理命令。
- 提供稳定的 JSON 输出和退出码，并包含 AI 助手技能说明。
- GitHub Actions 在 Linux、macOS 和 Windows 上执行构建与测试，推送版本 tag 后
  自动生成多平台发布包。

[未发布]: https://github.com/tarnish233/gitpic-cli/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.6
[0.1.5]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.5
[0.1.4]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.4
[0.1.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.3
[0.1.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.2
[0.1.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.1
[0.1.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.0
