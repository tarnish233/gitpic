# 更新日志

本项目的所有重要变更都会记录在此文件中。格式参考
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

## [0.20.4] - 2026-08-26

### 被拒绝的更新检查现在会说清是哪一种拒绝

- **GitHub 返回的每一个 403 都被报成「已被限流，稍后再试」，包括那些等下去也不会好的。**被封的 User-Agent、或者在 GitHub 看到请求之前就抢答的公司代理，产生的提示和「这一小时配额用完了」完全一样——于是建议是错的，而 GitHub 自己的解释被丢掉了。现在只有响应确实这么说时才会被称为限流，其他情况会把 GitHub 实际返回的内容报出来。
- **真的被限流时现在会说要等多久。**它本来就知道——GitHub 在每一个这样的响应里都带着重置时间——但代码在构造提示之前就把 header 丢掉了，于是明明能说出秒数，只能说「稍后」。
- **设置 ▸ 通用 里的「上次检查」改成了「上次成功检查」。**那个时间戳只在检查成功完成时才前进，所以它挨着一条失败信息时描述的是另一个时刻——一个两天前的时间戳压在一条刚出现的「RATE_LIMITED」上面，读起来像「两天前被限流了」。

<!-- release-notes-end: 以上是 GitHub Release 与 App 内更新弹窗共用的文案；以下只留在本文件。上面每条保持一行——App 的更新弹窗用 .inlineOnlyPreservingWhitespace 渲染，换行会保留，折行会在 480pt 处断句 -->

### CLI

- `release.rs` 的 `status_error` 只凭状态码就把 `403 | 429` 映射成 `RATE_LIMITED`。它自己的文档
  注释解释说，之所以不用 `crate::github` 那份映射，是「因为同样的状态码在这里含义不同」——而唯一
  真正含义不同的那一点恰好是它搞错的，反倒是它刻意分道扬镳的那个模块先看了 body。GitHub 会用
  403 拒绝一个被封的 User-Agent，中间盒子也会在请求到达 GitHub 之前用 403 挡掉它；这两种等下去
  都不会好。
- 现在由三个信号决定，因为 GitHub 用了三种形状：主限流的 `x-ratelimit-remaining: 0`、次级限流的
  `retry-after` header，以及在 header 被中间盒子剥掉时作为兜底的 body 里那句话——后者正是
  `crate::github` 用的同一个判据。状态码自己什么都不决定。
- `AppError::with_retry_hint` 从错误码引入时就存在，文档写着它是给「唯一一个『等一会儿再试』就是
  标准解法的错误码，所以也是唯一一个给出数字算指引而不算噪音的」——而真正需要它的这个调用点从来
  没用过它。`check_against` 读完 `resp.status()` 就把 response 丢了，于是带着答案的那些 header
  在映射发问之前一行就已经消失。现在 header 和 body 都会传进去。
- `retry-after` 本身就是秒数；`x-ratelimit-reset` 是绝对的 epoch 秒，在这里换算成差值。一个已经
  过去的重置时间不会给出任何提示，而不是给出「retry after 0s」——因为 0 读起来像建议，而它不是。
- 原先覆盖这一处的测试断言的是这个缺陷本身：它检查一个裸的 `FORBIDDEN` 会映射成 `RATE_LIMITED`。
  现在它断言相反的事——GitHub 的原话要留下来、不能给出那条不可能奏效的建议——把映射回退会让它变红，
  验证过了。另外三个测试分别覆盖真限流的每一种形状、等待时间从两个 header 中任一个到达、以及重置
  时间已过去的情形。

### App

- 更新那一栏下面的状态行写着「上次检查」，而这个值 `AppModel` 只在检查完整跑完时才打戳——这是刻意
  的，否则离线一周会被悄悄算成检查了一周。「成功」这两个字是让这一行和它下面那条失败信息能被读成
  「两个不同时刻」的关键。

## [0.20.3] - 2026-08-26

### 更新窗口开着时不再挡住注销

- **在更新窗口开着的时候注销、重启、或者从 Dock 图标退出，此前都会被拒绝——唯一的出路是强制退出。**macOS 在任何窗口挂着 sheet 时都会拒绝终止 App，而更新窗口就是一个在整个下载过程中一直挂着的 sheet；0.20.2 修好的是 App 自己的「退出 GitPic」和 ⌘Q，而 macOS 自己合成的那几条路径从不经过那段代码，因此一直是坏的。现在它们能退出了，并且走的是同一套清理，所以安装中途注销同样不会留下已挂载的磁盘映像、准备了一半的应用副本和下载文件。

<!-- release-notes-end: 以上是 GitHub Release 与 App 内更新弹窗共用的文案；以下只留在本文件。上面每条保持一行——App 的更新弹窗用 .inlineOnlyPreservingWhitespace 渲染，换行会保留，折行会在 480pt 处断句 -->

### App

- 两处改动，单独任何一处都是错的。`Updater.allowTerminationWithSheets()` 在每个 sheet 开始时
  清掉 `preventsApplicationTerminationWhenModal`，让 `terminate:` 不再被拒；随后
  `AppDelegate.applicationShouldTerminate` 把放行进来的请求接到唯一那条退出路径上。只做前者
  会让 AppKit 按自己的方式拆掉进程，既不回收登录子进程也不撤销暂存——那正是 0.20.2 发布出去
  要堵的泄漏，从另一道门又回来了。只做后者是死代码，因为 sheet 的拒绝发生在 delegate 被询问
  之前，这一点在 0.20.0 上用探针构建实测过：失败的那次运行里它一行日志都没有。
- 用 `willBeginSheetNotification` 观察者，而不是在每个弹出点各修一遍。今天有五处 sheet 形状的
  呈现——更新弹窗、图床的「把这个配置文件移开？」、「升级前需要退出 GitPic」、「下载并安装」，
  以及 agent 集成的确认框——而源码里早就记下了为什么逐点修是错的形状：它会让下一个人加的第六个
  弹窗静默地把这个 bug 带回来。这个标记是隔一轮再读、并且对所有 sheet 都设一遍，因为
  `willBeginSheet` 在 AppKit 填好 `attachedSheet` 之前就触发了。
- `QuitPathContractTests` 把这两半当成一对来断言，因为任何一半单独存在都是缺陷而不是「修了一
  半」。验证方式是分别回退每一半、再加上把 notification 换成错的那个：三种都会让它变红。
- `scripts/check-self-update.sh` 新增了能给出结论的那个阶段，因为没有任何单元测试能——
  `swift test` 导不进 `GitPicApp`，而这个行为是 AppKit 在真窗口上的真 sheet 上的行为。它在安装
  进行中发出与注销完全相同的 `kAEQuitApplication`，然后同时断言进程消失了、以及没有任何残留。
  第二条断言才是区分「退出了」和「正确地退出了」的那一条：如果 delegate 返回 `.terminateNow`，
  进程一样会退出，只有残留检查能抓到。
- 门控本次发布的那次运行实测：进程退出了、没有残留，并且安装中途退出的那个阶段赢下了竞态——
  中断落在暂存过程之中而不是交接之后，那是它可能遇到的两种情况里更难的一种。
- 用 `tell application id … to quit` 而不是去点 Dock 图标的菜单，因为它不需要辅助功能树、也不
  必把 App 置于最前台——脚本自己的注释记着，把它置于最前台会让辅助功能树在本次运行剩下的部分
  里失效。

### 测试

- 那个契约测试把期望的 skill 路径写成 `agent_home.join("skills/gitpic/SKILL.md")`。Windows 上
  `Path::join` 会把这一整串当字面量接上去、斜杠原样保留，而二进制那边是逐分量拼出它上报的
  路径，于是断言拿 `skills\gitpic\SKILL.md` 去比 `skills/gitpic/SKILL.md`。二进制是对的，测试
  是错的。
- 它从 per-agent skill 那次改动起就一直是错的：从 2026-08-23 起每一次推送到 main 都会让
  `windows-latest` 那条腿失败，而 0.18.0 到 0.20.2 六个版本全部发布在那个红色运行之上。没人
  发现，是因为 tag 触发不到 `ci.yml`，而 tag 路径上根本没有任何东西跑 `cargo test`——两个缺陷
  互相掩护。
- 门的 PASS 那行在陈述一个它自己杀掉的进程：它报的是最后一次重启的 pid 而不是更新替换掉的那
  个，并且声称重新回来的 App 正在运行，而后面的阶段早已把它拆掉了。这是靠真跑一遍发现的，读
  代码读不出来。

### 发布方式

- 一条 tag 现在会在任何东西能发布之前跑测试套件，在 Linux 和 Windows 上。macOS 和 Linux 解析
  同一套 `#[cfg(unix)]`，是真冗余；Windows 是另外两者顶不上的那条腿，而且是这个版本真在发的
  target。工作流里如实写着：这道门本来会挡住上面那六个发布，而挡的原因是一个测试自己的 bug，
  不是坏二进制。
- `cargo fmt --check` 和 `cargo clippy -- -D warnings` 一起带上，但作为只留注解、不阻塞的步骤。
  浮动 `@stable` 上的 `-D warnings` 是这里唯一能把一个**本来没问题的**发布变成失败的检查——一
  条 tag 被切出来时还不存在的 lint，去判一段从没见过它的代码——而且会让重跑旧 tag 变得不可能。
  没被 lint 过的代码不会因此发得更差。
- tag 路径上的缓存 key 谁都对不上。`Swatinem/rust-cache` 从 job id 推导它，所以叫 `tests` 的
  job 产生 `v0-rust-tests-…`，而 CI 写的是 `v0-rust-test-…`：每次发布必然 miss，然后写入
  234MB。现在显式声明 `shared-key: test`，于是改任何一边的 job 名都不会静默地把 miss 带回来。
- 缓存只在 `main` 上保存。tag 写出的缓存被记在形如 `refs/heads/refs/tags/vX.Y.Z` 的 ref 上，
  只有同一条 tag 的重跑能读到，而 tag 运行本来就能读 main 的那一份。仓库当时是 10.7 GB 顶着
  10 GB 上限、最小的一条 142MB，所以每一次保存都在挤掉某个 pull request 依赖的东西；十一条 tag
  一共占着 6.16 GB。
- `ci.yml` 的 MSRV job 继续不作为发布门，但现在理由是写下来的，而不是留成一处不对称。每一个
  消费者都核实过：`Cargo.toml` 自己写着这个字段只影响从源码构建，这个 crate 不在 crates.io 上，
  而 Homebrew 的 formula 装的是预编译产物、从不编译它。
- tap 的通知在 2026-08-24 的 09:32 到 14:41 之间失效，之后连续三个版本返回 `Bad credentials`，
  每次都静默退回六小时一次的 cron。`continue-on-error` 一边在为发布做它该做的事，一边掩盖了一
  次回归，因为绿色运行里的一个红色步骤不是报告。现在这一步会区分「没配 token」和「token 被
  拒」，两种都会抬出一条警告注解和一行 step summary。



## [0.20.2] - 2026-08-26

### 更新的校验和现在覆盖真正被安装的那个文件

- **校验和是在下载文件的一次打开上验证的，磁盘映像却是另一次打开挂载的。**没有任何东西能证明两次打开的是同一个文件，于是被校验过的字节并不可证明就是被安装的字节。现在会记录被哈希那份数据的身份，并在挂载前重新核对，不一致就中止安装。
- **留在下载路径上的符号链接现在也会被拒绝。**原先的核对会跟随符号链接，把它指向已校验的映像就能通过——这等于把核对的对象交给了做这个链接的人。
- **安装更新的过程中退出 GitPic，不会再留下任何东西。**以前安装期间根本退不出去，因为 macOS 在更新窗口开着时会拒绝退出；现在退出能用了，它同时会清掉已挂载的磁盘映像、准备了一半的应用副本和下载文件，而不是把它们留到第二天的清理。

<!-- release-notes-end: 以上是 GitHub Release 与 App 内更新弹窗共用的文案；以下只留在本文件。上面每条保持一行——App 的更新弹窗用 .inlineOnlyPreservingWhitespace 渲染，换行会保留，折行会在 480pt 处断句 -->

### App

- 摘要和它所覆盖字节的 `dev`/`ino` 现在通过同一个描述符取得——在被哈希的那个 handle 上
  `fstat`，绝不再做第二次路径解析——并且 `stage` 会在 `hdiutil attach` 之前重新断言该路径
  仍然指向那个 inode。两次打开之间的窗口不是瞬间：中间夹着一次 `Task.checkCancellation`
  和一次跳到与 20 秒 `brew list --cask` 共用的串行队列。
- 这个重新断言用 `lstat` 而不是 `stat`。`stat` 会跟随符号链接，所以对它而言只证明了路径
  *解析到* 已校验的 inode——而符号链接替换的不是文件，是名字，而名字才是交给 `hdiutil` 的
  东西。实测：把映像移到一边、在下载路径留一个指向它的符号链接，比对会通过，因为 rename
  保留了摘要所基于的那个 inode。
- 对应的拒绝测试现在替换进一个与映像逐字节相同的副本，而不是 31 字节的 ASCII。用垃圾数据
  时它什么也没断言：`hdiutil attach` 本来就会拒绝垃圾并抛出同一个 case，所以把核对删掉
  测试照样通过。逐字节相同是能拿到的最强前提——摘要根本分辨不出这两个文件，只有 inode 能。
