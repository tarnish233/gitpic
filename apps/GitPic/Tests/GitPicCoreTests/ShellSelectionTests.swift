import Foundation
import Testing
@testable import GitPicCore

struct ShellSelectionTests {
    @Test("a refresh preserves the chosen shell instead of reverting to the login shell")
    func preservesChoice() {
        #expect(CommandLineTool.preferredShell(
            current: .fish, available: [.bash, .zsh, .fish],
            loginShell: URL(fileURLWithPath: "/bin/zsh")) == .fish)
    }

    @Test("the first selection uses the measured shell when available", arguments: CommandLineTool.Shell.allCases)
    func startsWithLoginShell(shell: CommandLineTool.Shell) {
        #expect(CommandLineTool.preferredShell(
            current: nil, available: CommandLineTool.Shell.allCases,
            loginShell: URL(fileURLWithPath: "/bin/\(shell.rawValue)")) == shell)
    }

    @Test("removing a shell falls back to an available measured shell, then the first choice")
    func unavailableSelection() {
        #expect(CommandLineTool.preferredShell(
            current: .fish, available: [.bash, .zsh],
            loginShell: URL(fileURLWithPath: "/bin/zsh")) == .zsh)
        #expect(CommandLineTool.preferredShell(
            current: .fish, available: [.zsh, .bash],
            loginShell: URL(fileURLWithPath: "/bin/nu")) == .zsh)
        #expect(CommandLineTool.preferredShell(current: .fish, available: [.bash], loginShell: nil) == .bash)
    }

    @Test("no available shells means no selectable value")
    func emptyInventory() {
        #expect(CommandLineTool.preferredShell(
            current: .fish, available: [], loginShell: URL(fileURLWithPath: "/bin/fish")) == nil)
    }
}
