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
        if !dirty.isEmpty || model.statusLine != nil || model.busy {
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.statusLine ?? "\(dirty.count) 项未保存")
                    .font(.callout)
                    .foregroundStyle(model.statusLine == nil ? .secondary : .primary)
                    .lineLimit(2)
                Spacer()
                if !dirty.isEmpty {
                    Button("放弃") { model.revert() }
                    Button("保存") { Task { await model.save() } }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
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
private struct ConfigField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    /// Return commits, so changing one field does not need a trip to the bottom
    /// bar. Saving with nothing dirty is a no-op that just reports "没有改动".
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommit)
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
                    Text("改完按 Return 或 ⌘S 保存，窗口底部会先列出要写入哪几个键。\n"
                         + "Repo 可以填 `name` 或 `owner/name`；填后者会同时改写 Owner，"
                         + "保存后这里会显示实际落盘的值。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section { Text("读取配置中…").foregroundStyle(.secondary) }
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
        ConfigField(label: label, prompt: prompt, text: text) {
            Task { await model.save() }
        }
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
                                text: draft.upload.pathTemplate) {
                        Task { await model.save() }
                    }
                    Text("可用占位符：{year} {month} {day} {hash} {hash8} {name} {ext}")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("链接") {
                    Picker("默认形态", selection: draft.upload.linkKind) {
                        Text("CDN (jsDelivr)").tag("cdn")
                        Text("Raw (githubusercontent)").tag("raw")
                    }
                    .pickerStyle(.menu)
                    Text("这项只决定 CLI 的默认输出。App 每次上传都会一并拿到 "
                         + "Markdown / HTML / CDN / Raw 四种形态，在菜单里切换不会重新上传。")
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
                Section { Text("读取配置中…").foregroundStyle(.secondary) }
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
    @State private var format: LinkFormat = .markdown

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("复制为", selection: $format) {
                    ForEach(LinkFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
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
                        .help("复制 \(format.label)")
                    }
                    .padding(.vertical, 2)
                }
                .scrollEdgeEffectStyleSoftIfAvailable()
            }
        }
    }

    /// History stores only the CDN url, so the other forms are derived from the
    /// configured target rather than read back.
    private func copy(_ r: HistoryRecord) {
        guard let cfg = model.savedConfig else { return }
        let text: String
        switch format {
        case .cdn:      text = r.url
        case .raw:      text = r.rawURL(config: cfg)
        case .markdown: text = "![\(r.name)](\(r.url))"
        case .html:     text = "<img src=\"\(r.url)\" alt=\"\(r.name)\">"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        model.statusLine = pb.setString(text, forType: .string)
            ? "已复制 \(format.label)：\(r.name)"
            : "写剪贴板失败：\(r.name)"
    }

    private func byteText(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1024)
    }
}

struct AboutPane: View {
    @Bindable var model: AppModel

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return v
    }
    private var embeddedCLI: String {
        Bundle.main.infoDictionary?["GitPicEmbeddedCLIVersion"] as? String ?? "未知"
    }

    var body: some View {
        Form {
            Section("版本") {
                LabeledContent("App") { Text(appVersion).monospacedDigit() }
                LabeledContent("内嵌 gitpic") { Text(embeddedCLI).monospacedDigit() }
                Text("App 与 CLI 各自独立发版；这里显示的是这份 App 里实际打包的 CLI。")
                    .font(.caption).foregroundStyle(.secondary)
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
