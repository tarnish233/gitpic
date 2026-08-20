# 更新日志

本项目的所有重要变更都会记录在此文件中。格式参考
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

## [0.7.0] - 2026-08-20

### 注释里写下的不变量，代码现在真的守住了

这一版的多数修复是同一个形状：某处注释、文档、或上一版更新日志已经声明了一条不变量，
而代码并没有守住它。actor 声称它把 `gitpic` 调用串行化了（并没有）；8 秒上限声称它约束
了探测（并不约束）；`skill.rs` 的注释声称「关闭的 stdin 不算同意」，而关闭的 stdout 却
让一次盲装看起来像是被同意了；上一版的 App 段声称草稿和状态行已经修好（都还没）。现在
它们都成立了，而且每一条都配了一个「不成立就会失败」的测试。

顺带删掉了一段永不执行的代码：上一版声称修复了「大于 1 MB 图片的去重与覆盖」，但那条
路径从来没有被触发过——GitHub 对 4 MB 的文件返回的是 200，`ContentsGet` 本来就能解析。
去重和覆盖一直是正常的，那 45 行只是死代码，现在它连同那句不实的声明一起被移除。

### CLI

- **`--name` 只决定文件名主干，绝不决定文件类型。** `gitpic photo.jpg --name shot`
  会把 JPEG 字节发布到 `shot.png`，写成 `--name shot.png` 也一样——因为这个名字整个
  替换掉了扩展名，而 `render_path` 的 `{ext}` 默认是 `png`。现在扩展名跟随字节，与
  `--stdin` 和 `paste` 早已采用的规则一致：两种写法都发布成 `shot.jpg`。解码器认不出
  的格式则保留输入文件自带的扩展名，所以 `diagram.svg --name shot` 得到 `shot.svg`，
  而不是报一个 usage 错误。
- **会 404 的 cdn 链接在提交任何东西之前就被拒绝。** jsDelivr 把 ref 编码成
  `repo@branch/path`，所以分支里的 `/` 让「分支到路径」的边界变得歧义，且没有任何编码
  能修好它。含 `/` 的分支配上 `--link cdn`（或默认）现在是 `USAGE` 错误，且在取凭证
  之前、在任何 PUT 之前抛出——什么都不会上传，改用 `--link raw` 重跑即可。以前是往
  stderr 打一条警告然后照样报 `ok: true` 并给出一个死链接，而 `--json` 的消费者根本
  看不到 stderr。
- **stdout 被关掉时，不会再替用户回答他从未看见的问题。** `printf '…' | gitpic init
  | true` 会往磁盘写出一份完整配置：每次提问的写入都被静默丢弃，而 stdin 照样被消费，
  于是答案落盘了，而用户一个问题都没看到。`gitpic skill install` 更糟——它往 agent
  目录里写文件，而它的提问默认值是「全部」。现在，如果提问的文字送不出去，就干脆
  拒绝读取答案。
- **stdout 被关掉时，失败的退出码不再被改成 0。** `gitpic config get no.such.key
  --json | true` 以前会退出 0，因为 broken-pipe 处理在 `print_error` 里直接
  `process::exit(0)`。成功写入时读者提前离开仍是正常结束；进程现在返回它已经决定
  的状态。
- **`gitpic init` 校验的是「下一条命令会解析到的配置」，而不只是它即将写出的文件。**
  `GITPIC_OWNER=me gitpic init` 只回答 `pics` 会被拒绝并提示「a target repo is
  required」，尽管「owner 来自环境变量 + repo 来自文件」正是每次上传都接受的组合——
  而且 repo 提问的默认值本来就是为这个场景写的，于是 `init` 在拒绝它自己刚提示的
  默认值。环境变量派生的值不会被写进文件。`owner/` 仍会被拒绝、仍然不留下任何文件；
  `gitpic config edit` 仍会在 `$EDITOR` 退出后重新解析，拼写错误是 `CONFIG_INVALID`，
  而不是先报成功、再让之后每条命令都失败。
