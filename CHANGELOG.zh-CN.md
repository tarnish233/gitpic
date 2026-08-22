# 更新日志

本项目的所有重要变更都会记录在此文件中。格式参考
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

## [0.13.0] - 2026-08-22

### 反馈回到动作发生的地方

这一版没有新功能，改的是 App 在**哪里**回话。三件事同一个毛病：反馈离动作太远。

### App

- **复制按钮自己报告，不再弹横幅、不再响一声。** 点一次行内的复制按钮，原先会发一条系统通知并播
  `.default` 声音 —— 而那个按钮就在光标底下。现在按钮上的图标就地变成对勾，停留 1 秒。**失败仍然
  走通知**，因为失败消息带着真正的诊断（比如分支含 `/` 时 jsDelivr 解析不了那一整句），塞不进一个
  角标；`Notifier` 本身一个字没改,上传结束照样有横幅有声音,那里"窗口通常是关着的"这个前提是成
  立的。这次改的正是这个前提不成立的地方：点行内按钮时窗口开着、指针就在按钮上。
  两个字形是**叠放**后靠透明度切换,不是条件替换 —— 实测 `doc.on.clipboard` 是 16×18pt、
  `checkmark` 是 14×13,条件替换会把右边的字节数右移 2pt、把行高缩掉 5pt。
- **缩略图到达不再是硬切,但只有真的等过才淡入。** 判据不是"是否命中缓存",而是**"占位符到底在
  屏幕上出现过没有"** —— 按 `.task` 里的实耗时间,门槛 100ms。实测热缓存下 33 张一次性答完只要
  4.0–6.6ms(最慢单行 6.5ms),全内存 0.1–0.2ms,所以 100ms 大约是最慢热行的 15 倍,又远低于任何
  网络往返。给缓存命中也淡入等于**在本来没有闪烁的地方造闪烁**,每次重开历史页都造一次。
- **App 第一次有了无障碍适配**(`Motion.swift`)。`accessibilityDisplayShouldReduceMotion` 在用到的
  那一刻读,不做观察 —— 屏幕上没有任何东西是从这个标志推导出来的,它只在缩略图落地的那一个瞬间被
  问一次。注意 reduce-motion 在这里**不等于"不淡入"**:没有位移的交叉淡入正是这个设置要求用来替代
  运动的东西,所以它仍然淡,只是更短、线性;缩放和 spring 在两个分支里都被排除。
- **历史页头部会说还有多少张没取回来**(`正在取缩略图 12/33`)。冷缓存下那 33 个灰框要坐约 4 秒,
  什么都不说的话,慢链路和坏掉是分不出来的。**热缓存下它一次都不会闪**,靠两个机制:缓存命中根本
  不进分母(计数发生在磁盘缓存的提前 return 之后、上限和 URL 守卫之后、拿 fetch 闸门之前,所以
  「正在取缩略图」是一句真话 —— 读磁盘不是取图);真实但极短的 episode 再压 300ms,因为规则一抓不
  住"刚上传那一张、链路 200ms 就回来了",那会闪一下 `0/1`。刻意**不加** `ProgressView`:它比这行
  文字高,会成为唯一真的改变头部高度的东西,而且每次开窗改两次。
- **菜单栏图标现在会表示"这张图我接"。** 系统本来就会在拖拽影像上画绿色 "+",所以接受与拒绝从来
  不是不可见的 —— 但那个角标跟着光标走,而且对屏幕上任何一个可复制目标都说同一句话,没有任何东西
  标出**这个**目标才是会接的那个。所以目标侧也变,而且只在接受侧变:**拒绝依然完全沉默**,系统自己
  的飞回动画比任何提示都说得清楚。悬停期间不做任何工作(`draggingUpdated` 一秒能触发约 78 次),
  图标只在进入/退出/结束的转折点上改。
- 去重角标那个写死的 7pt 换成了 `.caption2` + `.imageScale(.small)`。用 `ImageRenderer` 对着同一个
  44×32 的框实测:原先 13×16(占框高 50%),`.caption2` 裸用会变 17×20(62%,挤角还抢图),加上
  `.small` 落在 14×17(53%)。调的是布局旋钮,不是退回魔数。

### 修复

- **没装 `gitpic` 时,那个警告图标会被一次上传失败永久擦掉。** 找不到 CLI 时状态栏图标是警告三角,
  但缺工具本身产生的那条「找不到 gitpic」失败会走 `report`,而 `report` 无条件把图标写回空闲态 ——
  于是警告消失,而 `resolveTools` 只在启动跑一次,没有任何东西能把它恢复。这一版把图标的形状改对
  了(`StatusIcon`):一个 `State` 字段(空闲/上传中/工具缺失,所以两个状态不可能同时成立)加一个悬停
  标志,悬停结束后恢复的是**底下原本那个** —— 上传中恢复成箭头,没工具恢复成警告。`report` 收尾时
  去问 `restingState`,从 `AppModel.toolState` 读,不留第二份「工具找到了吗」去和第一份闹矛盾。

### 测试

- 新增 12 个用例(共 123):缩略图进度的记账 6 个、状态栏图标状态机 6 个。图标规则搬进了
  `GitPicCore` 才测得到 —— `GitPicApp` 是可执行 target,测试导不进去,这也是 `ImageDrop` 和
  `UploadReport` 当初搬过去的原因。
- 其中「迟到的订阅者」那条一开始是**靠睡 180ms** 落到"三个 120ms 请求里的第二个"上,然后断言已经
  有一张落地了。本机连跑五次都过,CI 上挂了 —— 那台 runner 上第一个请求没在这个窗口内完成,于是读
  到 0/3,把一个 store 其实守住了的断言判成失败。**能在所有机器上都安全的 sleep 是没人挑得出来
  的**,所以前提改成等事件:消费一个订阅直到 store 自己报出"有一张落地、还有别的没完",再去建第二个
  订阅做断言。延时从此只是余量而不是时序。修完在 8 个 CPU 占满进程的负载下也跑过。

## [0.12.0] - 2026-08-22

### 历史页现在看得见图，每张只取一次

### App

- **历史页每行现在有缩略图。** 之前一行只有一个 SF Symbol（`photo`，去重的行是 `doc.on.doc`），
  37 行长得一模一样 —— 想找某张图只能读文件名。现在每行左边是一个 44×32 的固定框，图按比例完整
  放进去。**不裁切**：截图被居中裁成方块就没剩下什么可看的了，代价是留白，所以那个框是一个可见
  的表面而不是什么都没有。宽度固定则是因为文字列的起点必须是同一个 x，这是一个上百行的列表唯一
  不能牺牲的东西。
