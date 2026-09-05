import Foundation
import SwiftUI
import GitPicCore

/// One compact card: install once, choose a shell, configure it. Technical details and removal
/// are secondary; failures and conflicting PATH results must never be hidden in the disclosure.
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
    let shellConfiguration: [CommandLineTool.Shell: CommandLineTool.ShellConfiguration]
    let workingShell: CommandLineTool.Shell?
    let failureShell: CommandLineTool.Shell?
    let onConfigureShell: (CommandLineTool.Shell) -> Void
    let onUnconfigureShell: (CommandLineTool.Shell) -> Void

    @State private var selectedShell: CommandLineTool.Shell?
    @State private var showingDetails = false
    @State private var confirmingRepoint = false
    @State private var confirmingOverwrite = false
    @State private var confirmingRemoval = false

    var body: some View {
        Section("命令行") {
            VStack(alignment: .leading, spacing: 12) {
                installationRow

                if status == .linked {
                    Divider()
                    shellSettings
                }

                // An error from another shell (or from installation/removal) remains visible
                // even if the user changes the picker or the failed shell disappears.
                if let failure, status != .linked || failureShell != selectedShell
                    || selectedShell == nil {
                    CommandLineNotice(message: failure)
                }

                if status == .linked, !probing, let warning = reachWarning {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CommandLineNotice(message: warning)
                        Spacer(minLength: 0)
                        Button("详情") { showingDetails = true }
                            .controlSize(.small)
                    }
                }

                Divider()
                DisclosureGroup("高级选项", isExpanded: $showingDetails) {
                    CommandLineDetails(
                        status: status, reach: reach, probing: probing,
                        completionsInstalled: completionsInstalled, working: working,
                        shell: selectedShell,
                        configuration: selectedShell.flatMap { shellConfiguration[$0] },
                        onCopySetup: onCopySetup, onUnconfigure: onUnconfigureShell,
                        onRemove: { confirmingRemoval = true })
                        .padding(.top, 12)
                }
                .font(.callout)
            }
            .padding(.vertical, 4)
        }
        .onChange(of: availableShells, initial: true) { _, available in
            selectedShell = CommandLineTool.preferredShell(
                current: workingShell ?? selectedShell ?? (failure == nil ? nil : failureShell),
                available: available, loginShell: reach.shell)
        }
        .onChange(of: workingShell, initial: true) { _, shell in
            if let shell, availableShells.contains(shell) { selectedShell = shell }
        }
        .confirmationDialog("让命令行链接改为当前 GitPic？", isPresented: $confirmingRepoint) {
            Button("重新指向", role: .destructive) { onInstall(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(status.detail)
        }
        .confirmationDialog("替换现有的 gitpic 文件？", isPresented: $confirmingOverwrite) {
            Button("替换文件", role: .destructive) { onInstall(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(CommandLineTool.link.path) 不是符号链接。替换会永久覆盖这个文件。")
        }
        .confirmationDialog("移除命令行工具？", isPresented: $confirmingRemoval) {
            Button("移除", role: .destructive, action: onRemove)
            Button("取消", role: .cancel) {}
        } message: {
            Text("会移除命令链接；内容被修改过的补全文件会保留。")
        }
    }

    private var installationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("gitpic").font(.headline.monospaced())
                Text(installationCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if working, workingShell == nil || workingShell != selectedShell || status != .linked {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在更新命令行工具")
            } else if showsInstallButton {
                Button(installTitle, action: beginInstall)
                    .controlSize(.small)
                    .disabled(installDisabled || working)
            } else {
                Label("已安装", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var shellSettings: some View {
        if let selectedShell, let configuration = shellConfiguration[selectedShell] {
            Picker("配置终端", selection: $selectedShell) {
                ForEach(availableShells, id: \.self) { shell in
                    Text(shell.rawValue).tag(Optional(shell))
                }
            }
            .pickerStyle(.segmented)
            .disabled(working)

            CommandLineShellRow(
                shell: selectedShell, configuration: configuration,
                working: working, workingShell: workingShell,
                failure: failureShell == selectedShell ? failure : nil,
                onConfigure: { onConfigureShell(selectedShell) })
        } else if probing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检测可用终端…").foregroundStyle(.secondary)
            }
        } else {
            Text("未检测到可配置的终端。可在高级选项查看安装信息。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var availableShells: [CommandLineTool.Shell] {
        CommandLineTool.Shell.allCases.filter { shellConfiguration[$0] != nil }
    }

    private var installationCaption: String {
        switch status {
        case .linked:
            completionsInstalled ? "随应用更新，无需单独升级。" : "命令已安装，补全文件尚未齐全。"
        case .notInstalled:
            "在终端中上传图片，包含命令补全。"
        case .dangling:
            "原来的应用已不在，需重新安装命令。"
        case .pointsElsewhere:
            "命令链接指向另一个位置。"
        case .occupied:
            "安装位置已有文件，替换前会再次确认。"
        }
    }

    private var reachWarning: String? {
        switch reach {
        case .reachable: nil
        case .shadowed(_, let shell): "\(shell.lastPathComponent) 会优先运行另一份 gitpic。"
        case .notOnPath(let shell): "\(shell.lastPathComponent) 还找不到 gitpic。"
        case .unknown: "暂时无法确认登录终端的 PATH。"
        }
    }

    private var showsInstallButton: Bool {
        if case .linked = status { return !completionsInstalled }
        return true
    }

    private var installTitle: String {
        switch status {
        case .notInstalled: "安装"
        case .linked: "补齐安装"
        case .dangling: "重新安装"
        case .pointsElsewhere: "改为当前版本…"
        case .occupied: "替换…"
        }
    }

    private func beginInstall() {
        switch status {
        case .pointsElsewhere: confirmingRepoint = true
        case .occupied: confirmingOverwrite = true
        case .notInstalled, .linked, .dangling: onInstall(false)
        }
    }
}
