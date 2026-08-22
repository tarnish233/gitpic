import AppKit
import SwiftUI
import GitPicCore

/// The image host: the three `github.*` keys that say where uploads land, and a
/// read-only connectivity test against them.
struct HostPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            // One condition, because the two ways to have no form here — a read that
            // failed, and a read that has not happened — both end in `ConfigTrouble`.
            // `configFailure` is the half that has to be asked *first*: `draft`
            // outlives a failed reload on purpose (unsaved edits), so letting it win
            // would leave a later CONFIG_INVALID showing the last good form, with
            // 「备份并重建」 never appearing.
            if model.configFailure == nil, let draft = Binding($model.draft) {
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
                    .disabled(model.busy || model.toolState != .ready)
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
