import Testing
@testable import GitPicCore

/// The rule this suite exists for: a hover is an *overlay*, so leaving one has to
/// restore what was underneath. Before ``StatusIcon`` the icon was whatever was
/// assigned last, and "restore" could only mean the idle glyph — which is wrong twice
/// over, once for a drag that ends mid-upload and once for a drag over an app that
/// never found `gitpic`.
@Suite("Menu-bar icon")
struct StatusIconTests {

    @Test("resting on nothing in particular is the app's own mark")
    func idle() {
        #expect(StatusIcon().symbol == StatusIcon.idleSymbol)
    }

    @Test("an accepted hover changes the glyph")
    func hover() {
        var icon = StatusIcon()
        icon.dropTargeted = true
        #expect(icon.symbol == StatusIcon.dropTargetedSymbol)
        #expect(icon.symbol != StatusIcon.idleSymbol)
    }

    @Test("a hover that ends mid-upload gives the upload its icon back, not the idle one")
    func hoverDoesNotStealAnUpload() {
        // The sequence a second drag over a busy icon produces. The upload is still
        // running when the drag leaves, and it owns the icon again the moment it does.
        var icon = StatusIcon(state: .uploading)
        icon.dropTargeted = true
        #expect(icon.symbol == StatusIcon.dropTargetedSymbol)
        icon.dropTargeted = false
        #expect(icon.symbol == StatusIcon.uploadingSymbol)
    }

    @Test("a hover that ends with no gitpic gives the warning back, not the idle one")
    func hoverDoesNotEraseTheWarning() {
        var icon = StatusIcon(state: .unavailable)
        icon.dropTargeted = true
        icon.dropTargeted = false
        #expect(icon.symbol == StatusIcon.unavailableSymbol)
    }

    @Test("the hover outranks every other state, including the missing-tool warning")
    func hoverWins() {
        // Deliberate, not incidental: `draggingEntered` accepts the drag whether or
        // not `gitpic` was found, so the system is already drawing its copy badge on
        // the cursor. The icon agrees with the cursor rather than arguing with it.
        for state in [StatusIcon.State.idle, .uploading, .unavailable] {
            #expect(StatusIcon(state: state, dropTargeted: true).symbol
                    == StatusIcon.dropTargetedSymbol)
        }
    }

    @Test("no two states draw the same glyph")
    func distinct() {
        // Otherwise a state change is a state change the user cannot see — which is
        // the entire complaint this type was added to answer.
        let symbols = [StatusIcon(state: .idle), StatusIcon(state: .uploading),
                       StatusIcon(state: .unavailable),
                       StatusIcon(state: .idle, dropTargeted: true)].map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