- **历史里没有本地文件，所以缩略图是一次网络读取 —— 每张图一次，永久。** 一条记录只记
  `path`/`sha`/`size`，没有任何本地文件的痕迹（`src/commands/upload.rs:187-195`），而打开这个面板
  的时候源文件通常已经不在原处了。三层：内存按内容、磁盘按 blob sha、网络带闸门且去重。磁盘上存
  的是**解码并缩小之后**的 PNG，不是原图 —— 本机实测 13.3 MB 的原图换来 472 KB 的缓存，平均每张
  14 KB，29 倍。sha 是内容寻址的，所以这个缓存永不失效：`github.repo` 改了它还是同一张图，字节
  不一样了它就是另一个 key。
- **地址是 jsDelivr 优先、`raw.githubusercontent.com` 兜底。** 不是速度选择 —— 这点实测过，两个
  host 在这台机器上是平的：本机 33 张不重复的图，8 路并发各取两轮，jsDelivr 5.16s / 4.11s，raw
  6.03s / 3.59s。（单个文件重复取三次曾显示 jsDelivr 快 2–3 倍，TTFB 0.29–0.31s 对 0.79–0.94s；
  放到 33 张边缘冷的图上这个数字不成立。）CDN 在前是另外两个理由：它是配置默认指向的地址
  （`upload.link_kind = "cdn"`），面板走的就是用户发布出去的那个 host；而 jsDelivr 在取不到
  `raw.githubusercontent.com` 的网络里取得到。raw 在后面，因为它是不会缺席也不会落后的那个：分支
  含 `/` 时 jsDelivr 根本没有可解析的 ref，那种仓库直接只用 raw，一个多余请求都不发；而 jsDelivr
  解析 branch ref 走它自己的缓存，几分钟前刚上传的图 —— 也就是这个面板最上面那几行 —— 可能在它
  那儿 404，而 GitHub 正常服务。那次 404 只花一个请求，之后结果按内容缓存，不会再发生一次。两个
  都失败时报的是 raw 的答复，因为 CDN 的 404 在这里说明不了任何事。
- **打开这个面板会一次取完所有行：`Form` + `ForEach` 在 macOS 上不是懒加载。** 实测 —— 37 行的历史
  打开后什么都不碰、一下都不滚，33 张不重复的图全部进了缓存。所以并发数是唯一能决定冷启动要多久
  的数字，同样这 33 张：4 路 6.26s、8 路 4.11–5.16s、12 路 2.21s。定在 8 而不是 12 是礼貌，不是
  客户端限制 —— 这些图来自一个免费服务它们的 CDN，为一次性的成本省两秒，不值得做那个一口气开
  十二条连接的 app。
- **几条上限，都是写下来的而不是碰巧的**：原图超过 12 MB 不下载（记录里就有 `size`，所以连请求都
  不发）；缩略图长边 160 px（44×32 的框在 Retina 上要 88×64）；磁盘缓存 32 MB，超了按最旧的先删，
  和 CLI 的 `history::trim_file` 同一个形状；内存 120 张，够一整页 `list --limit 100`。
- **`sha` 会变成文件名，所以它必须先被验证。** 它是从 `history.jsonl` 读出来的 —— 一个任何进程都
  能写的追加文本文件 —— 马上要拼进目录路径，而 `appendingPathComponent` 不会拒绝
  `../../../../Library/Preferences/…`。只接受不超过 64 位的十六进制：SHA-1 的 40 位和以后 SHA-256
  的 64 位都进得来，分隔符、`.`、`..` 都进不来。
- **去重从图标变成了角标。** `deduped` 原先靠换图标表达（`doc.on.doc` 而不是 `photo`），缩略图占
  了那个位置。它是变成右下角的角标而不是被丢掉，因为去重的那行显示的是**和它去重的那行同一张
  图** —— 这恰好就是这个区分必须留在某处的原因。同一个 sha 的多行也只发一个请求：本机 37 行里有
  4 行是去重的，缓存里正好 33 个文件。
- 新增 `ThumbnailTests`（14 个用例，含一个数请求数的 `URLProtocol` 桩）：钉住「一张图只取一次」、
  「换个 store 同目录走磁盘不走网络」、「CDN 404 会落到 raw」、「两个都挂时报 raw 的答复」、
  「超限的原图连请求都不发」，以及 `sha` 的路径注入用例。

### CI

