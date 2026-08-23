import SwiftUI
import GitPicCore

/// The integrations stay separate even when their skills directories resolve
/// through symlinks to the same file.
struct AgentPaneReadyContent: View {
    var model: AppModel

    var body: some View {
        if model.skillTargetsLoading, model.skillTargetsLoaded == false {
            Section {
                Label("正在检查 Agent 集成…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        } else {
            if let failure = model.skillFailure {
                Section {
                    Label("Agent 集成操作失败", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            ForEach(SkillAgent.allCases) { agent in
                AgentIntegrationSection(
                    agent: agent,
                    target: target(for: agent),
                    isInstalling: model.skillInstallID == "agent:\(agent.rawValue)",
                    installDisabled: model.skillInstallID != nil,
                    onInstall: { force in install(agent, force: force) })
            }

            Section {
                Button("刷新状态", action: refresh)
                    .controlSize(.small)
                    .disabled(model.skillInstallID != nil || model.skillTargetsLoading)
            }
        }
    }

    private func target(for agent: SkillAgent) -> SkillTarget? {
        model.skillTargets.first { $0.agents.contains(agent.rawValue) }
    }

    private func install(_ agent: SkillAgent, force: Bool) {
        Task { await model.installSkill(for: agent, force: force) }
    }

    private func refresh() {
        Task { await model.loadSkillTargets() }
    }
}
