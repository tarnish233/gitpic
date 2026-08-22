# gitpic macOS App — 设计方案

> 状态：设计定稿，待实现。基线 CLI `gitpic 0.5.1`。
> 本文件里每一条"约束"都是在这台机器上**实测**得到的，不是推断。测法一并记录，便于日后复核。

## 1. 实测硬约束

这五条决定了方案的形状。前两条如果没提前测出来，会在实现到一半时把设计推翻。

### C1 — Finder 启动的 app 拿不到用户 PATH，因此找不到 `gh`

```
launchctl getenv PATH                     → (空)
Finder 启动的 .app 内 ProcessInfo.PATH     → /usr/bin:/bin:/usr/sbin:/sbin
该环境下 `which gh`                        → (空)
`/bin/zsh -l -c 'command -v gh'`          → /opt/homebrew/bin/gh   ✅ 可用作兜底
```

测法：`osascript -e 'tell application "Finder" to open POSIX file …'` 启动探针 app，让 Finder 当父进程。
**注意**：用 `open Probe.app` 测是错的——`open` 会把调用方（终端）的环境传播进去，PATH 完整、`gh` 能找到，测出来是假阴性。必须由 Finder 启动。

影响：`src/auth.rs:49` 是 `Command::new("gh")` 裸名 PATH 查找，无绝对路径兜底、无配置项可覆盖；而 v0.4.0 之后 gitpic 的凭据**只**来自 `gh auth token`。所以 Finder 启动的 GUI 直接 spawn `gitpic` 会 100% 拿不到 token，报 `CONFIG_MISSING`（exit 3）。→ 见 §3。

### C2 — 菜单栏那 32px 是系统保留区，任何 window level 的面板都收不到鼠标/拖拽事件

```
屏幕 1512x982，safeAreaInsets.top = 32  →  菜单栏占 y_bottomLeft ∈ [950, 982]

面板 y ∈ [948,982]（落在菜单栏区内），ignoresMouseEvents=false，逐个 level 试：
  shielding (2147483628) / statusBar+1 (26) / mainMenu+1 (25) / popUpMenu (101) / floating (3)
  → 合成真实点击，五个 level 全部收不到 mouseDown，acceptsFirstMouse 甚至未被查询

同一个面板改为 y ∈ [862,982]（垂到菜单栏下方 88px），点击 y_bottomLeft=902：
  → acceptsFirstMouse queried → mouseDown loc=(110,40) → mouseUp   ✅
```

测法：探针 app 内建 `NSPanel` + `registerForDraggedTypes([.fileURL])`，用从终端启动的 CGEvent 投递器合成真实点击（终端已有辅助功能授权，`AXIsProcessTrusted()=true`，事件确实投递——光标位置回读验证过）。

**这是刘海方案的地基**：视觉上可以贴着刘海（黑色 `NotchShape` 齐屏幕上边缘），但**可点、可拖的区域只有下沉到菜单栏以下那部分**。任何"点刘海本身"的交互都做不出来，不要设计进去。

### C3 — accessory（LSUIElement）app 必须 `acceptsFirstMouse = true`

菜单栏 app 永不成为活跃 app，非活跃窗口的第一次点击默认被吞掉用于激活。实测 C2 成功那次日志里 `acceptsFirstMouse queried` 先于 `mouseDown` 出现——返回 `false` 这一击就没了。

### C4 — 只有 Apple Development 证书，签不出可分发产物

```
security find-identity -v -p codesigning
  1) …"Apple Development: …(2FG46FXYX9)" (CSSMERR_TP_CERT_REVOKED)   ← 已吊销
  2) …"Apple Development: …(2FG46FXYX9)"                             ← 有效
  无 Developer ID Application
```

Apple Development 只能签本机开发用，**不能公证**。已按你的决定「签名暂时使用本机」处理：产物是本机/源码构建，不是可下载的公证 DMG。→ 见 §7。

### C5 — 工具链

Xcode 26.6 / Swift 6.3.3 / macOS 26.5.2 (Tahoe, build 25F84)，本机有刘海。可以用 macOS 26 的 liquid glass 与 Swift 6 严格并发。

---

## 2. 架构决策：GUI 怎么和 gitpic 说话

**选定：把 `gitpic` 二进制打进 app bundle，用 `--json` 调用。**

