import AppKit
import UniformTypeIdentifiers
import GitPicCore

/// The drop target that makes the menu-bar icon accept a dragged image.
///
/// `NSStatusItem.button` is an `NSStatusBarButton` the system creates, so it cannot
/// be subclassed and its dragging-destination callbacks cannot be overridden. A
/// child view is the only interception point; `AppDelegate.setUpStatusItem` adds one
/// of these to the button and lets autoresizing keep it at the button's size.
///
/// **There is deliberately no `hitTest` override.** The deleted notch drop view had
/// one that forced every event to itself, which would have been fatal here: the
/// status item has a menu attached, and swallowing the click would mean the icon no
/// longer opens it. Measured with a probe on this exact shape — button, attached
/// menu, this view as a subview, no `hitTest` override — a real Finder drag reached
/// `draggingEntered` and `performDragOperation`, *and* clicking the icon still fired
/// `menuWillOpen`. Both work only because AppKit's own hit testing is left alone.
///
/// The hover feedback added on top of that was exercised the same way, with one
/// difference worth being honest about: a real drag session cannot be synthesised, so
/// the probe drove `draggingEntered` / `draggingExited` / `draggingEnded` /
/// `performDragOperation` directly, passing a stub `NSDraggingInfo` over a real
/// pasteboard carrying real files, against a real `NSStatusItem` with a menu attached.
/// What that confirmed, on macOS 26.5: one image → `.copy` and `onTargeted(true)`;
/// two images → no operation and `onTargeted` never fired at all; and every one of
/// the four ways out — exited, ended, dropped, dropped-and-refused — put the icon
/// back, including back to the *in-flight* glyph when the hover happened during an
/// upload rather than to the resting one. What it cannot show is that a real Finder
/// drag delivers those callbacks; the paragraph above is the evidence for that.
final class StatusItemDropView: NSView {
    var onDrop: ((URL) -> Void)?

    /// Called with `true` when an **accepted** drag arrives over the icon, and with
    /// `false` on every way back out of one — exited, ended, dropped, or a drop that
    /// failed. `AppDelegate.attachDropTarget` turns it into the icon's hover state.
    ///
    /// The system already badges the drag image with a green "+" once
    /// `draggingEntered` returns `.copy`, so accept-vs-refuse was never invisible.
    /// But that badge rides the cursor, and it says the same thing over any copy
    /// destination on screen; nothing marked *this* target as the one that would take
    /// it. Hence a change on the target too — and only on the accept side, which is
    /// why this is one callback fired from two places rather than an `NSDragOperation`
    /// the caller re-derives.
    var onTargeted: ((Bool) -> Void)?

    /// Decided once per drag in `draggingEntered`.
    ///
    /// Not a micro-optimisation: `draggingUpdated` fires on every mouse move, and a
    /// single one-second hover was measured at ~78 calls. Re-reading the pasteboard
    /// there — as the old notch view did — meant ~150 `readObjects` calls to answer a
    /// question whose answer cannot change while the same drag is over the same view.
    private var pending: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    /// Required, not optional: this app is `.accessory` and so never the active app,
    /// and AppKit swallows the first click into an inactive window to activate it.
    /// See `docs/macos-app-plan.md` §C3.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Every image file the drag is offering.
    ///
    /// `urlReadingContentsConformToTypes` does the image check, matching how the
    /// clipboard path already reads file URLs. It filters on the file's real type,
    /// so folders (`public.folder`) drop out here rather than needing a separate
    /// directory test.
    private func imageURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true,
                      .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        ) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let images = imageURLs(sender)
        // The count rule lives in `ImageDrop.accepted`, where a test can reach it.
        pending = ImageDrop.accepted(imageURLs: images)
        if pending != nil {
            onTargeted?(true)
            return .copy
        }

        // Refusal is silent to the user on purpose — the system's own snap-back says
        // "not for me" better than any message could. But silent *and* untraced is
        // the failure `uploadClipboard` already learned to log: with no line here,
        // "拖上去没反应" leaves nothing in the log to diagnose. Reachable only once
        // per hover, so it cannot flood, and the extra pasteboard read happens only
        // on the refusal path.
        let all = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Diagnostics.log("drop refused: \(all.count) file(s) of which \(images.count) image(s)"
                        + " -> " + all.map(\.lastPathComponent).joined(separator: ", "))
        // Returning no operation is the whole of the rejection: `onTargeted` is
        // never fired, so the icon does not change, and the system plays its own
        // snap-back. Only the accept path above touches the icon.
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Nothing but the cached answer, deliberately — see `pending`. The icon was
        // already set on entry, and setting it here would be ~78 redundant writes per
        // second of hover to say what it already says.
        pending == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrag()
    }

    /// Clears state for drags that finish without exiting the view.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrag()
    }

    /// Every way out of a drag, in one place.
    ///
    /// There are four — exited, ended, dropped, and dropped-but-refused — and the
    /// hover icon has to come back on all of them; a drag left holding the icon is
    /// worse than never highlighting it, because nothing else will put it back. So
    /// the two facts a drag leaves behind get cleared together rather than one per
    /// callback.
    ///
    /// Fired unconditionally, without first checking whether a hover was ever
    /// accepted: the only caller assigns it into `StatusIcon.dropTargeted`, which
    /// redraws on change, so `false` → `false` costs nothing — and a condition here
    /// would be one more thing to keep in step with `pending`.
    private func endDrag() {
        pending = nil
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Re-read rather than trusting `pending`. This is the callback that commits
        // to an upload, and the pasteboard at drop time is what should decide it;
        // the cache exists for the hot path above, not for this one.
        let url = ImageDrop.accepted(imageURLs: imageURLs(sender))
        // Before `onDrop`, not after: this is the one exit path that hands control to
        // someone else, and that someone sets the icon too — `upload` reports
        // `.started` synchronously. Restoring first means the two arrive in the order
        // they happened (hover off, then uploading) instead of the upload's glyph
        // being followed by the drag's restore. Either order in fact lands on the same
        // icon, because ``StatusIcon`` keeps the hover and the state in separate
        // fields — but only one of them reads as what occurred.
        endDrag()
        guard let url else { return false }
        onDrop?(url)
        return true
    }
}