- 「退出 GitPic」和 ⌘Q 用的是 `NSApplication.terminate`，而 AppKit 在任何窗口挂着 sheet 时
  都会拒绝终止，于是图床的「把这个配置文件移开？」提示和更新弹窗都会让 App 退不出去。两者
  现在都走更新路径已经在用的那个真正的 `exit`。
- 修掉它同时移除了一层没人注意到的保护：AppKit 的拒绝恰好是安装*期间*唯一阻止退出的东西，
  因为安装是从更新弹窗里的按钮启动的，而那个弹窗全程挂着。`exit` 不会运行任何清理，所以
  `stage` 现在会登记它创建的东西，退出时逐一撤销——杀掉还在写的子进程、删掉暂存目录和映像
  文件，并把挂载交给一个能活过本进程的 `hdiutil detach -force`。
- 这个撤销里有三处是关键的，而且每一处最初都是错的。`hdiutil attach` 刻意永不被杀，因为
  已被内核接受的 attach 会活过它自己的进程，与之竞争会把挂载点从一个正在落地的映像下面
  unlink 掉——那是不可恢复，而不只是泄漏。暂存目录在派生安装脚本之前被原子地交接，否则落在
  两者之间的退出会删掉脚本正要移动的那份 bundle，而脚本的回滚 trap 会把旧版本拉回来，让一次
  成功的安装变成静默回滚。以及登记是会回答而不只是记录：撤销取走的是那一刻已登记的东西，
  而退出在 `exit` 之前还要做一次阻塞的 `UserDefaults.synchronize()`——足够 `stage` 建出一个
  再也不会被读到的目录。
- 退出路径的绊线现在会找 AppKit 接受的每一种写法。它原先找的是字面量
  `NSApplication.terminate`，而这匹配不到 `NSApp.terminate(nil)`——0.20.0 实际发布的正是这种
  写法，也是源码里解释这个缺陷时提到五次的写法。它的注释剥离按单个 `/` 切分，会把该行更早
  一个斜杠之后的真代码整段藏掉，又会把顶格的 `///` 判成失败；而它的文件列表把目录读取失败
  吞成空列表，于是扫描可以在什么都没读到的情况下报绿。
- `scripts/check-self-update.sh` 现在会驱动用户真正会按的那两个退出入口，而它此前从不：
  它是通过「下载并更新」到达退出的，也就是更新路径自己的退出，于是「退出 GitPic」和 ⌘Q
  只靠一个源码 grep 兜着。在原有阶段之后新增了两个阶段——在更新弹窗挂着、且没有任何安装
  在跑时退出（这正是 0.20.0 的复现步骤），以及在安装真正进行中退出，随后断言没有残留的
  已挂载映像、暂存目录和下载文件。
- 第二个阶段对一个它无法稳定赢下的竞态是诚实的：5MB 的下载加上一个小 bundle 的 `ditto`
  可能两三秒就跑完，所以退出可能落在交接之后而不是暂存过程之中。两种情况下"没有残留"的
  断言都成立，而运行结果会说明这次落在了哪一种。⌘Q 仍然没有被驱动，因为 `keystroke` 需要
  App 处于最前台，而把它置于最前台会让辅助功能树在本次运行剩下的部分里失效；⌘Q 与菜单项
  共用同一个 selector，那一点由单元测试来保证。
- 同一个脚本此前会在把仓库留成坏状态的同时报告成功。当 Cargo.toml 的恢复没生效时，它会
  告警、然后照样执行 `cargo build --release`，把伪造的 0.0.1 版本烤进共享的 target 目录
  ——那正是这次重建本来要防的事——并且在 `PASS` 已经打印之后仍然以 0 退出。现在它会跳过
  重建、让整次运行失败，并保留自己保存的原始副本供恢复，而不是把它们删掉再让人去用
  `git checkout --`（它自己的文件头正解释了在多个 agent 同时工作的检出里不能那么做）。

## [0.20.1] - 2026-08-25

### 修复一个「更新已装好、跑的还是旧版本」的问题

- **之前 App 说「正在退出」却没有退出。**AppKit 在更新确认框仍挂着时会拒绝终止，替换脚本
  等满时限后照常替换，`open -a` 只是重新激活了没退出的旧进程——日志写着「已重新打开」，跑的
  还是旧版本。现在退出是真正的 `exit`，任何 sheet 都拦不住。
- **「已重新打开」改按进程实际执行的映像判定**，而不是启动时记录的路径——被替换到一边的旧进程
  仍然在跑旧代码，不能再冒充新版本。
- **启动清扫同样按实际执行的映像保护**，而不是启动路径，避免删掉正在运行的备份。
- 新增 `scripts/check-self-update.sh`：真正安装一次更新，断言旧进程退出、新进程以新版本回来。
  凡是动到更新路径的发布必须先通过它——0.20.0 正是因为没有这一关才带着上面的问题发布。

<!-- release-notes-end: 以上是 GitHub Release 与 App 内更新弹窗共用的文案；以下只留在本文件。上面每条保持一行——App 的更新弹窗用 .inlineOnlyPreservingWhitespace 渲染，换行会保留，折行会在 480pt 处断句 -->

### 修复

- **真正的修复是 `exit`，而不是一个更好的 terminate。**失败的运行里，AppKit 自己的日志是：
  ```
  [AppKit:Application] terminate:
  [AppKit:Application] Attempting sudden termination (1st attempt)
  [AppKit:Application] App termination blocked by modal sheet
  [AppKit:Application] Termination aborted
  ```
  更新路径上永远有 sheet 挂着——安装正是从更新 sheet 里的按钮发起的——而 AppKit 在询问
  delegate **之前**就拒绝终止，所以 `applicationShouldTerminate` 从未被调用（实测：失败的运行里
  探针构建在这个回调一声不吭，而成功的运行里它照常触发）。激活策略同样被洗清：窗口开着、没有
  sheet 时，关窗流程照样跑 `windowWillClose` 里的 `setActivationPolicy(.accessory)`，进程正常
  退出。先关掉 sheet 再终止被否决：只有在关闭动画先于 `terminate:` 跑完时才有效，而且任何
  人以后加一个新 sheet 都会让这个 bug 悄悄复活。`quitForUpdate` 返回 `Never`，让编译器守住
  0.20.0 丢掉的约束。此前 dry-run 没发现它，是因为 `GITPIC_APP_DRY_RUN=1` 在退出之前就
  return 了——那一行从未被测试、dry-run 或 code review 执行过；现在它跑完除 `exit` 之外的一切。
- **「`Killed: 9`」这条测量在它曾支撑的注释里被纠正。**重新实测两次：把正在运行的 bundle
  目录改名，进程会继续从移走的副本运行——这正是「失败的退出变成重新打开的旧版本」的机制。
  先退出再替换的次序站得住的理由是朴素的那条（换了一半的 bundle 会把新老版本混在一起，这里
  没有任何东西能把它换回来），而不是那条错误的测量。
- **重开的证据从 argv 换成映像。**`ps` 显示的是启动时的路径；`lsof -a -p <pid> -d txt` 显示
  的是实际执行的。两个条件都满足才算：pid 不是脚本等待过的那一个，且它的映像在安装目标内部。
  原来「无条件 reopened」的一种结局变成五种可区分的：确认新版本在跑；旧进程从未退出（0.20.0
  的形状——说明新版本已在磁盘上，让用户退出再开即可）；`open` 被接受但没有任何进程在执行
  那个 bundle；被拒绝；回滚后的「看似确认」——那里在跑的是原本就在的那份。60 秒等待超时现在
  记为 `ANOMALY`，不再无声通过。候选来源用 `pgrep -x GitPic` 也被否了，理由和 argv 一样：
  在这台机器上它会匹配 `/Applications` 里一份完全无关的、Homebrew 管理的 GitPic。
- **清扫按实际执行的映像保护，而不是启动路径。**`Bundle.main.bundleURL` 是启动时的路径，
  而改名恰好会让它失效；被替换在脚下的进程因此保护着一个它根本没在执行的目标，却把备份——
  唯一的另一份 App——暴露在外。今天还够不着，只是因为清扫恰好只在启动时跑一次、存活进程
  永远到不了它；但一旦挪到定时器或安装完成时就会变 live，而 unlink 不会停下一个正在执行的
  Mach-O：伤害无声，`ROLLBACK FAILED` 的指引还会指向一片虚无。默认值改为
  `SelfUpdate.currentImage()`（lsof），失败时回落到启动路径——不设防比设错防更糟。新测试
  顺便回答了为它而设的问题：`contains` 的符号链接归一化确实能把 lsof 的
  `/private/var/folders/…` 与 `contentsOfDirectory` 的 `/var/folders/…` 两种拼写对上。
- **这道关是整个流程的一部分，不只是个脚本。**`scripts/check-self-update.sh` 构建一个旧版本
  GitPic，装进 `~/Applications`，通过 UI 驱动一次真实更新，断言旧 pid 退出、新 pid 以新版本
  从安装路径回来、重开后的 App 是 `.accessory`、以及机器上 `/Applications/GitPic.app` 从未
  被移动。`~/Applications/GitPic.app` 已存在时没有 `--force` 会拒绝运行，并通过 trap 还原
  `Cargo.toml`、`Cargo.lock` 和共享的 release 二进制。`AGENTS.md` 现在写着这条规则：动到
  更新路径的发布，必须先在一台真机上通过它。

## [0.20.0] - 2026-08-24

### 手动安装的也能在界面里更新

- **Homebrew 装的走 brew，手动装的由 GitPic 自己下载安装。**以前只有前者能一键更新，手动装的用户只能去发布页自己下 DMG、拖进 Applications、再手工清 quarantine。
- 下载、校验、挂载、复制全部在退出之前完成，失败什么都不会改动；只有全部通过才退出替换，完成后自动重新打开。
- 校验用 GitHub 为该文件公布的 SHA-256，和 Homebrew 验证 cask 的方式相同。**拿不到校验和就拒绝安装。**
- Homebrew 管着这份 GitPic 时永远走 brew，不会绕过它替换。
- 不能在界面里更新时，如实说明是哪一种原因，而不是一律说「不是用 Homebrew 装的」。
- CLI 的 `gitpic update check --json` 现在也报告发布资产（名称、大小、下载地址、校验和）。

<!-- release-notes-end: 以上是 GitHub Release 与 App 更新提示的正文；以下只留在本文件里。上面每条写成一行，不要硬折行 —— App 的更新弹窗用 .inlineOnlyPreservingWhitespace 渲染，换行会原样保留，480pt 宽度下折过的行会断在句子中间 -->

### CLI

- `update check` 现在报告发布资产：名称、大小、`browser_download_url`，以及 GitHub 为每个文件
  计算的 `digest`。追加字段，`Decodable` 会忽略未知键，所以旧版 App 解析新信封不受影响；
  `human()` 与 `-q` 的输出一字未变。
- `digest` 是 `Option`：它不属于任何有文档保证的 API 契约（实测 0.15.0 起每个带 DMG 的发布都
  有，更早的发布根本没发过 App 资产）。消费方把「没有」当成「无法校验，不许安装」，而不是当成
  「可以跳过校验」。前缀 `sha256:` 保留而不是剥掉 —— 前缀才是说明用了哪个算法的东西，将来真出现
  `sha512:` 而被当作 SHA-256 处理，就是「看起来验了，其实什么都没验」。
- 下载地址直接透传 `browser_download_url`，不按模板拼。拼出来等于在这个 crate 里放第二处发布
  地址的写法，而 `the_release_feed_is_a_compile_time_constant` 这个测试存在的意义就是只允许有
  一处。

### App

- 新增**自己安装更新**：Homebrew 不管这份 bundle 时，「下载并更新」会去取该版本的 DMG、校验、
  替换正在运行的 GitPic，然后重新打开。以前这种安装方式只能看到「打开发布页」。
- **顺序就是安全性的来源。**下载、校验 SHA-256、挂载映像、核对里面的版本号、验签、把新 bundle
  复制到旧的旁边 —— 全部在 App 还活着的时候完成，可取消，失败零代价。只有到这一步都通过了才退出，
  之后脚本只做两次同目录 rename。不可逆的窗口从「一次下载的时长」缩短到「两次 rename 之间」。
  这也是这条路不需要看门狗的原因，而 brew 那条路需要 —— 它是在 App 已经消失之后才去联网。
- **信任模型，说清楚。**GitPic 是 ad-hoc 签名，没有签名链，macOS 自己验不了下载物的来源。真正
  起作用的是经 TLS 从 `api.github.com` 取到的 SHA-256 与实际字节的比对 —— 这和 Homebrew 完全
  一样：cask 里的 `sha256` 同样是经 TLS 从 GitHub 取的，brew 也没有签名链。所以这不是比现状更
  弱的东西。两者都挡不住 GitHub 账号或 CI 被攻破；真正的升级是 Developer ID 加公证，那件事对
  两条路同样做不到。实测：API 报的 0.19.0 映像 digest 与 `shasum -a 256` 对已发布文件算出的值
  逐位一致。