- **`feat/x` 重新是合法分支**，但有一条边界。`check_branch` 以前连 `/` 一起禁了，尽管
  注释里的例子就是 `feat/x`。git ref 允许 `/`；空段、`.` / `..`、以及开头或结尾的
  斜杠仍会拒绝。查 `/branches/{branch}` 时把 `/` 编成 `%2F`，避免多出一层路径；
  `?ref=` 则保留 `/`，这是 GitHub 对该查询参数的约定。raw 链接会给分支单独一个路径
  段，可以正常用；cdn 链接表达不了它，会被拒绝（见上）。
- 对两个及以上文件使用 `--name` 是 `USAGE`，不再默默丢掉。stdin、paste 和单个文件
  仍然可用。
- 本地拒绝超过 100 MB 的上传。Contents API PUT 本来就接不下，先做 base64 再交给
  远端只会换来一句含糊的错误。
- GitHub 409（ref 冲突）和 422（无法处理，包括分支保护）单独分类，不再掉进未标注
  的 4xx。两者都还是 `GENERAL`（没有单独可执行的修复），但信息里会写明状态码。

### App

- **两次 `gitpic` 调用不会再同时进行。** 这个类型是 actor，它的注释也声称这就实现了
  串行化；但 actor 是可重入的，方法里每个 `await` 都是执行器放下一个调用者进来的
  地方。就这个形状实测过：两次重叠的 `applyConfig` 会让两个 `gitpic` 进程同时在机器
  上跑，而 `config set` 是「读取 → 改一个键 → 整文件写回」且没有锁，于是两处改动里
  有一处被静默丢弃。上传有同一个漏洞，那正是注释声称 actor 能防住的 GitHub 409
  分支 ref 竞态。现在由一条串行队列为每次调用把关。
- **`gh auth status` 和 login shell 查找的 8 秒上限，现在是真的了。** 原先的排空要等
  EOF，而 EOF 需要管道的**每一个**写端都关闭——一个在 profile 里启动了 ssh-agent、
  gpg-agent 或 nvm 的 login shell 会留着一个，所以杀掉我们自己 spawn 的子进程并不会
  产生 EOF，那次等待根本不会返回。现在换成受截止时间约束的 `poll` 循环，而且是
  **子进程退出**而不是 EOF 结束排空：这让 ssh-agent 那个场景从「8 秒后被杀」变成
  「约 0.1 秒拿到完整答案」。真的超时的调用也会把已读到的内容交回。
- **被杀掉的子进程不会再让 app 崩溃。** `Process.terminationStatus` 对尚未退出的进程
  会抛 Objective-C 异常，而 `try` 捕不到它；SIGKILL 之后那次等待本身也可能超时。现在
  只在终止回调真的触发过之后才去读状态；始终没有回报的子进程会被描述成「被 SIGKILL」
  而不是去问它。
- **shell profile 会打印东西的机器上也能找到 `gh` 了。** login shell 探测原先把
  **整个** stdout 做 trim 当成一个路径，所以 nvm/conda 的絮语或 `command -v` 答案
  之前的一条 motd 就会让查找失败，于是在装了 gh 的机器上报「找不到 gh，请 brew
  install gh」。现在会逐行扫描，只接受「绝对路径 + 最后一段等于工具名 + 可执行」的
  那一行——这同时也避免了 profile 里某个无关的可执行路径被当成 `gh` 去 spawn——并且
  非 UTF-8 的噪音不再让答案整体作废。
- **配置表单不会再把已保存的值报成未保存。** `repo` 填成 `owner/name` 时会被拆开
  存储，所以填进去的形式再也不等于文件里的值；而草稿的对账是整体式的，于是别处的
  一次编辑就会抑制整个回读，那个键无论保存多少次都一直显示「未保存」，唯一的出路是
  `revert()`。现在对账是**逐键**的——用户没在编辑的键以文件为准，用户在这次往返期间
  动过的键以用户为准；部分失败的保存则只采纳真正落盘的那些键，写失败的那个值会留在
  表单里供重试。
- **屏幕上不会再出现没有真正跑过的检查结论。** `doctor` 失败时原先会留着上一次的
  报告，于是「仓库可写 ✓」和「doctor 失败」并排显示。现在各面板区分三种工具状态而
  不是两种：发现过程还在进行时会照实说，而不是卡在「读取配置中…」；「找不到 gitpic」
  只在查找真的结束后才说——启动后头几秒的一次拖放，以前会为一个只是还没被定位到的
  可执行文件收到这句话。发现一完成表单也会自己去加载，不再等用户找到重试按钮。
