import Foundation
import SwiftUI
import GitPicCore

/// Only the selected shell is described. Other installed shells are choices, not unfinished work.
struct CommandLineShellRow: View {
    let shell: CommandLineTool.Shell
    let configuration: CommandLineTool.ShellConfiguration
    let working: Bool
    let workingShell: CommandLineTool.Shell?
    let failure: String?
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if workingShell == shell {
                    ProgressView().controlSize(.small)
                    Text("正在配置并验证 \(shell.rawValue)…")
                        .foregroundStyle(.secondary)
                } else if configuration == .configured {
                    Label("\(shell.rawValue) 已配置", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(configuration == .notConfigured ? "只需配置你常用的终端" : "\(shell.rawValue) 无法确认")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("自动配置", action: onConfigure)
                        .controlSize(.small)
                        .disabled(working)
                        .accessibilityLabel("自动配置 \(shell.rawValue)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let failure {
                CommandLineNotice(message: failure)
            } else if case .unknown(let reason) = configuration {
                CommandLineNotice(message: reason)
            } else if configuration == .notConfigured {
                // The one relevant consent detail stays beside the action, not hidden in
                // Advanced: a named startup file + backup for bash/zsh, no file edit for fish.
                Text(configurationHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configurationHint: String {
        if let file = shell.startupFile(home: FileManager.default.homeDirectoryForCurrentUser) {
            return "写入 \(file)，原文件会备份；其余配置保持不变。"
        }
        return "保存到 fish 的持久 PATH，不改动启动文件。"
    }
}