- **Homebrew 优先，永远。**绕过 brew 替换它管理的 bundle 会让 cask 的 manifest 描述一个已经不
  在磁盘上的版本，下一次 `brew upgrade` 就会和它打架。所以自己安装不是 brew 的替代品，而是
  「brew 不是这份 bundle 的主人」时才发生的事。brew 探测**没有得到答案**时绝不当成「不是 brew 的」
  —— 超时可能正藏着一个好用的 Homebrew，凭这个猜测覆盖一个 cask 就是上面那种破坏。
- 归属是问 Homebrew「你装的是**哪一份**」，而不是「cask 装了没有」。`brew list --cask gitpic`
  只要 cask 存在就退 0，于是在一台 cask 装到 `/Applications` 的机器上，`~/Applications` 里的副本
  会被判成 brew 的 —— 那样它会被交给 `brew upgrade`，brew 去替换**另一份**，脚本再把这一份原样
  打开：一个旧构建，仍然报同一个更新可用，而 brew 报告无事可做，可以无限重复。Homebrew 自己有
  确切答案，现在读的就是它：Caskroom 里有个
  `<prefix>/Caskroom/<cask>/<version>/GitPic.app` 符号链接，指向 app 实际被装到哪。
  这条是在一台真的装了 cask 的机器上把整个流程跑了一遍才发现的，不是读代码读出来的。
- 只在 `/Applications` 或 `~/Applications` 里替换。代价写明：放在别处的副本仍然只看到发布页。
  这也顺带排除了仓库 `dist-app/` 里的开发构建 —— 否则一次自更新会把开发者的构建换成 release 构建。
- 拿不到校验和就拒绝安装，退回发布页。宁可不装，也不装没人担保过的字节。
- 资产按 `release.yml` 生成的确切文件名匹配，不按「以 .dmg 结尾」。一个发布里有五个压缩包和五个
  `.sha256` 附属文件，「第一个看起来像下载物的东西」就是拿附属文件去算哈希、再去挂载它的由来。
- 目标架构从运行进程读取，不硬编码 `arm64`。将来真出了别的架构，这里是「找不到就报不可用」，
  而不是「装错架构」。
- `locateBrew()` 原来对「机器上没装 brew」和「8 秒 login-shell 探测超时」返回同一个 `nil`，两者
  都被当成「过会儿再问」。在 brew 是唯一安装方式时这没有代价；现在有了 —— 没装 brew 的机器正是
  这个功能要服务的人，把它和「问不出来」混在一起，等于让那个用户永远重试一个不会改变的探测。
  新的 `locateBrewOutcome()` 把两者分开，判定的不对称沿用 `loginShellLookup` 已有的理由：
  stdout 里出现的路径即使 shell 被杀也照样采信，所以上限只决定「没有路径」算不算证据。
- 更新判断用的是 **bundle 自己的**版本号，不是报告里的 `current` —— 那个是 CLI 的版本，而这里
  替换的是 bundle。打包安装里两者恒等（`build-app.sh` 拒绝打包不一致的组合），源码构建会错位。
- 复制用 `ditto --noqtn` 而不是 `cp -R`：`man ditto` 明确它默认保留 resource fork、扩展属性和
  ACL，而 ad-hoc 签名就存在扩展属性里，`cp -R` 会把签名弄坏。同一段还写着 ditto 默认连
  quarantine 位一起保留，而带 quarantine 的未公证 bundle 会被 Gatekeeper 直接拒绝。
- **先退出再替换，这条是实测的。**把一个正在运行的可执行文件的父目录 rename 掉、再在原路径放一份
  新的，进程会被 `Killed: 9`。所以「在进程内就地替换」这个更简单的方案不能用。
- 交接脚本里有四处是先发现写错了才改对的：
  - 备份目录名带 UUID，并在 `mv` 前断言它不存在。`mv a a.old` 在 `a.old` 已存在时**不会失败**，
    而是把 `a` 移进去，变成 `a.old/a`（已复现）。用固定名字的话，第二次尝试就会「回滚」出一个
    不是 bundle 的空壳目录，然后 `rm -rf` 把真的旧 App 一起删掉。
  - 脚本根本不删回滚素材。`open -a` 返回 0 并不等于新版本真的跑起来了——实测：一个启动即 abort
    的 bundle，`open -a` 照样返回 0，而且 macOS 会把崩溃进程保留足够久，连 `pgrep` 看到它也证明
    不了什么——所以脚本能观察到的任何东西都不足以授权它销毁唯一可用的那份。旧版本留在磁盘上，
    改由后续某次启动清理。腾空后的 staging 目录用 `rmdir` 收掉，万一替换没发生，`rmdir` 也带不走
    里面的 bundle。
  - 重新打开写在 `trap … EXIT` 里，不是写在成功路径末尾。GitPic 是 `.accessory`，退出之后没有
    Dock 图标也没有菜单栏图标，脚本中途死掉就等于把整个 App 拿走了。
  - `PATH` 显式固定。不是为了防提权（全程没有 root），而是 App 自己的 PATH 前面拼了 Homebrew
    前缀，而一个负责替换 bundle 的脚本没有理由从用户可写的目录里解析 `mv`。
- `codesign --verify` 跑在**拷贝出来的那份**上，在 `ditto` 之后、也在会改动它的 `xattr` 之后；
  注释里写清了它**证明不了来源** —— 任何人 ad-hoc 签的东西都能通过。它的全部意义就是发现被截断或
  写坏的副本，所以必须验拷贝：像第一版那样去验只读挂载，只是把 digest 已经证明过的事再证一遍，
  还白搭一次完整解压。唯一的身份验证是那个 digest。
- 启动时清扫的范围扩大：除了旧的升级脚本，还包括取消下载留下的 `.dmg`、以及中断的安装留在
  Applications 目录里的 staging 与备份目录。后两者是整份 App 大小的副本，而脚本删不掉自己所在的
  staging 目录，也完全不删备份。两条规则保证它不会吃掉正在用的东西：凡是**就是**、或者**包含**
  当前运行 bundle 的候选都跳过——按结构判断而不是按年龄，因为任何时间界最终都会在 App 仍然从那里
  运行时到期；以及残留的年龄从 `st_ctime` 读，不从 mtime 读——实测 `mv` 和 `ditto` 会把 mtime
  **和 birthtime 一起**保留，所以备份一生成就已经比任何 cutoff 都老，那条「一天」下限保护了它零秒。
- 旧版本会在 Applications 目录里以隐藏目录的形式留大约一天，占一份 App 的空间——一天内更新三次就
  留三份。这是有意的取舍：另一条路是仅凭一个名不副实的退出码，就删掉这台机器上唯一能用的 GitPic。
- 「取消」在整条序列里都有效，不只是下载阶段。staging 的各步之间会检查它——挂载、版本闸、验签、
  拷贝——而落在 staging 之后的取消会先删掉 staging 目录再抛错。过了交接点就没有什么可取消的了
  （那时脚本已经是个脱离的进程），所以按钮在那一刻是消失，而不是留在那里点了没反应。
- **不考虑提权。**原本打算「目标目录写不进去就弹管理员密码框」，一轮红队审查推翻了它：
  `/Applications` 是 `root:admin drwxrwxr-x`，admin 组用户本来就能写，提权对他们从来用不上；
  真会撞上的只有标准用户，而对他们提权是真的本地提权 —— App 是 ad-hoc 签名、无 library
  validation、无 hardened runtime，用户能往自己这个 GitPic 进程里注入代码、控制最终送进
  `do shell script` 的字符串，而授权框不显示任何命令文本。所以写不进去时如实说明原因，并提示
  「装到 `~/Applications` 就不需要额外权限」。
- 「不能在这里升级」的说明改为按真实原因分支。原来那句「不是用 Homebrew 装的，或者机器上没有
  brew」在 brew 管着一份 bundle 而运行的是另一份时就已经是错的，现在又多了「目录不可写」
  「发布里没有可校验的映像」两种，一句话包不住。
- 手动安装的用户如果自己给 `bin/gitpic` 建过符号链接，不需要做任何事：替换前后 bundle 路径不变，
  链接依然有效且自动指向新版本。

## [0.19.0] - 2026-08-24

### 开机自启动与检查更新

- 新增**开机自启动**：设置 ▸ 通用 ▸「开机自启动」。与「系统设置 ▸ 通用 ▸ 登录项与扩展」是同一个开关。
- 新增**检查更新**：每天自动检查一次，打开设置窗口也会补查，也可以随时手动检查。发现新版本会显示更新内容，并可以直接升级。
- 「Finder 右键」开关从「上传」页移到了「通用」页。
- 精简「图床」页文案。
- CLI 新增 `gitpic update check`：查询最新版本与更新内容，支持 `--json`。

<!-- release-notes-end: 以上是 GitHub Release 与 App 更新提示的正文；以下只留在本文件里。上面每条写成一行，不要硬折行 —— App 的更新弹窗用 .inlineOnlyPreservingWhitespace 渲染，换行会原样保留，480pt 宽度下折过的行会断在句子中间 -->

### CLI

- 新增 `gitpic update check`：查询 `tarnish233/gitpic` 的最新发布，报告当前版本、最新版本与更新
  内容，支持 `--json` 与 `-q`。不读配置、不读凭据 —— 端点是公开的，所以配置坏掉的机器也能问
  「是不是有新版本」，而修复它的那一版可能正是要找的东西。查询地址是编译期常量，不能被配置或
  环境变量改动：这段文字会在 App 里渲染，让别处决定它的来源等于给了一个投放入口。
- 版本比较用三段整数而不是字符串。`"0.9.0" > "0.10.0"` 在字符串上成立，所以一旦跨过 `.9`，
  字符串比较就会把降级当成更新推给用户。历史遗留的 `app-v*` 标签、预发布后缀和任何非三段的
  标签都会被拒绝而不是硬解析；无法比较时如实报错，而不是回答「已是最新」—— 那会把真实存在的
  更新藏在一句让人放心的话后面。
- 终端里打印的更新内容和 App 弹窗裁掉的是同一部分。原来它原样打印 release body，所以
  `gitpic update check` 是唯一一个会吐出 `## GitPic.app` 安装说明的地方 —— 那段是写给下载 DMG 的
  人的（拖到 Applications、清 quarantine），打给一个已经装了 CLI 的人看，外加一遍和上方发布标题
  重复的主题行。实测 0.18.1：23 行正文里只有 6 行在讲改了什么。

### App

- GitPic.app 新增**开机自启动**：「设置 ▸ 通用 ▸ 开机自启动」。写的是 macOS 自己的
  登录项登记（`SMAppService.mainApp`），所以「系统设置 ▸ 通用 ▸ 登录项与扩展」里是同一个开关，
  不存在两份会互相矛盾的状态。
- 开关按**系统回读的状态**显示，而不是按点击结果。翻完开关后重新读一次
  `SMAppService.mainApp.status`，所以「已登记但被 macOS 扣着等你批准」这个状态能如实显示成
  「开 + 去系统设置批准」，而不是伪装成关 —— 那种情况下再点一次也不会有任何变化。真的没生效时，
  会把系统原话一并显示出来。
- **「Finder 右键」开关从「上传」页移到了「通用」页的「系统集成」。** 全 App 只有这两个开关是
  立即写系统状态、不走配置文件和「保存」的；放在一起之后，「上传」页那段解释「我为什么和邻居
  行为不一样」的说明就不需要了。代价说清楚：习惯在「上传」页底部找它的话，位置变了。
- 精简「图床」页文案：删掉登录区那段 `public_repo` / jsDelivr 的说明（正下方就是登录按钮），以及
  仓库区那条常驻的「还要按保存」提示 —— 右上角的「保存」一直都在，鼠标悬停还会列出待写入的键；
  真正需要这句话的「还没配置图床」那一处仍然会说。
- 「设置 ▸ 通用 ▸ 更新」：`自动更新` 开关、状态行和 `检查更新` 按钮。状态行分四种情况，
  其中「当前版本比最新发布更新」是必要的一种 —— 本仓库每个未发布的构建都处于这个状态，说成
  「已是最新」虽然勉强站得住，但会让人困惑。
- 菜单栏菜单里也有一项：`.accessory` App 没有 Dock 图标也没有应用菜单，macOS 用户找
  「检查更新」的那个位置在这里不存在。发现新版本后这一项会变成「有新版本 x.y.z…」，所以即使
  通知早就被划掉了，菜单自己也还在说这件事。
- 自动检查每天一次，到期判断发生在启动时和每次打开设置窗口时。没有用定时器：代价是一个没人盯着
  的后台请求节奏，而「打开窗口就补一次」已经覆盖了日常使用。实现上的坑值得记一笔 —— 这句话一开始
  是假的：只有 `GeneralPane` 的 `.task` 在调它，而 `orderOut` 不发 `onDisappear`、窗口关掉也还
  在，所以那个 `.task` 每个进程只跑一次，「每天」实际上是「每次启动」。现在 `showWindow` 里也调。
- 自动检查发现新版本只发通知，不弹窗；手动检查才弹。一个没人要求的弹窗盖在正在用的窗口上是打扰，
  而且日常检查落地时窗口通常是关着的。设置页会一直留着「查看更新内容」按钮，所以什么都不会丢。
  同一个版本只通知一次：`Notifier.post` 每条都用新 id，不会合并，所以看过通知又决定先不升的人，
  本来每天都会再被告知一次同一件事。
