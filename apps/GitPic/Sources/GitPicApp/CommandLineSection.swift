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

    @State private var confirmingRepoint = false
    @State private var confirmingOverwrite = false
    @State private var confirmingRemoval = false

    /// Computed from the verdict rather than passed in: it is a couple of `fileExists` calls, and
    /// deriving it here keeps "which shell was measured" in one place.
    private var otherShells: [(shell: CommandLineTool.Shell, setUp: CommandLineTool.SetUp)] {
        CommandLineTool.otherShellsNeedingPath(measured: reach.shell)
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

                // Stated for every shell that looks in use and was not the one measured, because
                // the verdict above is only ever true of one shell. The author's own machine is
                // the case this exists for: `$SHELL` is zsh and `~/.zshrc` exports
                // `~/.local/bin`, so the row above says "reachable" — while the fish used for
                // actual work had never heard of the directory and `gitpic` was `Unknown
                // command` there. Worded as a fact rather than a warning: the app cannot tell
                // whether that shell's PATH is already right without spending 8 seconds per
                // shell asking, and a false alarm here is worse than a line of information.
                ForEach(otherShells, id: \.shell) { other in
                    Text("\(other.shell.rawValue) 的 PATH 是单独配置的。\(other.setUp.why)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(other.setUp.lines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button {
                            onCopyPath(other.shell)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制 \(other.shell.rawValue) 的 PATH 设置")
                    }
                }
            }

            LabeledContent("补全") {
                Label(
                    completionsInstalled ? "bash、zsh、fish 已安装" : "尚未完整安装",
                    systemImage: completionsInstalled
                        ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(completionsInstalled ? .green : .secondary)
            }

            if completionsInstalled, let setUp = CommandLineTool.Shell.zsh.setUp {
                Text("zsh 还需要把下面两行加入 \(setUp.file)。\(setUp.why)")
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
