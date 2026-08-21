import AppKit
import SwiftUI
import GitPicCore

enum MainTab: String, CaseIterable, Identifiable {
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
final class MainNavigation {
    static let shared = MainNavigation()
    var selectedTab: MainTab? = .host
    private init() {}
}

struct MainWindowView: View {
    @State private var navigation = MainNavigation.shared
    @State private var model = AppModel.shared

    private var activeTab: MainTab { navigation.selectedTab ?? .host }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(MainTab.allCases, selection: $navigation.selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .foregroundStyle(.primary)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectStyleSoftIfAvailable()
            .navigationTitle("GitPic")
            .frame(width: 190)
            .navigationSplitViewColumnWidth(min: 190, ideal: 190, max: 190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .navigationTitle("GitPic")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 480)
        // A toolbar is what forces NSToolbar to exist, which the liquid-glass
        // title bar treatment depends on.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.busy)
                .help("重新读取配置与历史")
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    @ViewBuilder private var detail: some View {
        switch activeTab {
        case .host:    HostPane(model: model)
        case .upload:  UploadPane(model: model)
        case .history: HistoryPane(model: model)
        case .about:   AboutPane(model: model)
        }
    }

    @ViewBuilder private var statusBar: some View {
        let dirty = model.dirtyKeys
        let text = model.statusLine ?? (dirty.isEmpty ? nil : "\(dirty.count) 项未保存")
        // On a config pane the bar is unconditional, because that is where 保存 lives
        // and a button that only appears once you have already changed something
        // cannot tell you that clicking it is how a change gets written. The panes
        // that save nothing keep it transient — a status line and nothing else.
        if activeTab.savesConfig || text != nil || model.busy {
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                if let text {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(model.statusLine == nil ? .secondary : .primary)
                        .lineLimit(2)
                }
                Spacer()
                if activeTab.savesConfig {
                    // Both stay put and go dim rather than appearing and
                    // disappearing: a bar that changes width as you type moves the
                    // button out from under the pointer.
                    Button("放弃") { model.revert() }
                        .disabled(dirty.isEmpty || model.busy)
                    Button("保存") { Task { await model.save() } }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                        .disabled(dirty.isEmpty || model.busy)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
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

/// Shown in the host and upload panes until the config arrives.
///
/// Three states, not two. `loadFailed` alone left the worst case unrepresented:
/// while tool discovery is still running `reload()` returns early without ever
/// setting it, so this sat on "读取配置中…" indefinitely with a retry button that
/// could not appear — and when discovery *failed* it said the same thing about a
/// config that was never going to be read at all.
private struct ConfigPlaceholder: View {
    var model: AppModel

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
            if model.loadFailed {
                Section {
                    Text("读取配置失败。")
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await model.reload() } }
                }
            } else {
                Section { Text("读取配置中…").foregroundStyle(.secondary) }
            }
        }
    }
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
            } else {
                ConfigPlaceholder(model: model)
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
                } else {
                    // Says what the button will do before it is pressed. The three
                    // probes behind it are all GET (`/user`, the repo, the branch),
                    // so this is safe to run against a real image host at any time.
                    Text("还没测过。测试只读取 GitHub 上的账号、仓库权限和分支，不会写入任何东西。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("连通性测试") { Task { await model.runDoctor() } }
                    .disabled(model.busy)
            }
        }
        .formChrome()
    }

