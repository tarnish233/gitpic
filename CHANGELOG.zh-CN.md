# 更新日志

本项目的所有重要变更都会记录在此文件中。格式参考
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 把契约与实现对齐

### 修复
- `gitpic init` 不再写出一个自己拒绝加载的配置。它是唯一**落盘**却跳过
  `Config::validate` 的写入方，所以 "Target repo" 里填 `me x/pics`、或分支带空格、
  或填 `..`，都会在打出"✓ saved config"之后让**每一条**读配置的命令以
  `CONFIG_INVALID`（退出码 10）失败 —— 包括 `init` 自己（它开头就 `Config::load()`），
  唯一出路是 `gitpic config edit`。现在校验发生在写盘之前，坏答案报 `USAGE` 且盘上
  什么都没动，`init` 可以直接重跑。
- `--repo` 现在和其他来源一样被校验。它是优先级**最高**的来源，却是唯一不过
  `validate` 的：`--repo o/..` 会让 reqwest 归一化掉一整段请求 URL（打到了别的端点），
  `--repo 'o/re po'` 把 `%20` 送进路径 —— 两者都表现为一句光秃秃的 404，而同一个值
  写在配置文件里是 `CONFIG_INVALID`、来自 `GITPIC_REPO` 是 `USAGE`。五个入口现在都
  必须经过 `validate` 的两个包装之一。

## [0.4.0] - 2026-08-19

### 变更
- **破坏性变更：**GitHub 凭据现在只通过
  `gh auth token --hostname github.com` 获取。`GITPIC_TOKEN` 会被忽略，遗留的
  `github.token` 配置键会被拒绝。升级前请删除该键，并运行 `gh auth login`。
- `gitpic doctor` 为保持 JSON 契约兼容继续输出 `token_source`，但其非空值现在只可能是
  `"gh"`。

### 重构
- 删除三来源凭据优先级、凭据来源枚举、配置脱敏路径，以及 `init`、`config` 中的遗留
  token 分支。
- 将 `config set` 的语义校验统一收口到 `Config::validate`，把上传专用辅助逻辑移回上传
  模块，并合并 stdout 的受保护写入路径；在不改变非认证行为的前提下减少重复逻辑。

## [0.3.0] - 2026-08-18

### 安全
- `gitpic init` 不再询问 token。`prompt` 走的是裸 `stdin.read_line()`，输入的 token
  会明文回显到终端，并留在 scrollback、`script`/asciinema 录像以及任何终端日志里 ——
  而回答它又会把这枚 token 明文写进磁盘，恰恰是凭据链改造要消除的那件事。现在 `init`
  改为引导 `gh auth login` 与 `GITPIC_TOKEN`。配置里已有的 `github.token` 继续可用、
  且仍优先于 `gh`，没有人被断掉。
- 配置所在目录收紧为 `0700`。`config set` 与 `init` 生成的配置可能存着遗留 token，
  `create_dir_all` 默认建出的 `0755` 目录会让同机用户**列出**文件名（不只是读到内容）；
  现在每次保存后立即收紧。写入路径本身（同目录临时文件、`0600` 起步、权限错误不吞）
  已在 0.2.3 收口。

### 修复
- `gitpic doctor` 不再仅凭仓库级 push 权限就报 `repo_writable: true`。仓库级 `push`
  完全没有回答"上传要写的那个 ref 是否存在"，于是一个有 push 权限、但分支不存在的组合
  能通过所有预检，然后在 Contents API 上收到一个光秃秃的 404。现在会并发探测目标分支，
  `repo_writable` 要求两者同时成立。分支缺失会报 `REMOTE_NOT_FOUND`，并在消息里写明
  该怎么修。
- `gitpic init` 按回车不再抹掉已配置的仓库。"Target repo" 的默认值原来只从 `owner`
  推导，所以当 owner 为空 —— 单独设过 `repo`、或 owner 来自 `GITPIC_OWNER` 时都会
  发生 —— 就不给默认值，回车返回 `""`，`set_repo_spec("")` 把它清掉。现在什么都没配
  时的空回答直接报 USAGE，而不是打个"✓ saved config"却留下一个不可用的配置。
- 裁剪历史不会再把历史清空。此前单条记录超过裁剪预算时一行都放不进，`trimmed` 返回
  空字符串，调用方把它写盘 —— 为了执行一个体积上限而删掉全部已记录的链接。现在无条件
  保留最新一条。在 0.2.0–0.2.2 中可通过一个病态的 `--name` 触发（其控制字符经 JSON
  转义后膨胀六倍）。
