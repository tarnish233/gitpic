import SwiftUI
import GitPicCore

struct AgentPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Label("管理 GitPic 与 AI Agent 的集成。",
                      systemImage: "cpu")
                Text("Claude Code、Codex 与通用 Agent 分开管理；分别安装 gitpic Skill 后，"
                     + "它们就能调用 gitpic 上传图片并返回链接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let version = model.skillVersion {
                    LabeledContent("内置版本") {
                        Text(version).monospacedDigit()
                    }
                }
            }

            switch model.toolState {
            case .resolving:
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在查找 gitpic…").foregroundStyle(.secondary)
                    }
                }
            case .missing:
                Section {
                    Label("找不到 gitpic 可执行文件，请重新安装 GitPic。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            case .ready:
                AgentPaneReadyContent(model: model)
            }
        }
        .formChrome()
        .task(id: model.toolState) {
            guard model.toolState == .ready else { return }
            await model.loadSkillTargets()
        }
    }
}