    private func row(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        ConfigField(label: label, prompt: prompt, text: text)
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

                Section("链接") {
                    // One axis, named as one: this key is `upload.link_kind`, which
                    // picks the *host*. It has nothing to say about Markdown vs
                    // HTML — that is `--format`, the other axis — and labelling it
                    // "形态" alongside a four-way Markdown/HTML/CDN/Raw switcher was
                    // what made the two look like one choice.
                    Picker("默认地址", selection: draft.upload.linkKind) {
                        ForEach(LinkTarget.allCases) { t in
                            Text(t.detailedLabel).tag(t.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("这项只决定 CLI 默认用哪个地址。App 的两个维度各自独立：菜单里的"
                         + "「链接格式」选 Markdown / HTML / 纯链接，「图片地址」选 CDN / Raw，"
                         + "任意组合都不会重新上传。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("行为") {
                    Toggle(isOn: draft.upload.dedup) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("内容去重")
                            Text("相同内容不再重复提交，直接返回已有链接。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: draft.upload.autoCopy) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动复制到剪贴板（仅 CLI）")
                            // Stated rather than quietly ignored: the flag is real,
                            // it just cannot affect this app.
                            Text("对 App 无效——App 走 --json，CLI 在该模式下从不写剪贴板，"
                                 + "复制由 App 自己完成。改这项只影响你在终端里直接用 gitpic。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("压缩") {
                    Toggle("上传前压缩", isOn: draft.upload.compress)
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
                ConfigPlaceholder(model: model)
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

    var body: some View {
        VStack(spacing: 0) {
            // Two controls side by side, because the two choices are side by side:
            // any syntax can address either host. The one segmented picker these
            // replace listed Markdown / HTML / CDN URL / Raw URL as if they were
            // four alternatives, so half the grid was unreachable and "CDN URL"
            // handed back a raw link whenever the config said raw.
            HStack(spacing: 16) {
                Picker("格式", selection: $model.linkForm.syntax) {
                    ForEach(LinkSyntax.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("地址", selection: $model.linkForm.target) {
                    ForEach(LinkTarget.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text("\(model.history.count) 条")
                    .foregroundStyle(.secondary).font(.callout)
            }
            .padding(12)

            if model.history.isEmpty {
                ContentUnavailableView("还没有上传记录", systemImage: "clock",
                                       description: Text("上传一张图片后会出现在这里。"))
            } else {
                List(model.history) { r in
                    HStack(spacing: 10) {
                        Image(systemName: r.deduped ? "doc.on.doc" : "photo")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).lineLimit(1)
                            Text(r.path)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(byteText(r.size))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button {
                            copy(r)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                        .help("复制 \(model.linkForm.label)")
                    }
                    .padding(.vertical, 2)
                }
                .scrollEdgeEffectStyleSoftIfAvailable()
            }
        }
    }

    /// History stores one URL and no record of which kind it is, so both addresses
    /// are rebuilt from the configured target — see `UploadedLink`.
    private func copy(_ r: HistoryRecord) {
        guard let cfg = model.savedConfig else {
            // Was a bare `return`: the button did nothing at all and said nothing
            // about why.
            model.post("读不到配置，无法生成链接", from: .window)
            return
        }
        let form = model.linkForm
        let link = UploadedLink(r, config: cfg)
        guard let text = link.snippet(form) else {
            // Names the cause, not just the gap: with a slashed branch every row in
            // the pane is CDN-less, and the remedy is a config change.
            model.post(link.unavailable(form.target)?.message
                       ?? "没有 \(form.target.label) 链接：\(r.name)",
                       from: .window)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        model.post(pb.setString(text, forType: .string)
                   ? "已复制 \(form.label)：\(r.name)"
                   : "写剪贴板失败：\(r.name)",
                   from: .window)
    }

    private func byteText(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1024)
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
            Text("App 与 CLI 同版本发布，内嵌的就是这个版本的 gitpic。")
                .font(.caption).foregroundStyle(.secondary)
        case (_?, _?):
            Text("版本不一致——这份 App 内嵌的 gitpic 与 App 自身版本不符，请重新构建。")
                .font(.caption).foregroundStyle(.orange)
        default:
            Text("开发构建：没有打包成 .app，读不到版本信息。App 与 CLI 同版本发布，"
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
                LabeledContent("内嵌 gitpic") { Text(embeddedCLI ?? "未知").monospacedDigit() }
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
            Section("诊断") {
                LabeledContent("日志") {
                    Text(Diagnostics.logURL.path)
                        .font(.caption).textSelection(.enabled)
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL])
                }
            }
        }
        .formChrome()
    }
}