- **`scripts/build-app.sh` 的 Info.plist heredoc 不再执行注释里的三个词。** 那个 heredoc 是
  `<<PLIST` —— 不加引号,因为要展开 `$APP_VERSION` 和 `$CLI_VERSION` —— 而注释里写着
  \`Cancel\` / \`Open\` / \`Undo\`。未加引号的 heredoc 里反引号就是命令替换,所以每次构建都
  真的去执行了这三个名字:`Open` 在大小写不敏感的文件系统上命中 `/usr/bin/open`,于是构建日志里
  冒出一段 open 的用法说明和一行 `Undo: command not found`,而生成的 plist 里那三个词变成了空白。
  plist 始终是合法的、每个 key 也都是对的(`plutil -lint` 一直过),所以这个 bug 一直没露出来 ——
  但它会执行 PATH 里任何叫这三个名字的东西。按 `scripts/new-worktree.sh` 早就在用的写法转义,
  那份文件的作者显然知道这个坑。转义后实测:构建日志干净了,plist 里那三个词回来了,三处版本号
  照旧正确替换。

## [0.11.5] - 2026-08-22

### 名字归位：仓库和 cask 都叫 `gitpic`

**仓库从 `gitpic-cli` 改成了 [`gitpic`](https://github.com/tarnish233/gitpic)。** 这件事需要先腾名字：
纯 Swift 的老 App 仓库 `GitPic`（停在 2.0.5）占着它 —— GitHub 的仓库名**不区分大小写**，`GitPic` 和
`gitpic` 是同一个名字，而封存并不腾名字，封存之后仓库还只读、连改名都做不了。所以顺序只能是：先在老
仓库两份 README 顶部留一行指路，再把它改名成
[`GitPic-legacy`](https://github.com/tarnish233/GitPic-legacy)，最后封存。

旧 URL 由 GitHub 重定向，但**重定向不是名字**：仓库里 78 处引用全部改写了 —— 两份 changelog 的历史
release/compare 链接各 28 处、`Cargo.toml` 的 repository/homepage/documentation、两份 README、
`SKILL.md`、两个插件 manifest、App 关于页那个链接，以及 `docs/macos-app-plan.md` 目录树里的仓库根名。
你要输入的插件市场地址也跟着变成 `tarnish233/gitpic`。

**Homebrew 里 cask `gitpic_app` 改成 `gitpic`，同时删掉了 formula 的旧名映射。** 这两件事是一个包，
不能只做一半：映射还在的时候，cask 也叫 `gitpic` 会让这个名字永久二义 —— 实测 brew 会打印

    Warning: Treating …/gitpic as a formula. For the cask, use …/gitpic or specify the `--cask` flag.

它连替代写法都说不出来（两个 token 是同一个字符串），然后默默按 formula 处理。删掉映射之后，裸名字
干净地归 cask，零警告：

    brew install tarnish233/tap/gitpic       # App + 终端命令 gitpic（--cask 可省）
    brew install tarnish233/tap/gitpic_cli   # 只要命令行

所以 `brew install tarnish233/tap/gitpic` 的**含义变了**：以前装的是命令行，现在装的是 App —— 而 App
从 0.11.4 起本来就带命令行。已经装了 `gitpic_app` 的由 `cask_renames.json` 自动迁移（本机实测：
`Caskroom/gitpic` 成为实体，`gitpic_app` 留成兼容软链）。formula 那侧的旧名 `gitpic` 不再解析成
`gitpic_cli`，tap 的 README 里留了退路。

crate、二进制、skill 的名字都没动，构建方式和用法一个字没变。

### App

- 关于页里的仓库链接指向新地址 `github.com/tarnish233/gitpic`。
- 除此之外 App 没有代码改动。

## [0.11.4] - 2026-08-22

### App 那份 CLI 现在也是终端里那份

装了 App 又用 `brew install tarnish233/tap/gitpic_cli`，机器上就有两份同一个构建的 `gitpic`：装两次、
升两次，两次之间还可能对不上。现在 cask 把 App bundle 里那份软链成 `bin/gitpic`，并生成 bash、zsh、
fish 三份补全 —— **装 cask 就等于同时装了命令行**，而且升 App 就是升命令，版本对不上这件事从结构上
没有了。formula 留着：Linux、Intel Mac、CI，以及只想要命令行的人只能走它。

用的是 Homebrew 自己的 `generate_completions_from_executable`（cask 版，`cask/artifact/
generated_completion.rb`），不是 postflight 私自往 prefix 里写 —— 卸载时 brew 自己会清掉，实测
`brew uninstall --cask gitpic_app` 之后软链和三份补全一起没了。

两个都装会抢同一个 `bin/gitpic` 和同三份补全，两个方向都实测了：cask 先在 → formula 装得上但整个
没 link（`Error: The \`brew link\` step did not complete successfully`）；formula 先在 → cask 照样装完
App，只是打印 `skipping link` 和三条 `Will not overwrite`，而且 keg 里的文件一个字节没动（brew 自己
拦住了写穿软链，md5 比对过）。命令和补全归先到的那个，所以 README 现在写的是「装一个」，而不是之前
那句「两个都装也不冲突」。附带一个坑也记在 tap README 里：从「formula 先在」的状态卸掉 formula，
`bin/gitpic` 会直接消失（cask 当初跳过了没建），要 `brew reinstall --cask gitpic_app` 补回来。

**顺带修掉一个只在全新安装才出现的 bug**：去 quarantine 原来放在 `postflight`，而补全是**跑**那个
二进制生成的，postflight 又在 artifact 之后 —— 于是全新安装时 macOS 把还带着 quarantine 的自签名
二进制 SIGKILL 掉，三份补全一个都没生成（重装看不出来，因为重装用的是上一轮已经去过 quarantine 的
bundle）。现在移到 `preflight`、在 staging 目录里做，`app` 用 `mv` 搬走时那个「已清除」的状态跟着走。

## [0.11.3] - 2026-08-22

### 装的时候分得清：`gitpic_cli` 和 `gitpic_app`

CLI 和 App 一直是同一个版本、同一个 Release 里的两件东西，但 Homebrew 里只有一个名字叫
`gitpic`，于是 `brew install tarnish233/tap/gitpic` 装的是命令行还是菜单栏应用，只能靠猜。现在
两件都在 tap 里注册，名字各归各的：

    brew install tarnish233/tap/gitpic_cli         # 命令行，装出来的命令仍然是 gitpic
    brew install --cask tarnish233/tap/gitpic_app  # 菜单栏应用 GitPic.app

**用法一个字都没变。** formula 装的还是 `bin/gitpic`、还是那三份补全脚本、还是
`/opt/homebrew/bin/gitpic` 这个软链 —— 变的只有 formula 名和 Cellar 里的目录名。旧名字也没废：
tap 里留了一份 `formula_renames.json`，`brew install tarnish233/tap/gitpic` 照样能装，已经装了的
由 `brew update` / `brew upgrade` 迁移，也可以直接 `brew migrate gitpic`（本机实测：unlink → 把
`Cellar/gitpic` 移成 `Cellar/gitpic_cli` → relink，之后 `gitpic --version` 照旧）。

**两份 CLI 不会打架。** 装了 App 又装了 `gitpic_cli`，机器上确实有两个 `gitpic` 二进制，但它们
互不寻址：App 永远跑自己 bundle 里那份（`ToolDiscovery.locateGitpic` 先看
`Contents/Resources/gitpic` 并直接返回，PATH 上那份只在没有 bundle 的 `swift run` 开发场景兜底
—— 启动日志实测 `gitpic=/Applications/GitPic.app/Contents/Resources/gitpic`），brew 那份只服务
终端。共享的是 `~/.config/gitpic/config.toml` 和 `~/.local/share/gitpic/history.jsonl`，而那是
设计：在 App 里改仓库，终端里的 `gitpic` 立刻照新的走；从菜单栏传的图，`gitpic list` 里就看得
到。唯一要留意的是别让两边版本拉开太远 —— 配置是严格校验的，新版本写进去的键旧版本会拒。

tap 里每六小时跑一次的 updater 现在同时改 formula 和 cask。它读 `releases/latest`，失败不报警，
所以改名之后路径写错会**静默**失效：拿假 tag 和假 sha 重放了一遍，三处 url、三个 sha256 加 cask
的 version/sha256 都被正确改写才推的。

### App