理由：
- **契约只有一份。** JSON envelope 是你花了 v0.4.0/v0.5.0/v0.5.1 三个版本硬化的东西——10 个错误码由 `src/error.rs:124` 的契约测试锁死，partial-success 用 `results` 字段是否存在来判别，`doctor` 的 `error` 字段有 `ok==false` 的不变量断言。GUI 复用它，等于免费继承这些保证。
- **绕开 C1 的一半。** bundle 内绝对路径，不依赖 PATH。
- **独立版本号天然成立。** app 有自己的版本，内部钉住一个 gitpic 版本。（0.6.0 起改为与 CLI 共用一个版本号，见 §7。）
- 一次上传拿全链接形态：`ItemResult` 带 `url`/`raw_url`/`markdown`/`html`/`path`/`sha`/`size`/`deduped`（`src/output.rs:31-43`），所以 GUI 切 md/raw/html/cdn **零重传**。

否决的方案：
- **抽 `src/lib.rs` 走 FFI**：`src/output.rs:107,120` 直接 `std::process::exit(0)`、`upload::run` 收 `&Cli` 并返回退出码、`Config`/`history` 路径是进程全局的——侦察估算 400–600 行签名改动。这是 v2 的事，不是 v1 的。
- **Swift 重写上传**：立刻产生契约漂移，GitHub Contents API 那套 409/dedup/路径模板逻辑要维护两份。

---

## 3. `gh` 发现与首启动引导

C1 决定这一节不是可选项——不做，Finder 启动的 app 每次上传都失败。

**发现顺序**（首次启动解析一次，存进 UserDefaults，失效时重解析）：
1. `/opt/homebrew/bin/gh`（Apple Silicon Homebrew，本机命中）
2. `/usr/local/bin/gh`（Intel Homebrew）
3. `$SHELL -l -c 'command -v gh'`（实测可用，覆盖 nix / asdf / 自定义前缀）

解析到后，spawn `gitpic` 时**显式传 env**：`PATH = <gh 所在目录>:/usr/bin:/bin:/usr/sbin:/sbin`。这是让 `src/auth.rs:49` 的裸名查找能成功的唯一办法，且不需要改 CLI。

**首启动诊断用 `doctor --json`**，不要自己猜状态。它返回 `config_ok`/`token_valid`/`repo_writable`/`branch_protected`/`token_source`/`login`/`detail`，够画一个体检页。

但有一个已知的分辨率问题必须在 GUI 侧补：`src/auth.rs:57-60` 和 `84-86` 把**「没装 gh」「装了但没登录」「gh 因任何原因非零退出」三种情况塌成同一个 `CONFIG_MISSING` + 同一句文案**，且 `gh` 的 stderr 被 `Stdio::null()` 丢掉。而首启动引导最需要区分的恰好是前两种。

→ GUI 自己跑一次 `gh auth status`（拿得到 stderr），据此给出精确指引：
- `gh` 找不到 → 引导 `brew install gh`
- `gh` 在但未登录 → 引导 `gh auth login`
- 其它非零 → 原样展示 stderr，不要粉饰

（把这三种拆成不同错误码是 CLI 侧的 v-next 议题，本方案不依赖它。）

---

## 4. UI 三件套

### 4.1 菜单栏（NSStatusItem）——主入口

始终可用，不受 C2 限制（popover 完全在菜单栏以下）。点击弹 popover：
- 拖拽落区 + 「上传剪贴板」按钮
- 最近上传（读 `history.jsonl`，只读，不与 CLI 争写）
- 格式切换（md / raw / html / cdn，零重传，见 §2）
- 打开主窗口 / 设置

### 4.2 主窗口——历史与设置

`NavigationSplitView`，macOS 26 liquid glass（参考 `macos-settings-ui` skill）。两个 pane：历史浏览、设置。
设置直接读写 CLI 的十一个合法 key（`github.owner/repo/branch`、`upload.path_template/format/link_kind/dedup/auto_copy/compress/max_width/quality`）。

**并发注意**：`config set` 是 load→改一个 key→整文件存盘，两个并发 set 会丢更新（`src/commands/config_cmd.rs:82-84`，无锁）。GUI 侧把设置写入串行化到一个队列，别并发发多个 `config set`。

### 4.3 刘海拖拽区——受 C2 约束的那一块

> **本节已废弃，保留作为记录。** 刘海面板从未通过验收，代码已删除；拖拽落区最终做在菜单栏
> 图标上，见下文「M1 的实际结果」。本节的 C2/C3 分析仍然正确，也正是它否掉了这个方案。

视觉：黑色 `NotchShape` 齐屏幕上边缘，看起来从硬件刘海里长出来。
交互：**只有菜单栏以下的部分有效**。具体结构：