- 手动检查一定拿得到答案，这有两个地方要保证。弹窗挂在设置窗口的根视图上，不在「通用」页里 ——
  `detail` 每次切页都会销毁当前页，所以检查跑完时人已经切到「图床」的话，弹窗没有地方可挂，答案
  直接丢了，而那个标志还留着，下次进「通用」会突然弹出来、内容还可能已经换了一版。另外手动点击
  撞上正在跑的自动检查时不再被丢掉：那一次检查会认领这个请求，而不是把结果发成通知。
- 更新内容弹窗里的正文做了两处结构性裁剪，都是看渲染结果才发现的：release body 开头那行
  `### <主题>` 会被 `release.yml` 拿去当发布标题，弹窗上方已经显示了，留着就是同一句话印两遍；
  末尾 `## ` 级别的段落是给下载 DMG 的人看的安装说明（拖到 Applications、清 quarantine），
  对已经打开 App 的人毫无用处。判定「是标题」要求 `#` 后面有空格，并且跳过 ``` 代码围栏 ——
  否则开头写 `#42 修复…` 的一条会被整行删掉，而围栏里引用的 `## ` 会把正文截断在那里、还留下
  一个没闭合的围栏。`gitpic update check` 用的是同一条规则（`UpdateReport::summary`）。
- 「立即更新」代跑 `brew upgrade --cask gitpic`。App 是 Homebrew cask、ad-hoc 签名、没有公证，
  所以 Sparkle 那种自更新既没有签名链可校验，也会和 Homebrew 的 manifest 打架。Homebrew 不能
  替换正在运行的 bundle，所以流程是：写一个脚本 → App 退出 → 脚本等它退完 → 升级 → 重新打开。
  升级失败也会重新打开，原来的版本仍然可用；过程记录在 `~/Library/Logs/GitPic-update.log`。
  `brew upgrade` 本身有上限（看门狗，15 分钟）—— 重新打开排在它后面，所以一次卡住的升级会让用户
  连 App 一起失去：`.accessory` 退出之后没有 Dock 图标、没有菜单栏图标，唯一的出路是去终端敲
  `open -a GitPic`。日志里区分「被看门狗杀掉」和「brew 自己失败」。子进程继承 App 的环境、只覆盖
  `PATH`（和 `GitpicRunner.run` 一样），否则代理变量会被丢掉，brew 的抓取全部直连。
- 只有确认 brew 确实在管这个 App 才显示「立即更新」。找到 `brew` 不代表这份 App 来自它 ——
  机器上装着 Homebrew、App 却是拖进去的，是完全正常的情况，那时 `brew upgrade --cask` 会失败。
  cask 装了也还不够：还要求正在运行的这个 bundle 就在 cask 会安装的位置（`/Applications` 或
  `~/Applications`），否则从 `dist-app/` 跑的副本会去升级 `/Applications` 那一份、再把自己原地
  打开 —— 旧版本、同样报有新版本，而 brew 说没什么可做的，可以无限循环。这两种情况都不显示按钮，
  而是给出发布页和可以自己敲的命令。
- 「立即更新」按钮的可用性只缓存确定的答案。`brew list --cask` 撞上 20 秒上限、或者 8 秒的
  登录 shell 探测超时，都不说明这台机器的安装方式；把它们记下来会让一台 Homebrew 完好的机器
  在整个进程生命周期里都被告知「这份 GitPic 不是用 Homebrew 装的」，只能重启 App 才能再问一次。
- `GITPIC_APP_DRY_RUN=1` 下「立即更新」只写脚本、不执行、不退出。替换 `/Applications/GitPic.app`
  至少和向图床提交一次一样重，而且是这个 App 里唯一一个事后删不掉的动作。
- 「右键上传已关闭」的通知指向「设置 ▸ 通用 ▸ 系统集成」。开关搬页之后它还在指「上传」页 ——
  而关掉右键之后，这条通知是 App 唯一一次告诉用户开关在哪。
- 「通用」页那两个镜像系统状态的开关在窗口重新获得焦点时也会重读。窗口开着时 App 是 `.regular`，
  有 Dock 图标和「窗口」菜单，这两条路都绕过 `showWindow`。开机自启动这一项尤其要紧：状态过期时
  `needsSystemSettings` 是 false，于是 `.requiresApproval` 唯一的补救按钮「打开「登录项与扩展」」
  根本不会画出来，而说明文字还在断言一个不会发生的自启动。
- 「图床」页补回两句被精简掉的话，都只在需要时出现。选完仓库后会显示一行「还没写入配置文件，要按
  保存」—— 原来那条常驻提示确实是在重复工具栏，但删掉之后，恰好在「刚选完、`draft` 里有值、关窗口
  就会丢」的那一刻没有任何提示，而还留着这句话的「还没配置图床」区块在选完的瞬间就消失了。登录按钮
  上方补回一句 `public_repo` 的说明：那是登录*之前*唯一会提到权限范围的地方，删掉之后，图床是私有
  仓库的人要先白授权一次、拿到一个空的仓库列表，再被指去终端跑 `--scope repo`。

### 内部

- 新增 `LaunchAtLoginState`（`GitPicCore`）承担状态映射与文案，可被测试覆盖。实测推翻了两处
  想当然的做法：`SMAppService.Status.notFound` **就是全新安装的状态**（从未登记过的 bundle 报的
  就是它，只有登记过再取消才报 `notRegistered`），所以它必须等同于「关」，而不能做成一个指向
  系统设置的错误态；另外头文件里写的 `kSMErrorAlreadyRegistered` / `kSMErrorJobNotFound` 在
  macOS 26.5 上并不会抛出 —— 重复调用直接成功。文档和系统不一致，所以判定只认回读状态。
- 新增 `src/release.rs`（版本解析与比较、发布查询）和 `GitPicCore/UpdateCheck.swift`
  （`--json` 解码、每日到期判断、正文裁剪），两边的规则都有测试覆盖。到期判断把「上次检查时间在
  未来」也算作到期 —— 时钟走快后被校正、或从备份恢复的机器会留下一个未来的时间戳，比较有符号差值
  会让它在真实时间追上之前一直不检查。正文裁剪两边各有一份实现（跨语言，只能如此），所以规则写在
  两边的文档注释里，逐条对应；`--json` 里的 `notes` 保持原样不裁，脚本可能要整段。
- 修掉 `src/github.rs` 里 stub server 的一个偶发失败：它每个连接只 `read` 一次，而 TCP 是流，
  `reqwest` 的 header 和 body 分两段发，所以单次 `read` 经常只拿到 header。全套测试里只有
  `put_file_sends_the_existing_sha_when_overwriting` 断言请求 body，实测约五次挂两次 —— CI 跑
  三个平台，发布构建变红的概率不低。现在读到 header 结束，再按 `Content-Length` 读完 body。
- 那个正确的读法搬进了新的 `src/testutil.rs`（`#[cfg(test)]`），`github` 和 `release` 共用。
  起因是 `release.rs` 的 loopback 测试原样重犯了单次 `read` —— 而它的后果比偶发失败更糟：那个
  测试断言更新检查**不发** `Authorization` 头，而一次截断的读会因为压根没读到 header 块而通过。
  一条因为什么都没看到所以成立的安全断言，比没有这条断言更糟，因为它看起来像是在守着。
- `RunFailure` 有了 `message`（`GitPicCore`，可测试）。原来 App 侧只匹配 `.cli`，其余走
  `String(describing:)`，于是把 Swift enum 打给了用户：源码构建的 App 配上 0.18.x 的
  `gitpic_cli`，「通用」页会显示 `undecodable(status: 2, raw: "error: unrecognized subcommand
  'update'")`，而且检查从不完成、`lastUpdateCheck` 不落戳，每次进页面都重来一遍。
  `ConfigFailure.other` 有同一个兜底，一起改掉了 —— 它原有的测试用 `contains` 断言，所以一直是绿的。
- 新增 `.github/scripts/release_notes.py`：「标记之前是摘要」这条规则只留一份实现，`release.yml`
  用它提取正文，`check_manifests.py` 导入它做校验。原来提取在 awk、校验在一个子串判断，两边漂移出
  三个问题：awk 命中行内任意位置的标记名（摘要里提一句这个标记就会把发布正文截断，而 workflow 自己
  的非空检查还会通过，因为剩下的标题行不是空的）；子串判断分不清标记放在细节下面（那样什么都没挡住）；
  以及这个校验只在 `ci.yml` 里跑，而 `release.yml` 由 tag 触发、根本不调它，`git push --follow-tags`
  会让两个 workflow 并行，Release 可能先发出去。现在 `version` job 里也跑一次，`publish` 依赖它。
  `MARKER_SINCE = (0, 19, 0)` 是让这个守卫能上发布路径的关键：0.19.0 之前的段落没有标记是故意的
  （backfill 旧 tag 要照发整段），所以标记只对 0.19.0 及以后强制要求。脚本带 `--self-test`，
  `ci.yml` 会跑 —— 这个仓库没有任何 Python 测试设施可以挂一个测试文件。

## [0.18.1] - 2026-08-23

### 设置页更简洁

### App

- 精简 Agent、关于、历史与上传设置页的文案，只保留操作所需的标签和说明。

## [0.18.0] - 2026-08-23

### Agent 集成各自管理，覆盖不再靠猜

### CLI

- `gitpic skill install --agent generic` 可把内置 Skill 安装到通用 Agent 的
  `~/.agent/skills`（或 `AGENT_HOME/skills`）。
- `gitpic skill path --json` 现在为每个目标报告预期的 `action`，UI 客户端无需先写入，就能区分
  新安装、有差异和未变化三种状态。
- `gitpic skill install` 默认拒绝替换有差异的 `SKILL.md`，只有显式传入 `--force` 才会覆盖。
  新安装采用原子无覆盖写入：即使状态检查后有其他进程创建了文件也不会误覆盖；读取失败也会如实
  报错，不再当成文件不存在。

### App

- GitPic.app 新增 **Agent** 设置页：Claude Code、Codex 与通用 Agent 分开管理，各自显示未安装、
  内容有差异或已是最新，并有独立的安装或更新操作。只有用户确认替换后，App 才会把覆盖权限传给
  CLI。

## [0.17.0] - 2026-08-23

### 一次全项目 review：三份会骗人的体检报告，两处会悄悄丢东西的写入

这一版没有新功能。对 CLI、App、脚本和 workflow 各跑了一遍 review，下面是查出来的东西 ——
凡是有得选，都选了「测试能失败」的那个版本。

**三处 breaking，范围都很窄。**

- `doctor --json` 的 `token_valid` 和 `repo_writable` 现在是 `true | false | **null**`，
  `null` 表示这项根本没查。下面说为什么原来的 `false` 是在撒谎。
- `gitpic config edit --json` 直接按 `USAGE` 拒掉，不再先把 stdout 交给编辑器、然后在后面补一个信封。
- 文件上传按**内容**命名，所以 `.jpeg` 渲染成 `.jpg`，扩展名和内容不符的文件会拿到真实扩展名。
  这类文件的新上传会落到新的远端路径，跟已经在仓库里的那份不再 dedup —— 每个文件多一个 blob，
  一次性的。已经传上去的东西不会移动、也不会坏。

#### `--compress` 在把人的照片转向

手机相机存的是横向像素加一个 `Orientation = 6`，自己并不转。`load_from_memory_with_format`
从不调 `orientation()`，两个重编码器也都不写回 EXIF —— `JpegEncoder` 只有调过 `set_exif`
才写，而这里没调。于是像素按原样重编码，那个「请把我转过来」的标签被丢掉了：所有看图的软件都
把照片显示成跟用户本地看到的差 90°，报告 `ok: true`，没有任何一处提示文件被改过。同一张照片上
`--max-width` 也是错的，原因一样 —— 它比的是存储宽度，于是缩错了那条边。

把旋转烤进像素是唯一能在元数据被丢掉之后还成立的做法。没有方向标签的图（也就是大多数图）
一点代价都不付。

#### `doctor`把三种坏配置说成健康

- **`link_kind = "cdn"` 配一个含 `/` 的分支。** 上传路径在解析凭据之前、发任何请求之前就按
  `USAGE` 拒掉它，因为 jsDelivr 把 ref 编码成 `repo@branch/path`。而 `gitpic repos` 会把
  GitHub 报的默认分支原样写进去，所以默认分支是 `release/v1` 的仓库就会跟默认的 `cdn` 一起
  躺在 `config.toml` 里 —— 而且是合法的，`Config::validate` 每个键单独校验。`doctor` 压根
  没读过 `cfg.upload.*`，于是报 ✓ ✓ ✓、退出 0，而每一次上传都退出 2、什么都没发。现在它报的
  代码和文案跟上传那边完全一样。