- **可以用 brew 装了**：`brew install --cask tarnish233/tap/gitpic_app`，升级是
  `brew upgrade --cask gitpic_app`。App 是本机自签名、未经 Apple 公证的，所以 cask 装完自己把
  quarantine 去掉 —— README 里那条要手抄的 `xattr -dr com.apple.quarantine` 现在归 brew 做。
- `zap` 只清 App 自己的东西（`~/Library/Preferences/dev.gitpic.app.plist`、`Logs/GitPic.log`、
  Caches、HTTPStorages、Saved Application State），**不动** `~/.config/gitpic` 和上传历史 —— 那
  两份是和 CLI 共用的，删掉等于把终端那边也一并清了。
- App 本体没有代码改动，版本号跟着仓库走。

## [0.11.2] - 2026-08-22

### 窗口的两处装配件，和平台不一样

**侧边栏折叠按钮之前根本没有。** 补回来不只是「别隐藏它」：`columnVisibility` 原本是
`.constant(.all)`，按钮放上去也是个按了没反应的东西。现在它是一个真的 `@State` 绑定，
`.toolbar(removing: .sidebarToggle)` 去掉，侧边栏能收起也能回来 —— 实测点它：AX 描述在
「隐藏边栏 / 显示边栏」之间翻，四行面板列表随之消失和回来，侧边栏收起后按钮移到工具栏里紧挨着
前进/后退，也就是「密码」和「邮件」放它的位置。

**刷新按钮是个宽了一倍、图标偏在一边的胶囊** —— 这是 0.11.1 自己造的。那一版为了不让工具栏在
开工时重排，把一个隐藏的转圈常驻在按钮旁边，而隐藏的视图照样参与布局：按钮和这个看不见的转圈
共用一个玻璃胶囊，于是胶囊按两个控件的宽度算，箭头落在其中半边，跟「放弃」「保存」都不一样。

现在转圈画在按钮**内部**、替掉那个箭头，两种状态共用一个 16×16 的盒子。一个控件、一个胶囊、
两种状态同宽：实测空闲时和连通性测试跑着的时候，按钮都是 44pt 宽、x=1152，其他工具栏项的位置
也都不动 —— 0.11.1 那条理由仍然成立，因为不再往工具栏里插东西。

### App

- **侧边栏可以折叠了。** 见上：真绑定 + 系统自带的切换按钮，不是自制控件。
- **刷新按钮回到图标按钮该有的样子**：圆形、和「放弃」「保存」同高，图标居中；开工时它自己变成
  转圈，尺寸不变。

## [0.11.1] - 2026-08-22

### 打开设置窗口的那半秒，几乎和设置无关

窗口开得慢，而且开的一瞬间工具栏的「刷新」和图床页的「连通性测试」会自己动一下。两件事都不是
观感问题，实测（本机，每次打开）：

    NSHostingController(rootView: SettingsWindowView())   首次 338ms，之后每次 133–172ms
    super.showWindow + 上屏                                44–91ms
    showWindow 返回之后主线程还在忙                            176ms
    reload（三次 gitpic 调用）                              115–154ms

窗口每次都是从头建的 —— `windowWillClose` 把 controller 释放了，于是每次打开都重新搭一遍整棵
SwiftUI 树。现在只建一次（启动时，在主循环自己的一轮里，没有任何点击在等它）然后留着：之后每次
打开 `build=0ms`、`showWindow=20–28ms`、主线程 26–35ms 内安静下来。

而抖动是「进度报告」造成的：`busy` 一变，刷新和连通性测试就变灰再变回来；更糟的是那个转圈是
**插进**工具栏、结束时再删掉的，AppKit 因此重排，刷新/放弃/保存 整排左右滑一下再滑回来 —— 报告
把它正在报告的控件挪动了。现在 `busy` 的含义是「跑过 250ms 还没完」：开窗那次 reload 根本到不了
这条线，所以什么都不变；而保存（每个改动键一个进程）、上传、连通性测试会越过它，照旧转圈。

### App

- **设置窗口只建一次，之后打开是直接显示。** `SettingsWindowController.prewarm()` 在启动时
  建好窗口（状态栏图标先上屏，这是启动时用户真正在等的东西），`windowWillClose` 不再把它释放。
  释放原本捎带了一件值得留的事 —— 关掉窗口，前进/后退的足迹就作废，和系统设置一样；那原先是
  销毁 `@State` 的副作用，现在明说：足迹搬到 `SettingsNavigation`（它比一次开窗更长命），由
  `endSession()` 在关窗时清掉。实测：切一次面板「返回」亮起；关掉重开，它在你离开的那一页上是灰的。
- **`config path` 从「每次 reload 一次」改成「每次启动一次」。** 一整个进程，换一个在本次运行里
  不可能变的答案（路径来自 `XDG_CONFIG_HOME` 和家目录，而 `rebuildConfig()` 是把文件改名留在
  原地）。它还是这串调用里最贵的一个：~120ms 里占 ~90ms，因为一轮里的第一次 spawn 还要等主线程
  画完窗口第一帧。现在一次 reload 是 16–24ms。
- **转圈常驻工具栏，只是有时不可见。** 之前是按需插入/删除，所以它一出现就把旁边的按钮推走。
  现在只改 `opacity`，布局不动。实测（AX）：窗口出现那一瞬间和 2.5 秒后，五个工具栏按钮的 x 坐标
  和 enabled 状态逐一相同 —— 832 / 873 / 1155 / 1196 / 1246，刷新全程可用。
- **「刷新」在读取期间不再变灰。** `reload()` 是幂等的，而且每次调用都过 `GitpicRunner` 的串行
  闸门，所以再按一下是排队而不是并发；多读一次比一个会闪的按钮划算。

## [0.11.0] - 2026-08-21

### 窗口就是设置，快捷键交还给系统

这一版全部是 app 侧的，CLI 一行未改。四件事是同一类账：名字、平台惯例，以及界面上写着的话
和它实际做的事不一致。

窗口一直叫「主窗口」，而它从头到尾只做一件事——改配置。所以菜单项改成「打开设置…」，图标从
`macwindow` 换成 `gearshape`，标题栏主标题固定「设置」、副标题跟着面板。系统设置的标题栏只写
面板名，因为它有 Dock 图标和应用菜单交代自己是谁；这个 app 是 `.accessory`，两样都没有，只写
「图床」的话，屏幕上就没有任何东西说明这是哪个窗口、以及它是改设置的地方。

