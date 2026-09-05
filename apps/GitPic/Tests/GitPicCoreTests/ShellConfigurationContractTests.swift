import Foundation
import Testing

/// GitPicApp is an executable target, not importable by tests. Like the window-focus and quit
/// contracts, these hold the thin UI wiring; FishConfigurationTests exercises the actual work.
struct ShellConfigurationContractTests {
    private func source(_ name: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/GitPicApp/\(name).swift"),
                          encoding: .utf8)
    }

    @Test("the fish configuration child stays off the main actor")
    func fishRunsOnProbeQueue() throws {
        let model = try source("AppModel")
        let start = try #require(model.range(of: "private nonisolated static func configureFish("))
        let end = try #require(model.range(of: "func configureShell(", range: start.upperBound..<model.endIndex))
        let bridge = model[start.lowerBound..<end.lowerBound]
        #expect(bridge.contains("commandLineProbeQueue.async"))
        #expect(bridge.contains("CommandLineTool.configureFish(fish: fish)"))
        #expect(model.contains("result = try await Self.configureFish(fish: fish)"))
    }

    @Test("a stale fish refresh is rejected after its final suspension")
    func refreshChecksGenerationAfterFish() throws {
        let model = try source("AppModel")
        let start = try #require(model.range(of: "let configurations = await loadShellConfiguration("))
        let assignment = try #require(model.range(of: "shellConfiguration = configurations",
                                                 range: start.upperBound..<model.endIndex))
        let afterFish = model[start.upperBound..<assignment.lowerBound]
        #expect(afterFish.contains("guard commandLineProbeGeneration == generation else { return }"))
    }

    @Test("the normal card has one shell selection and keeps removal behind Advanced")
    func progressiveDisclosure() throws {
        let view = try source("CommandLineSection")
        #expect(view.contains(".pickerStyle(.segmented)"))
        #expect(view.contains("@State private var showingDetails = false"))
        #expect(view.contains("DisclosureGroup(\"高级选项\""))
        #expect(view.contains("CommandLineShellRow("))
        #expect(view.contains(".onChange(of: workingShell, initial: true)"),
                "returning to General while fish works must show fish, not the login shell")
        #expect(view.contains(".confirmationDialog(\"替换现有的 gitpic 文件？\""))
        #expect(view.contains(".confirmationDialog(\"移除命令行工具？\""))
        let details = try source("CommandLineDetails")
        #expect(details.contains("if shell.usesStartupFile"))
        #expect(details.contains("onUnconfigure(shell)"))
        #expect(details.contains("action: onRemove"))
    }

    @Test("progress and failures reach the shell row instead of only a notification")
    func rowFeedback() throws {
        let pane = try source("GeneralPane")
        #expect(pane.contains("workingShell: model.commandLineWorkingShell"))
        #expect(pane.contains("failureShell: model.commandLineFailureShell"))
        let view = try source("CommandLineSection")
        #expect(view.contains("failureShell != selectedShell"), "errors from another shell stay visible")
        let row = try source("CommandLineShellRow")
        #expect(row.contains("if workingShell == shell"))
        #expect(row.contains("if let failure"))
        #expect(row.contains("else if case .unknown(let reason) = configuration"))
    }
}
