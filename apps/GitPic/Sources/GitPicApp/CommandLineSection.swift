import SwiftUI
import GitPicCore

/// The user-owned terminal command and completions installed by GitPic.app.
struct CommandLineSection: View {
    let status: CommandLineTool.Status
    let reach: CommandLineTool.Reach
    let probing: Bool
    let completionsInstalled: Bool
    let working: Bool
    let installDisabled: Bool
    let failure: String?
    let onInstall: (_ replacing: Bool) -> Void
    let onRemove: () -> Void
    let onCopySetup: () -> Void
    let onCopyPath: (CommandLineTool.Shell) -> Void
    let shellConfiguration: [CommandLineTool.Shell: Bool]
    let onConfigureShell: (CommandLineTool.Shell) -> Void
    let onUnconfigureShell: (CommandLineTool.Shell) -> Void

    @State private var confirmingRepoint = false
    @State private var confirmingOverwrite = false
    @State private var confirmingRemoval = false

    private func configuredDetail(_ shell: CommandLineTool.Shell) -> String {
        if let file = shell.startupFile {
            return "GitPic 在 \(file) 里维护一个带标记的块；原文件备份为 \(file).gitpic.bak。"
        }
        // fish's path is a universal variable, so there is no block to point at and nothing for a
        // "移除" button to undo without reaching into a store the user may have curated since.
        return "已通过 fish_add_path 记录（universal 变量）。移除请自行运行 fish_remove_path。"
    }

    var body: some View {
        Section("命令行") {
            LabeledContent("安装位置") {
                Text(CommandLineTool.link.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            LabeledContent("命令") {
                Label(status.label, systemImage: statusAppearance.icon)
                    .foregroundStyle(statusAppearance.color)
            }
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            LabeledContent("终端") {
                if probing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在检查 PATH…")
                    }
                } else {
                    Label(reach.label, systemImage: reachAppearance.icon)
                        .foregroundStyle(reachAppearance.color)
                }
            }
            if !probing {
                Text(reach.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // One row per shell the machine actually has. PATH and completion loading are both
            // per-shell configuration, so there is no single answer to show — and the version that
            // showed one said "reachable" to someone whose fish could not find the command.
            //
            // Buttons rather than lines to copy. The app used to refuse to touch a startup file at
            // all and printed the text instead; that satisfied "never change someone's shell
            // config behind their back" by leaving three blocks of manual instructions on screen.
            // An explicit button, a named file, a backup and a removal serve the same intent and
            // actually finish the job.
            ForEach(CommandLineTool.Shell.allCases, id: \.self) { shell in
                if let configured = shellConfiguration[shell] {
                    LabeledContent(shell.rawValue) {
                        HStack(spacing: 8) {
                            Label(
                                configured ? "已配置" : "未配置",
                                systemImage: configured
                                    ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(configured ? .green : .secondary)
                            if configured {
                                if shell.startupFile != nil {
                                    Button("移除") { onUnconfigureShell(shell) }
                                        .controlSize(.small)
                                        .disabled(working)
                                }
                            } else {
                                Button("自动配置") { onConfigureShell(shell) }
                                    .controlSize(.small)
                                    .disabled(working)
                            }
                        }
                    }
                    Text(configured ? configuredDetail(shell) : shell.pathSetUp.why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("补全") {
                Label(
                    completionsInstalled ? "bash、zsh、fish 已安装" : "尚未完整安装",
                    systemImage: completionsInstalled
                        ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(completionsInstalled ? .green : .secondary)
            }

            // Only when zsh is present *and* GitPic has not configured it. The managed block
            // already carries these lines, so showing them beside a configured zsh was the pane
            // telling the user to do by hand what it had just done for them.
            if completionsInstalled, shellConfiguration[.zsh] == false,
               let setUp = CommandLineTool.Shell.zsh.setUp {
                Text("不想让 GitPic 改 \(setUp.file) 的话，手动加这两行也一样。\(setUp.why)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(setUp.lines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("复制 zsh 设置", systemImage: "doc.on.doc", action: onCopySetup)
                    .controlSize(.small)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if showsInstallButton {
                    Button(action: beginInstall) {
                        ZStack {
                            Text(installTitle).opacity(working ? 0 : 1)
                            if working { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(installDisabled || working)
                }

                if case .linked = status {
                    Button("移除命令行工具", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .disabled(working)
                }
            }
            .controlSize(.small)
        }
        .confirmationDialog(
            "让命令行链接改为当前 GitPic？",
            isPresented: $confirmingRepoint
        ) {
            Button("重新指向", role: .destructive) { onInstall(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(status.detail)
        }
        .confirmationDialog(
            "替换现有的 gitpic 文件？",
            isPresented: $confirmingOverwrite
        ) {
            Button("替换文件", role: .destructive) { onInstall(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(CommandLineTool.link.path) 不是符号链接。替换会永久覆盖这个文件。")
        }
        .confirmationDialog(
            "移除命令行工具？",
            isPresented: $confirmingRemoval
        ) {
            Button("移除", role: .destructive, action: onRemove)
            Button("取消", role: .cancel) {}
        } message: {
            Text("会移除命令链接；内容被修改过的补全文件会保留。")
        }
    }

    private var statusAppearance: (icon: String, color: Color) {
        switch status {
        case .linked:          ("checkmark.circle.fill", .green)
        case .notInstalled:    ("square.and.arrow.down", .secondary)
        case .dangling:        ("link.badge.plus", .orange)
        case .pointsElsewhere: ("arrow.triangle.branch", .orange)
        case .occupied:        ("exclamationmark.triangle.fill", .orange)
        }
    }

    private var reachAppearance: (icon: String, color: Color) {
        switch reach {
        case .reachable:  ("terminal.fill", .green)
        case .shadowed:   ("arrow.up.arrow.down", .orange)
        case .notOnPath:  ("exclamationmark.circle", .orange)
        case .unknown:    ("questionmark.circle", .secondary)
        }
    }

    private var showsInstallButton: Bool {
        if case .linked = status { return !completionsInstalled }
        return true
    }

    private var installTitle: String {
        switch status {
        case .notInstalled:       "安装命令行工具"
        case .linked:             "补齐命令行工具"
        case .dangling:           "重新安装命令行工具"
        case .pointsElsewhere:    "改为使用此 GitPic"
        case .occupied:           "替换现有 gitpic"
        }
    }

    private func beginInstall() {
        switch status {
        case .pointsElsewhere:
            confirmingRepoint = true
        case .occupied:
            confirmingOverwrite = true
        case .notInstalled, .linked, .dangling:
            onInstall(false)
        }
    }
}
