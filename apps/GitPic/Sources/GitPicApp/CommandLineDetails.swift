import Foundation
import SwiftUI
import GitPicCore

struct CommandLineDetails: View {
    let status: CommandLineTool.Status
    let reach: CommandLineTool.Reach
    let probing: Bool
    let completionsInstalled: Bool
    let working: Bool
    let shell: CommandLineTool.Shell?
    let configuration: CommandLineTool.ShellConfiguration?
    let onCopySetup: () -> Void
    let onUnconfigure: (CommandLineTool.Shell) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("安装位置").foregroundStyle(.secondary)
                Text(CommandLineTool.link.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(status.detail).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            LabeledContent("命令补全", value: completionsInstalled ? "已安装" : "尚未完整安装")

            VStack(alignment: .leading, spacing: 4) {
                Text("登录终端检测").foregroundStyle(.secondary)
                Text(probing ? "正在检查 PATH…" : reach.detail)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let shell, configuration == .configured {
                Divider()
                if shell.usesStartupFile {
                    Button("移除 \(shell.rawValue) 配置", role: .destructive) { onUnconfigure(shell) }
                        .disabled(working)
                    if let file = shell.startupFile(home: FileManager.default.homeDirectoryForCurrentUser) {
                        Text("只移除 \(file) 中 GitPic 的配置块，其余内容和已有备份保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("fish 的持久路径可能被其他工具共用，不自动移除。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shell == .zsh, completionsInstalled, configuration == .notConfigured,
               let setUp = CommandLineTool.Shell.zsh.setUp {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("手动设置 zsh 补全").foregroundStyle(.secondary)
                    Text("将以下内容添加到 \(setUp.file)：").font(.caption)
                    Text(setUp.lines.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("复制设置", systemImage: "doc.on.doc", action: onCopySetup)
                }
            }

            if status == .linked {
                Divider()
                Button("移除命令行工具…", role: .destructive, action: onRemove)
                    .disabled(working)
            }
        }
        .controlSize(.small)
    }
}