- **状态消息由写它的人负责清除。** 这一行被四个写入方共用，而谁都清不掉别人的：保存
  失败的「写入失败」比那次证明它已不成立的成功读取活得更久，「没有改动」根本没有任何
  东西会清掉它，历史面板的「写剪贴板失败」也以同样方式滞留。进入上传状态时还会作废
  仍在等待的复位任务——正是它以前会在上传中途把「上传中…」抹掉。
- 工具发现不再阻塞协作线程。`Task.detached` 并不自带线程，而探测每个工具会阻塞最多
  8 秒；现在它跑在一条专属队列上，协作线程池只等一个 continuation。
- 嵌套的 reload/save/doctor 不再让第一个 `defer { busy = false }` 清掉仍在跑的那次
  工作的转圈。再次打开主窗口不再泄漏 `.regular` 激活策略：`showWindow` 在窗口生命
  周期内只 `enter()` 一次，即使菜单项在窗口已显示或最小化时被点过，关闭后也会回到
  `.accessory`。
- 上传成功后刷新历史；菜单里只展示 8 条，内存里也只保留这 8 条。刘海浮层不再把进行
  中的上传自动收回 idle。菜单栏「连通性测试」打开「图床」页并走窗口里同一个探测，
  不再另弹一份 NSAlert。历史里的 Raw URL 编码与 CLI 对齐（`+` `#` `?` 会转义，`/`
  不会）。解析不了的 CLI 输出会把 stderr 一并展示。

## [0.6.0] - 2026-08-20

### 一个版本号，一次发布 —— CLI 与 App 从此一起发

从这一版起，`gitpic` CLI 和 GitPic.app 使用同一个版本号，并发布在同一个 GitHub Release 里。
`Cargo.toml` 是唯一的版本来源；`apps/GitPic/VERSION` 和 `app-v*` tag 命名空间都已移除。
以后每次发布只打一个 `vX.Y.Z` tag。

### 发布方式

- **两个版本号合一，而且由构建来证明，不是靠承诺。** `scripts/build-app.sh` 从
  `Cargo.toml` 的 `[package]` 段读版本，然后断言即将嵌入的 `gitpic` 二进制自报的版本与之
  相等。以前一个过期的 `target/release/gitpic` 会静默打进一个版本号与内容不符的 bundle；
  现在构建会停下来，并指明该重建哪个二进制。
- 删除 `.github/workflows/release-app.yml`，它的构建、校验、打包步骤并入 `release.yml`
  的一个 macOS job。由**唯一**的发布者把全部产物（四个 CLI 归档 + app 的 zip）附到同一个
  Release，所以这个 Release 要么齐全，要么不存在。
- 发布走**正常 release**，不再是 prerelease。app 仍是本机 ad-hoc 签名、未公证，这个前提写在
  release notes 里紧挨 app 资源说明，而不是塞进 prerelease 标记。这个标记留不住：
  `releases/latest` 会跳过 prerelease，而 Homebrew tap 的更新流程读的正是这个端点 ——
  合并后的 Release 一旦标成 prerelease，formula 就再也不会更新，且**静默无声**，因为它的
  cron 不会报错。
- 发布流程新增一条断言：tag 必须与 `Cargo.toml` 的版本一致。以前只有 app 侧校验自己的 tag，
  CLI 侧是从 tag 反推版本，从不和任何东西比对。
- 发布前的产物守卫不再用宽松的 `gitpic-*` glob 计数，改为断言确切的产物集合。两类产物进同一
  个目录后，`ls gitpic-*` 在任何大小写不敏感的文件系统上都会匹配到 `GitPic-…zip` ——
  之前之所以没出事，只是因为发布 job 恰好跑在 Linux 上。
- 两份 changelog 现在每个版本段内分 `### CLI` 与 `### App` 两节。
  `apps/GitPic/CHANGELOG.md` 冻结在 0.1.2，作为历史保留。

### CLI

- 无功能变更。版本从 0.5.1 跳到 0.6.0 是因为 CLI 与 app 开始共用一个版本号，
  不是因为 CLI 的行为有任何变化。

### App