- 读取端关闭管道不再让进程崩溃。`gitpic list | head`、`gitpic completion zsh | true`、
  `gitpic skill print | head` —— 任何提前停止读取的消费者 —— 都会让 `println!` panic，
  而 release profile 的 `panic = "abort"` 意味着 SIGABRT：退出码 134，落在文档承诺的
  1-10 之外，还在 stderr 上吐一段裸 Rust panic。管道被关闭不是错误（读取方已经拿到了
  它要的），所以现在退出 0，这也是 `head` 之类期待的行为。crate 里所有 stdout 写入都
  收敛到一处守卫，包括 `completion` —— 它此前经由 `clap_complete` 自己的 `.expect()`
  写出，本 crate 拦不住。
- 并发上传不再损坏历史。`writeln!` 会把记录正文和换行分成**两次** `write`；`O_APPEND`
  保证单次原子但不保证这一对原子，所以另一个进程同时追加时，它的记录会插进这两者之间。
  合并成一行的记录随后被读取端静默跳过 —— `gitpic list` 里凭空少几条且毫无提示。现在
  改成一次 `write_all`；裁剪用的临时文件名带上 pid，两个进程也不会写同一个路径。
- 配置**值**现在无论从哪里进来都会被校验，而不只是 `config set` 那一条路。
  `deny_unknown_fields` 守的是键名；手改的 `link_kind = "raw2"` 或 `GITPIC_LINK=raw2`
  仍然能加载，而宽松的读取端随后永久给出 cdn 链接。`github.owner` 此前完全没有校验，
  于是 `config set github.owner "  me  "` 会产出 `/repos/%20%20me%20%20/repo` ——
  正是环境变量去空格所要防的那个问题，只是发生在它没覆盖的入口上 —— 而 `..` 会让 URL
  静默少一段。文件里空的 `github.branch` 和越界的 `upload.quality` 同样会被拒绝，而不是
  撞上 422 或被静默钳制。现在文件、环境变量、`config set` 三者跑同一个 `validate`。
- `gitpic --stdin` 按字节内容命名，而不再一律叫 `image.png`。此前
  `cat photo.jpg | gitpic --stdin` 会把 JPEG 数据发布到 `.png` 路径，GitHub 与 jsDelivr
  随后按 `image/png` 提供。这与 0.2.0 修的 `paste --name shot.jpg` 是同一个缺陷，只是
  发生在那次修复漏掉的来源上：扩展名由内容决定，`--name` 只提供文件名主干。无法识别
  且没给 `--name` 时报 USAGE，而不是猜一个错的 `.png`。
- 每个产出输出的子命令都真正支持 `--json`。此前 `config path` 出纯文本、`config get`
  出 TOML、`skill print` 出裸 Markdown，于是遵循技能文档"总是传 `--json`"的 agent 拿到
  的是解析错误。`init` 是交互式的，现在直接拒绝 `--json`，而不是把提示和信封混在一起。
- `--quiet` 只输出机器可用的行。此前 `gitpic list --quiet` 打的是完整人类列表，空历史
  时还会打"no uploads recorded yet" —— 脚本得自己过滤掉的散文。现在是一行一个 URL，
  与上传路径的既有行为一致。

### 新增
- `gitpic doctor` 报告 `branch_protected`。分支受保护并不意味着当前账号不能写，所以
  它不会让报告变成不健康；但当所有预检都通过、上传却仍被拒绝时，它通常就是原因。
- `tests/json_contract.rs`：会启动构建出的二进制。`--json` 与断管契约存在于
  `dispatch` 和各渲染器之间的接线里，任何单元测试都够不到 —— 我先写的一个源码扫描式
  检查在 bug 仍然存在时就通过了，所以换成了这个。

## [0.2.3] - 2026-08-18

### 配置写入与发布契约收口

### 修复
- 配置文件现在先写入同目录临时文件、完整刷新后再替换目标文件，避免进程中断留下
  半份 TOML；Unix 上从创建临时文件起就强制使用 `0600`，权限设置失败不再被忽略。
- 损坏配置的诊断不再回显 TOML 源行，避免语法错误恰好位于 `github.token` 时把凭据
  打到终端；未知字段名和 `gitpic config edit` 修复提示仍会保留。
- Markdown 输出会转义 URL 目标中的括号和反斜杠，带这些字符的合法地址不再提前
  终止图片链接。

### CI
- Release 说明只接受与 tag 完全匹配的 changelog 标题，并拒绝只有空白的章节；
  `0.2.3-extra` 之类的标题不会再被误当作 `0.2.3`。

