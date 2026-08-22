import AppKit
import SwiftUI

/// The one animation in this app, and the accessibility preference that governs it.
///
/// **Everything here exists for one 44×32 pt box.** Before this file the app contained
/// no `withAnimation`, no `.animation` and no `.transition` at all — a deliberate
/// absence for a window shaped like System Settings, and one worth keeping. The single
/// exception is a history thumbnail that arrives from the network *after* its row is
/// already on screen: that swap is a hard cut, and on a cold cache it is 33 of them
/// spread over the seconds the pane takes to fill.
///
/// It is a named type rather than two literals in a view body because it is also the
/// app's **first** accessibility-preference handling. The next person to reach for a
/// spring in this app should find the policy before they find the API, and one file
/// named for the concern is where they will look for it.
enum Motion {

    /// Whether the user has asked for less motion.
    ///
    /// **Read at use time, not observed.** AppKit does post
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` when this flips
    /// while the app runs, and ignoring that would be wrong if anything on screen were
    /// *derived* from the flag — a spinner that has to stop turning, a parallax that
    /// has to stop shifting. Nothing here is. The flag is consulted at exactly one
    /// instant, the tick a thumbnail arrives, and all it does is pick the animation for
    /// that single transition; between arrivals no pixel depends on it. An observer
    /// would exist to keep a mirrored copy current so that the next read — which does
    /// its own read anyway — could agree with it.
    ///
    /// The consequence is worth naming rather than hiding: a change mid-run takes
    /// effect on the next thumbnail that arrives late, so the one way to see the stale
    /// behaviour is to flip the setting while a cold history pane is still filling in,
    /// and even then only for the rows already in flight.
    ///
    /// `@Environment(\.accessibilityReduceMotion)` is the other spelling of the same
    /// system flag, and the right one *inside a body*. This decision is not taken in a
    /// body — it is taken in the `.task` that awaits the image — so the workspace read
    /// is the direct one here, and keeping it in one place means the next view that
    /// needs it finds an answer rather than writing a second one.
    @MainActor
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// How late a thumbnail has to be before its arrival is worth softening.
    ///
    /// **This threshold is the whole difference between removing a flicker and
    /// manufacturing one.** A warm pane resolves every row before anyone could see a
    /// placeholder, so fading those in would add a flutter to every reopen where today
    /// there is none — the reverse of the point.
    ///
    /// Measured on this machine, against the real 33-image cache directory copied to a
    /// temp dir, a brand-new ``ThumbnailStore`` (empty memory, warm disk) asked for all
    /// 33 at once, three rounds: **4.0–6.6 ms for the whole set, worst single row
    /// 6.5 ms**. Second pass on the same store, so memory hits: 0.1–0.2 ms for the set,
    /// worst row 0.13 ms. That was a test process with an idle main thread, and the real
    /// pane's is busy laying the window out, which is why the line is not drawn tight
    /// against 6.5 ms.
    ///
    /// A tenth of a second is the conventional line for "instant", and it sits about
    /// fifteen times above the slowest warm row measured above while staying far below
    /// anything the network can do — the TTFB figures recorded in
    /// ``HistoryRecord/thumbnailSource(config:)`` are 0.29 s at best. So the two cases
    /// separate with room on both sides, and no layer of the cache has to be asked
    /// which one it answered from.
    static let thumbnailIsLateAfter = Duration.milliseconds(100)

    /// A thumbnail becoming visible where its placeholder was: an opacity cross-fade,
    /// and nothing else.
    ///
    /// No scale and no spring in either branch. The box does not move, grow or
    /// overshoot; the picture simply becomes visible where the grey placeholder was.
    /// That is the smallest thing that stops a cut from reading as a cut, and this is a
    /// System-Settings-shaped window where the platform's own motion is the familiar
    /// one — the goal is to stop a flicker, not to add character.
    ///
    /// **Reduce-motion does not mean "no fade" here.** A cross-fade with no
    /// displacement is what that setting asks animation to be *replaced by*, not what
    /// it asks to have removed; dropping it would hand the user who asked for less
    /// motion precisely the 33 hard cuts this exists to fix. What the branch does is
    /// keep it short, and — more usefully — put the no-spring constraint somewhere the
    /// next person animating this transition has to read first.
    @MainActor
    static var thumbnailArrival: Animation {
        reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.2)
    }
}