```
y=982 ┬─────────────────────────┐  屏幕上边缘
      │  黑色 NotchShape 视觉区   │  ← 菜单栏保留区，收不到任何事件（C2）
y=950 ┼─────────────────────────┤  菜单栏下沿 (safeAreaTop=32)
      │  透明 hover ledge ~16px  │  ← 常驻，registerForDraggedTypes，draggingEntered 触发展开
y=934 ┼─────────────────────────┤
      │                         │
      │  展开后的真实落区 ~120px  │  ← 拖拽悬停时弹簧展开
      │                         │
      └─────────────────────────┘
```

- 面板：`NSPanel`，`[.borderless, .nonactivatingPanel]`，`ignoresMouseEvents = false`，`acceptsFirstMouse → true`（C3），`collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`。
- **偏离 skill 参考实现**：`macos-notch-ui/references/NotchWindow.swift:42` 是 `ignoresMouseEvents = true` 全程点击穿透——那样永远收不到拖拽，必须改掉。`NotchShape.swift` 可原样用。
- **常驻 ledge 只有 16px 且透明**，所以平时几乎不挡操作；NSView 命中测试按 bounds 而非 alpha，透明不影响收事件。
- 无刘海的 Mac：`NSScreen.safeAreaInsets.top == 0` 时回落到 skill 的 `showPill()` 底部胶囊形态，逻辑同构。

**待人工确认的一件事**：C2 证明了菜单栏以下能收*点击*。拖拽走的是同一条窗口命中测试路径且 `registerForDraggedTypes` 已设，风险很低，但我无法在无授权下合成真实拖拽手势。→ 列为实现里程碑 M1 的验收动作（人手拖一次文件，5 秒）。若失败，兜底是菜单栏 popover 落区（不受 C2 约束，必然可用）。

---

## 5. 上传流程与剪贴板归属

```
落区收到 fileURL / 剪贴板有图
      ↓
spawn  <bundle>/Contents/Resources/gitpic  <paths…>  --json
       env: PATH=<gh dir>:/usr/bin:/bin:/usr/sbin:/sbin
      ↓
读到 EOF 再解析（stdout 是一次性写出的 pretty JSON，不是 NDJSON）
      ↓
ok:true → results[]        ｜  有 results 且 ok:false → 部分成功  ｜  只有 error → 全败
      ↓
GUI 自己写 NSPasteboard（按当前格式）+ 通知 + 落区显示结果
```

要点：
- **`--json` 会完全抑制 CLI 的剪贴板写入**（`src/commands/upload.rs:205` 要求 `Mode::Human`），所以剪贴板归 GUI 所有。这不是妥协而是更好：一次上传，事后随意切格式。`--no-copy` 在 `--json` 下是多余的，别传。
- **没有流式进度**：单次 PUT，stdout 到结束才写（`src/commands/upload.rs:219`）。所以按批显示不确定进度。想要逐文件粒度可以加 `-v` 解析 stderr 的 `gitpic: <name> -> <path> (<n> bytes)`——但那是散文不是契约、无测试锁定（`link={Cdn}` 这种 Debug 输出就在里面），**只能当进度提示，绝不作为正确性来源**。
- **多文件结果对位靠数组下标**：`ItemResult` 没有回显输入路径的字段，`name` 是去扩展名的 stem。结果按输入顺序 push（`src/commands/upload.rs:201`），下标是唯一对应关系。GUI 保留自己的输入数组。
- **并发上传要串行**：两个 gitpic 进程同时 PUT 会撞 GitHub 的 ref 竞争（`src/commands/upload.rs:136-138` 注释解释了为什么进程内是串行的），而 `map_status` 没有 409 分支（`src/github.rs:143-159`），会掉进 `GENERAL`/exit 1 且带原始响应体。**GUI 必须用单一串行队列**，不能一次起多个 gitpic。
- **`arboard` 的未知项**：`src/commands/upload.rs:319` 从 GUI 进程调用时能否拿到剪贴板图像未实测（侦察也标了这条）。但我们走 `--json`，剪贴板由 GUI 用 NSPasteboard 直接处理，`paste` 子命令根本不会被 GUI 调用——**这条风险被架构绕过了**。

---

## 6. 目录结构

同仓库，与 Rust crate 并列，互不干扰：