上传页的「自动复制到剪贴板」此前标着「仅 CLI」，说明里承认「对 App 无效」——一个设置项在自己
的界面上声明自己是装饰。现在 app 读同一个键。复制动作仍然留在 app 这边，因为 `--json` 不写
剪贴板是故意的（`upload.rs` 把写入限制在 `Mode::Human`，`--quiet` 也在外）：别人脚本里的
`gitpic upload --json` 不该覆盖他剪贴板上的东西。对齐的是行为，不是把副作用塞进机器模式。

设置窗口里 ⌘W、⌘Q、⌘M、⌘C、⌘V、⌘Z 全是死的，因为这些键由**主菜单**的 key equivalent 派发，
而这个 app 从来没有主菜单——它是 `.accessory`，自己的菜单栏平时不画出来，于是也就没人建过。
最难发现的一条在文本框：它们自己不实现编辑命令，是「编辑」菜单把 `copy:`/`paste:`/`undo:` 发给
第一响应者的，所以焦点确实落在 Owner 框上（实测 `AXFocusedUIElement` = `AXTextField`）时，
⌘A ⌘C 也复制不出任何东西。

### App

- **「主窗口」从名字到类型都改叫「设置」。** 菜单项「打开主窗口…」→「打开设置…」，图标
  `macwindow` → `gearshape`（前者描述的是形状，而形状不说明点下去会发生什么）；
  `MainWindowController` / `MainWindowView` / `MainTab` / `MainNavigation` 依次改名为
  `SettingsWindowController` / `SettingsWindowView` / `SettingsTab` / `SettingsNavigation`。
  标题栏改成主标题「设置」加副标题当前面板，理由见上。**一处故意没跟着改**：
  `setFrameAutosaveName("GitPicMainWindow")` 保留旧拼写 —— 它是 UserDefaults 的键
  （`NSWindow Frame GitPicMainWindow`），不是给人看的名字；改了会让已经存在的窗口忘掉自己的
  大小和位置，代价真实而收益为零。
- **装了一条标准主菜单，设置窗口里的系统快捷键终于响应。** 三个菜单：GitPic（关于、设置… ⌘,、
  隐藏、退出 ⌘Q）、编辑（撤销/重做、剪切/拷贝/粘贴/删除/全选）、窗口（关闭 ⌘W、最小化 ⌘M、
  缩放，窗口列表交给 `NSApp.windowsMenu`）。里面没有一条自定义绑定：标准标题、标准 selector、
  标准快捷键，动作发给当前的第一响应者——这一层的「交给系统」就是这个意思。「关闭」放在「窗口」
  而不是新造一个只装一条的「文件」菜单，因为这个 app 没有文件操作，系统设置也是这么处理的。
  **这不等于全局热键**：主菜单的快捷键只在本 app 最前台时响应，对 `.accessory` app 来说就是
  只在它自己的窗口开着时；状态栏菜单仍然一个快捷键都不带，理由没变（那些看起来像全局的，
  其实不是）。⌘R 接到工具栏的「刷新」上——它和 ⌘S 一样由 SwiftUI 在窗口内部派发，这也正是
  没有主菜单的那段时间里唯一还能用的两个键。
- **`upload.auto_copy` 现在 app 也听，不再自称「仅 CLI」。** 开关标题去掉了那个括号，说明改成
  实话；关掉之后 app 不写剪贴板，链接仍在「最近上传」和「历史」里，随时能手动复制。配置读不出来
  时默认按 `true`，与 CLI 对一份缺失文件的默认一致。顺带把复制结果从 `Bool` 换成三态
  `ClipboardOutcome`（`written` / `failed` / `suppressed`）：此前「没去复制」和「复制失败」
  共用一句「上传成功，但写剪贴板失败」，等于把一个正常工作的开关报成故障。现在关着开关上传，
  报告是「N 张已上传，未自动复制。链接在「最近上传」里」——是成功，但绝不声称复制了。
- **bundle 声明 `zh-Hans`，系统提供的那半边 UI 跟着中文走。** AppKit 是拿 bundle 声明的语言
  来挑它自己那套字符串的，而一个什么都不声明的 bundle 被当成英文的——所以一个中文 app 会弹出
  `Cancel` / `Open`，「编辑」菜单里的 `Undo` 挤在 剪切/拷贝/粘贴 中间。Info.plist 补上
  `CFBundleDevelopmentRegion` 与 `CFBundleLocalizations` 之后，文件选择框是「取消」/「打开」、
  边栏是「最近使用」/「个人收藏」，撤销显示「撤销键入」，连系统自己追加的「自动填充」/
  「开始听写…」/「表情与符号」也一并中文。只声明 `zh-Hans` 而不加 `en`：这里没有英文界面可以
  退回去，给一种语言到底好过中文面板配英文按钮。

## [0.10.0] - 2026-08-21

### 配置这件事，现在能在窗口里做完

起因是一行过期的 `github.token`——0.5.0 起就不再接受的字段。`config get` 老老实实回了
`CONFIG_INVALID`，还指名了是哪个键、哪个文件；App 却把这个完好的错误信封当成了无法解析的输出：
`ConfigEnvelope` 声明 `config` 非可选，解码失败，于是整件事塌成一句「读取配置失败。」外加一个
按多少次都不会改变答案的「重试」。图床、上传、历史三个面板同时空白，窗口底部那行状态栏显示
`undecodable(status: 10, raw: "{\n \"ok\": false,…` ——被截断的 JSON 当解释用。

真正致命的是没有出路。CLI 每一个**写**配置的子命令都以 `Config::load()` 开头，正是失败的那一
步，所以 `config set` 救不了一个它自己都读不动的文件；而 `init` 是交互式的，GUI 调不了。也就是
说：配置一坏，就只能回终端手改文件——一个 GUI 应用把用户赶回命令行。

这一版把三件事补齐了。**错误信封在 `GitpicRunner` 一处统一解码**（`doctor` 和分批上传不受影响：
它们的 `error` 本来就是可选的，按数据处理，永远走不到这个回退分支），面板说出 CLI 的原话，并给出
一个真会改变答案的动作——「备份并重建」把不能解析的文件改名留在原地，然后表单重新可编辑。**复制
形态成了配置**：新增 `upload.format`（第 11 个键），和 `upload.link_kind` 一起决定 App 复制出
什么、以及终端里 `gitpic` 的默认值——此前它只活在内存里，每次启动都回到 Markdown · CDN，菜单的
勾选还会和窗口各说各话。**设置窗口按 macOS 26 的规范重做**：工具栏的前进/后退、标题跟随面板、
历史面板改用和其他面板同一个容器（它此前左右各溢出 11pt，从没和任何东西对齐）。