- **在 Finder 里 ⌘C 复制图片文件后上传，不再报"剪贴板里没有图片"。** 原来的读取只认位图数据
  （`.png`、`.tiff`、`NSImage`），而 Finder 复制放上剪贴板的这三样都没有 —— 只有
  `public.file-url`，`NSImage` 也读不出来。实测得出，不是推断。现在优先识别文件 URL 并按文件
  上传，原始字节、扩展名、文件名都得以保留，不再一律变成重新编码的 `clipboard.png`。剪贴板上
  没有可用内容时也会记日志 —— 这曾是唯一一种什么痕迹都不留的失败，导致"GitPic 没反应"无法
  诊断。
- 写剪贴板失败不再被报成"已复制"。`setString` 的返回值原先被丢弃，于是失败也宣告成功，用户
  粘出来的是旧内容却不知为何。结果为空时也不再用空字符串清空剪贴板。
- **Owner / Repo / Branch 和路径模板现在看得出来可以编辑。** grouped Form 里裸的 `TextField`
  不画边框、还把文字右对齐，在 macOS 26 上与旁边的只读行逐像素一致 —— 这些字段一直是可写的，
  只是屏幕上没有任何东西这么说。现在它们有边框、从左侧起排、带占位符，按 Return 即保存。
- 「目标仓库」页改名为 **图床**，其 `doctor` 按钮改为 **连通性测试**，状态栏菜单里那条同步
  改名。该按钮的三次探测全部是读操作，页面在按下之前就会这么说明。
- **状态栏菜单不再显示它兑现不了的快捷键。** `⌘⇧V`、`⌘O`、`⌘,`、`⌘Q` 原本像全局热键一样列在
  菜单里，但 App 没有注册任何热键，而状态栏菜单不在主菜单链上，所以它们只在菜单已经打开时
  才生效 —— 实测：让 Finder 在前台按 `⌘⇧V`，日志里一点痕迹都没有。标识已移除，点击照常可用。
- 文件选择框和连通性测试弹窗现在在显示期间持有 `.regular`，与主窗口一致，不再调用
  `NSApp.activate(ignoringOtherApps:)` —— 后者自 macOS 14 起废弃，而且在协作式激活下，
  后台 App 无法把自己拉到活动 App 前面。
- 应用图标改为 Icon Composer 文档：把菜单栏用的 SF Symbol `photo.on.rectangle.angled` 放大，
  作为白底上的黑色标记。Tahoe 会依据 `AppIcon.icon` 施加高光玻璃与阴影，更老的 macOS 用压平
  后的 `.icns`。`scripts/build-app.sh` 用 `actool` 编译（icns + `Assets.car`），并同时声明
  `CFBundleIconFile` 与 `CFBundleIconName`。旧 `sips` 流水线缩放用的那张 1024 px PNG 已删除。
- CI 现在会在 macOS 上跑 `scripts/build-app.sh` 与那套 bundle 断言。以前只跑 `swift build`
  和 `swift test`，bundle、图标、签名这条路径直到打 tag 才会被走一次 —— 这正是一条仍在找
  `Resources/GitPic.icns` 的发布守卫能在改用 `actool` 之后一直存活的原因。

### 本版未包含

- **全局热键。** 不打开菜单就上传剪贴板图片需要 `RegisterEventHotKey`，目前还没有注册。

## [0.5.1] - 2026-08-19

### 声明 MSRV，并让 CI 替你守住它

### 打包
- 声明 MSRV：`rust-version = "1.88"`。此前没有声明，于是在更老的工具链上
  `cargo install` 会在某个依赖内部炸开，而不是给出一句"gitpic 需要 rustc 1.88"。
  1.88 是依赖图定下的地板 —— `image 0.25.10` 声明 1.88.0，`reqwest` 拽进来的
  `icu_*` 系列声明 1.86 —— 并且是**实测**的：装上 1.88.0 工具链跑
  `cargo build --locked` 通过，不是照着依赖清单估的。只影响从源码构建；Homebrew 和
  release 压缩包里是 CI 用 stable 编出来的二进制。两份 README 与技能文档的"从源码"
  一节也写上了这个要求。

