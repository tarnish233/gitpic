import Foundation

/// Which SF Symbol the menu-bar icon should be showing.
///
/// The icon has to answer two independent questions with one glyph — what the app is
/// doing, and whether a drag hovering over it right now will be taken. This holds
/// both and resolves them in one place. The four scattered
/// `statusItem.button?.image = …` assignments it replaces could not: the icon was
/// whatever the last writer wrote, and that already had a bug in it. With `gitpic`
/// missing the icon is the warning triangle, but the "找不到 gitpic" failure that the
/// missing tool itself produces goes through `AppDelegate.report`, which reset the
/// glyph to the idle one — so the warning was gone for the rest of the session, with
/// nothing able to bring it back (traced through the call sites, not seen on screen).
/// Restoring the icon after a hover is that same problem a third time, which is why
/// this is a value with a rule rather than one more assignment.
///
/// In `GitPicCore` for the reason `ImageDrop` gives: the rule is worth a test, and
/// `GitPicApp` is an executable target no test can import. The symbol *names* travel
/// with it — they are plain strings, no AppKit — so a test can pin the whole rule
/// instead of half of it.
public struct StatusIcon: Equatable, Sendable {

    /// What the app is doing. One field rather than a flag each, so "uploading" and
    /// "no tool" cannot both be set — and they never can be in truth either: with no
    /// `gitpic` there is no runner, so no upload can start.
    public enum State: Equatable, Sendable {
        /// Nothing in flight. The resting glyph.
        case idle
        /// An upload is running, and held for exactly as long as it runs — see
        /// `AppDelegate.report`.
        case uploading
        /// Discovery finished and `gitpic` was not found. Decided once at launch and
        /// never recovered from, so this outlives any number of upload outcomes.
        case unavailable
    }

    public var state: State

    /// A drag the drop target has **accepted** is over the icon right now.
    ///
    /// Set between `draggingEntered` returning `.copy` and the drag leaving, ending,
    /// or dropping. A refused drag never sets it: refusal stays silent, for the
    /// reasons written down in `StatusItemDropView.draggingEntered`.
    public var dropTargeted: Bool

    public init(state: State = .idle, dropTargeted: Bool = false) {
        self.state = state
        self.dropTargeted = dropTargeted
    }

    /// The resting glyph: the app's own mark, and what the menu bar shows almost
    /// always.
    public static let idleSymbol = "photo.on.rectangle.angled"
    /// In flight. An arrow, because the direction is the news.
    public static let uploadingSymbol = "arrow.up.circle"
    /// No `gitpic`; nothing here can upload.
    public static let unavailableSymbol = "exclamationmark.triangle.fill"

    /// An accepted drag is over the icon.
    ///
    /// A glyph swap rather than `NSStatusItem.button.highlight(true)`, which was the
    /// obvious alternative and is a bigger change than any glyph — it fills the whole
    /// item with the system's selection pill. That pill is exactly the problem:
    /// captured from a real click, it is already what the icon wears while its *menu*
    /// is open, so borrowing it for a hover would give one appearance two meanings.
    /// The glyph is also the part that survives being the only thing on screen the
    /// user is looking at, and it is a plain string, so the rule below stays testable.
    ///
    /// Same `photo` family as the resting glyph on purpose — "the same thing, plus
    /// one" rather than an unrelated picture — and deliberately not an arrow, which is
    /// already spoken for by the in-flight state.
    ///
    /// `.fill` is what makes it read at menu-bar size. Rendered into a 22 pt box at 2x
    /// (macOS 26.5, this display): the resting glyph inks 9.6% of the box, the plain
    /// `photo.badge.plus` 10.0%, this one 11.4%. Against the resting glyph, 6.8% of
    /// the box changes ink state — where the swap to `arrow.up.circle` the app already
    /// relies on for an upload in flight changes 11.0%. So this is a smaller change
    /// than the one already accepted as legible, and roughly two thirds of it: the
    /// outlined two-card stack becomes one filled card with a badge, which at 2x is
    /// plainly a different mark (checked against a real status item, side by side with
    /// a second one showing the resting glyph).
    ///
    /// It is also the **widest** of the four, and that is load-bearing, not cosmetic.
    /// A status item is `variableLength`, so the glyph decides the item's width:
    /// measured on a real status item, 36 pt resting, 37 pt for this, 32 pt in flight,
    /// 33 pt for the warning. A hover glyph *narrower* than the one it replaces would
    /// shrink the item out from under a pointer near its edge — `draggingExited`, icon
    /// restored, item grows back, `draggingEntered` again, and the icon flickers for as
    /// long as the drag hovers there. Growing cannot do that. Anything swapped in here
    /// later has to stay at least as wide as ``idleSymbol``.
    public static let dropTargetedSymbol = "photo.badge.plus.fill"

    /// The symbol to draw.
    ///
    /// **The hover wins over every other state, `.unavailable` included.** Not an
    /// oversight: the drop target's answer does not depend on whether `gitpic` was
    /// found — `draggingEntered` asks only `ImageDrop.accepted` — so the system is
    /// already drawing its copy badge on the cursor. An icon saying "broken" under a
    /// cursor saying "will copy" is two answers to one question. The drag ends a
    /// moment later and the warning comes straight back, and a drop that cannot run
    /// still says why in a notification.
    public var symbol: String {
        if dropTargeted { return Self.dropTargetedSymbol }
        switch state {
        case .idle: return Self.idleSymbol
        case .uploading: return Self.uploadingSymbol
        case .unavailable: return Self.unavailableSymbol
        }
    }
}