窗口底部那条状态栏整块删了，结果只走系统通知。

### 新增

- **`upload.format` —— 第 11 个配置键，`--format` 的默认值。** 取值 `md` | `html` | `url`，
  和 `--format` 的三个写法逐字相同。此前「输出什么语法」只能靠每次敲 `-f`：`link_kind` 早就是
  配置项，格式却不是，所以「我总是要 HTML」这件事在配置文件里表达不出来。现在
  `effective_format` 先看 flag、再看配置、最后才落到 md —— flag 保持 `Option` 的意义正在
  于此，「用户明确要了 md」和「谁都没说」必须分得开，只有后者才轮到文件说话。
  非法值一律拒绝（`parse_output_format_strict`，与 `parse_link_kind_strict` 同一套做法）：
  手改文件成 `htlm` 是 `CONFIG_INVALID` 并指名 `upload.format`，`config set upload.format htlm`
  是 `USAGE`。生成的新配置里 `format` 紧挨着 `link_kind`，因为这两个键回答的是同一个问题的两半。

  **升级提示**：0.9.0 及更早的 `gitpic` 不认识这个键 —— 配置是 `deny_unknown_fields` 的，所以
  一份带 `format` 的配置会被旧版本整份拒绝。App 与 CLI 同版本发布，装了新版就都认；但如果机器上
  还留着旧的 `gitpic`，它会报 `CONFIG_INVALID`。

### App

- **「复制格式」从历史页搬到上传页，并且变成了真正的配置。** 两个维度现在绑
  `upload.format` 与 `upload.link_kind`：窗口里它们和其他设置一样走 draft、由右上角「保存」
  写入、「放弃」可撤；状态栏菜单里改是即时写入（菜单没有、也放不下一个「保存」，点一下就是全部
  交互）。原先上传页那一行「CLI 默认地址」没了 —— 同一个地址有两个控件、其中一个还得在说明里
  自称「对 App 无效」，这才是要收掉的东西。现在 App 复制的 snippet 和终端里 gitpic 的默认值
  取的是同一份配置。
- **`linkForm` 不再是内存里的一份状态，而是从已保存配置派生出来的。** 此前它每次启动都回到
  Markdown · CDN（不管配置怎么写），而且菜单的勾选和窗口可以各说各话 —— 实测：窗口切成
  「纯链接 · Raw」之后菜单仍显示 Markdown ✓ / CDN ✓，复制行为是对的（两边读同一个变量），只有
  勾在骗人。现在只有一个答案，而且 `onConfigChange` 会在配置变化后重建菜单，包括变化来自两个
  面板之外的「保存」。
- **配置读不出来时，说得出原因。** `RunFailure` 新增 `.cli(status:error:)`，携带 CLI 自己的
  `ErrorCode` 与消息；`GitpicRunner.runJSON` 先按本命令的载荷解，解不动再按错误信封解。分支顺序
  是有意的：`doctor` 和部分成功的 `upload` 都把 `error` 声明为可选，所以它们把 `ok:false` 当**数
  据**解掉，根本到不了这里；载荷非可选的 `config get` 和 `list` 才会走到，而它们此前正是把
  `{ok:false,error:…}` 变成 `undecodable` 的两个。面板显示的是 CLI 的原话——它已经点明了文件和
  出问题的键，比任何转述都准，而且 `src/config.rs` 有测试钉住被拒的 `token` 不会连值一起打印，
  所以照搬是安全的。
- **配置坏掉时，GUI 给得出出路：「备份并重建」。** 原文件在同目录改名保留
  （`config.toml.broken-<时间戳>`），不删除——`owner`/`repo`/`branch` 大概率还是对的，备份就是抄回
  它们的地方。移开之后 `config get` 返回一份默认配置（缺文件不是错误，见 `src/config.rs`），表单
  重新可编辑，「保存」照常一键一个 `config set` 写下去。重命名由 App 做，因为没有子命令能做：所有
  配置写入都从 `Config::load()` 开始。**只改名，从不读取**：0.5.0 之前的配置里还躺着
  `github.token`，把内容显示到窗口里或塞进通知就是把一个可能仍然有效的凭据摆到屏幕上——CLI 在错误
  消息里守住了这条线，App 不该成为它拒绝成为的那个泄漏点。
- **只有「文件本身读不动」才提供重建。** `CONFIG_INVALID` 意味着文件在、文本有问题，改名能解决；
  `spawnFailed`、非信封输出、`CONFIG_MISSING` 都与文件内容无关，对它们提供重命名等于毁掉一份能用
  的配置去修一个不存在的问题。
- **空白表单现在说得出自己是干什么的。** Owner 或 Repo 任一为空时，图床面板直接说明：填好这两项、
  按右上角「保存」，以及凭据不在这里配（`gh auth token`，需要先 `gh auth login`）。两条路都会到达
  这个状态——从没跑过 `init` 的机器（缺文件读回来是默认值，不是错误），和刚做完重建的机器。
- **上传面板不再只是一句「读取配置失败」。** 同一个原因、同样的原话，外加一个「去『图床』处理」的
  跳转——修复动作只在拥有配置的那个面板里存在一份。
- **历史面板改用和其他面板同一个 grouped Form 容器，它此前根本没和任何东西对齐。** 原先是裸的
  `VStack` + `List`，两个毛病：一是 `VStack` 只有在某个子视图贪心时才撑开，而
  `ContentUnavailableView` 只报理想高度、不填充 —— 历史为空时没东西撑开这个栈，它保持内容尺寸、
  被 detail 列整体垂直居中，格式切换器就浮在面板正中（有记录时 `List` 是贪心的，正好把这个遮
  住）；二是即使有记录也是歪的：`Form` 会遵守 detail 列自己的边距，裸 `List` 不会。实测本机这个
  窗口 —— 表单面板内容在 x=847、滚动区从 827 起（左右各内缩 20pt），而列表的滚动区从 816 起、
  宽 494，左边 11pt 钻到分栏分隔线底下、右边 11pt 溢出窗口右沿。手工补 padding 意味着把那个 11
  硬编码进去，还要在每个窗口尺寸下重新推导一遍；换成其他面板用的容器则是零成本且不会漂移，现在
  三个面板的滚动区与 section 是同一组数字（828/472、848/432）。
  代价写在这里：格式切换器从顶部固定条变成随内容滚动的两行 Form —— 状态栏菜单里那两项共享同一个
  `linkForm`，所以它不是唯一入口，而固定条正是当初逼出手工对齐的原因。
