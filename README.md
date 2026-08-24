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

菜单栏 App 和命令行是同一个东西的两个界面，同版本、共用配置和上传历史。认证只有一条路 ——
`gitpic auth login`（浏览器授权），配置文件里**不保存任何密钥**。

## GitPic.app（macOS 菜单栏）

```bash
brew install tarnish233/tap/gitpic      # App + 终端命令
```

从菜单里选文件上传，或上传剪贴板里的图 —— 链接直接进剪贴板，成功与失败都走
系统通知。**也可以在 Finder 里选中图片按右键，点「GitPic 上传至图床」**（App 没在运行会被
拉起来；不想要这一项的话，「通用」页的「系统集成」开关可以关掉它）。设置窗口有六页：通用
（开机自启动、Finder 右键）、图床（账号、仓库、连通性测试）、上传（路径模板、链接形态、压缩）、
历史（带缩略图，一键复制）、Agent（各家 Skill 安装）、关于。

想让 GitPic 一登录就待在菜单栏里，把「通用」页的「开机时自动启动 GitPic」打开就行 —— 它写的是
macOS 自己的登录项，所以「系统设置 ▸ 通用 ▸ 登录项与扩展」里也能看到、也能关掉，两边永远是同一个开关。

**第一次用不需要开终端。** 打开设置窗口 → 图床页 → 「使用 GitHub 登录」，一次性码会显示在窗口里、
浏览器自动打开；授权完成后下面的下拉框会列出你可以上传的仓库，选一个，按右上角「保存」写进配置文件。
仓库只能从这个列表里选，分支跟着仓库来（GitHub 上的默认分支，不是硬编码 `main`）—— 没有手填的入口，
所以拼错仓库名、或者给一个默认分支是 `master` 的仓库配上 `main` 这两种情况都不再可能。

想用终端也一样，而且只有一条命令：`gitpic auth login` 登录成功后会直接把可选仓库列出来让你挑。
两边共用同一份凭据和配置。

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
gitpic auth login                # 浏览器授权登录 GitHub，登录完顺手选图床仓库
gitpic repos                     # 列出这份凭据能上传的仓库
gitpic branches                  # 列出当前仓库的分支（可加 --repo owner/name）
gitpic doctor                    # 检查认证与仓库权限
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
gitpic config get                        # 查看全部
gitpic config set github.repo owner/name # 改一项，也可一次多项
gitpic config path                       # 配置文件在哪
gitpic config edit                       # 用 $EDITOR 打开
```

图床仓库是在 `gitpic auth login` 的最后一步选的（App 里是图床页的下拉框），之后要换就用
`gitpic config set github.repo owner/name` —— `gitpic repos` 会把可选的连默认分支一起列出来。
**换仓库不会自动改 `github.branch`**：目标仓库的默认分支不是当前配的那个时，`github.branch` 要一起
改，否则每次上传都会撞上一个不存在的 ref。`gitpic branches` 正是用来看这件事的：

```bash
$ gitpic branches --repo tarnish233/GitPic-legacy
  master
  tmp-verify-sha
  note: `main` is configured but not in this list, so every upload will fail on a ref
        that does not exist — `gitpic config set github.branch <one of the above>`
