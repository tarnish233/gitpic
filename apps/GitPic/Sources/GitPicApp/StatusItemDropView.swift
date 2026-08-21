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
final class StatusItemDropView: NSView {
    var onDrop: ((URL) -> Void)?

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
        if pending != nil { return .copy }

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
        // Returning no operation is the whole of the rejection: the icon does not
        // highlight and the system plays its own snap-back.
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pending == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pending = nil
    }

    /// Clears state for drags that finish without exiting the view.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        pending = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Re-read rather than trusting `pending`. This is the callback that commits
        // to an upload, and the pasteboard at drop time is what should decide it;
        // the cache exists for the hot path above, not for this one.
        let url = ImageDrop.accepted(imageURLs: imageURLs(sender))
        pending = nil
        guard let url else { return false }
        onDrop?(url)
        return true
    }
}
