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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        // An .accessory app cannot own a focused, title-barred window, so become
        // .regular for as long as this window is open.
        AppActivationPolicy.enter()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        Task { await AppModel.shared.reload() }
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.leave()
        Self.shared = nil
    }
}