- **两个 segmented picker 一行一个，都不带 `.fixedSize()`。** 挤在同一个 Form 行里活不下来：
  行会多出一个标签列，而两个不肯压缩的分段控件把内容撑到 920pt（窗口宽 680）—— 实测 —— 侧栏被
  压成一条，大小与复制两列被顶出右沿。Form 行把标签放进自己的列、控件占值列，这才是能放下的布局。
- **历史为空的时候不再撒谎。** 历史和配置是同一次 `reload()` 读的，配置在前——所以一个读不动的配置
  会把历史一起带走，此时的空列表与「有没有上传过」毫无关系。现在这种情况显示「读不到历史」加原因
  加两个动作，而「N 条」计数在读取失败时干脆不显示：0 条摆在一个失败旁边，读起来像是关于历史的事
  实，而它不是。
- **窗口底部的状态栏整块删除，结果只依赖 macOS 通知。** 它原本兼着两件事：一行状态文字，和
  保存/放弃两个按钮。文字是删掉而不是搬走——结果是事件，而出事时这个窗口通常是关着的，通知中心本来
  就是 App 报告上传结果的地方，两个surface说同一件事的结果是底下那个基本上是过期的。它唯一独有的
  内容（配置读取失败）现在说在拥有它的面板里、紧挨着能修它的按钮。按钮移到了工具栏，仍然是无改动
  时变灰而不是消失，⌘S 照旧。代价如实记在这里：通知权限被拒时，结果只到
  `~/Library/Logs/GitPic.log`——所以每条通知现在也会写一行日志。
- **窗口按 macOS 26 设置窗口的规范补齐了缺的几处。** 骨架本来就对（`.fullSizeContentView`
  的 `NSWindowController`、balanced 的 `NavigationSplitView`、grouped Form 三件套、
  `.accessory` 应用的激活策略引用计数），这次补的是：工具栏左侧的**前进/后退导航历史**（侧栏
  一步能到任意面板，所以这两个键的用处是「回到刚才那页」，与系统设置一致）；
  **窗口标题跟随当前面板**（侧栏的 `navigationTitle` 是应用叫什么，标题栏是你正在看什么）；
  以及 detail 面板显式 `alignment: .topLeading`。
- **detail 面板的对齐从「一个面板一个补丁」升级成规则。** 历史面板那个「控件条浮在窗口正中」
  的 bug，根因是内容比窗口短时 detail 列会把它整体居中；上一条修的是历史面板自己。现在
  `.topLeading` 加在面板路由那一层，下一个面板不必重新踩一遍。
- **四个 Toggle 显式声明 `.toggleStyle(.switch)`。** grouped Form 里的 Toggle 本来就渲染成
  开关，但样式是继承的 —— 上游任何一处 `.toggleStyle` 都能把它们悄悄变成复选框。
- **次要按钮统一 `.controlSize(.small)`。** 连通性测试、配置修复那三个、在 Finder 中显示备份、
  显示日志 —— 它们是行内动作，不是那一行的主角。
- **「关于」多了一节「项目」**：一句话说清 CLI 与 App 同仓库同版本、凭据只过 GitHub CLI、配置
  文件不存密钥，加一条仓库链接。
- **连通性测试跑不起来时，说在它自己那一节里。** 此前它去了窗口底部那行状态，离触发它的按钮两个
  面板远；也和「报告回来说不健康」区分开——后者是另一个分支。

## [0.9.0] - 2026-08-21

### 「链接格式」其实是两个选择

这一版还是 app 侧的。CLI 一行未改，版本号跟着走是 0.6.0 起「一个版本、一个 Release」的结果。

菜单里那个四选一的「链接格式」——Markdown / HTML / CDN URL / Raw URL——看着像一组备选项，
其实是把两件互不相干的事挤在了一个下拉框里：**snippet 用什么语法包裹**，和**链接指向哪个
主机**。CLI 从一开始就是两个独立的 flag（`--format` × `--link`），app 这边却塌成了一个。

代价是实打实的两条。六种组合里有两种根本没有入口，「Markdown 包裹 raw 链接」选不出来；而历史
面板的「CDN URL」直接返回 `record.url`，也就是 `upload.link_kind` 恰好选中的那个地址——所以
配置成 `raw` 时，它在一个写着 CDN 的标签下交回一条 `raw.githubusercontent.com` 链接。

现在是两个各自独立的维度，六种组合都能选，而且切换不会重新上传。顺带把 `src/link.rs` 移植到
了 Swift，因为信封里只有一个地址；转义规则一起移植，历史面板原先用裸插值拼 Markdown，文件名
里一个 `]` 就能拼出坏链接。

### App

- **「链接格式」拆成两个各自独立的维度：语法 × 地址。** 原先是一个四选一的扁平枚举
  （Markdown / HTML / CDN URL / Raw URL），而它并不是对任何东西的拆分：`markdown` 和 `html`
  用的是 `upload.link_kind` 恰好选中的那个地址，`cdn` 和 `raw` 则是裸链接。后果有两个，都是真
  的 —— **「Markdown 包裹 raw 链接」根本没有对应项**，六种组合里有两种无法表达；而历史面板的
  `cdn` 分支直接返回 `record.url`，也就是 `link_kind` 选中的那个地址，所以配置成 `raw` 时，
  「CDN URL」在一个写着 CDN 的标签下交回一条 `raw.githubusercontent.com` 链接。CLI 从来就是
  两个独立的 flag（`--format` × `--link`），现在 app 与之对齐。
- **这个选择现在由菜单和窗口共用。** 之前状态栏菜单和历史面板各存一份，于是在菜单里选了 HTML，
  窗口那边仍然在复制 Markdown，而界面上没有任何地方解释这个分歧。
- **`src/link.rs` 移植到 Swift，因为信封里只有一个地址。** `ItemResult.url` 是
  `upload.link_kind` 选中的那一种，所以配置成 `raw` 的图床根本不会产出任何 jsDelivr 链接；
  `list --json` 更窄 —— 每行一个 URL，且不记录它是哪一种。转义规则一并移植：历史面板原先用
  `"![\(r.name)](\(r.url))"` 这样的裸插值拼 Markdown，文件名里一个 `]` 或 `(` 就会提前终止
  标签、产出坏掉的 Markdown。两个转义器都按 `unicodeScalars` 遍历以对齐 Rust 的 `chars()`：
  按 `Character` 遍历会把 `\r\n` 合成一个字素，只吐一个空格，而 CLI 吐两个。