- **私有仓库配 `cdn` 链接。** `RepoInfo` 只反序列化了 `permissions`，把 `private` 从一个
  `doctor` 本来就已经拉到的响应里丢掉了。这种配置下每次上传都成功、每个 jsDelivr 链接都 404，
  而且没有任何地方说过：`repos` 只在选仓库那一刻警告，后来一句
  `config set upload.link_kind cdn`、或者把仓库改成私有，都会静悄悄走到同一个死状态。这算
  caveat 不算 failure，因为上传确实是成功的 —— 而这恰恰是它在某个意义上更糟的地方。
- **给一份根本没查过的凭据报 `token_valid: false`。** 三个探针都挂在 `config_ok` 上，但其中
  只有两个需要目标仓库。所以在「已经 `gitpic auth login`、还没 `gitpic repos`」的机器上，
  `/user` 从来没被调用，报告却说凭据无效 —— 而同一台机器上 `gitpic auth status` 说它是好的，
  GitPic.app 还会把这两个结论并排显示出来。看到 `✗ token valid`，人会去「重新登录」，那是拿
  一个新 token 去修一个配置文件。`null` 把「没查」和「查了，不行」分开；凭据本身**解析不出来**
  仍然是 `false`，因为那是一个确定的答案。要求 `true` 的 agent 不受影响。

#### `gitpic auth login`：拒绝启动、丢掉 token、对着没人的管道轮询

- 一个坏掉的 `auth.toml` 会挡住唯一能替换它的那条命令。`previous` 只是用来说一句「替换了原来
  存的 X 的凭据」，却是用 `?` 读的。
- 写失败会逃出它自己文档里承诺的流式契约，还把 token 一起带走。`auth::save` 在那个「错误会变成
  `error` 事件」的块外面，所以磁盘满时产生的是 `main` 那个七行的 pretty 信封：App 的逐行解析器
  把每一行都丢掉、报告「没有给出结果」，而几秒前刚拿到的 token 已经没了。
- `--json` 丢了人类路径里写得明明白白的那个闭合管道检查，所以
  `gitpic auth login --json | true` 会发出一次性码，然后对着 GitHub 轮询整整十五分钟 ——
  为了一个没人收到的码。
- `auth logout` 说的是「removed」，用户会理解成「revoked」。授权在 github.com 上仍然有效、
  而且不过期，所以一块恢复出来的磁盘、或者一份同步过去的旧文件，仍然是一份能用的凭据。gitpic
  没法吊销它（那需要 client secret），所以现在它把能吊销的那个页面地址说出来。

另外还有 `oauth.rs`，同一个文件里两处注释对「这个值算不算秘密」意见相反：`Device` 的 `Debug`
把 `device_code` 打码，理由是它「就是拿 token 的凭证」；而 `post` 说在设备端点「响应里没有任何
东西是凭据」，解析失败时照打 200 个字符的原始 body。现在两个端点都不打 body，状态码和
content-type 承担诊断，这两个都带不出秘密。

#### 三种悄无声息丢东西的方式

- **空的 `--repo` 会擦掉配好的目标。** `set_repo_spec` 只负责解析、不负责判断，所以一个空
  spec 会把空仓库名**覆盖**到文件里的值上，而失败要到两层之后才以 `CONFIG_MISSING` 冒出来，
  让用户去配一个文件里已经写着的仓库。触发它的就是一行普通脚本：`gitpic shot.png --repo "$REPO"`
  而 `REPO` 没设。现在空值等于「没给」，跟 `GITPIC_REPO`、`--client-id ''` 一个规矩。
- **一个坏字节毁掉整个 history 文件。** `read_to_string` 遇到非法 UTF-8 是整文件失败，所以一次
  被截断的追加会让 `gitpic list` 永久变成 `GENERAL` 错误 —— 而 `trim_file` 从此在每一次追加时
  提前返回，等于把 2 MB 上限关掉，文件无限长下去。现在两个读取都是 lossy 的，一个坏字节只花掉
  一条记录。
- **真正失败的 stdout 会报成功。** 同一个错误有两个相反的答案：`record_write` 直接 panic，
  在 `panic = "abort"` 下就是退出 134；而 `finish` 把它咽下去，让这次运行以退出 0 结束、留下一个
  被截断的文件 —— 你拿到哪个只取决于最后一次写有没有带换行。实测 `skill print` 在 `ulimit -f 1`
  下：改之前退出 101 加一段裸 panic，改之后退出 1 加
  `error: failed printing to stdout: File too large`。管道被关掉仍然算正常结束。

#### 这次一并做的

- **零字节文件会被拒掉**，跟 stdin 一直以来的规矩一样。`touch shot.png && gitpic shot.png`
  以前会产生一个真的 commit，再打出一个渲染成破图的链接。
- **大小上限在读文件之前就问。** `gitpic bigvideo.mov` 以前先分配三个 G，**然后**才说上限是
  100 MB —— 内存紧的机器上则是直接被 OOM 杀掉，退出 137。
- **只可能是 GET/PUT 竞态的那种 422 现在可重试。** 它的镜像是 409，从 0.13.2 起就是
  `NETWORK`、「让 agent 重试」；而竞态里输掉的那一方被告知退出 1，`SKILL.md` 把 1 定义为不要重试。
  按 body 判断，所以分支保护（也是 422）仍然是 `GENERAL`。（这个判断的第一版匹配的是带引号的
  `"sha"`，在生产里永远不会命中 —— body 是原始 JSON，那对引号是转义过的。测试抓到了。）
- **限流会说什么时候可以再试。** `retry-after` / `x-ratelimit-reset` 在读 body 前一行就被扔了，
  所以退出 9 —— 唯一一个存在意义就是被重试的码 —— 携带的信息反而最少。
- **`config edit` 能启动带参数的编辑器。** `EDITOR="code --wait"` 以前会去找一个就叫这个名字的
  可执行文件。现在走平台 shell，跟 git 启动编辑器的做法一样，并且先看 `$VISUAL`。发布审计还抓到
  Windows 初版错把 `cmd /C` 的 `%1` 当成 `sh -c` 的 `$1`；现在路径通过单独的环境变量传入，既不
  落进 shell 代码，也不会在 Windows 上变成字面量 `%1`。同一轮跨平台检查还修复了私有写入策略
  标志只在 Unix 使用、导致 Windows 的 warnings-as-errors 构建失败的问题。
- **`skill install --dir` 指到 `skill path` 打出来的那个路径，不再多装一层**（写成
  `gitpic/gitpic/SKILL.md` 还报成功）。写入改成原子的，崩溃不会留下一个 frontmatter 完好、
  正文被截断的 skill。`--agent all` 部分失败时会报告已经装好的那些，而不是丢掉。列表里的字样从
  `outdated` 改成 `differs` —— 前者是在替用户的文件下一个这里根本支持不了的结论。
- **`XDG_CONFIG_HOME=.config` 不再让所有路径变成相对 cwd 的**，而 0.16.0 之后这会把凭据一起带走。

#### GitPic.app

- **关掉设置窗口真的会停掉登录。** `cancelLogin()` 只有一个调用者 —— 取消按钮，而 0.15.0 之后
  窗口关闭不再释放，所以 ⌘W 会让 `gitpic auth login` 一直轮询到码过期。
- **取消后立刻重新登录不会再丢掉新任务。** 旧登录的流还要一个调度周期才能退完；它原来的
  `defer` 会无条件清空 `loginTask`，所以这时启动的新登录会突然显示成“不在进行”，取消按钮和关窗
  都再也停不掉它。现在只有创建这个任务的 generation 仍然有效时，它才能清自己的句柄。
- **复制一次性代码不再吞掉剪贴板失败。** 写不进去时会明确提示手动输入，而不是让按钮看起来像成功。
- **`gitpic` 找不到时，账号那一栏会一直转「检查登录状态…」直到进程结束。** `attach` 会回调
  `refreshAuth`，失败那条分支不会，而别处也没人会。
- **读不了 history 文件会被报成配置失败**，而两个面板对配置失败的处理是把整个可编辑表单换掉 ——
  于是一个坏掉的 `history.jsonl` 让所有设置都不能改，还指着错的文件说事。
- **启动跑了两遍 `reload()`**，在冷启动右键上传前面的串行闸口上多压了一次 `config path`、
  一次 `config get` 和一次 `list`。
- **启动日志用的是真的 `O_APPEND`**，不是 `seekToEnd()` 加一次写 —— `FileHandle` 上没有
  `O_APPEND`，而那个 seek 本身就是证据。两个进程并发实测：改之前 400 行只剩 396，改之后 400。
- **缩略图磁盘缓存的键带上了缩略图尺寸**，因为尺寸是「这些字节是什么」的一部分。原来调大
  `maxPixel` 之后每一行都还是命中，而 `decode` 不放大，于是面板会在更大的框里永远画小图。

#### CI 一直没在跑那个最要紧的检查

`FinderServicePlistTests` 读打好包的 `Info.plist`，没有包就把自己禁用掉 —— 而两个 workflow
都在 `scripts/build-app.sh` **之前**跑 `swift test`，`dist-app/` 又是 gitignore 的。所以从
0.15.0 以来的每一次 CI，那个把 `NSServices` plist 和注册它的 Swift 钉在同一组名字上的唯一检查
都在静静地什么都不检查 —— 而被跳过的测试仍然计入 "Test run with N tests"，连总数都没变。步骤
顺序修好了，并且在设了 `CI` 时这个测试现在会**失败**而不是跳过，所以再把它弄坏不会没声音。

另外三个原本不可能失败、现在可以了：`-q` 的源码扫描把「已被保护」的标记一直留到函数结束，所以
把真的保护删掉它照样全绿；四个 `pbs` 线上键此前只跟自己比，所以改错那个新键会让整个 suite 通过，
而开关会给一个已关闭的服务报「开」；`pngRoundTrip` 只断言了尺寸，而尺寸是能活过 JPEG 的，整个
target 里也没有一张带透明的图能抓到那些黑块。`check_manifests.py` 也会让一个被截断成 `{}` 的
manifest 通过，因为 `{}` 是 falsy 的。

#### 文档里过期的部分，恰好在被读得最多的两个地方

`release.yml` 的发布说明结尾还写着「Requires GitHub CLI (`brew install gh`)」—— 而 0.16.0
删掉了 `gh`，这段话从那以后被追加到**每一个** release body 上。`SKILL.md` 说 `auth login`
「refuses `--json` outright」，而同一个文件第 318 行详细描述了它的 `--json` 流。
`new-worktree.sh` 和 `AGENTS.md` 承诺 `--seed-config` 就能真的上传，而凭据搬进按 worktree 隔离
的 `auth.toml` 之后这句话就不成立了。

#### 顺手收掉的重复

`✓`/`✗` 存在四份、三种形状，`note:` 第四份 —— 正好是 `-q` 契约扫描看不见的那一份。路径模板的
dummy 样本写了三遍、错误文案写了两遍，而且已经漂移了。`matches!(mode, Mode::Quiet)` 八处。
`effective_link_kind`、`ConfigGate`、`Clipboard.write`、`UploadedLink.snippetOrReason`
各自收掉一条原来靠人在两三个地方同步的规则。`build-app.sh` 现在认 `CARGO_TARGET_DIR` ——
这个仓库自己的 worktree 流程就导出它 —— 失败时也不再留下一个长得像 bundle 的目录。

## [0.16.0] - 2026-08-23

### 只剩 `gitpic auth login` 一条路 —— `gh` 删掉了

**破坏性变更。** gitpic 不再从任何别的地方读凭据：

```bash
gitpic auth login     # 浏览器授权（GitHub device flow）
gitpic auth status    # 这枚凭据是谁的
gitpic auth logout    # 删掉
gitpic repos          # 这枚凭据能往哪些仓库上传
```

token 落在 `~/.config/gitpic/auth.toml`，权限 0600，用的是和 `config.toml` 同一套原子私有写入 ——
那套逻辑抽成了一个函数共用，不是抄一遍：紧挨着密钥的地方，"从第一个字节之前就是私有的"这条性质不值得
再推导一次。单独一个文件是故意的：`gitpic config get` 会打印它知道的每个键、`config edit` 会用
`$EDITOR` 打开文件，两者都碰不到凭据。也因此，`auth.toml` 是 `~/.config/gitpic/` 里唯一不该进 dotfiles
同步的文件。

**升级方式：跑一次 `gitpic auth login`。** 然后 `gitpic repos` 会列出这枚新凭据能上传的所有仓库 ——
挑一个，别再手输一个可能根本访问不到的 `owner/repo`。

授权请求的是 **`public_repo`**：公开仓库的写权限，是能干成这件事的最窄 OAuth scope（GitHub 没有"只给
某一个仓库"这种 scope）。它也够用 —— `link_kind = "cdn"` 指向的 jsDelivr 只服务公开仓库。图床是私有
仓库要用 `gitpic auth login --scope repo`，`repo` 宽到不适合做默认值；`GITPIC_SCOPE` 可以覆盖它，和
`GITPIC_CLIENT_ID` 覆盖 app 是一样的机制。

**GitHub App** 是另一个候选，权限本来更窄 —— 可以只给某一个仓库 `Contents: write`。它输在**流程**上，
不是权限上：GitHub App 的 user token 只能访问 App 被**安装**过的仓库，而 device flow 不会顺带完成安装。
那意味着每个用户都得先在终端授权、再去浏览器把 App 装到自己账号上并勾选仓库。"登录完立刻有一个列表
可选"比"更紧的授权但一半人走不完"更值。

