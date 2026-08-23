import AppKit
import SwiftUI
import GitPicCore

private struct FormChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
    }
}

extension View {
    func formChrome() -> some View { modifier(FormChrome()) }
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
/// The one pasteboard write in the app.
///
/// `setString` can fail, and reporting 「已复制」 anyway is worse than not copying — the
/// user pastes stale content and never learns why — so the result is returned and every
/// caller has to look at it. It was hand-rolled at three sites, one of which ignored the
/// result entirely.
enum Clipboard {
    @discardableResult
    static func write(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(s, forType: .string)
    }
}

/// The config-or-trouble gate both editing panes open with.
///
/// One owner for the condition, its reasoning, and the `ConfigTrouble` fallback. The two
/// panes carried this byte-identically, comment included — so the invariant it encodes
/// ("a failed read must beat a surviving draft, or 备份并重建 never appears") was being
/// held by hand in two places, and the next pane to edit config would have re-derived it
/// or got it wrong.
struct ConfigGate<Content: View>: View {
    @Bindable var model: AppModel
    /// Whether the trouble view offers the repair actions — only the pane that owns the
    /// image host does.
    let repairs: Bool
    @ViewBuilder let content: (Binding<GitpicConfig>) -> Content

    var body: some View {
        // One condition, because the two ways to have no form here — a read that failed,
        // and a read that has not happened — both end in `ConfigTrouble`. `configFailure`
        // is the half that has to be asked *first*: `draft` outlives a failed reload on
        // purpose (unsaved edits), so letting it win would leave a later CONFIG_INVALID
        // showing the last good form, with 「备份并重建」 never appearing.
        if model.configFailure == nil, let draft = Binding($model.draft) {
            content(draft)
        } else {
            ConfigTrouble(model: model, repairs: repairs)
        }
    }
}

struct ConfigTrouble: View {
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

/// A switch with a line of explanation under its label.
///
/// Beside ``ConfigField`` because it answers the same question for toggles that
/// `ConfigField` answers for text rows: the shape was being rebuilt by hand at every
/// call site, and with it the two invariants that are easy to get wrong.
///
/// - `.toggleStyle(.switch)` is **explicit and required**. A `Toggle` in a `.grouped`
///   Form already renders as a switch on macOS, but the style is inherited — one
///   `.toggleStyle` anywhere up the tree silently turns every one of these into a
///   checkbox.
/// - The caption is `.caption` + `.secondary` at `spacing: 2`, which is what keeps rows
///   in different sections looking like the same control.
///
/// `caption` is optional rather than absent for the caption-less rows: an empty caption
/// would reserve the space, but a `nil` one renders no `Text` at all, so a plain switch
/// row looks exactly as it did while still going through the one place that spells
/// `.toggleStyle(.switch)`. Every switch in the app comes through here — a row that
/// hand-built its own was one `.toggleStyle` up the tree away from becoming a checkbox
/// while its captioned neighbours stayed switches.
struct CaptionedToggle: View {
    let label: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            if let caption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    Text(caption)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                // Not a one-child `VStack`: this is the exact view tree the rows that
                // used a plain `Toggle` had, so adopting this type cannot move them.
                Text(label)
            }
        }
        .toggleStyle(.switch)
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
struct ConfigField: View {
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
