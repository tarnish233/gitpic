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

    @Test("progress and failures reach the shell row instead of only a notification")
    func rowFeedback() throws {
        let pane = try source("GeneralPane")
        #expect(pane.contains("workingShell: model.commandLineWorkingShell"))
        #expect(pane.contains("failureShell: model.commandLineFailureShell"))
        let view = try source("CommandLineSection")
        #expect(view.contains("if workingShell == shell"))
        #expect(view.contains("if failureShell == shell, let failure"))
        #expect(view.contains("else if case .unknown(let reason) = configuration"))
    }
}