#### 删掉一条路，另一条从未发布过

**破坏性的是 `gh auth token`。** 它在 0.14.0 及之前的每一版都能用，所以靠它的机器需要跑一次
`gitpic auth login`。两个来源就是两个身份：装了 `gh` 的机器上，一次上传算在谁头上取决于某个文件在不在，
而每个凭据错误都有两种解释要讲。它还让 `gh` 成了事实上的依赖 —— 而这件事 gitpic 现在自己一条命令就
做完了。

`--with-token` 只存在于通往这里的若干次提交之间，没有任何一个发布版本提供过它，所以不会有谁的配置依赖
它。但理由值得留下来：

- **粘贴 token（`--with-token`）。** 手工搬运的 token 会留在 shell history、scrollback、聊天记录里，
  而且它让 AI 助手可以要求用户"把 token 贴进对话"。device flow 不需要任何密钥经过人手。这个 flag 是
  **被拒绝**而不是被忽略的：悄悄丢掉别人 pipe 进来的 token 是最坏的结果 —— 密钥已经离开钥匙串了，却
  没有任何东西告诉你它没被用上。

`GITPIC_TOKEN` 和配置里的 `github.token` 仍然不支持，理由和当初删掉它们时一样：环境变量会漏进进程列表
和 CI 日志，`config.toml` 会被 `config get` 打印出来。文件里还留着 `token` 行的话，会得到一个点名它的
`CONFIG_INVALID`。

#### 这次一并做的

- **`gitpic init`没有了。** 它会依次问仓库、分支、链接形态，三样都得手打。前两样由
  `gitpic repos` 取代，而且做得更好：它列出这个凭据真的能 push 的仓库，按编号选，然后把
  `owner`/`repo` 连同 **GitHub 报告的默认分支**一起存下来 —— 手打分支正是默认分支为
  `master` 的仓库被配成 `main` 的原因，之后每次上传都会在一个不存在的 ref 上 404。
  链接形态改由 `gitpic config set upload.link_kind cdn|raw` 设置。所以第一次用现在是
  `gitpic auth login`，然后 `gitpic repos`。
- **`token_source` 字段删了**（`doctor --json` 里的；`auth status` 从来没有过）。只剩一个来源时，一个
  取值只可能是 `"gitpic"` 的字段，重复的是产生它的那条命令。`gitpic doctor` 也因此少打印一段。
- **所有持有 token 的类型都手写了 `Debug`**（`auth::Stored`、`oauth::Granted`），打印成 `<redacted>`。
  derive 出来的那个会把凭据送进 panic 信息和 `expect` 输出 —— 那是最没人会去翻的地方。
- **过期是 `AUTH_FAILED`，不是 `CONFIG_MISSING`。** 现在两者指向同一条命令，但把 3 读成"还什么都没配"
  的 agent，会跑去重配一个从来没出问题的仓库。
- **`gitpic repos` 是新命令。** 列出这枚凭据能访问的每个仓库，带默认分支、是否私有、能不能写 ——
  `--json` 给选择器用，纯文本给人看。它存在的理由：手输一个 token 看不见的 `owner/repo`，失败形式是
  一个光秃秃的 `404`；而且默认分支并不总是 `main`。
- **`auth login --json` 是唯一一个流式输出的子命令。** 其他地方 `--json` 都是"一次调用恰好一个信封"；
  这里代码必须比结果早几分钟到达调用方，而一个信封只能写一次。所以是逐行 JSON：一行一个完整对象，
  每行带 `event` 标签（`code`，然后 `done` 或 `error`），最后一行永远是结果。这正是让 GitPic.app 能在
  自己窗口里完成登录的东西。AI 助手仍然不该调它 —— 把 stdout 当单个对象解析的读者会在第一行就失败，
  而那个码只有人能输。
- **没人看得见的登录，在开始之前就被拒。** `gitpic auth login | true` 会把一次性代码扔进关掉的管道，
  然后照样轮询 GitHub 整整十五分钟。现在那行标题写在设备码请求**之前**，并且它同时就是探针：stdout
  被关掉这件事只能靠"往里写一次"发现，所以查得比这更早永远不会触发，查得更晚则代码已经签发出去了。
- **会过期的 token 在登录当时就报出来**，而不是等八小时后某次上传失败才发现。gitpic 用的 app 关掉了
  token 过期，所以这条通常不会出现；`GITPIC_CLIENT_ID` 指向一个开着过期的 app 时会。gitpic 不会自动
  刷新 —— 提示会让你重新登录。（device flow 拿到的 token 刷新其实**不需要** client secret，所以这是
  一个待补的缺口而不是做不到；目前 `refresh_token` 不落盘。）
- `GITPIC_CLIENT_ID` / `--client-id` 把流程指向另一个 OAuth app，`GITPIC_SCOPE` / `--scope` 指向另一种
  授权范围；`--no-browser` 跳过自动打开，而那个打开动作只对 `https://github.com/` 的 URL 生效。

#### GitPic.app：不开终端也能登录、选仓库

图床页多了「账号」区和仓库下拉框，第一次配置不再需要从"打开终端"开始。登录在窗口里完成：一次性码显示
出来（可复制），浏览器自己打开，GitHub 那边确认后这一页立刻切成已登录。仓库是**选**的，不是填的：
Owner / Repo / Branch 三个输入框已经没有了，分支跟着仓库来 —— 取 GitHub 上的默认值而不是假定 `main`。
和以前一样，不按「保存」不落盘。列表里显示不出来的仓库，`gitpic config set github.repo owner/name`
仍然可以直接给值。

背后三件值得点名的事：

- **登录不走那道串行闸门。** 其他每一次 `gitpic` 调用都在那里排队，好让两次上传不会在分支 ref 上打架，
  而那道闸门没有超时 —— 所以一次 device flow 登录（阻塞到码失效为止）会占住它十五分钟，把所有上传堵在
  后面。而登录和谁都不冲突：它写的是 `auth.toml`，没有别的命令碰这个文件。
- **流式读行复用了原有的 drain。** `ChildProcess` 用一个 `poll` 循环同时读两个管道，正是为了让哪一个都
  不会被饿死进那个 64 KiB 死锁；再加一个只读 stdout 的循环就是把它请回来。所以行回调是接进那个循环里的。
- **取消是真的停得住。** 关窗口或按「取消」会终止子进程，而不是留它一直轮询 GitHub 到码过期。

另外，App 里为 `gh` 准备的东西全都跟着删了：`ToolPaths.gh`、
`locateGH`、`GHStatus`、`GHProbe`、「关于」里的 gh 一行、「图床」里的「凭据来源」一行。`childPATH` 也
不再往前面拼任何目录了，因为 CLI 认证时不再 spawn 任何东西。

那套 gh 探测存在的理由只有一个：CLI 把"gh 没装"、"gh 没登录"、"gh 挂了"压成同一条 `CONFIG_MISSING`
并且把 gh 的 stderr 丢掉了，所以 GUI 只能自己再跑一次 `gh auth status` 才能说出点有用的话。只剩一个
来源就只有一种状态、一个处理办法，而且它已经在 `error.message` 里了 —— 所以 App 现在直接把 CLI 说的话
显示出来，不再自己推导一遍、然后和 CLI 走偏。
## [0.15.0] - 2026-08-23

### 选中图片，右键就能上传

**Finder 里选中图片按右键，菜单里多了一项「GitPic 上传至图床」。** 点它走的是和「选择文件
上传」完全相同的那条路：`gitpic <文件> --json`，完事按当前「格式 / 地址」把链接写进剪贴板，
再弹通知。多选可以，一次一批。App 没在运行也不要紧 —— 右键会把它拉起来。

**用的是 `NSServices`，不是 Finder 扩展。** 另外两种能往右键菜单里加项的做法都算过账：
Action 扩展（`com.apple.services`）和 `FIFinderSync` 能带上 App 图标，但前者要在
`Contents/PlugIns` 里放一个签好名的扩展包 —— SwiftPM 不构建这种目标 —— 后者还得用户自己去
「系统设置 ▸ 登录项与扩展」里打开，且只在它注册过的目录里生效。两者都需要一张真正的
Developer ID 才能稳定注册，而这个项目只有 ad-hoc 签名（见 `docs/macos-app-plan.md` C4）。
`NSServices` 写在 bundle 自己的 `Info.plist` 里，Launch Services 直接读，ad-hoc 签名不妨碍
它，用户也不用打开任何开关。代价是菜单项没有图标。

**少一个 `NSRequiredContext`，条目就根本不出现 —— 而且其他所有检查都会通过。** 这是这次
最贵的一个坑。没有这个键，服务照样注册、照样进服务缓存、`NSPerformService` 照样能按名字调起
它并完成整条上传链路 —— 唯独在 Finder 的右键菜单里不存在。也就是说除了"真的用手右键一次"，
没有任何一项验证能发现它。

定位方式是在一个 bundle 里同时声明五个变体，每个只和基线差一处，然后看菜单里少了谁：只有
去掉 `NSRequiredContext` 的那个缺席。顺带排除了几个当时更像元凶的怀疑对象 ——
`NSPortName` 无害（Safari 和 Xcode 都带它）；`LSUIElement` 无关（这台机器上恰好所有别的
服务提供者都是有 Dock 图标的普通 app，很容易误判成它）；app 装在隐藏目录 `.claude` 下也无关。
另外 `NSSendFileTypes = public.image` 本身完全可用，所以"只对图片显示"这个目标不用退让。

**条目在「服务」子菜单里，不在顶层。** 早先这里写的是"应该落在顶层"，依据是 Ghostty 那两项
当时确实内联显示 —— 那是误读：Finder 按当前服务的数量决定排布，本项加进去之后，Ghostty 自己
那两项也一起被折进了「服务」子菜单（实测）。位置由 Finder 决定，声明里没有任何键能钉住它，
所以设置里的说明文字改成告诉用户去哪儿找，而不是承诺一个位置。

**右键上传通常是一次冷启动，为此改了一处上传逻辑。** 服务把 App 拉起来，文件在
`resolveTools()` 还在找 `gh` 的时候就到了 —— 老代码这时会回一句「正在查找 gitpic，请稍候
重试」，也就是让人把刚做过的那一步再做一遍。现在 discovery 被存成一个 `Task`，上传先亮起
状态栏图标、报「开始上传」，**然后**才 `await` runner —— 这个顺序是重点：等待本身正是用户
否则会体验成"什么都没发生"的那一段。实测冷启动派发时 `upload started` 确实早于 discovery
的落地记录出现。

「上传剪贴板」也跟着改了。它原先在 discovery 期间会拒绝，而同一秒里右键却会等待并成功 ——
同样的意图、同样的文件 URL，结果相反，只取决于点了哪个入口。两条路现在都 `await`。

**首次配置的读取也被拉进了这条等待里，否则右键拿到的是错的链接形态。** `finish()` 要读
`AppModel.savedConfig` 才能解析两个地址、才能遵守 `upload.auto_copy`，而 `reload()` 要经过
`GitpicRunner` 那道串行门两次（`configPath()` 然后 `loadConfig()`，冷启动时 `configPath` 为
nil）。上传会挤在这两次之间，门序变成 `configPath` → `upload` → `loadConfig`，于是 `finish()`
读到空配置：CDN 地址不可用、`form.target` 被强制成 `.raw` 而横幅仍报着用户配置的形态，并且
**`auto_copy = false` 会被无视**（读不出配置时的兜底是 `true`）。现在 `resolveTools()` 直接
`await` 首次 reload，所以 discovery 完成即意味着配置已就绪 —— 这是语言层面的顺序保证，不是
靠时序碰运气。

**非图片会被挡下来，而且这道检查是必需的。** 实测：`NSSendFileTypes` 里的 `public.image`
只决定菜单里显不显示这一项；派发时 pbs 只检查剪贴板上有没有 `public.file-url` —— 它自己会
这么说（"Pasteboard contained types (), but service expects types (public.file-url)"）——
一个 `notes.txt` 就这样一路送到了 App 手里。而 CLI 也不验：`gitpic <文件>` 把拿到的字节原样
传上去（`src/commands/upload.rs` 只在 `--stdin` 命名时嗅探格式，`imageproc::maybe_compress`
认不出的格式直接放行）。所以这里是唯一能拒绝的地方，否则一个 PDF 会变成图床仓库里一个真实
的 commit。

### 设置里有开关

**「上传」页新增「Finder 右键」一节，一个开关管这一项在不在右键菜单里。** 它写的是 macOS
自己存这件事的地方 —— `pbs` 域里 `NSServicesStatus` 下的一条按服务的记录，也就是「系统设置
▸ 键盘 ▸ 键盘快捷键 ▸ 服务」那个勾写的同一条。之所以要写到那里去：菜单项来自 bundle 的
`Info.plist`，App 运行时做什么都拿不掉它，只有这条记录能。

**没有第二份状态。** 开关直接读那条记录，而不是在旁边另存一个自己的标记 —— 否则用户在系统
设置里关掉之后，GitPic 的开关还会显示"开"。菜单标题本身也不是第二份：`pbs` 用标题做键，所以
标题从**运行中 bundle 的 `NSServices` 数组**里按 `NSMessage` 反查出来，开关的键在构造上不可能
和菜单不一致。也因此它即时生效，不跟着右上角「保存」走；它和配置文件无关，所以那一节放在依赖
配置的分支**外面**，配置读不出来时也还在。