```

上传走的是 contents API，**它不能创建分支** —— 目标分支必须已经存在。所以 `github.branch` 的合法取值
恰好就是这个列表，App 的图床页也把分支做成了下拉框（受保护的分支会标出来，但不会被过滤掉：受保护不等于
写不进去，规则可能允许当前账号）。

配置在 `~/.config/gitpic/config.toml`（遵循 `$XDG_CONFIG_HOME`），历史在
`~/.local/share/gitpic/history.jsonl`（遵循 `$XDG_DATA_HOME`）。配置里没有 token 项，所以这个
文件可以安全地纳入 dotfiles 同步 —— 但**同一个目录下的 `auth.toml` 不行**，那里面是
`gitpic auth login` 存的 token（见下）：

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

```bash
gitpic auth login              # 浏览器授权（GitHub device flow）
gitpic auth login --scope repo # 图床是私有仓库时才需要
gitpic auth status             # 现在这枚凭据是谁的
gitpic auth logout             # 删掉
gitpic repos                   # 这枚凭据能往哪些仓库上传
gitpic branches                # 当前仓库有哪些分支
```

**只有这一条路。** token 存在 `~/.config/gitpic/auth.toml`，权限 0600，和 `config.toml` 分开放
—— 后者会被 `gitpic config get` 整份打印、被 `config edit` 丢进 `$EDITOR`，不是放密钥的地方。

`gitpic auth login` 走 GitHub 的 device flow：打印一个一次性代码，你在
<https://github.com/login/device> 输进去，完事。全程没有 client secret，也没有任何需要你手工搬运
的密钥。

授权时会请求 **`public_repo`** scope —— 只对你的**公开**仓库有写权限。这是能干成 gitpic 这件事的最
窄 scope，因为 GitHub 没有"只给某一个仓库"这种 OAuth scope；而它也够了：`link_kind = "cdn"` 指向的
jsDelivr 只服务公开仓库。

图床是**私有**仓库的话得用 `gitpic auth login --scope repo`。`repo` 很宽 —— 你能访问的每个仓库的读写
权限，所以它不是默认值。私有仓库也只有 `link_kind = "raw"` 的链接能用。

`gitpic auth login` 登录成功后会**直接**把这枚凭据能上传的仓库列出来让你选，选中的那个连默认分支一起
落盘 —— 不用再跑第二条命令。`gitpic repos` 是之后想再看一眼时用的（带默认分支、是否私有、能不能写），
`gitpic branches` 则是看某个仓库有哪些分支。

想指向自己注册的 OAuth App 就设 `GITPIC_CLIENT_ID`，或 `gitpic auth login --client-id <id>`；scope
同样可以用 `GITPIC_SCOPE` 覆盖。

> 为什么不用 GitHub App？GitHub App 的权限更窄 —— 可以只给某一个仓库 `Contents: write`，比
> `public_repo` 精确得多。它输在**流程**上：GitHub App 的 user token 只能访问 App 被**安装**过的仓库，
> 而 device flow 不会顺带完成安装。那意味着每个用户都得先在终端授权、再去浏览器把 App 装到自己账号上
> 并勾选仓库。"登录完立刻就有一个列表可选"比"更紧的授权但一半人走不完"更值。

以下三条路都**已经删掉**了，不是"不推荐"：

- **`gh auth token`**。两个来源就是两个身份：装了 `gh` 的机器上，一次上传算在谁头上取决于某个文件
  在不在，而每个凭据错误都有两种解释要讲。它还让 `gh` 成了事实上的依赖 —— 而这件事 gitpic 现在自己
  一条命令就做完了。
- **粘贴 token（`--with-token`）**。手工搬运的 token 会留在 shell history、scrollback、聊天记录里，
  而且它让 AI 助手可以要求用户"把 token 贴进对话"。device flow 不需要任何密钥经过人手。
- **`GITPIC_TOKEN` 和配置里的 `github.token`**。环境变量里的凭据会漏进进程列表和 CI 日志；配置文件
  里的会被 `gitpic config get` 打印出来。配置里还留着 `token` 行的话会报 `CONFIG_INVALID` —— 删掉它。

只剩一个来源，也就没有"来源"可报了：`doctor` 和 `auth status` 都不再有 `token_source` 字段。

### 退出码与 `--json`

`0` 成功 · `1` 其他错误 · `2` 参数错误 · `3` 缺少设置 · `4` 认证失败 · `5` 网络错误 · `6` 本地
文件不存在 · `7` 权限不足 · `8` 远端资源不存在 · `9` 请求过于频繁 · `10` 配置文件无法使用。

`3` 是"还没配"（跑 `gitpic auth login`，或 `gitpic config set github.repo owner/name`），`10` 是
"配了但文件有问题"（跑 `gitpic config edit`）—— 处理方式不同，所以分开两个码。

`--json` 在每个子命令上都返回带 `ok` 的信封，失败也一样，三个例外：`gitpic auth login --json` 是
**流式**的 —— 每行一个带 `event` 字段的完整 JSON 对象（`code` 带一次性码，最后一行一定是 `done` 或
`error`），因为一次性码必须在"等浏览器"之前就发出去，而一个信封只能写一次。这是 App 能把登录做进设置
窗口的原因，也是唯一一处不遵守"一次调用一个信封"的地方，所以脚本和 AI 助手不该调它。另外
`gitpic completion <shell>` 忽略 `--json`、照打 shell 脚本；`gitpic config edit` 则在 `--json` 下
**直接拒掉**（`USAGE`）—— 它要把 stdout 交给编辑器，没法同时是一份 JSON。要读配置用
`gitpic config get --json`，要改用 `gitpic config set`。编辑器取 `$VISUAL`、再取 `$EDITOR`，
带参数的写法（`EDITOR="code --wait"`）也能用。参数解析错误在 `--json` 下同样是
`{ "ok": false, "error": … }`。

## AI 助手技能

`gitpic` 自带一份 [Agent Skill](./skills/gitpic/SKILL.md)，告诉 Claude Code、Codex 等助手怎么
调用它。技能文档编进了二进制，所以装上的版本永远和你正在跑的 `gitpic` 一致。

使用 GitPic.app 时也可以打开「设置 ▸ Agent」，分别管理 Claude Code、Codex 与通用 Agent：查看各自
是未安装、有差异还是已是最新，并单独安装或更新；替换一份有差异的 `SKILL.md` 前，App 会先确认。

```bash
gitpic skill install                 # 从检测到的助手里选
gitpic skill install --agent codex   # 或指定一家
gitpic skill install --agent generic # 通用 Agent（~/.agent/skills）
gitpic skill install --dir DIR       # 或指定任意 skills 目录
gitpic skill install --agent codex --force # 检查后替换有差异的文件
gitpic skill print                   # 打到 stdout
```

自动检测 `~/.claude/skills`、`~/.codex/skills` 与 `~/.agent/skills`（分别尊重
`CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`AGENT_HOME`），写入前先问。脚本和 CI 里请加 `--yes`、
`--agent` 或 `--dir` —— 没有终端时它会报错而不是替你猜。已有 `SKILL.md` 内容不同时，CLI
会保留原文件并报错；检查后只有显式传入 `--force` 才会替换。App 会在确认对话框之后代为传入。

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

`token_valid` 和 `repo_writable` 有三种取值：`true`、`false`，以及**没查过**时的 `null`。
两个 GitHub 检查只在 `config_ok` 为真时才发，所以"已经 `gitpic auth login`、还没挑仓库"
的机器上它们是 `null` —— 之前报 `false`，那是在替一份根本没人看过的凭据下结论，而
`gitpic auth status` 在同一台机器上说它是好的。

## 更新日志

见[中文更新日志](./CHANGELOG.zh-CN.md)；英文版见 [CHANGELOG.md](./CHANGELOG.md)。

## 许可证

MIT