```
gitpic/
├─ src/                     Rust CLI（不动）
├─ apps/GitPic/             ← 新增
│  ├─ Package.swift            SwiftPM，可 CLI 构建，CI 友好
│  ├─ Sources/GitPicApp/
│  │  ├─ GitPicApp.swift       @main, .accessory
│  │  ├─ StatusItem.swift      菜单栏
│  │  ├─ StatusItemDropView.swift  图标落区（M1 的最终形态，见 §「M1 的实际结果」）
│  │  ├─ MainWindow.swift      历史 + 设置
│  │  ├─ GitpicRunner.swift    进程调用 + JSON 解码 + 串行队列
│  │  ├─ ToolDiscovery.swift   gh 发现（§3）
│  │  └─ Envelope.swift        与 output.rs 对齐的 Codable
│  ├─ Tests/GitPicAppTests/    Swift Testing
│  └─ Resources/               打包进 bundle 的 gitpic 二进制
└─ scripts/build-app.sh        构建 + 内嵌 gitpic + 签名 + 组 .app
```

`Package.swift` 而非 `.xcodeproj`：纯文本、可 diff、`swift build`/`swift test` 直接跑，不需要 Xcode GUI。

---

## 7. 版本与发布

> **已过时（0.6.0 起）。** 本节记录的是 app 独立版本号、`app-v*` tag 前缀隔离的设计。
> 从 0.6.0 起 CLI 与 app **共用一个版本号、发在同一个 Release**：`Cargo.toml` 是唯一版本源，
> `apps/GitPic/VERSION` 与 `release-app.yml` 都已删除，`app-v0.1.0` / `app-v0.1.1` 作为历史
> tag 保留。原设计与现状的差异见下方"合并后"小节；原文保留，因为它记录了当初为什么要隔离，
> 以及隔离一旦拆掉会踩到什么。

**（原设计）独立版本号，tag 前缀隔离。** 已核实隔离是真的：

- `release.yml:5` 触发器只有 `tags: ["v*"]`。`app-v0.1.0` **不匹配** `v*`（glob 从头匹配），所以 app tag 不会触发 CLI 发布。
- 新增 `.github/workflows/release-app.yml`，触发 `tags: ["app-v*"]`。

**两条红线**（踩了会把现有 CLI 发布搞坏）：

1. **app 产物绝不能叫 `gitpic-*` 且绝不能进 CLI 的 `dist/`。** 当时 `release.yml` 的守卫是 `sidecars=$(ls gitpic-*.sha256 | wc -l)` 然后 `test "$sidecars" -eq 4`；多一个 `gitpic-x.dmg.sha256` 就变 5，**发布直接失败**。且 `files: dist/gitpic-*` 会把 dmg 一并收走。→ app 产物命名 `GitPic-<ver>.dmg`，走独立 dist 目录。
2. **绝不把 app 加进插件清单。** `check_manifests.py` 把 `Cargo.toml` 版本焊死等于 `.claude-plugin/marketplace.json` 两处 + `.codex-plugin/plugin.json` 一处，并断言 `len(plugins) == 1`（第 87、114 行），还要求两份 changelog 都有该版本段。app 版本与 Cargo 版本不同，塞进去必然红。→ app 的 changelog 另开 `apps/GitPic/CHANGELOG.md`。

**分发形态（受 C4 限制，按你「暂时本机签名」的决定）**：`scripts/build-app.sh` 用有效的那张 Apple Development 证书签名，产物是本机可运行的 `.app`。这**不是**可公开下载的公证包——别人下载后会被 Gatekeeper 拦。所以 `app-v0.1.0` 定位为**源码构建 / 本机安装**，Release 页面写明构建方式，不承诺开箱可用。等有 Developer ID 再补公证与 DMG 分发。

### 合并后（0.6.0 起的实际做法）

- **一个版本源**：`Cargo.toml` 的 `[package] version`。`build-app.sh` 读它，并断言即将嵌入的
  `gitpic --version` 与之相等 —— 版本合一是每次构建都被验证的事实，不是承诺。
- **一个 tag、一个 Release、一个发布者**：`release.yml` 里 app 作为 macOS job 构建与自检，
  然后把 zip 作为 artifact 交给唯一的 publish job。artifact **不能**叫 `dist-*`，否则会被
  `pattern: dist-*` + `merge-multiple` 扫进 CLI 的 `dist/`。
- **红线 1 换了形式，没有消失**：两类产物现在确实在同一个 Release 里，所以宽松的 `gitpic-*`
  计数被换成**按确切名字逐个断言**。宽松 glob 之所以一直没出事，只因为 publish job 跑在
  Linux —— `ls gitpic-*` 在大小写不敏感的文件系统上会匹配到 `GitPic-*`。
