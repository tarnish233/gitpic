import AppKit
import SwiftUI

/// The main window, created as an `NSWindow` rather than a SwiftUI `Window`
/// scene: `.fullSizeContentView` has to be in the style mask at creation time for
/// macOS 26 to render the liquid-glass chrome, and a SwiftUI scene does not
/// expose it.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: MainWindowController?

    static func show(tab: MainTab? = nil) {
        if let tab { MainNavigation.shared.selectedTab = tab }
        if shared == nil { shared = MainWindowController() }
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 760, height: 560)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        window.title = "GitPic"
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("GitPicMainWindow")
        window.minSize = NSSize(width: 680, height: 480)
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: MainWindowView())
        // Open showing the form, not editing it.
        //
        // AppKit hands initial focus to the first view in the key-view loop when a
        // window is first shown, and here that is the Owner field — so the window
        // came up with a caret in it and the value selected, one keystroke away from
        // replacing a working image-host owner with whatever was typed next.
        //
        // Set after `contentViewController`, because that is what creates the
        // `contentView` this points at.
        //
        // **Not sufficient on its own** — measured, not assumed. `initialFirstResponder`
        // is the documented way to decline initial focus, but `NSView` does not accept
        // first responder by default and `NSHostingView` does not override that, so
        // AppKit reads this as a view that declines and moves on to *the next valid key
        // view*: the Owner field, the very one being declined. The invariant only looked
        // like it held because the pane it protects renders no text field at all while
        // the config cannot be read — which was this machine's state in every version
        // that shipped it. `showWindow` does the real work.
        window.initialFirstResponder = window.contentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One `enter()` for the life of this window. Calling `showWindow` again
    /// while it is already on screen (or miniaturised) used to increment depth
    /// without a matching `leave`, so closing the window left the app `.regular`
    /// with a Dock icon.
    private var holdingActivation = false

    override func showWindow(_ sender: Any?) {
        // An .accessory app cannot own a focused, title-barred window, so become
        // .regular for as long as this window is open.
        if !holdingActivation {
            AppActivationPolicy.enter()
            holdingActivation = true
        }
        super.showWindow(sender)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        // Decline focus for real: `nil` makes the *window* first responder, which is
        // the one answer AppKit does not resolve into "then the next text field".
        window?.makeFirstResponder(nil)
        Task { await AppModel.shared.reload() }
    }

    func windowWillClose(_ notification: Notification) {
        if holdingActivation {
            AppActivationPolicy.leave()
            holdingActivation = false
        }
        Self.shared = nil
    }
}