## [0.2.2] - 2026-08-17

### 拒绝那些原本会被静默忽略的输入

> **升级提示**：`gitpic list --compress` 这类调用现在会报 USAGE（exit 2）而不是
> exit 0。受影响的只有"给非上传子命令传上传参数"的脚本 —— 那些参数此前从未生效过，
> 所以脚本的行为本来就不是它以为的那样。

### 修复
- 会逃出仓库的路径模板现在被拒绝，而不是产出一个光秃秃的 404。此前
  `upload.path_template = "../../../etc/{name}.{ext}"` 会被接受并发给 Contents
  API，只换回一句没头没尾的 "Not Found"。校验做在**渲染后**的路径上 —— 那是三个
  模板来源（`config set`、`--path`、手改配置文件）唯一的汇合点；`config set` 另外
  会先渲染一个样本，让坏模板在设置的那一刻就报错。
- 上传专用选项现在会被那些原本忽略它们的子命令拒绝。此前
  `gitpic list --compress --max-width 99` 能解析、exit 0、然后什么都不做，
  `completion`、`config`、`skill`、`init` 同样如此。它们仍然是 `global = true`
  （否则 `gitpic paste --no-copy` 会坏掉），但 `dispatch` 现在会把当前子命令无法
  生效的那些报出来。`--json`、`--quiet`、`--verbose` 到处都有意义，不受影响；
  `--repo` 仍被 `doctor` 接受，因为它确实要解析目标。
- `history.jsonl` 不再无上限增长。超过 2 MB 时裁剪到最新的一半，先写临时文件再
  rename，所以中断的裁剪不会留下半个历史。裁剪只在一次廉价的 metadata 检查发现
  超限时才发生，普通的追加根本不读这个文件。**这会丢掉最旧的记录**，其中含有早期
  上传的链接。

### CI
- 发布流程不再有四个 job 抢着创建同一个 Release。现在每个构建上传 artifact，由
  单独一个 `publish` job 全部下载、校验四个归档与四个 sidecar 齐全、只调用一次
  `action-gh-release`。Release 不会再在其他平台还在构建时就先露出半份产物；四个
  构建 job 拿到的是只读 token，只有 `publish` 能写。
- Windows 的校验和 sidecar 现在与 `shasum -a 256` 逐字节一致（小写哈希、两个空格、
  文件名、LF、无 BOM）。此前 `(Get-FileHash).Hash | Out-File` 写出的是大写哈希且
  没有文件名，`shasum -c` 完全读不了。现在每个 sidecar 都会在 CI 里验证 —— 在生成
  它的平台上验一次、发布前再验一次；Windows 的格式不是 macOS 上的维护者能本地检查
  的东西。
- `check_manifests.py` 现在要求两个 changelog 都带有 `Cargo.toml` 里那个版本的
  章节。`release.yml` 从来只读中文那份，所以一个把 `CHANGELOG.md` 留在
  `## [Unreleased]` 的发布也能让 CI 全绿 —— 而 AGENTS.md 明确要求两份保持对齐。

## [0.2.1] - 2026-08-17

### `doctor` 现在能区分"凭据坏了"和"GitHub 在抖"

### 修复
- `gitpic doctor` 不再把仓库检查挂在凭据检查之后。这两者回答的是不同的问题 ——
  `/user` 回答"这个凭据被接受吗"，`/repos/{owner}/{repo}` 回答"它能往这里写吗"，
  而上传只会调用后一类。此前仓库探测只在 `/user` 成功后才执行，所以 `/user` 上
  一个暂时性的 503 会连带报出 `repo_writable: false` —— 这与"凭据坏了"无法区分。
  实测撞到过：`gh api user` 返回 503 的同时 `gh api repos/...` 返回
  `push: true`，而 `doctor` 依然全红。现在两个探测并发执行、各自独立汇报，同样的
  故障会呈现为 `token_valid: false, repo_writable: true`，配一个可重试的
  `NETWORK` 码。
- 两个探测都失败时，确定的答案现在优先于 `NETWORK`（后者只意味着"没探出来"）。
  `/user` 的 503 不会再掩盖仓库端点返回的 401，所以真正坏掉的凭据仍然报
  `AUTH_FAILED`，而不是让人无休止地重试。
- agent 技能文档此前只要 `token_valid` 为 false 就让 agent 叫用户去跑
  `gh auth login`。现在改为要求把两个检查合起来读：当 `repo_writable` 为 true
  且错误码是 `NETWORK` 时应当重试 —— 那种情况下 `gh auth login` 解决不了任何问题。

