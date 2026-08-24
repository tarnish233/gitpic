import AppKit
import SwiftUI

/// The settings window, created as an `NSWindow` rather than a SwiftUI `Window`
/// scene: `.fullSizeContentView` has to be in the style mask at creation time for
/// macOS 26 to render the liquid-glass chrome, and a SwiftUI scene does not
/// expose it.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show(tab: SettingsTab? = nil) {
        if let tab { SettingsNavigation.shared.selectedTab = tab }
        prewarm()
        shared?.showWindow(nil)
    }

    /// Build the window without showing it.
    ///
    /// This is where the cost of opening the window went. Measured on this machine:
    /// `NSHostingController(rootView: SettingsWindowView())` is ~150ms of main-thread
    /// work (~340ms the first time, before SwiftUI is warm) and `showWindow` another
    /// ~50ms, and **every** open used to pay all of it, because `windowWillClose`
    /// released the controller. Building it once, at launch, where no click is waiting
    /// on it, is what makes 打开设置 feel like opening a window rather than starting
    /// one.
    ///
    /// Safe before `gitpic` has been located: the panes render their "still looking"
    /// state, nothing is on screen to see it, and `showWindow` reloads anyway.
    static func prewarm() {
        if shared == nil { shared = SettingsWindowController() }
    }

    /// Whether the settings window is on screen right now.
    ///
    /// `shared` being non-nil says nothing about that: ``prewarm()`` builds the controller and
    /// its hosting view at launch, long before anything is shown, and `windowWillClose`
    /// deliberately keeps the instance alive so that reopening is not another ~200 ms. The
    /// window's own visibility is the only question that matches what the user can see, which
    /// is what ``AppModel/presentUpdateSheet()`` needs: a sheet raised on a window that is not
    /// on screen is a sheet nobody can dismiss.
    static var isOnScreen: Bool { shared?.window?.isVisible ?? false }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 760, height: 560)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        window.title = "设置"
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        // The old spelling on purpose: this is a defaults key ("NSWindow Frame
        // GitPicMainWindow"), not a name anyone reads. Renaming it to match the
        // type would forget the size and position of every window already out
        // there, which is a real cost for zero benefit.
        window.setFrameAutosaveName("GitPicMainWindow")
        window.minSize = NSSize(width: 680, height: 480)
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsWindowView())
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
        // 通用's two switches mirror system state, and 系统设置 can change either behind
        // the app's back — so both are re-read every time this window is put on screen.
        // `GeneralPane`'s `.onAppear` is not enough and was measured not to be: `orderOut`
        // emits no `onDisappear`, so neither `makeKeyAndOrderFront` nor a
        // close-then-`showWindow` re-emits `onAppear`; the window survives closing
        // (see `windowWillClose`) and `prewarm()` fires `onAppear` for a pane that was
        // never shown. Without this a toggle could sit stale for the life of the
        // process — and flipping a stale switch writes the wrong value back.
        AppModel.shared.refreshFinderService()
        AppModel.shared.refreshLaunchAtLogin()
        // And the daily update check, for exactly the reason the paragraph above gives. This
        // was the missing half of it: `GeneralPane`'s `.task` fires once when the pane is
        // first mounted, so "checks again whenever the window is opened" — which is the
        // stated reason `GitPicApp` does not run a repeating timer — was not true of
        // anything. A Mac left logged in checked once, at launch.
        Task { await AppModel.shared.checkForUpdatesIfDue() }
    }

    /// Re-read the two system-state mirrors whenever the window is focused again.
    ///
    /// `showWindow` covers *opening*, and `GeneralPane`'s `.onAppear` covers the pane being
    /// mounted — but neither fires when a window already on screen is simply re-keyed, and
    /// this window can be: it holds `.regular` for as long as it is open, so it has a Dock
    /// icon and a 窗口 menu, and both of those route around `showWindow` entirely.
    ///
    /// The launch-at-login switch is the one that made this worth a delegate method. Leave the
    /// window open on 通用, revoke GitPic in 系统设置 ▸ 登录项与扩展, click back: the system now
    /// reports `.requiresApproval`, but the pane still held `.off`/`.on` — and because
    /// `needsSystemSettings` is false for the stale value, the 「打开「登录项与扩展」」 button
    /// that is the *only* remedy for that state was not drawn, under a caption asserting a
    /// launch that would not happen.
    func windowDidBecomeKey(_ notification: Notification) {
        AppModel.shared.refreshFinderService()
        AppModel.shared.refreshLaunchAtLogin()
    }

    /// Closing gives back the activation policy and spends the pane history — but
    /// keeps the window.
    ///
    /// It used to `Self.shared = nil` here, which meant the next open rebuilt the
    /// window and its whole SwiftUI tree from scratch: ~200ms of nothing, on every
    /// open, for a window whose contents are rebuilt from the config file anyway. The
    /// one thing that release did carry — a back/forward trail that starts over, the
    /// way System Settings does — is now said out loud in `endSession()` instead of
    /// being a side effect of destroying a view.
    func windowWillClose(_ notification: Notification) {
        if holdingActivation {
            AppActivationPolicy.leave()
            holdingActivation = false
        }
        // A login in flight is the one thing the surviving window cannot carry. Since
        // this stopped releasing the controller there is no `onDisappear` and no
        // `.task` to cancel, and `loginTask` hangs off the process-lifetime
        // `AppModel.shared` — so closing the window left `gitpic auth login` polling
        // GitHub every few seconds until the code expired a quarter of an hour later.
        // 取消 was the only thing that stopped it, while the changelog says closing the
        // window does too. A no-op when no login is running.
        AppModel.shared.cancelLogin()
        SettingsNavigation.shared.endSession()
    }
}
