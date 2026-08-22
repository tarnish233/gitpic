import Testing
@testable import GitPicCore

/// The rule this suite exists for: **a state change the user cannot see is not a state
/// change.** Before ``StatusIcon`` the icon was whatever was assigned last, and the
/// missing-tool warning was erased by the very failure the missing tool caused.
///
/// What is testable here is the mapping and its distinctness. The other half of that bug's
/// fix — that an outcome returns the icon to the *warning* rather than to idle when there is
/// no `gitpic` — lives in `AppDelegate.restingState`, which reads `AppModel.toolState` and
/// so cannot be reached from a test target.
@Suite("Menu-bar icon")
struct StatusIconTests {

    @Test("resting on nothing in particular is the app's own mark")
    func idle() {
        #expect(StatusIcon.idle.symbol == StatusIcon.idleSymbol)
    }

    @Test("an upload in flight says so")
    func uploading() {
        #expect(StatusIcon.uploading.symbol == StatusIcon.uploadingSymbol)
    }

    @Test("no gitpic shows the warning")
    func unavailable() {
        #expect(StatusIcon.unavailable.symbol == StatusIcon.unavailableSymbol)
    }

    @Test("no two states draw the same glyph")
    func distinct() {
        // Otherwise a state change is a state change the user cannot see — which is the
        // entire complaint this type was added to answer.
        let symbols = [StatusIcon.idle, StatusIcon.uploading,
                       StatusIcon.unavailable].map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