**关掉之后服务端会再确认一次。** pbs 实测仍会把消息派发给一个已关闭的服务，所以
`ServiceProvider` 自己也查一遍：菜单项已经不在了是常态，但服务缓存没跟上的时候，这一道才是让
开关的答案仍然为真的东西。（标题改名会孤立旧记录，那种情况这道检查也救不了 —— 只有别改名能。）

**读这条记录踩过两个坑，第二个更要紧。**

`enabled_context_menu` 不是现在的写法。AppKit 自己的诊断字符串把它叫做 *"the older
'enabled_context_menu' key"* —— 这句连同 `presentation_modes`、`ContextMenu`、`ServicesMenu`、
`TouchBar` 都能在 macOS 26.5 的 dyld 共享缓存里逐字找到。只认旧键的读法，会在系统设置只写了新键
时把一个已关闭的服务报成"开"。现在以 `presentation_modes` 为主、旧键兜底、都读不懂才默认为开。
**新键的值结构是推断的，不是观察到的**：这台机器从没有人切过任何服务（`NSServicesStatus` 回读
是空字典），所以没有真实条目可看，模式名来自 AppKit 的符号而不是某个 plist。因此读的时候两种
可能的编码都认，写的时候**只更新已经存在的** `presentation_modes`、绝不凭猜测新建一个。

另一个坑：同一个标志在真实 `pbs.plist` 里可能是布尔、整数，也可能是字符串 ——
`defaults write … '{enabled_context_menu = 0;}'` 存进去的那个 `0` 是 `NSTaggedPointerString`，
因为老式 plist 文本里根本没有数字语法。只认 `NSNumber` 会把已关闭的服务读成开着。三种写法现在
都认，而且字符串只认可识别的值：`NSString.boolValue` 从不返回 nil，会把 `""` 也算成 `false`，
那样一个读不懂的条目就会**关掉功能**却什么都没从菜单里拿掉 —— 恰好是"读不懂就默认为开"要防的。

**写入是尽力而为，而且它说明了这一点。** 早先这里会回读一次并给调用方一个"是否落地"的标志，
那是同义反复：回读命中的是刚写过的同一个进程内 CFPreferences 缓存，所以无论底下发生了什么它都
回显写入值。用 `chflags uchg` 锁住 `pbs.plist` 实测：`CFPreferencesAppSynchronize` 仍返回
`true`，进程内读到新值，而 `NSDictionary(contentsOfFile:)` 读到旧值。改读文件也不行 —— 写入正常
时 cfprefsd 通常还没落盘，那样会把好的写入报成失败。所以那条"改不了右键菜单"的假通知删掉了，
开关的说明文字改为指向系统设置，那是这段代码唯一能诚实提供的东西。

**改动那条记录时会保留同级键。** 原先是整条替换子字典，会连 `key_equivalent` 一起丢掉 ——
那是用户自己设的服务快捷键（这台机器的 `pbs.plist` 里有 `ServicesShortcutsPresent`，说明确实
存在）—— 于是把右键项关掉再打开，会静默拿走一个快捷键。

### App

- 状态栏菜单没有变化：右键是第四个入口，前三个（选择文件、剪贴板、CLI）都还在。
- 失败措辞按情况分开：没有图片说「选中的不是图片：<名字>」（超过三个折成"等 N 个"，因为
  通知正文会被系统按它自己挑的长度截断），一个文件都没收到说「右键上传没有收到文件」，开关
  关着时说「右键上传已关闭」—— 走的是中性通知，不是上传失败那条路（那条的横幅标题硬编码为
  「GitPic 上传失败」，而一个被遵守的设置不是上传失败）。混选里被丢掉的文件现在会单独点名，
  而不是留下一个跟用户所选数量对不上的成功计数。
- `~/Library/Logs/GitPic.log` 记下每次右键派发：收到几个、其中几张是图片、跳过了哪些。

CLI 一行没改。

## [0.14.1] - 2026-08-23

### stdin 认不出格式时，报错在让人重做刚做过的事

0.14.0 把「字节认不出 + `--name` 只有词干」判成 `USAGE` —— 这是对的，把它按猜出来的
`.png` 发上去就等于对内容撒谎 —— 但沿用了「完全没给 `--name`」那一版的措辞：
*「cannot tell what kind of image this is from the bytes; pass --name to set the
filename」*。已经传了 `--name shot` 的人读到这句，唯一能想到的下一步正是刚刚失败的那步。

agent 会稳定踩进这个循环，因为 `SKILL.md` 其他地方的规则是「`--name` 给词干，字节给扩展名」，
还专门写了「不要靠 `--name` 设扩展名」。而认不出格式的字节恰好是这条规则反过来的唯一场景：
没有别的地方能拿到扩展名，只能由 `--name` 带。

两头都修了。报错现在说清缺的是什么（`--name "shot" carries no extension and these bytes
are not an image gitpic can identify … e.g. --name shot.bin`），随二进制发布的 skill 则在
§3 和那条会冲突的规则旁边都写明了这个例外，并给了 agent 真正需要的一句：重试时不要把扩展名
去掉。skill 是 `include_str!` 编进二进制的，所以要靠这一版才送得出去。

skill 里另外补上：`config set --json` 带 `changes`（每个键一条 `{key, value}`，值是落盘后的），
只有单对时才保留顶层的 `key`/`value`。

## [0.14.0] - 2026-08-23

### 新增 `gitpic branches`，分支也变成"选"的

分支原来在 App 里是只读的，取仓库的 `default_branch` —— 绝大多数时候对，但想用一个专门的 `images`
分支或者 `gh-pages` 时就不对了。现在它是第二个下拉框，背后是一条新子命令：

```bash
$ gitpic branches                              # 当前配置的仓库
* main  (configured, protected)
  images

$ gitpic branches --repo octocat/legacy --json  # 任意仓库
{ "ok": true, "repo": "octocat/legacy", "configured": "main", "complete": true,
  "branches": [ { "name": "master", "protected": false } ] }
```

用列表而不是输入框，理由是这个字段独有的：上传走的 contents API **只往已存在的 ref 里写，不会创建
分支**，所以 `github.branch` 的合法取值恰好就是这个仓库的分支集合。取值落在集合外，每次上传都是
`REMOTE_NOT_FOUND` —— 而 GitHub 对"ref 不存在"和"token 看不见这个仓库"回的都是 404，这让打错的分支名
成为 gitpic 里信息量最低的一种失败。

所以在会发生的时候，纯文本输出会把这件事顶到最前面：

```
$ gitpic branches --repo tarnish233/GitPic-legacy
  master
  tmp-verify-sha
  note: `main` is configured but not in this list, so every upload will fail on a ref
        that does not exist — `gitpic config set github.branch <one of the above>`
```

这正是 `config set github.repo` 留下的那个隐患 —— 现在一条命令就能看见，而不是等一次上传失败。

- **受保护的分支会标出来，但不会被过滤掉。** 受保护不等于写不进去（规则可能允许当前账号），把它从列表里
  拿掉就是拿掉一个合法选项。它之所以要报，是因为在其他检查都过了之后出现 409/422，它通常就是原因。
- **没有 commit 的仓库列不出分支，而这不是错误。** 第一次上传会创建那个 ref，所以 `ok` 仍然是 true，
  人类可读的输出会把这件事说出来。
- **这里可以用 `--repo`**，和 `doctor` 一样 —— 这两条是"回答关于某个仓库的问题"的只读查询，先看一眼
  再决定要不要写进配置才有意义。放错位置的上传参数的报错文案里两条都提到了。
- **App 的分支下拉是跟着草稿走的，不是跟着已保存的文件。** 有意思的时刻恰好是"选好仓库、还没按保存"
  之间，而那时屏幕上留着的正是上一个仓库的分支 —— 所以一份为已经被切走的仓库返回的列表会被丢掉，而不是
  拿出来给人选。
- **图床页去掉了 `App` 那一行。** 它显示的是 OAuth client id，一个紧挨着账号名的常量字符串。
  `gitpic auth status` 会打印它，那才是二十个字符的不透明值该待的地方；换 app 真正会改变的那件事 ——
  token 会过期 —— 本来就有自己的一行。
- **`gitpic branches --json` 遵循 agent 读的那份分支契约**（技能文档 §0c），包括那条规则：`configured`
  不在 `branches` 里，这本身就是结论，不是权限问题。

### `gitpic init`删掉了：选仓库这件事挪到取凭据的地方

**破坏性变更。** `gitpic init` 已删除。`gitpic auth login` 现在会在最后把这份新凭据能上传的仓库列出
来，选中的那个直接落盘：

```
✓ logged in to github.com as octocat
  stored in: /Users/x/.config/gitpic/auth.toml

which repository should gitpic upload to?

  [1] octocat/GitPic-legacy   (branch master)
* [2] octocat/picture_of_notes  (branch main)
  [3] octocat/dotfiles        (branch main, private)

image host? [1-3] [2]:

✓ octocat/picture_of_notes on main — saved to /Users/x/.config/gitpic/config.toml
```

`init` 的形状已经错了两层。它需要凭据之后就不再是「初始化」—— gitpic 不知道你是谁之前，列表里没有
任何东西可选 —— 于是这个名字承诺"第一条跑的命令"的子命令，实际上严格是第二条，而两个 README 都还在
不提顺序地介绍它。同时它自己也没剩什么要问的了：目标改成从列表里选而不是打字之后，`init` 只剩一个
问题，晚了一条命令才问，而问的那一刻调用方手里正好握着回答它所需要的那份凭据。

**之后想换图床仓库**：`gitpic config set github.repo owner/name`，用 `gitpic repos` 看有哪些可选
（App 里是图床页的下拉框）。有一个 `init` 以前替你藏着的代价 —— **`config set github.repo` 不会动
`github.branch`**。默认分支是 `master` 的仓库配上 `main`，每次上传都会撞上一个不存在的 ref；
`gitpic repos` 会把每个候选的 `default_branch` 一起打出来，真撞上了 `gitpic doctor` 会直接说是分支
不存在。

`gitpic init` 没有被特判成一条提示。`Cli` 收位置参数当文件名，并且刻意不设
`args_conflicts_with_subcommands`，所以这个词现在就是被当成文件名：`error: file not found: init`，
退出码 6 —— 和任何一个打错的子命令一直以来的行为一样。

这次一并做的：

- **`CONFIG_MISSING` 的处理建议不再提它。** `Config::require_target` 和 `doctor` 都把"跑
  `gitpic init`"作为最常见的首次失败的解法发布出去，不改的话，退出码 3 的建议就会指向一个已经解析不了
  的子命令 —— 对照着做的 agent 还会因此陷入循环。两处现在都改成 `gitpic repos` 和
  `gitpic config set github.repo`，这两条在任何情况下都不会是错的建议：`repos` 自己会去取凭据，所以
  没登录的人会从真正需要凭据的那条命令那里拿到登录提示。有一个集成测试会去读未配置用户实际收到的那条
  消息，并要求它提到的东西真的能解析。
- **选择器和列表放在一起**（`commands::repos`），不在 `auth_cmd` 里。哪些仓库才有资格被列出来 ——
  能不能 push、私有仓库与 jsDelivr 的关系、翻页被截断 —— 是同一套规则，而 agent 读的那份 `--json`
  列表必须遵守同样的规则。
- **选错了是重问，不是报错返回。** 选择器跑在凭据已经落盘**之后**，所以为一个手误返回 `USAGE` 会让一次
  已经完成的浏览器登录以失败收场，而"登录失败"最自然的反应就是再登一次 —— 为了修一个仓库列表而多铸一个
  token。给三次机会，然后给出兜底命令。不该由用户负责的失败（列表拿不到，比如没网）出于同样的理由也只是
  一条 note。
- **`commands::prompt` 跟着那条命令一起删了。** 它把 EOF 当成"同意默认值"，这只对 `init` 那种"保持
  当前配置"的字段是安全的；剩下的两个提示 —— 选择器和 `skill install` —— 都把 EOF 当成中止，因为两者
  都要写东西。
- **没有写权限的仓库被排除，但会报出数量。** 一个推不进去的仓库不是"选项"，而是一个之后才失败的选择。
  但"我的仓库怎么不在里面"是更难回答的问题，所以数量要打出来。

### 拖拽上传整体删除，包括菜单栏图标落区

**从这一版起 GitPic.app 不接受任何拖拽。** 往菜单栏图标上拖图片不再上传 —— 这是 0.13.x 一直有的行为，
现在没了。上传入口剩下三个，都还在：菜单里的**「选择文件上传」**、**「上传剪贴板」**，以及 CLI
（`gitpic <文件>`，app 和终端共用同一个二进制）。

删掉的原因不是它不工作，而是**这个交互本身别扭**。落区一共做过五种形态，每一种都真的做出来、装上、
上手拖过：