- **两个地址在上传落地时就解析完成，而不是等到复制时。** URL 由 `github.owner/repo/branch`
  拼出，若延后到复制时再推导，十分钟前的那条菜单项会悄悄指向那次上传从未用过的目标。
- **含 `/` 的分支不再产出 CDN 链接，而不是产出一条死链。** jsDelivr 把 ref 编码成
  `repo@branch/path`，分支里的 `/` 让 branch 与 path 的边界无法解析，链接必然 404 —— CLI 为此
  直接拒绝上传（`reject_dead_cdn_link`）。但 app 现在自己拼 CDN 地址，而 `--link raw` 配在
  `feat/x` 分支上是能正常上传的，于是同一个谓词不移植过来，app 就会亲手造出 CLI 拒绝打印的那
  条死链。缺少 CDN 地址时**原因随之传递**：读不到配置和分支含 `/` 需要用户做的事完全不同，把
  后者报成前者是一条会让用户去查错地方的提示。
- **窗口打开时不再把光标放在 Owner 里。** AppKit 会把初始焦点交给键盘循环里的第一个视图，这里
  正好是 Owner 输入框 —— 于是窗口一开，插入符就在里面、值处于全选状态，再按一个键就把一个能用
  的图床 owner 换成了随手输入的内容。
- **Return 不再保存，底部的「保存」成为唯一路径。** 相应地，配置面板上的状态栏改为常驻、按钮置
  灰而不是整条出现又消失 —— 一个「只有你已经改过东西才出现」的按钮，没法告诉你保存要点它；而
  一条会随输入改变宽度的状态栏，会把按钮从指针底下挪走。
- **「关于」页加上 app 自己的图标**，通过 `NSImage.applicationIconName` 从 bundle 里读回，因此
  显示的是真正打包进去的那个图标，而不是第二份可能漂移的副本。

## [0.8.0] - 2026-08-21

### 拖一张图到菜单栏图标

这一版全部是 app 侧的。CLI 一行未改，版本号跟着走是 0.6.0 起「一个版本、一个 Release」
的结果。

app 之前有三个上传入口，没有一个是拖拽 —— 唯一为此设计的刘海面板从未通过验收，以默认关闭
的形态搁置在树里，于是任何地方都接不了拖拽。现在落区做在菜单栏图标上：拖一张图上去就传，
点它照样弹菜单。刘海的两个文件（366 行）连同它们记录的平台实测一起清理，实测结论保留在
`docs/macos-app-plan.md`。

同时上传结果改走系统通知，因为那是用户可能已经离开屏幕时发生的事；而「正在上传」仍然由
图标表示，因为那是一个有自然终点的状态。

### App

- **菜单栏图标现在是拖拽落区：拖一张图上去就能上传。** 之前 app 根本没有任何落区。刘海面板
  本来是为此设计的，但它从未通过验收 —— 合成一次真实的 Finder→面板拖拽需要辅助功能授权下的
  CGEvent 序列，所以它以 `NotchDropZone` 默认关闭的形态搁置，结果没有任何地方能接拖拽。
  `docs/macos-app-plan.md` 早已把「拖到菜单栏图标上」列为最省的替代方案，而探针在这台机器上
  实测确认它可行：往 `statusItem.button` 上挂一个注册了 `.fileURL` 的子视图，真实 Finder 拖拽
  收得到，**而且**点击图标仍然弹出菜单 —— 前提是不要去覆写 `hitTest`。旧的刘海落区视图覆写了
  它、把所有事件留给自己，那套做法用在状态栏图标上会让菜单再也打不开。
- **一次拖拽只接受一张图片，否则在开始之前就被拒。** 多个文件、非图片、文件夹，都会让
  `draggingEntered` 返回空操作：图标不高亮，系统播放它自己的飞回动画。这推翻了已删除的刘海
  落区视图写下的决定 —— 它当时以「CLI 自己也不做内容校验」为由接受任何文件类型。两点压过了
  那个理由：另外两个上传入口本来就只收图片，不过滤的那个才是异类；而拖拽没有撤销机会，等一个
  错文件传上去，它已经是图床仓库里的一次提交了。
- **上传结果改走系统通知，刘海整个删除。** 状态栏图标仍然在上传进行中改变形态，因为那是一个
  有自然终点的**状态**；而**发生了什么**由横幅送达，因为那是用户可能已经离开屏幕的**事件**。
  `NotchPanel.swift` 与 `NotchShape.swift` 已删除（366 行）；它们注释里记录的 C2/C3 实测结论
  保留在 `docs/macos-app-plan.md` 中，其中 C3 对新落区依然生效。
- **图标复位定时器和它的守卫 token 是删掉、而不是搬走。** 图标原先由一个 2.6 秒的任务恢复，
  为此需要一个 token 防止过期的复位擦掉更新的消息。现在由结果本身直接复位图标，没有定时器可
  竞争，也就没有什么需要守卫。`AppModel.clearStatus(_:from:)` 跟着一起走了 —— 它唯一的调用者
  就是那个任务。
- **上传结果文案现在有测试覆盖了。** 它的四种结果 —— 单张、多张、部分成功、以及上传成功但写
  剪贴板失败 —— 原先内联在 app 层，而那一层没有任何测试能 import。现在行为不变地搬到了
  `GitPicCore` 的 `UploadPresentation.report`，其中最要紧的一条被锁住了：写剪贴板失败绝不能
  报成成功，否则用户去粘贴陈旧内容，而且永远不知道为什么。

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
- 新增 Claude Code 插件市场清单，可用 `/plugin marketplace add tarnish233/gitpic`
  安装。
- 新增 Codex 插件清单，可用 `codex plugin marketplace add tarnish233/gitpic` 安装。

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

[未发布]: https://github.com/tarnish233/gitpic/compare/v0.13.0...HEAD
[0.13.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.13.0
[0.12.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.12.0
[0.11.5]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.5
[0.11.4]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.4
[0.11.3]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.3
[0.11.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.2
[0.11.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.1
[0.11.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.0
[0.10.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.10.0
[0.9.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.9.0
[0.8.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.8.0
[0.7.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.7.0
[0.6.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.6.0
[0.5.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.5.1
[0.5.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.5.0
[0.4.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.4.0
[0.3.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.3.0
[0.2.3]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.3
[0.2.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.2
[0.2.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.1
[0.2.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.0
[0.1.6]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.6
[0.1.5]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.5
[0.1.4]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.4
[0.1.3]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.3
[0.1.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.2
[0.1.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.1
[0.1.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.0
