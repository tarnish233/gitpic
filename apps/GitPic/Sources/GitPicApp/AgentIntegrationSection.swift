import SwiftUI
import GitPicCore

/// One agent's independent gitpic Skill installation controls.
struct AgentIntegrationSection: View {
    let agent: SkillAgent
    let target: SkillTarget?
    let isInstalling: Bool
    let installDisabled: Bool
    let onInstall: (_ force: Bool) -> Void

    @State private var confirmingReplacement = false

    private var title: String {
        switch agent {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .generic: "通用 Agent"
        }
    }

    private var status: (title: String, icon: String, color: Color) {
        switch target?.action {
        case nil:        ("未检测到", "questionmark.circle", .secondary)
        case .install:   ("未安装", "square.and.arrow.down", .secondary)
        case .update:    ("内容有差异", "exclamationmark.triangle.fill", .orange)
        case .unchanged: ("已是最新", "checkmark.circle.fill", .green)
        }
    }

    var body: some View {
        Section(title) {
            LabeledContent("状态") {
                Label(status.title, systemImage: status.icon)
                    .foregroundStyle(status.color)
            }

            if let target {
                LabeledContent("安装文件") {
                    Text(target.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if target.action == .update {
                    Text("替换会用 GitPic 内置版本覆盖现有 SKILL.md。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("没有检测到配置目录；安装会创建该 Agent 的默认 skills 目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if target?.action != .unchanged {
                Button(action: beginInstall) {
                    ZStack {
                        Text(actionTitle)
                            .opacity(isInstalling ? 0 : 1)
                        if isInstalling {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                    .disabled(installDisabled)
                    .confirmationDialog(
                        "替换 \(title) 的 Skill？",
                        isPresented: $confirmingReplacement
                    ) {
                        Button("替换", role: .destructive) {
                            onInstall(true)
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("现有 SKILL.md 与 GitPic 内置版本不同，替换会覆盖它的全部内容。")
                    }
            }
        }
    }

    private var actionTitle: String {
        target?.action == .update ? "替换" : "安装"
    }

    private func beginInstall() {
        if target?.action == .update {
            confirmingReplacement = true
        } else {
            onInstall(false)
        }
    }
}