1. **菜单栏图标本身**（0.13.x 的行为）—— 实测落区只有 **36×29 pt**（图片 20×16，系统左右各补 8pt），
   而且**把图标调大也没用**：`NSStatusBar.system.thickness` 就是 22 pt，字号提到 `pointSize 17` 也只到
   42×30。天花板是菜单栏本身。
2. **拖拽即弹的浮窗**（240×132 pt，出现在光标旁）—— 行程为零，但在 Finder 里挪一张 PNG 也会弹，噪音
   无法接受。
3. **屏幕右上角热区** —— 安静了，但要跑到角上。
4. **图标下方热区** —— 更近，但**看不见的触发区，手停短了就悄无声息什么都不发生**：追踪到真实的瞄准
   落点是 y = 1015~1032，而热区从 1038 才开始。热区加深到 64pt 之后能触发了，代价是又多一层要解释的
   行为。
5. **⌃ 召唤**（面板出现在光标下方 48pt）—— 撞不短、不用瞄、零噪音，技术上也全部验通。但到这一步已经很
   清楚：为了让"拖一下"这件事成立，需要向用户解释一个键、一段延迟、一块会出现的面板。

结论是不做。**「选择文件上传」和「上传剪贴板」两个入口本来就覆盖了同样的需求，而且没有任何需要解释的
地方。** 与之一起删除的还有：`StatusIcon` 的悬停态（那个 glyph 只为落区存在）、`ImageDrop`（"落区接受
什么"的规则）、`Motion.shelfArrival`（面板的淡入）。

**实测数据保留在 `docs/macos-app-plan.md` §C6，标注为已废弃。** 那一节里的约束都还是真的，谁将来想再
做拖拽都得先跨过它们：菜单栏图标落区的 36×29 pt 上限；`.accessory` app 的非激活面板确实能收到别的 app
发起的拖拽；全局*鼠标*监听不需要辅助功能授权，但**任何普通键（包括空格）都需要**——两个进程同一时刻
采样 `CGEventSource.keyState`，受信任的读到 `true`，不受信任的全程 `false`，而这份授权按代码签名记，
ad-hoc 签名每次构建都变；`NSPasteboard(name: .drag)` 的 `changeCount` 变了**不等于**内容写好了
（`clearContents()` 自己就递增计数器，而真正写入条目根本不再递增）；以及这块面板不能用 `.behindWindow`
模糊 —— 120Hz + 4K@2x 上，拖拽图标从它上面经过时每帧都要重算。

### 菜单栏图标跟着正在跑的上传走

以前 `report()` 谁后写谁赢：第二次上传，或从「最近上传」里复制一条，都会把图标打回空闲，
哪怕另一次上传还在排队。现在是计数；复制走自己的通知，不再打成「GitPic 上传失败」。
`CONFIG_MISSING` 的 `gh` 探测改到 discovery 队列上，不再占协作线程，并且先把上传中的
图标拿掉。

之后再读到 `CONFIG_INVALID`，图床 / 上传页不再继续显示上一份能用的表单——「备份并重建」
会再出现。没有 `gitpic` 时点连通性测试会说找不到，而不是一直停在「还没测过」。

### CLI：坏的 `--path` 在取凭据之前就是 USAGE；409 可重试

`--path ../x/{name}.{ext}` 以前会走到 `gh auth token` 再报 `CONFIG_MISSING`。现在先按
`USAGE`（退出码 2）拒绝，时机和「分支带 `/` 的 CDN 链接」一样。`--stdin` 读到辨不出格式的
字节、又只给了词干（`--name shot`）时也是 `USAGE`，不再发明一个假 `.png`；文件上传仍然回退到
文件自带的扩展名。Contents API 409 是 `NETWORK`（退出码 5），agent 会重试；Windows 写配置
不再先删掉再 rename。

`gitpic config set` 接受多对 `KEY VALUE`，写一次文件，后面的键校验失败不会把前面的留在
盘上。App 的保存就是这一次进程。

上传专用 flag（`--compress`、`--no-copy` 等）不再是 global，换来两件事：`gitpic list
--compress` 是 clap 报错而不是静默忽略，以及**它们现在必须写在子命令后面**。写法是
`gitpic paste --no-copy`；`gitpic --no-copy paste` 会报 `USAGE`（退出码 2），而不是解析
通过再被丢掉，`doctor` 前面的 `--repo` 同理。`--json`、`--quiet`、`--verbose` 不动 ——
它们在哪儿都有意义，写在子命令哪一侧都行。

## [0.13.2] - 2026-08-22

### App 改发 dmg，设置界面少说几句话

**macOS App 从这一版起发 `GitPic-<版本>-macos-arm64.dmg`，不再发压缩包。** 镜像里除了 App 还有一个
指向 `/Applications` 的符号链接 —— 这个别名才是它值得做成 dmg 的理由，打开就能拖过去，zip 给不了。
UDZO 压缩，体积和原来的 zip 差不多：拿 0.13.1 的 bundle 实测 4.76 MB 对 4.35 MB，为安装手感贵 9%。

**但它对 Gatekeeper 毫无帮助，这点没变。** App 仍是本机 ad-hoc 签名、未经 Apple 公证的，下载下来的
dmg 一样带隔离属性 —— 手动安装的人**仍然要**跑 `xattr -dr com.apple.quarantine`（用 brew 装的话 brew
替你做）。dmg 改善的是安装的手感，不是 macOS 对它的信任。

CI 的验证方式跟着改了：**只读挂载镜像后就地断言**，而不是解压一份出来查 —— 发布的是镜像，那就该查
镜像。原有十条断言一条没少，另加一条查 `/Applications` 别名还在（丢了它照样能手装，只是会悄悄不再是
"拖一下"）。整条打包+验证在本机 macOS 上先跑通了才交给 CI。

### App

- **状态栏菜单的三个省略号删了**：`选择文件上传`、`打开设置`、`连通性测试`。需要说明这是**有意偏离
  平台惯例** —— macOS 用 `…` 标记"这个命令还需要更多输入才能完成"，Apple 自己的 `设置…` 和所有打开
  面板的项都带它，而这三项确实都会打开东西。
- **「上传」页「链接」的说明只留第一句**（两个键叫什么、按「保存」才生效）。删掉的是"状态栏菜单即时
  写入 / 复制哪个 snippet / 六种组合不重传 / `-f` `--link` 可临时覆盖"那一整段 —— 都是真的，但在一个
  人正盯着两个分段控件的时候都不需要。
- **「自动复制到剪贴板」的说明整段删掉**，开关收成一行；开关自己说明了它做什么。App 为什么和 CLI 读
  同一个键，留成了代码注释 —— 那才是它该待的地方。
- **「关于」页删掉两处解释**：`versionNote` 整个移除（它用三段散文说的事，两个版本号对上或对不上本来
  就说清了），「工具位置」保留两行路径、删掉那句关于 Finder 启动只有最小 PATH 的话。

### 文档

- **两份 README 顶部加了 App 图标**，居中排版（图标 → 标题 → 一句话说明 → 语言切换），和多数开源项目
  一致。图标是从已安装的 `AppIcon.icns` 里抽出来的（`iconutil`，512×512），不是重画的 —— README 上
  显示的就是 App 实际装的那个。放在 `docs/assets/icon.png`，相对路径，fork 和离线都能渲染。

**旧 README 里的 `brew install tarnish233/tap/gitpic` 被写成"仍然装命令行"，而它现在装的是
App。** 0.11.5 把 cask 改名成 `gitpic` 并删掉了 formula 的旧名映射，那次发布只改了 changelog 和
manifest，两份 README 没跟上。实测确认过：这条命令解析到 cask（0.13.1），而 `--formula` 加同一个
名字会报 `No available formula ... Found a cask named "tarnish233/tap/gitpic" instead` —— 也就是说
照旧文敲、想装命令行的人会装到 App。只要命令行的正确写法一直是 `brew install
tarnish233/tap/gitpic_cli`。旧 cask 名 `gitpic_app` 仍由 `cask_renames.json` 兜着，已经装了的不会断。

**两份 README 重排了顺序，也短了不少**：先 GitPic.app，再讲命令行和 App 是同一个东西（同一个文件、
不可能版本不一致、配置和历史共用）以及 CLI 用法，最后是 AI 助手技能。271 → 178 行，英文 315 → 202。
砍掉的是重复和过度细节 —— 开头那段长 console 演示、formula/cask 冲突的逐种情形展开、独立的「命令行
补全」和「Downloads」两节（各折成一行）、以及关于 `--json`、严格键校验、`doctor` 的几段长散文。留下
的是照着敲会用到的东西：完整的 `config.toml`、占位符列表、退出码表、`--json` 的三个例外、给助手的
两条约定。新 README 里每条命令都实跑验过。

**AGENTS.md 现在写清了 tap 是怎么知道有新版本的**，顺带修掉同一段里两处已经不成立的说法（说 cask 叫
`gitpic_app`；说 `formula_renames.json` 别删 —— 那个文件 0.11.5 就删了，正是因为留着会让 `gitpic`
在 formula 和 cask 之间二义）。

### CI

- **发布之后 tap 不用再等最多 6 小时了。** `release.yml` 的 `publish` job 在 release 发布成功后向
  tap 派发一个 `repository_dispatch`（`gitpic-released`，载荷带版本号），tap 秒级跟上 —— 实测 10 秒
  跑完。这件事的动机是量出来的：0.13.0 在 05:17Z 发布时 tap 还钉着 0.11.5，`brew upgrade` 对一个已
  经发布的版本无话可说。需要 `secrets.TAP_DISPATCH_TOKEN`（限定 tap 单仓库的 fine-grained PAT，
  Contents: write），因为 `GITHUB_TOKEN` 的作用域到不了别的仓库。
- **tap 那条六小时 cron 保留**，降级成兜底。这是设计而不是遗漏：token 没设、过期、被撤，或者 GitHub
  抖一下，都必须退回旧行为而不是让 tap 永久卡住。同理，派发步骤带 secret 守卫（secret 不存在就整个
  不运行，所以加它的那段时间里不可能弄坏发布）和 `continue-on-error`（跑到它的时候 release 已经发布
  了，为一件 cron 会自己修好的事把好 release 标成失败是不划算的）。
- **派发带着版本号，tap 核对不上就响亮地失败。** 发布和 `releases/latest` 更新不是一个原子操作，早跑
  一秒的 run 会读到上一个版本、把 tap 钉在它上面、然后报成功 —— 接着一直坐到下一次 cron。那种静默的
  错答案比失败更糟。两个方向都实测了：版本对上 → success；故意派发 `0.0.1` → failure，日志打出
  `dispatch was fired for v0.0.1 but releases/latest is v0.13.1` / `refusing to pin the tap to a
  release the dispatch did not name`，而且是在下载校验和、重写 formula/cask 之前就死的 —— 事后核对
  tap 一个字节都没被动过。

## [0.13.1] - 2026-08-22

### 边栏不再折叠：那个按钮对标错了窗口

### 修复

- **设置窗口的边栏不再能折叠，那个折叠按钮也删掉了。** 隐藏和展开它是会抽的:展开的瞬间详情内容
  还按折叠状态的旧宽度布局,被挤出窗口右边缘裁掉;工具栏同时按变窄后的区域计算,放不下就长出一个
  `»` 溢出指示符,一闪又没。两个现象一个根因,而这一版的做法是**删掉这个操作而不是修它的动画**。
- **这推翻了 0.11.2 里 `192566c` 的决定,而理由不止是那个 bug。** 那个提交加回按钮的论据是"缺少边栏
  折叠按钮不符合平台惯例",举的例子是 Passwords 和 Mail。但那两个是带可拖拽边栏的**内容浏览器**,
  而这个窗口不是照它们做的——它照的是 **System Settings**,这句话在同一个源文件里已经写过两次,
  而 **System Settings 根本没有边栏折叠按钮**。四个固定面板不需要它,当初类比错了对象。
- **删的是三样东西,所以这个操作是"没有了"而不是"藏起来了"**:`columnVisibility` 状态、
  `NavigationSplitView` 上的绑定,以及 `.toolbar(removing: .sidebarToggle)` 拿掉按钮本身。在构建好
  的 bundle 上实测:工具栏从 6 个按钮变 5 个,里面没有 隐藏边栏／显示边栏;菜单栏没有「显示」菜单,
  所以既没有菜单项也没有 ⌃⌘S。
- **一个遗留物记在注释里而不是默默删掉**,因为它会咬到以后任何想再加折叠的人:`.frame(width: 200)`
  同时压在边栏的内容和它的列上。写它的时候无害——那时边栏根本不能折叠——但一旦能折叠,每次折叠
  都是在把一个列从 200pt 动画到 0,而它的内容被用绝对点数告知"只能是 200 宽"。没有任何宽度同时满
  足这两条指令,所以过渡没有平滑的路可走。`navigationSplitViewColumnWidth` 本来就是全部所需,现在
  留下的就是它。
- 代价写在注释里:那 200pt 现在是**永久占用**的,小屏幕拿不回来。这和 System Settings 给的条件一样。

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

[0.18.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.18.1
[0.18.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.18.0
[0.17.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.17.0
[0.16.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.16.0
[0.15.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.15.0
[0.14.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.14.1
[0.14.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.14.0
[0.13.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.13.2
[0.13.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.13.1
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
