import Foundation
import Testing
@testable import GitPicCore

@Suite("Skill JSON contract")
struct SkillTests {
    @Test("UI agents use the CLI spellings")
    func agentStrings() {
        #expect(SkillAgent.allCases.map(\.rawValue) == ["claude", "codex", "generic"])
    }

    @Test("overwrite permission is only passed after confirmation", arguments: [false, true])
    func installArguments(force: Bool) {
        let arguments = GitpicRunner.skillInstallArguments(for: .generic, force: force)

        #expect(arguments.contains("--force") == force)
        #expect(arguments.last == "--json")
    }

    @Test("path status keeps the agent identity and final file")
    func pathStatus() throws {
        let json = #"""
        {
          "ok": true,
          "name": "gitpic",
          "version": "0.18.0",
          "targets": [{
            "agents": ["claude"],
            "action": "installed",
            "path": "/Users/you/.claude/skills/gitpic/SKILL.md"
          }]
        }
        """#

        let report = try JSONDecoder().decode(SkillPathEnvelope.self, from: Data(json.utf8))
        let target = try #require(report.targets.first)

        #expect(report.ok)
        #expect(report.version == "0.18.0")
        #expect(target.agents == ["claude"])
        #expect(target.action == .install)
        #expect(target.path == "/Users/you/.claude/skills/gitpic/SKILL.md")
    }

    @Test("a partial install keeps both the successful rows and the CLI error")
    func partialInstall() throws {
        let json = #"""
        {
          "ok": false,
          "name": "gitpic",
          "version": "0.18.0",
          "installed": [{
            "agents": ["claude"],
            "action": "updated",
            "path": "/Users/you/.claude/skills/gitpic/SKILL.md"
          }],
          "error": {
            "code": "GENERAL",
            "message": "cannot write Codex target"
          }
        }
        """#

        let report = try JSONDecoder().decode(SkillInstallEnvelope.self, from: Data(json.utf8))
        let installed = try #require(report.installed.first)
        let error = try #require(report.error)

        #expect(report.ok == false)
        #expect(installed.action == .update)
        #expect(error.code == "GENERAL")
        #expect(error.message == "cannot write Codex target")
    }

    @Test("all CLI action strings remain distinct")
    func actionStrings() throws {
        let values = ["installed", "updated", "already up to date"]
        let decoded = try values.map {
            try JSONDecoder().decode(SkillWriteAction.self, from: Data("\"\($0)\"".utf8))
        }

        #expect(decoded == [.install, .update, .unchanged])
    }
}
