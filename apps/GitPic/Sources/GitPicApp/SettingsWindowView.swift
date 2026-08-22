import AppKit
import SwiftUI
import GitPicCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case host, upload, history, about
    var id: Self { self }

    var title: String {
        switch self {
        case .host:    "图床"
        case .upload:  "上传"
        case .history: "历史"
        case .about:   "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .host:    "photo.stack"
        case .upload:  "arrow.up.circle"
        case .history: "clock.arrow.circlepath"
        case .about:   "info.circle"
        }
    }

    /// Whether this pane edits the config file, and so carries the save bar.
    var savesConfig: Bool {
        switch self {
        case .host, .upload:   true
        case .history, .about: false
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .host

    /// Visited panes, oldest first, and where in that list we currently are.
    ///
    /// Held here rather than in the view's `@State` because the window is no longer
    /// thrown away when it closes — see ``SettingsWindowController``. The behaviour is
    /// the one it always had; it is now stated instead of falling out of a destroyed
    /// view: ``endSession()`` spends the history when the window closes, the way
    /// System Settings starts over. `selectedTab` deliberately survives, because the
    /// status item's 连通性测试 sets it before the window exists.
    var history: [SettingsTab] = [.host]
    var historyIndex = 0
    /// Suppresses recording while back/forward is what moved the selection —
    /// otherwise stepping back appends the pane just left, and the two buttons
    /// walk in a circle instead of walking a history.
    var steppingThroughHistory = false

    private init() {}

    /// The window closed: the trail through it is spent, and the next open starts
    /// from wherever it will land rather than from a stale list.
    func endSession() {
        history = [selectedTab ?? .host]
        historyIndex = 0
        steppingThroughHistory = false
    }
}

/// The settings window: a sidebar, one pane at a time, and a toolbar.
///
/// **No bottom bar, deliberately.** It used to carry a status line and the
/// 保存/放弃 pair. The line is gone rather than moved: an outcome is an event, this
/// window is usually shut when one happens, and Notification Center is where the
/// app already reported uploads — two surfaces saying the same thing meant the
/// bottom one was mostly stale. What the line *did* uniquely carry, a failed config
/// read, is now stated in the pane that owns it, next to the buttons that fix it,
/// instead of as one truncated line of `undecodable(status: 10, raw: …)` at the
/// bottom of the window. The buttons moved to the toolbar.
///
/// The cost is stated because it is real: with notification permission denied,
/// outcomes reach only `~/Library/Logs/GitPic.log` — see `AppModel.notify`.
struct SettingsWindowView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var model = AppModel.shared

    private var activeTab: SettingsTab { navigation.selectedTab ?? .host }

    /// **The sidebar does not collapse, and there is no button offering to collapse
    /// it.** Both were here and both are gone; the reasoning is on ``sidebar``.
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 480)
        // A toolbar is what forces NSToolbar to exist, which the liquid-glass
        // title bar treatment depends on. It is also where 保存 lives, now that the
        // window has no bottom bar to put it in.
        .toolbar {
            // Leading, where the platform puts navigation: the sidebar can reach any
            // pane in one click, so these are for retracing — the same role they play
            // in System Settings, and the reason they are `.navigation` rather than
            // two more buttons crowded in beside 保存.
            ToolbarItemGroup(placement: .navigation) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!canStep(-1))
                    .help(canStep(-1) ? "回到\(navigation.history[navigation.historyIndex - 1].title)"
                                      : "没有上一个")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!canStep(1))
                    .help(canStep(1) ? "前往\(navigation.history[navigation.historyIndex + 1].title)"
                                     : "没有下一个")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Progress goes *inside* the refresh button, in place of its glyph.
                //
                // Two earlier arrangements were wrong in opposite ways. A separate
                // spinner item inserted when work started and removed when it stopped
                // made AppKit relayout the toolbar, so 刷新 / 放弃 / 保存 slid sideways
                // and back on every window open. Reserving the space for it instead —
                // a hidden `ProgressView` next to the button — stopped the sliding but
                // left the button and the invisible spinner sharing one glass capsule:
                // a pill twice the width it needed, with the arrow sitting off-centre
                // in it and nothing matching 放弃 / 保存 beside it.
                //
                // Swapping the glyph has neither problem. The button is one control in
                // its own capsule, the same size busy or idle, and the thing that
                // reports the work is the thing the work belongs to. A save writes one
                // `gitpic` process per changed key, so "nothing is happening" and "ten
                // processes are queued" still need telling apart — this says it in the
                // space the button already occupies.
                Button { Task { await model.reload() } } label: {
                    ZStack {
                        if model.busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    // One box for both states, so the button is the same width busy or
                    // idle — otherwise the spinner is a hair wider than the glyph and
                    // the sliding toolbar comes back in miniature.
                    .frame(width: 16, height: 16)
                }
                // Not disabled while a read is in flight. `reload()` is idempotent and
                // every invocation goes through `GitpicRunner`'s serial gate, so a
                // second press queues a second read rather than racing the first —
                // and gating it on `busy` meant the button greyed out and came back on
                // every window open, which is a worse trade than an extra read.
                //
                // ⌘R, where reload lives on every other Mac. `⌘S` on 保存 already
                // worked this way: SwiftUI dispatches these inside the window, which
                // is why they were the two keys that *did* respond before the app had
                // a main menu at all — see `MainMenu`.
                .keyboardShortcut("r")
                .help("重新读取配置与历史（⌘R）")

                if activeTab.savesConfig {
                    // Present on every config pane whether or not anything is dirty,
                    // for the reason the bottom bar had them unconditionally: a
                    // button that only appears once you have changed something cannot
                    // teach you that clicking it is how a change gets written.
                    Button("放弃") { model.revert() }
                        .disabled(model.dirtyKeys.isEmpty || model.busy)
                    Button("保存") { Task { await model.save() } }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                        .disabled(model.dirtyKeys.isEmpty || model.busy)
                        // Which keys, since there is no longer a line of text saying
                        // "N 项未保存".
                        .help(model.dirtyKeys.isEmpty
                              ? "没有改动"
                              : "保存 \(model.dirtyKeys.count) 项："
                                + model.dirtyKeys.map(\.rawValue).joined(separator: ", "))
                }
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in recordVisit() }
    }

    // MARK: - Sidebar

    @ViewBuilder private var sidebar: some View {
        List(selection: $navigation.selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .foregroundStyle(.primary)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("设置")
        // Fixed at 200, and not collapsible at all.
        //
        // **This reverses what `192566c` decided**, so here is why. That commit added
        // the toggle back — `columnVisibility` became a real `@State` binding and this
        // line was deleted — on the grounds that a missing sidebar toggle "did not
        // match the platform", citing Passwords and Mail. But those are content
        // browsers with resizable sidebars, and this window is not modelled on them:
        // it is modelled on System Settings, which is said out loud twice elsewhere in
        // this file — and **System Settings has no sidebar toggle.** Four fixed panes
        // do not need one, and the analogy was to the wrong kind of window.
        //
        // The collapse was also measurably broken, which is what brought this back up.
        // At the window's own minimum width of 680 the sidebar takes 200 and leaves 480
        // for a `Form` whose rows need very nearly that, while 保存 ends 4pt from the
        // window's right edge — measured. Every expansion therefore had a frame or two
        // where the detail content was still laid out at its collapsed width, running
        // off the right edge, and the toolbar could not fit its items and grew an `»`
        // overflow chevron that vanished again. Two symptoms, one cause: nothing had
        // any slack to animate through.
        //
        // A leftover made it worse and is worth recording, since it would bite anyone
        // who tries a toggle again: a `.frame(width: 200)` sat on this content as well
        // as on the column. It was harmless when written — the sidebar could not
        // collapse then — but once it could, every collapse animated a column from
        // 200pt to 0 around content told in absolute points that it may only ever be
        // 200 wide. No width satisfies both, so the transition had nowhere smooth to go.
        // `navigationSplitViewColumnWidth` was always the whole of what was wanted.
        //
        // The cost, stated: the 200pt is permanent, so a small screen cannot reclaim
        // it. That is the same deal System Settings offers.
        .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        Group {
            switch activeTab {
            case .host:    HostPane(model: model)
            case .upload:  UploadPane(model: model)
            case .history: HistoryPane(model: model)
            case .about:   AboutPane(model: model)
            }
        }
        // Title 设置, subtitle the pane — in that order, and not the other way round.
        // A settings window normally lets the title bar be the pane alone (System
        // Settings does), because the app it belongs to is named in the Dock and the
        // menu bar. This app is `.accessory`: no Dock icon, no app menu. A title bar
        // reading only 「图床」 leaves nothing on screen that says which window this is
        // or that it is where settings are edited.
        .navigationTitle("设置")
        .navigationSubtitle(activeTab.title)
        // Top-left, explicitly. A pane whose content is shorter than the window gets
        // centred by the detail column otherwise — which is exactly how the history
        // pane's format switcher ended up floating halfway down the window. Fixing it
        // per-pane leaves the next pane to rediscover it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Navigation history

    private func canStep(_ delta: Int) -> Bool {
        navigation.history.indices.contains(navigation.historyIndex + delta)
    }

    private func step(_ delta: Int) {
        let target = navigation.historyIndex + delta
        guard navigation.history.indices.contains(target) else { return }
        navigation.steppingThroughHistory = true
        navigation.historyIndex = target
        navigation.selectedTab = navigation.history[target]
        // Cleared in a later turn than the `onChange` this assignment triggers, which
        // is the whole point: clearing it here would let `recordVisit` see `false`
        // and append the pane we just stepped to.
        Task { @MainActor in navigation.steppingThroughHistory = false }
    }

    private func recordVisit() {
        guard !navigation.steppingThroughHistory,
              let tab = navigation.selectedTab else { return }
        guard navigation.history[navigation.historyIndex] != tab else { return }
        // Anything ahead of here was reached by going back; a new choice replaces that
        // future rather than being spliced into it.
        navigation.history = Array(navigation.history.prefix(navigation.historyIndex + 1))
        navigation.history.append(tab)
        navigation.historyIndex = navigation.history.count - 1
    }
}

// MARK: - Panes

private struct FormChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
    }
}