## [0.2.0] - 2026-08-17

### 凭据不再需要存在配置文件里

`config.toml` 里存着明文 GitHub token，这让它无法安全地纳入 dotfiles 同步 ——
而 scope 为 `repo` 的 classic PAT 对账号可访问的**每一个仓库**都有读写权限，且默认永不过期。

### 破坏性变更
- 配置文件的键名现在严格校验。此前写错的键或段（比如 `dedupe`、`[uplaod]`）能正常
  加载并静默忽略；现在它会让每个读取配置的命令以 `CONFIG_INVALID`（exit `10`）失败，
  直到文件被改对。**升级后突然看到这个错，说明你的配置里一直有一个从未生效的拼写
  错误** —— 报错会指出文件和出错的行，`gitpic config path` 与 `gitpic config edit`
  在这种状态下仍然可用，用来修它。
- 新增退出码 `10`，公开的退出码契约从 `1-9` 变为 `1-10`。这是纯增量，原有的码含义
  不变，但按"只有 1-9"来穷举的脚本需要补一个分支。

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
- `gitpic init` 的 token 提示可以留空以使用 `gh`，提示文案也这么写了。（它仍然是
  第一个字段。）

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
  然后向 `/repos/%20/repo` 发请求 —— 得到一个莫名的 404 而非可操作的错误。现在
  还会去掉首尾空格：此前空白判断看的是 trim 后的值、存的却是没 trim 的原值，
  所以 `GITPIC_OWNER=" me "` 会请求 `/repos/%20me%20/repo`。
- `config.toml` 里写错的键或段现在会被拒绝，而不是静默忽略。此前 `dedupe = false`
  或 `[uplaod]` 都能解析通过且什么都不做，`gitpic config get` 还会照常显示默认值，
  仿佛这个文件从没被编辑过 —— 和上面两条是同一类问题，只是发生在唯一一个**本就
  设计给人手改**的入口上（`gitpic config edit`）。报错会指出文件和出错的行；
  `gitpic config path` 与 `gitpic config edit` 在这种状态下仍然可用，用来修文件。
- 分支名进入 URL 前会做百分号编码。git 的 ref 名允许 `&`、`#`、`+`、`%` 和 `=`，
  而每一个都会静默改变请求的含义：`#` 让后面变成 fragment，`&` 另起一个参数，
  `+` 被解码成空格。于是查询打到了**错误的 ref**，看起来就像"这里还没上传过" ——
  既丢掉了去重，又让上传时不带 sha，覆盖已有文件时报 409。生成的 Markdown 链接
  也受同样影响。
- `gitpic list` 现在把去重的上传标记为 `(deduped)`，与上传输出里已用的措辞一致。

### 新增
- 退出码 `10` / `CONFIG_INVALID`：配置文件存在但读不了或解析不了。此前它是
  exit `1` / `GENERAL` —— 那个同时兜着剪贴板失败和编码失败的兜底码，谁都没法据此
  处理。`3` / `CONFIG_MISSING` 仍然表示"还没配"（跑 `gitpic init`），`10` 表示
  "配了但文件坏了"（跑 `gitpic config edit`）。
- 退出码 `1` / `GENERAL` 现在写进了两个 README 和 agent 技能文档。它一直是可达的
  —— 剪贴板初始化、PNG 编码、拉起 `$EDITOR` —— 但那些表格都从 `2` 开始，照表写的
  脚本会把它错判。

### 文档
- 两个 README 都写着环境变量"优先级最高"。实际上命令行参数会覆盖它们 ——
  `GITPIC_LINK=raw gitpic a.png --link cdn` 出的是 cdn 链接 —— 这也正是
  `src/config.rs` 一直写着的顺序。
- 补上 `GITPIC_OWNER` 的说明（它早已实现，但两个 README 都没提）。
- 英文 README 的安装章节只给了 `cargo install --path .`，而它在克隆之外根本用不了，
  后面的章节却又引用了它从未介绍过的 Homebrew 和 release 压缩包。现在与中文版一致。
- 演示输出里有一行 `📋 已复制到剪贴板`，而程序从不打印它（复制成功是静默的，只有
  失败才报），并且把 `gitpic init` 缩略成了只剩最后一行。

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

[未发布]: https://github.com/tarnish233/gitpic-cli/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.4.0
[0.3.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.3.0
[0.2.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.3
[0.2.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.2
[0.2.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.0
[0.1.6]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.6
[0.1.5]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.5
[0.1.4]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.4
[0.1.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.3
[0.1.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.2
[0.1.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.1
[0.1.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.0