- **红线 2 依然有效**：app 永远不进插件清单，`len(plugins) == 1` 保持不变。
- **不能标 prerelease**：Homebrew tap 的更新流程读 `releases/latest`，该端点跳过 prerelease，
  且它的 cron 失败时不报错。所以未公证这件事写进 release notes，而不是写进 prerelease 标记。

---

## 8. 测试策略

- **Swift 单测**（Swift Testing）：`Envelope` 解码——用真实 gitpic 输出的样本 JSON 覆盖三种 envelope（success / partial / error）与 10 个错误码；`ToolDiscovery` 的三级回退；路径/格式选择逻辑。
- **契约对齐测试**：一个测试实际调用打包的 gitpic 二进制拿 `--json` 输出并解码，确保 Swift 侧 `Codable` 与 `src/output.rs` 不漂移。这是防止"CLI 改了字段 GUI 静默失效"的唯一手段。
- **人工验收清单**（无法自动化的部分，逐条勾）：
  - ~~M1：从 Finder 启动 app，拖一个 png 到刘海落区~~ → 搁置，见 §9
  - Finder 启动下 `gh` 解析成功（这是 C1 的回归点）
  - ~~无刘海外接屏 / 多屏切换下面板定位正确~~（刘海面板已删除，不再适用）
  - 菜单栏 popover 落区可用（C2 的兜底路径）
- **菜单对齐**：`NSMenuItem` 按图片自身尺寸绘制，SF Symbol 每个字形的包围盒都不一样
  （本菜单六个符号在 2x 下 21–28 px 宽、19–25 px 高），所以每个符号都要居中画进同一个
  盒子；符号 scale 用 `.small`（默认的 `.medium` 比任何系统菜单都重）；section header 由
  AppKit 排在图标列而不是标题列，要塞一张同尺寸空图片才能和下面的条目对齐。三条都是拿
  Finder 的「文件」菜单当基准量出来的，不是眼估。

---

## 9. 里程碑

| # | 内容 | 验收 |
|---|---|---|
| M0 | SwiftPM 骨架 + `.accessory` 起得来 | `swift build` 过，菜单栏出现图标 |
| ~~M1~~ | ~~刘海 ledge 收到真实拖拽~~ — **搁置** | 见下 |
| M2 | `ToolDiscovery` + `GitpicRunner` + Envelope 解码 | Finder 启动下跑通一次真实上传 |
| M3 | 菜单栏 popover（落区 / 剪贴板 / 格式切换 / 最近） | 三种格式零重传切换正确 |
| M4 | 主窗口（历史 + 设置） | 设置改动落到 config，串行无丢更新 |
| M5 | 构建脚本 + 签名 + 独立 tag 发布流水线 | `app-v0.1.0` 不触发 CLI 发布，CLI 的 4-sidecar 断言不受影响（0.6.0 起改为合并发布，验收标准见 §7「合并后」） |

M1 原本排在功能之前——它是唯一一个失败就要改设计的里程碑（兜底见 §4.3）。

**M1 的实际结果：刘海方案放弃，落区改到菜单栏图标上（上面三个选项里的第 1 个）。**

刘海面板搁置的原因是验收动作本身做不到：合成一次真实的 Finder→面板拖拽需要辅助功能授权
下的 CGEvent 拖拽序列，我没做出来，而 §4.3 已经说明这一条只能人手验。`NotchPanel.swift`
与 `NotchShape.swift` 已删除；C2 / C3 那两条实测结论保留在本文 §C2、§C3，它们仍然有效，
并且 §C3（`.accessory` app 必须 `acceptsFirstMouse = true`）对新落区同样适用。

**选项 1 已实测通过**，探针在真机上验的（ad-hoc 签名、`.accessory`、菜单已挂在
`statusItem.menu` 上）：

- 往 `statusItem.button` 上 `addSubview` 一个注册了 `.fileURL` 的 `NSView`，真实 Finder
  拖拽能收到 `draggingEntered` 与 `performDragOperation`；
- **同时**点击图标仍然弹出菜单（`menuWillOpen` 照常触发）。

两件事同时成立的前提是**不要覆写 `hitTest`**。`NotchDropView` 当年那个「把所有事件留给
自己」的 `hitTest` 用在这里会吃掉点击，图标就再也打不开菜单了。

不受 C2 约束的原因确认成立：那个 button 属于系统自己的 status bar window，所以菜单栏保留
区吞掉的事件，它的子视图收得到。

**另一条实测**：`draggingUpdated` 触发极密（一秒悬停约 78 次），落区必须在
`draggingEntered` 里把判断结果缓存下来，不能每次重读剪贴板。