extension View {
    fileprivate func formChrome() -> some View { modifier(FormChrome()) }

    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

/// Shown in the host and upload panes when there is no config to edit — and, when
/// the cause is a file the CLI will not parse, the way out of it.
///
/// Four states, not two. A bare `loadFailed` flag left two of them unrepresented:
/// while tool discovery is still running `reload()` returns early without ever
/// setting it, so this sat on "读取配置中…" indefinitely with a retry button that
/// could not appear — and when discovery *failed* it said the same thing about a
/// config that was never going to be read at all.
///
/// The fourth is the one that made this pane useless in practice. "读取配置失败。"
/// plus 重试 is a dead end for the failure people actually have: a config file
/// carried over from before 0.5.0 still has `github.token` in it, which the CLI
/// refuses for good reason and will keep refusing however many times 重试 is
/// pressed. The CLI names the file and the offending key; showing that, and offering
/// the one action that changes the answer, is the difference between a diagnosis and
/// a shrug.
private struct ConfigTrouble: View {
    var model: AppModel
    /// Whether this pane owns the repair. The host pane does — it is where the config
    /// is edited — and the upload pane points at it instead of growing a second copy
    /// of the same buttons.
    let repairs: Bool

    @State private var confirmingRebuild = false

    var body: some View {
        switch model.toolState {
        case .resolving:
            Section { Text("正在查找 gitpic…").foregroundStyle(.secondary) }
        case .missing:
            Section {
                Text("找不到 gitpic 可执行文件，请重新安装 GitPic。")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            if let failure = model.configFailure {
                Section {
                    Label(failure.headline, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    reason(failure)
                    actions(failure)
                }
            } else {
                Section { Text("读取配置中…").foregroundStyle(.secondary) }
            }
        }
    }

    /// The CLI's own words, verbatim.
    ///
    /// Not paraphrased and not truncated: the message already names the file and the
    /// key that broke it, which is more than any sentence written here could say. It
    /// is also safe to show — `src/config.rs` pins that a rejected `github.token`
    /// is reported without echoing its value, so a real credential cannot ride along.
    @ViewBuilder private func reason(_ failure: ConfigFailure) -> some View {
        if let code = failure.code {
            LabeledContent("错误码") {
                Text(code).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        Text(failure.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        if let path = model.configPath {
            LabeledContent("配置文件") {
                Text(path.path).font(.caption).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func actions(_ failure: ConfigFailure) -> some View {
        HStack(spacing: 8) {
            Button("重试") { Task { await model.reload() } }
                .disabled(model.busy)
            if let path = model.configPath,
               FileManager.default.fileExists(atPath: path.path) {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                }
            }
            if repairs, failure.isFileUnusable {
                Button("备份并重建…") { confirmingRebuild = true }
                    .disabled(model.busy)
            }
            if !repairs {
                Button("去「图床」处理") { SettingsNavigation.shared.selectedTab = .host }
            }
        }
        .controlSize(.small)
        .alert("把这个配置文件移开？", isPresented: $confirmingRebuild) {
            Button("备份并重建") { Task { await model.rebuildConfig() } }
            Button("取消", role: .cancel) {}
        } message: {
            // Says what will be lost before it is lost. The rebuilt config is the
            // CLI's defaults, so the old repo target has to be typed again — and the
            // file it came from is still there to read it out of.
            Text("原文件会改名保留在同一个目录里（\(name).broken-…），不会删除。"
                 + "之后这里是一份空白配置：Owner / Repo / Branch 要重新填一次，"
                 + "旧值可以从备份文件里抄回来。")
        }
    }

    private var name: String { model.configPath?.lastPathComponent ?? "config.toml" }
}

/// One editable text row in a grouped form.
///
/// Hand-built rather than letting the form label the `TextField`, and both halves
/// of that are load-bearing:
///
/// - `.roundedBorder`: a bare `TextField` in a `.grouped` form draws **no bezel**,
///   so it is pixel-identical to the read-only `LabeledContent` rows it sits next
///   to. The row reads as a label, and nobody types into a label.
/// - The `HStack`: a form-labelled field — and a `LabeledContent` wrapping one —
///   puts its text in the value column *right-aligned*, and neither
///   `.multilineTextAlignment` nor `.labelsHidden` reaches it. Both measured on
///   macOS 26. An `HStack` opts out of that column, so the field reads from the
///   left like every other editable field on the platform.
///
/// Editing is not committing: Return used to save, which meant a form with no
/// visible way to save. The bottom bar's 保存 is now the only path, so this row
/// only ever writes to the draft.
private struct ConfigField: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// The image host: the three `github.*` keys that say where uploads land, and a
/// read-only connectivity test against them.
struct HostPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if let draft = Binding($model.draft) {
                Section("仓库") {
                    row("Owner", "GitHub 用户名或组织", draft.github.owner)
                    row("Repo", "仓库名，或 owner/name", draft.github.repo)
                    row("Branch", "分支名，例如 main", draft.github.branch)
                }
                Section {
                    Text("Repo 可以填 `name` 或 `owner/name`；填后者会同时改写 Owner，"
                         + "保存后这里会显示实际落盘的值。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // A blank form is not self-explanatory, and it is now reachable two
                // ways: a machine that never ran `gitpic init` (a missing file reads
                // back as the CLI's defaults, not as an error), and one that just
                // used 备份并重建 above. Neither said what to do next, and 保存 is no
                // longer a button sitting at the bottom of the window where an empty
                // field could be seen next to it.
                if isUnconfigured(draft.wrappedValue) {
                    Section {
                        Label("还没配置图床", systemImage: "exclamationmark.circle")
                        Text("填好 Owner 和 Repo，再按右上角的「保存」写进配置文件。"
                             + "凭据不在这里配 —— gitpic 只从 `gh auth token` 取，"
                             + "所以需要先 `gh auth login`。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Only after a rebuild, and it outlives the failure that caused it on
                // purpose: `ConfigTrouble` disappears the moment the read succeeds, so
                // if this hint lived there the backup's name would vanish at exactly
                // the moment the user needs to go read values out of it.
                if let backup = model.configBackup {
                    Section {
                        Label("旧配置已备份", systemImage: "arrow.uturn.backward.circle")
                        Text("原文件是 \(backup.lastPathComponent)，就在同一个目录里。"
                             + "上面的三项要重新填一次，旧值可以从它里面抄。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("在 Finder 中显示备份") {
                            NSWorkspace.shared.activateFileViewerSelecting([backup])
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                ConfigTrouble(model: model, repairs: true)
            }

            Section("连通性") {
                if let d = model.lastDoctor {
                    LabeledContent("配置") { mark(d.configOK) }
                    LabeledContent("凭据有效") { mark(d.tokenValid) }
                    LabeledContent("仓库可写") { mark(d.repoWritable) }
                    LabeledContent("分支保护") { Text(d.branchProtected == true ? "是" : "否") }
                    LabeledContent("凭据来源") { Text(d.tokenSource ?? "无").foregroundStyle(.secondary) }
                    LabeledContent("登录账号") { Text(d.login ?? "—").foregroundStyle(.secondary) }
                    if let e = d.error {
                        Text("\(e.code)：\(e.message)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if let failure = model.doctorFailure {
                    // The test could not be run at all — distinct from a report that
                    // came back unhealthy, which is the branch above. This used to go
                    // to the status line at the bottom of the window, two panes away
                    // from the button that caused it.
                    Text("测试没跑起来：\(failure)")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                } else {
                    // Says what the button will do before it is pressed. The three
                    // probes behind it are all GET (`/user`, the repo, the branch),
                    // so this is safe to run against a real image host at any time.
                    Text("还没测过。测试只读取 GitHub 上的账号、仓库权限和分支，不会写入任何东西。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("连通性测试") { Task { await model.runDoctor() } }
                    .controlSize(.small)
                    .disabled(model.busy)
            }
        }
        .formChrome()
    }

    private func row(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        ConfigField(label: label, prompt: prompt, text: text)
    }

    /// Whether this config could not upload anything yet.
    ///
    /// Either half missing is enough: `require_target` in `src/config.rs` refuses an
    /// empty owner and an empty repo alike, so a half-filled form is exactly as
    /// unusable as a blank one and must not look settled.
    private func isUnconfigured(_ c: GitpicConfig) -> Bool {
        c.github.owner.trimmingCharacters(in: .whitespaces).isEmpty
            || c.github.repo.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func mark(_ b: Bool?) -> some View {
        Group {
            switch b {
            case true:  Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil:   Text("—").foregroundStyle(.secondary)
            }
        }
    }
}

struct UploadPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if let draft = Binding($model.draft) {
                Section("路径") {
                    ConfigField(label: "模板", prompt: "images/{year}/{month}/{hash8}-{name}.{ext}",
                                text: draft.upload.pathTemplate)
                    Text("可用占位符：{year} {month} {day} {hash} {hash8} {name} {ext}")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Everything about "what link do I get" in one section. The two
                // live-together axes were in the history pane until now, one pane away
                // from the only other row naming the same idea.
                //
                // Two independent dimensions, because that is what they are: any syntax
                // can address either host. The flat four-case picker these replaced
                // listed Markdown / HTML / CDN URL / Raw URL as if they were
                // alternatives, which left two of the six combinations unreachable.
                //
                // One picker per row, and no `.fixedSize()`: two segmented controls in
                // one Form row plus the row's label column pushed the content to 920pt
                // inside a 680pt window — measured — squeezing the sidebar to a sliver.
                //
                // Two config rows, not app-local state: these bind to
                // `upload.format` and `upload.link_kind` through the draft, so they are
                // written by the toolbar's 保存 and reverted by 放弃 like every other
                // setting on this pane. There used to be a third row here — a separate
                // "CLI 默认地址" for `upload.link_kind` — with a caption admitting it had
                // no effect on the app. Two controls for the same idea, one of which
                // disclaimed itself, is what got collapsed: the app now copies what the
                // config says, so there is one address and one place to set it.
                //
                // Tagged by `rawValue` rather than by the enum, because the draft holds
                // the config's strings and those strings are the CLI's own spellings
                // (`md`/`html`/`url`, `cdn`/`raw` — see `LinkSyntax`).
                Section("链接") {
                    Picker("格式", selection: draft.upload.format) {
                        ForEach(LinkSyntax.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Picker("地址", selection: draft.upload.linkKind) {
                        ForEach(LinkTarget.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text("配置文件里的 `upload.format` 与 `upload.link_kind`，改完按右上角"
                         + "「保存」才生效 —— 状态栏菜单里改这两项是即时写入。App 复制的 snippet"
                         + "和终端里 gitpic 的默认值都取它们；六种组合任意切换都不会重新上传，"
                         + "命令行的 `-f` / `--link` 仍可临时覆盖。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("行为") {
                    // `.switch` explicitly on both. A `Toggle` in a grouped Form
                    // already renders as a switch on macOS, but the style is
                    // inherited — one `.toggleStyle` anywhere up the tree silently
                    // turns these into checkboxes.
                    Toggle(isOn: draft.upload.dedup) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("内容去重")
                            Text("相同内容不再重复提交，直接返回已有链接。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    Toggle(isOn: draft.upload.autoCopy) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动复制到剪贴板")
                            // No longer labelled 仅 CLI. The app performs the copy
                            // itself — `--json` never writes the clipboard — but it
                            // now reads this key first, so one switch covers both.
                            Text("上传成功后把链接写进剪贴板。App 和终端里的 gitpic 都听这一项；"
                                 + "关掉之后链接仍然在「最近上传」和「历史」里，随时能手动复制。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Section("压缩") {
                    Toggle("上传前压缩", isOn: draft.upload.compress)
                        .toggleStyle(.switch)
                    // Only the parameters are gated on the toggle. Disabling the
                    // whole section would disable the toggle too, leaving no way
                    // to switch compression back on.
                    Group {
                    LabeledContent("最大宽度") {
                        HStack(spacing: 12) {
                            Slider(value: intBinding(draft.upload.maxWidth), in: 0...4096, step: 64)
                                .frame(width: 180)
                            Text(draft.upload.maxWidth.wrappedValue == 0
                                 ? "不限制" : "\(draft.upload.maxWidth.wrappedValue) px")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    LabeledContent("质量") {
                        HStack(spacing: 12) {
                            Slider(value: intBinding(draft.upload.quality), in: 1...100, step: 1)
                                .frame(width: 180)
                            Text("\(draft.upload.quality.wrappedValue)")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    }
                    .disabled(!draft.upload.compress.wrappedValue)
                }
            } else {
                ConfigTrouble(model: model, repairs: false)
            }
        }
        .formChrome()
    }

    /// Slider works in Double; the config stores Int.
    private func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) },
                set: { b.wrappedValue = Int($0.rounded()) })
    }
}

struct HistoryPane: View {
    @Bindable var model: AppModel

    /// How much thumbnail fetching is outstanding, pushed by ``ThumbnailStore``.
    ///
    /// View state and not something on ``AppModel``, unlike everything else this pane
    /// reads. Two reasons. Its lifetime is exactly this pane's: `.task` below subscribes
    /// when 历史 appears and is cancelled when it goes away, so nothing keeps a
    /// subscription alive for a window that is closed — and the window now survives
    /// being closed (see ``SettingsWindowController``). And no other surface wants it:
    /// the status-item menu has no rows and no thumbnails, so putting it on the model
    /// would be widening the app's shared state for one `Text`.
    @State private var progress: ThumbnailProgress = .idle

    /// A copy that just landed: which row's button is showing its checkmark, and which
    /// click put it there.
    ///
    /// One value for the whole pane rather than state inside each row, because the
    /// states it has to rule out are all *between* rows. Two rows can never be
    /// mid-checkmark at once, and copying several in a row moves the mark instead of
    /// leaving a trail of them: whichever click was last owns the only mark there is,
    /// and the row it left reverts in the same update.
    ///
    /// `seq` is not decoration. `.task(id:)` restarts only when the id actually
    /// *changes*, so keyed on the record alone a second click on the **same** row would
    /// not restart anything — the first click's timer would still be the one running,
    /// and it would clear the second click's checkmark early, after whatever was left
    /// of the first second. Bumping a counter on every copy makes each click a distinct
    /// id, so the timer restarts and the mark always lasts its full stay.
    private struct CopyFlash: Equatable {
        let record: HistoryRecord.ID
        let seq: Int
    }
    @State private var flash: CopyFlash?
    @State private var flashCount = 0

    /// How long the checkmark stays. Long enough to be seen if the eye was elsewhere on
    /// the row when it was clicked, short enough that it is gone before the next copy —
    /// and it does not have to carry information the way a banner did, because the
    /// pointer is already on the thing it is about.
    private static let flashDuration = Duration.seconds(1)

    var body: some View {
        // Same container as every other pane, and that is the whole point.
        //
        // This was a bare `VStack` + `List`, and it did not line up with anything: a
        // grouped `Form` honours the detail column's own margins, a naked `List` does
        // not. Measured on this window — the form panes' content sits at x=847 inside
        // a scroll area starting at 827 (a symmetric 20pt inset); the list's scroll
        // area started at 816 and ran 494 wide, so it bled 11pt *under* the split-view
        // divider on the left and 11pt past the window's right edge. Padding it by
        // hand would have meant hard-coding that 11 and re-deriving it at every window
        // size. Using the container the other panes use costs nothing and cannot drift.
        //
        // The format switcher scrolls with the content now rather than being pinned
        // above it. It is not the only way to reach those two choices — the status-item
        // menu carries the same shared `linkForm` — and a pinned strip was what forced
        // the hand-aligned layout in the first place.
        if let failure = model.configFailure {
            // Not "还没有上传记录", which is a claim this pane is in no position to
            // make: history and config are read by the same `reload()`, config first,
            // so a file that will not parse takes the history down with it and the
            // list is empty for a reason that has nothing to do with uploads.
            ContentUnavailableView {
                Label("读不到历史", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(failure.headline)。历史和配置是一起读的，所以这里也是空的。")
            } actions: {
                Button("重试") { Task { await model.reload() } }
                    .disabled(model.busy)
                Button("去「图床」处理") { SettingsNavigation.shared.selectedTab = .host }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.history.isEmpty {
            ContentUnavailableView("还没有上传记录", systemImage: "clock",
                                   description: Text("上传一张图片后会出现在这里。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                // A header view rather than a title string, because it carries two
                // things: how many records, and what the copy buttons will produce.
                //
                // In the header and not the footer, and that is the whole point of the
                // second line. The switcher itself lives in 上传 now, so this pane has a
                // mode set elsewhere — and a footer sits below every row, which with 37
                // of them means below the fold, read by nobody. The copy button's
                // tooltip says the same thing, but only to whoever hovers the right
                // pixel.
                Section {
                    ForEach(model.history) { r in row(r) }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(model.history.count) 条记录")
                        // One line for the whole pane. On a cold cache the rows sit as
                        // grey boxes for about four seconds (``ThumbnailLimits``), and
                        // with nothing said about it a slow link is indistinguishable
                        // from a broken one.
                        //
                        // Next to the count rather than in place of it, and on the left
                        // rather than the right: the copy hint over there is a standing
                        // fact about this pane, and a line that comes and goes must
                        // neither replace it nor shove it sideways. Growing leftward
                        // into the `Spacer()` moves nothing.
                        //
                        // `.caption`, so the header cannot change height when it
                        // appears — the count beside it is the taller of the two either
                        // way — and `.monospacedDigit()` so a climbing number does not
                        // reflow its own text on every image, the same reason the byte
                        // sizes in the rows are monospaced.
                        //
                        // No `ProgressView` next to it, deliberately. The numbers moving
                        // already say "working"; a spinner is taller than this text and
                        // so is the one thing here that *would* change the header's
                        // height, and it would do it twice per open.
                        if progress.isActive {
                            Text("· 正在取缩略图 \(progress.done)/\(progress.total)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("复制 \(model.linkForm.label) · 在「上传」页的「链接」改")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formChrome()
            // Pushed, not polled: the store yields on every change and the current
            // state on subscribe, so this costs one hop onto the actor per image
            // resolved and nothing at all while the pane sits idle. Cancelled with the
            // pane, which is what releases the store's side of it.
            .task {
                // Subscribing is itself a hop onto the store, so it is its own `await`
                // rather than one buried in the `for` — the stream is handed back with
                // the current state already in it.
                let updates = await model.thumbnails.progressUpdates()
                for await update in updates {
                    progress = update
                }
            }
            // The checkmark's only way back. Keyed on the whole `CopyFlash`, so every
            // click — including a second one on the same row — cancels the previous
            // timer and starts a fresh one; see ``CopyFlash``. Clearing sets the id to
            // `nil`, which re-runs this and falls straight out of the guard.
            //
            // The cancellation check is what keeps a mark from being cleared by the
            // *previous* row's timer: when the id changes, this closure is cancelled
            // mid-sleep, and a cancelled run that went on to write `flash = nil` would
            // wipe the mark the new click had just set. Same shape as
            // `AppModel.beginWork`'s debounce, for the same reason.
            .task(id: flash) {
                guard flash != nil else { return }
                try? await Task.sleep(for: Self.flashDuration)
                guard !Task.isCancelled else { return }
                flash = nil
            }
        }
    }

    private func row(_ r: HistoryRecord) -> some View {
        HStack(spacing: 10) {
            // `savedConfig` is what an address is built from, so with no readable
            // config there is no URL to fetch — the row still lists what was uploaded,
            // it just cannot show it. The `configFailure` branch above already covers
            // the case where the read *failed*; this covers the seconds before the
            // first read lands.
            HistoryThumbnail(source: model.savedConfig.map { r.thumbnailSource(config: $0) },
                             store: model.thumbnails,
                             deduped: r.deduped)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).lineLimit(1)
                Text(r.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(byteText(r.size))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { copy(r) } label: { copyGlyph(flashed: flash?.record == r.id) }
                .buttonStyle(.borderless)
                // Swapped with the glyph, because this doubles as what a screen reader
                // reads off the button — see the note on ``copy(_:)`` about what the
                // checkmark cannot say out loud.
                .help(flash?.record == r.id ? "已复制" : "复制 \(model.linkForm.label)")
        }
        .padding(.vertical, 2)
    }

    /// The copy button's icon: the clipboard, or the checkmark that says the click
    /// landed.
    ///
    /// **Both glyphs are always laid out, one of them transparent.** A plain
    /// `Image(systemName: flashed ? … : …)` would resize the button as it swapped:
    /// measured at the 13 pt body size these rows inherit, `doc.on.clipboard` renders
    /// 16×18 pt and `checkmark` 14×13, so the mark would pull the byte count beside it
    /// 2 pt to the right and shorten the row's tallest trailing element by 5 on the way
    /// through — a twitch in the layout, to report that nothing went wrong.
    ///
    /// A `.frame(width:height:)` would pin it too, at the price of a hard-coded pair of
    /// numbers to re-measure whenever either symbol is redrawn. Stacking them makes the
    /// frame the union of the two glyphs, which is the same fix and derives itself.
    ///
    /// The swap is instant, deliberately: this is direct feedback for a click on the
    /// control under the pointer, and immediacy is the whole content of the message. The
    /// one animation in this app is for something that arrives late — see ``Motion``.
    private func copyGlyph(flashed: Bool) -> some View {
        ZStack {
            Image(systemName: "doc.on.clipboard").opacity(flashed ? 0 : 1)
            Image(systemName: "checkmark").opacity(flashed ? 1 : 0)
        }
    }

    /// History stores one URL and no record of which kind it is, so both addresses
    /// are rebuilt from the configured target — see `UploadedLink`.
    ///
    /// **Success is reported on the button; failure keeps the notification.** The split
    /// is not a preference, it is ``AppModel/notify(title:body:)``'s own justification
    /// applied where it holds and dropped where it does not. That justification is
    /// "outcomes are events, the window is usually closed when one happens" — true of an
    /// upload, and false of this button, which cannot be clicked without the window
    /// open, this pane in front, and the pointer resting on the control itself. A banner
    /// plus a system sound (`Notifier.post` sets `content.sound = .default`) for a click
    /// whose result is already under the cursor was the loudest available way of saying
    /// nothing.
    ///
    /// The failures below keep their banners because they carry a diagnosis no badge can
    /// hold: ``CDNUnavailable/ambiguousBranch`` is a sentence about a `/` in the branch
    /// name making every jsDelivr address a 404, and the remedy is a config change in
    /// another pane. A checkmark cannot say that, and neither can its absence. `Notifier`
    /// itself is untouched for the same reason — an upload finishing still wants the
    /// banner and the sound, because then the window really may be shut.
    ///
    /// One cost, stated because it is real: a checkmark is silent where the banner was
    /// announced, so a VoiceOver user loses a spoken confirmation and gets a changed
    /// button label instead. The log line below is what still distinguishes "copied, and
    /// you looked away" from "the button did nothing" after the fact — the same reason
    /// ``AppModel/writeLinkForm(_:)`` logs the success it deliberately does not announce.
    private func copy(_ r: HistoryRecord) {
        guard let cfg = model.savedConfig else {
            // Was a bare `return`: the button did nothing at all and said nothing
            // about why.
            model.notify(title: "复制失败", body: "读不到配置，生成不了链接")
            return
        }
        let form = model.linkForm
        let link = UploadedLink(r, config: cfg)
        guard let text = link.snippet(form) else {
            // Names the cause, not just the gap: with a slashed branch every row in
            // the pane is CDN-less, and the remedy is a config change.
            model.notify(title: "复制失败",
                         body: link.unavailable(form.target)?.message
                               ?? "没有 \(form.target.label) 链接：\(r.name)")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            flashCount += 1
            flash = CopyFlash(record: r.id, seq: flashCount)
            Diagnostics.log("copied \(form.label) from history: \(r.name)")
        } else {
            model.notify(title: "写剪贴板失败", body: r.name)
        }
    }

    private func byteText(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1024)
    }
}

/// One history row's picture: a fixed box holding the image, or the reason there is
/// none.
///
/// **Fixed box, image fitted inside it.** The width has to be constant or every row's
/// text starts at a different x, which is the one thing a list of 100 rows cannot
/// afford; and fitting rather than filling means a screenshot is shown whole instead
/// of centre-cropped to a shape it never had. The cost is letterboxing, which is why
/// the box is a visible surface rather than nothing.
///
/// The states are kept apart rather than collapsed into "no picture": a 404 on a
/// private image host is permanent and needs a decision from the user, a transport
/// error is worth reopening the pane for, and an original past the size ceiling is
/// working as designed. ``ThumbnailFailure/message`` is what the tooltip says.
private struct HistoryThumbnail: View {
    /// `nil` when there is no config to build an address from.
    let source: ThumbnailSource?
    let store: ThumbnailStore
    let deduped: Bool

    /// 44×32 at a 4:3-ish ratio, which is the shape most screenshots arrive in, so
    /// the common case letterboxes least. Retina wants 88×64 of it; the decoder is
    /// asked for 160 px on the long edge (``ThumbnailLimits/maxPixel``).
    private static let width: CGFloat = 44
    private static let height: CGFloat = 32
    private static let corner: CGFloat = 5

    private enum Load {
        case pending
        case loaded(Thumbnail)
        case failed(ThumbnailFailure)
    }
    @State private var load: Load = .pending

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(.quaternary)
            switch load {
            case .pending:
                // No spinner, deliberately. A hundred of them chasing each other down
                // the pane reports nothing and is the noisiest thing on screen; the
                // placeholder is the same glyph this row carried before.
                Image(systemName: "photo").foregroundStyle(.tertiary)
            case .loaded(let thumb):
                Image(decorative: thumb.image, scale: 1)
                    // The decoded thumbnail is larger than the box on a 1× display,
                    // so this is a downscale and the interpolation is visible.
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failed:
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        // Outside the clip, so the badge can sit on the corner rather than be cut by
        // it — the same place Finder puts an alias badge.
        .overlay(alignment: .bottomTrailing) { dedupBadge }
        .help(tooltip)
        // Keyed on the source, so a row whose address moved — `github.owner/repo/
        // branch` changed under it — refetches instead of showing the old picture.
        // Cancelled when the row scrolls away; the fetch itself survives that on
        // purpose, so the next row wanting the same image finds it cached.
        //
        // **Timed, so a cache hit and a download are not given the same treatment.**
        // The store cannot be asked which layer answered — and should not be, since
        // the answer that matters is not "was it cached" but "did anyone see the
        // placeholder". Both questions have the same answer, and the elapsed time is
        // the one that measures it directly: below the threshold nothing was on screen
        // long enough to fade *from*, and animating there would put a flutter on every
        // reopen of a warm pane where today there is none. Above it the grey box was
        // read as a grey box, and the picture replacing it is a change worth softening.
        // ``Motion/thumbnailIsLateAfter`` carries the numbers.
        //
        // Only the image. A late *failure* swaps one tertiary glyph for another inside
        // the same box, at the same size — there is no cut there to soften.
        .task(id: source) {
            guard let source else { return }
            let asked = ContinuousClock.now
            let result = await store.thumbnail(for: source)
            let late = ContinuousClock.now - asked >= Motion.thumbnailIsLateAfter
            switch result {
            case .success(let thumb):
                if late {
                    withAnimation(Motion.thumbnailArrival) { load = .loaded(thumb) }
                } else {
                    load = .loaded(thumb)
                }
            case .failure(let why):
                load = .failed(why)
            }
        }
    }

    /// `deduped` used to be the row's leading glyph — `doc.on.doc` instead of
    /// `photo` — and the thumbnail took that slot. It is a badge now rather than
    /// dropped: a deduped upload shows the *same picture* as the row it deduped
    /// against, which is exactly why the distinction has to be stated somewhere.
    ///
    /// **`.caption2` and not `.system(size: 7)`.** 7 pt was below every text style the
    /// platform ships — the macOS scale bottoms out at 10 pt, which `footnote`, `caption`
    /// and `caption2` all resolve to (measured with `NSFont.preferredFont(forTextStyle:)`)
    /// — so it was a number with nothing behind it, and one that could not follow the
    /// system text size anywhere.
    ///
    /// `.imageScale(.small)` is the half that keeps the swap from being a regression, and
    /// it is a relative knob rather than the magic number returning in a second spelling.
    /// Footprints below are the badge's own rendered layout size, measured with
    /// `ImageRenderer` against this same 44×32 box:
    ///
    /// | spelling | badge | of box height |
    /// | --- | --- | --- |
    /// | `.system(size: 7)`, as shipped | 13×16 | 50% |
    /// | `.caption2`, default medium scale | 17×20 | 62% |
    /// | `.caption2` + `.small` | 14×17 | 53% |
    ///
    /// The middle row is why the second modifier is here: at the default scale the token
    /// alone grows the badge to 17×20, which crowds the corner and starts competing with
    /// the picture 0.12.0 put in this slot. `.small` lands 1 pt larger on each axis than
    /// what shipped — still clear of the corner, glyph a shade bigger rather than
    /// smaller, and checked by eye at 1× and 2× as well as measured. `.footnote` +
    /// `.small` renders identically, both being 10 pt; `.caption2` is named because it is
    /// the bottom of the scale and says so.
    @ViewBuilder private var dedupBadge: some View {
        if deduped {
            Image(systemName: "doc.on.doc.fill")
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .padding(2)
                .background(Circle().fill(.background))
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                .offset(x: 3, y: 3)
                .help("内容重复：仓库里这个路径已经是同样的内容，这次没有再上传")
        }
    }

    /// Always something, never an empty tooltip: the failure message where there is
    /// one, and otherwise the address the picture came from — which the row's own path
    /// line can only show truncated.
    private var tooltip: String {
        switch load {
        case .failed(let why):
            return why.message
        case .pending:
            return source == nil ? "还没读到配置，取不了缩略图" : "正在取缩略图…"
        case .loaded:
            // The address it was *reached* at is not recorded — a CDN hit and a raw
            // fallback are one cached image afterwards — so this names where the row
            // points, which is what the truncated path line cannot show in full.
            return source?.urls.first ?? ""
        }
    }
}

struct AboutPane: View {
    @Bindable var model: AppModel

    /// `nil` when there is no bundle to read it out of — a `swift run` build
    /// rather than a packaged `.app`. Kept optional rather than defaulted so the
    /// note below can tell "no bundle" apart from "the two really disagree";
    /// defaulting them to "dev"/"未知" made an ordinary dev run look like a
    /// mismatched build.
    private var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    private var embeddedCLI: String? {
        Bundle.main.infoDictionary?["GitPicEmbeddedCLIVersion"] as? String
    }

    /// The three honest states, kept apart rather than collapsed into one string.
    @ViewBuilder private var versionNote: some View {
        switch (appVersion, embeddedCLI) {
        case (let app?, let cli?) where app == cli:
            Text("App 与 gitpic_cli 同版本发布，打包进来的就是这个版本。")
                .font(.caption).foregroundStyle(.secondary)
        case (_?, _?):
            Text("版本不一致——这份 App 里的 gitpic_cli 与 App 自身版本不符，请重新构建。")
                .font(.caption).foregroundStyle(.orange)
        default:
            Text("开发构建：没有打包成 .app，读不到版本信息。App 与 gitpic_cli 同版本发布，"
                 + "由 scripts/build-app.sh 在构建时校验。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The app's own icon, read back out of the bundle.
    ///
    /// `applicationIconName` rather than a resource of its own: the icon is compiled
    /// from `AppIcon.icon` by `actool` at build time (`scripts/build-app.sh`), so the
    /// bundle is the only place it exists and asking for it by name is what keeps
    /// this pane showing the *shipped* icon rather than a second copy that could
    /// drift. `nil` under `swift run`, where there is no bundle to read — the header
    /// then falls back to the name alone rather than to a placeholder box.
    private var appIcon: NSImage? {
        NSImage(named: NSImage.applicationIconName)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 14) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("GitPic")
                    .font(.title2.weight(.semibold))
                Text("把图片传到 GitHub 图床，拿回一条链接。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        Form {
            Section { header }
            Section("版本") {
                LabeledContent("App") { Text(appVersion ?? "dev").monospacedDigit() }
                LabeledContent("gitpic_cli") { Text(embeddedCLI ?? "未知").monospacedDigit() }
                // Both rows stay even though a real build always makes them agree:
                // the second is read back out of the bundle, so it is the only
                // place that shows what was *actually* packaged rather than what
                // the build intended. A mismatch means build-app.sh's equality
                // assertion was bypassed.
                versionNote
            }
            Section("工具位置") {
                LabeledContent("gitpic") {
                    Text(model.tools?.gitpic.path ?? "未找到")
                        .font(.caption).textSelection(.enabled)
                }
                LabeledContent("gh") {
                    Text(model.tools?.gh?.path ?? "未找到")
                        .font(.caption).textSelection(.enabled)
                }
                Text("Finder 启动的 App 只有最小 PATH，gh 由 App 自己探测后显式传给 gitpic。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("项目") {
                Text("CLI 与 App 同仓库、同版本发布，凭据只经过 GitHub CLI，配置文件里不存任何密钥。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("github.com/tarnish233/gitpic",
                     destination: URL(string: "https://github.com/tarnish233/gitpic")!)
                    .font(.caption)
            }
            Section("诊断") {
                LabeledContent("日志") {
                    Text(Diagnostics.logURL.path)
                        .font(.caption).textSelection(.enabled)
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL])
                }
                .controlSize(.small)
            }
        }
        .formChrome()
    }
}
