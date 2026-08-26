import AppKit

/// The app's main menu, which exists for one reason: the standard shortcuts.
///
/// AppKit dispatches `⌘W`, `⌘Q`, `⌘M`, `⌘C`, `⌘V`, `⌘Z` … through the **main menu's**
/// key equivalents, not through the window. This app had no main menu at all — it is
/// `.accessory` and lives in the status bar, where a menu bar of its own is never
/// drawn — so inside the settings window every one of those keys did nothing:
/// `⌘W` would not close it, `⌘Q` would not quit, and with the caret in the Owner
/// field `⌘A ⌘C` left the clipboard untouched (measured, not assumed: focus really
/// was on the `AXTextField`). Text fields do not implement editing commands
/// themselves; the Edit menu is what sends `copy:`/`paste:`/`undo:` to the first
/// responder, so an app without one has text fields that cannot copy or paste.
///
/// Nothing here is a custom binding. Every item is a standard title, standard
/// selector and standard key equivalent, and each one is dispatched to whatever the
/// first responder happens to be — which is exactly what "leave it to the system"
/// means at this layer.
///
/// **This does not add global hotkeys.** A main-menu key equivalent fires only while
/// this app is frontmost, which for an `.accessory` app means only while a window of
/// its own is open. The status-bar menu still carries no shortcuts at all, for the
/// reason documented on ``AppDelegate/item(_:_:_:)``: those would look global and
/// would not be.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(editMenu())
        main.addItem(windowMenu())
        NSApp.mainMenu = main
    }

    /// AppKit takes the first menu as the app menu and substitutes the app's name for
    /// its title, so the title given here is never displayed.
    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        let delegate = NSApp.delegate

        let about = menu.addItem(withTitle: "关于 GitPic",
                                 action: #selector(AppDelegate.openAbout), keyEquivalent: "")
        about.target = delegate
        menu.addItem(.separator())
        // `⌘,` is honest here in a way it would not be in the status-bar menu: the
        // item is only reachable while this app is frontmost, which is precisely when
        // the shortcut works.
        let settings = menu.addItem(withTitle: "设置…",
                                    action: #selector(AppDelegate.openSettings),
                                    keyEquivalent: ",")
        settings.target = delegate
        menu.addItem(.separator())
        menu.addItem(withTitle: "隐藏 GitPic", action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "隐藏其他",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "全部显示",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        // No target, so this travels the responder chain to `NSApp`, which hands what it
        // cannot handle to its delegate. Not `NSApplication.terminate`: AppKit refuses to
        // terminate while a sheet is attached to any window — see ``Updater/quit(_:)``.
        menu.addItem(withTitle: "退出 GitPic", action: #selector(AppDelegate.quitByUser),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    /// The menu that makes the text fields work.
    ///
    /// `undo:` and `redo:` have no exposed selector constant — they are responder-chain
    /// messages, which is why they are spelled as strings here. The rest go through
    /// `NSText` purely to name the selector; the message lands on the first responder,
    /// whatever kind of view that is.
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")

        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "重做", action: Selector(("redo:")),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    /// 关闭 lives here rather than in a 文件 menu, because this app has no files: a
    /// 文件 menu holding nothing but 关闭 would be a menu invented for one item.
    /// System Settings resolves it the same way.
    ///
    /// `NSApp.windowsMenu` hands the rest to AppKit — the window list at the bottom
    /// and its housekeeping are the system's, not ours.
    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")

        menu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