### CI
- 新增一个钉住 MSRV 的构建 job。工具链版本**从 `Cargo.toml` 读出来**，而不是写死在
  workflow 里 —— 写死的话它会和自己本该检查的那句承诺各自漂移，而那正是这个 job 存在
  的理由（`check_manifests.py` 给三份插件清单堵的是同一个洞）。它跑
  `cargo build --locked` 而不跑测试：承诺的是 `cargo install` 能过，那条路本来就不编译
  测试。cargo 自己会在某个依赖要求比我们声明的更新的 rustc 时拒绝构建 —— 那才是真实
  会发生的漂移，一次 `cargo update` 就可能把某个依赖的地板抬到我们之上。

## [0.5.0] - 2026-08-19

### 把契约与实现对齐

> **升级提示**：`--repo` 和 `gitpic init` 现在会拒掉以前被接受的坏目标值 ——
> `--repo 'owner/re po'`、`--repo owner/..`，或在 `init` 的仓库/分支提示里填带空格的
> 值，都会报 `USAGE`（exit 2）。受影响的只有那些**本来就产不出可用链接**的调用：它们
> 此前的结局是一句光秃秃的 404，或者一个 gitpic 自己都拒绝加载的配置文件。

### 新增
- `gitpic doctor` 的报告现在带 `error` 对象（`{code, message}`，与其他子命令同形），
  `ok` 为 false 时必有、为 true 时必无。此前失败原因只存在于**退出码**里，而那是个
  agent 未必看得到的旁路信道：`gitpic doctor --json | jq` 会把它换成 jq 自己的 0
  （实测如此，管道语义与 harness 无关），而 `| jq` 恰好是 agent 解析 JSON 最常用的写法；
  有些 agent 框架的 shell 封装也根本不返回退出码。stdout 是解析这份报告的调用方一定
  拿到的通道，所以码也放到那里。退出码不变。
- "所有探测都答复、GitHub 就是说不行"这一支现在也有消息可读。它的 `PERMISSION_DENIED`
  是**合成**出来的（没有探测错误可抄），于是此前既没有 `error` 也没有 `detail` ——
  最常见的"能读不能写"结局，机器无从得知原因，人也看不到 note。`summarize` 改为把码和
  消息装在同一个 `AppError` 里，而不是两个各自为政的 `Option`，那正是它们能走散的原因。

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

### 文档
- 技能文档与两份 README 此前三处让 agent 去读 `doctor` 报告里的 `error.code`，来区分
  "分支不存在"(8) 与"没有写权限"(7) —— 而那个字段并不存在。字段现在补上了（见上），
  文档也写明该读它、而不是退出码，以及退出码为什么靠不住。
- "总是传 `--json` 和 `--no-copy`"与文档自己的示例矛盾。`--no-copy` 只在上传路径有
  意义，其余五个子命令会把它当 `USAGE`（2）拒掉，所以
  `gitpic doctor --json --no-copy` 是失败的。现在措辞改为只在上传命令上加它。
- `--json` 的例外不止 `init` 一个：`gitpic completion <shell>` 忽略它、照打几百行
  shell 脚本；`gitpic config edit` 忽略它并把 stdout 交给 `$EDITOR`（默认 `vi`），
  非 tty 下先吐一屏终端控制序列再吐信封。三个例外现在都写明了。
- `CONFIG_INVALID` 自 0.2.3 起就不再报行号（为避免回显可能含凭据的源码行，`Display`
  换成了 `message()`），但技能文档的退出码表和两份 README 都还承诺"指出出错的行"。
- `--quiet` 被写成通用规则，实际只有上传路径和 `gitpic list` 兑现；`doctor -q` 与
  `skill install -q` 照打人类可读输出。

### CI
- Release 的副标题不再接受 Keep a Changelog 的类目词。它取 changelog 段里第一个
  `### `，于是当那一段直接以「变更」或「安全」开头时，公开的 Release 标题就成了
  "gitpic v0.4.0 — 变更" —— 一个没有信息量的类目词，而不是这次发布的主题。现在
  命中类目词就让 job 失败，逼 changelog 先写一行主题；空副标题也从回落 "Release"
  改为失败。0.4.0 段补上了它缺的那行主题。

## [0.4.0] - 2026-08-19

### 凭据只来自 GitHub CLI

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

[未发布]: https://github.com/tarnish233/gitpic-cli/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.7.0
[0.6.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.6.0
[0.5.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.5.1
[0.5.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.5.0
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
