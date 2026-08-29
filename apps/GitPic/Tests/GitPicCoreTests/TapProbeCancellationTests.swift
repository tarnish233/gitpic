import Foundation
import Testing

/// `GitpicRunner.run` must not honour task cancellation, and this is the tripwire for it.
///
/// A source scan rather than a behavioural test, for the same reason `QuitPathContractTests`
/// is one: the interleaving cannot be reached from `swift test`. It needs `AppModel`, which
/// lives in `GitPicApp` and is not importable here (`Updater.swift` records why), driven by a
/// SwiftUI `.task(id:)` cancelling mid-probe. So this checks the property a grep *can* hold —
/// that the prohibition has not been quietly undone — and the argument for it lives on `run`.
///
/// **What the prohibition is.** `AppModel.resolveUpgradePath` loops: when a check lands while
/// the tap probe is running, the generation moves, the in-flight call notices and asks again.
/// But moving the generation is exactly what makes `.task(id:)` tear that task down, so the
/// second ask is made from a task that is *already cancelled*. `withCheckedThrowingContinuation`
/// ignores cancellation, which is what lets the second ask succeed.
///
/// **Measured, both ways.** With a `withTaskCancellationHandler` around it, the first probe is
/// killed mid-flight and the re-query is killed before it starts — `onCancel` fires immediately
/// on an already-cancelled task. Without it, both complete. And because `CaskOwnership.verdict`
/// turns every failure into `Offer.unknown`, the killed version resolved the new report to
/// 「暂时读不到 Homebrew 提供的版本」 with a caveat instead of a real version comparison: wrong
/// information, where the alternative is an honest 「正在确认升级方式…」 for the length of the
/// bound. The bound is what keeps a wedged child harmless — `tapTimeout`, on its own queue,
/// blocking nothing.
///
/// **Being honest about what this cannot hold.** It cannot see whether the loop still depends on
/// the property, whether `verdict` still collapses failures into `Offer.unknown`, or whether some
/// *other* mechanism starts cancelling the probe. What it is genuinely good for is the one thing
/// that has already happened once: a plausible-looking cancellation handler being added to this
/// file by someone who had not traced the caller.
@Suite("Tap probe cancellation contract")
struct TapProbeCancellationTests {

    /// Every spelling that would make the continuation cancellable.
    ///
    /// `withTaskCancellationHandler` is the one that was tried and reverted.
    /// `Task.checkCancellation` and a bare `isCancelled` are the other two ways the same effect
    /// arrives — a throw or an early return on the second pass is just as fatal to the loop as a
    /// terminated child.
    static let forbidden = [
        "withTaskCancellationHandler",
        "checkCancellation",
        "Task.isCancelled",
    ]

    /// Located from `#filePath` rather than the working directory, because `swift test` runs both
    /// from the repository root and from inside the package — the argument is
    /// `QuitPathContractTests.appSources`'s, and so is the failure it guards against: a path that
    /// guessed wrong would leave this suite passing over a file it never opened.
    static func runnerSource() throws -> (url: URL, text: String) {
        var root = URL(fileURLWithPath: #filePath)
        // 3 components: …/Tests/GitPicCoreTests/<this file> → the `apps/GitPic` package root.
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("Sources/GitPicCore/GitpicRunner.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        return (url, text)
    }

    /// The precondition, asserted where it matters rather than assumed: if the file moves or is
    /// renamed, this fails first and says so, instead of the scan below reading nothing.
    @Test("the runner source is where the scan expects it")
    func sourceExists() throws {
        let (url, text) = try Self.runnerSource()
        #expect(text.contains("nonisolated func run("), "\(url.path) is not the runner any more")
        #expect(text.contains("func tapCask()"), "\(url.path) no longer holds the tap probe")
    }

    /// The tripwire.
    @Test("the runner does not make its spawn cancellable")
    func theSpawnIsNotCancellable() throws {
        let (url, text) = try Self.runnerSource()
        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            // Comments may name it — `run`'s own doc comment explains the prohibition at length,
            // and that explanation is the reason the property holds. Same rule and same reason as
            // `QuitPathContractTests.isComment`: whole-line comments only, so a trailing comment
            // cannot hide a real call.
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            for spelling in Self.forbidden where line.contains(spelling) {
                Issue.record("""
                    \(url.lastPathComponent):\(offset + 1) names \(spelling). \
                    `AppModel.resolveUpgradePath` re-asks for the tap from a task SwiftUI has \
                    already cancelled, so making this spawn cancellable turns a new report's \
                    answer into 「暂时读不到 Homebrew 提供的版本」. The bound in `tapTimeout` is \
                    what keeps a wedged child harmless. If this line is an explanation rather \
                    than code, make it a whole-line comment.
                    """)
            }
        }
    }

    /// The other half: the bound this relies on instead is still there and still shorter than the
    /// CLI's own request ceiling, which is what makes the Swift side the binding one.
    @Test("the tap probe is bounded rather than cancellable")
    func theTapProbeIsBounded() throws {
        let (_, text) = try Self.runnerSource()
        #expect(text.contains("static let tapTimeout: TimeInterval = 10"))
        // Off the shared gate, which is the other half of why an uncancelled child is harmless:
        // it holds up nothing that an upload waits on.
        #expect(text.contains("on: Self.tapQueue, timeout: Self.tapTimeout"))
    }
}
