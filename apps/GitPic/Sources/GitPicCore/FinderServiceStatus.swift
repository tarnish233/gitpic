import Foundation

/// Reading and writing the on/off state macOS keeps for one Service menu item.
///
/// **Why this is stored outside GitPic's own settings.** The right-click item is
/// declared statically in `Info.plist`; Launch Services reads it from the bundle, so
/// nothing the app does at runtime can take the item out of Finder's menu. What
/// *can* is the same switch 系统设置 ▸ 键盘 ▸ 键盘快捷键 ▸ 服务 writes: a per-service
/// entry under `NSServicesStatus` in the `pbs` preference domain. Writing there is
/// what makes GitPic's own switch remove the menu item rather than merely decline to
/// act on it.
///
/// Keeping GitPic's switch on that same entry — instead of a private flag beside it —
/// is deliberate. There would otherwise be two records of one fact, and the user can
/// change the other one: turning the service off in System Settings would leave
/// GitPic's switch reading 开.
///
/// **Measured on macOS 26.5.** `NSServicesStatus` exists in the `pbs` domain (it
/// reads back as an empty dictionary on a machine where nothing has been toggled),
/// and an entry written in this shape survives a `pbs -flush` unchanged.
public enum FinderServiceStatus {

    /// The service's `NSMessage` — the selector name without its `:userData:error:`
    /// tail — and the menu title the bundle declares for it.
    ///
    /// In `GitPicCore` for the same reason ``StatusIcon``'s symbol names are: `GitPicApp`
    /// is an executable target no test can import, so a constant left there has to be
    /// re-typed in the test, and a test asserting against its own copy of the string
    /// cannot notice the rename it was written to warn about. ``statusKey`` is built from
    /// these two, and the whole point of the test is that renaming either one orphans a
    /// user's off-state.
    ///
    /// `defaultMenuItemTitle` is the *fallback*, not the authority: the running bundle's
    /// `NSServices` array is, because that is the title `pbs` files the state under. See
    /// `FinderService.menuItemTitle`.
    public static let message = "uploadImagesToGitPic"
    public static let defaultMenuItemTitle = "GitPic 上传至图床"

    /// The two checkboxes System Settings shows for one service. GitPic drives both
    /// from one switch: a user turning off 右键上传 means the item, not one of its
    /// two placements.
    static let contextMenuKey = "enabled_context_menu"
    static let servicesMenuKey = "enabled_services_menu"

    /// How `pbs` names one service's entry: the provider, the menu title, the message.
    ///
    /// Spaced hyphens, and the title is the one from `NSMenuItem.default` — so
    /// renaming the menu item orphans the old entry and the service comes back on.
    /// That is the system's own behaviour, not something this can paper over; it is
    /// the reason ``ServiceProvider/message`` and the plist title are treated as a
    /// contract rather than as strings.
    public static func statusKey(bundleID: String, menuItem: String,
                                 message: String) -> String {
        "\(bundleID) - \(menuItem) - \(message)"
    }

    /// Whether the service is on, according to `status`.
    ///
    /// **No entry means on**, which is why this cannot be a plain dictionary lookup:
    /// a fresh install has never been toggled, and its item is in the menu. Reading
    /// absence as off would show 关 next to a working right-click.
    public static func isEnabled(_ status: [String: Any]?, key: String) -> Bool {
        guard let entry = status?[key] as? [String: Any],
              let raw = entry[contextMenuKey],
              let flag = boolValue(raw) else { return true }
        return flag
    }

    /// One plist value, three ways of spelling a boolean.
    ///
    /// Not defensive programming for its own sake — measured against a real
    /// `pbs.plist`. `defaults write pbs NSServicesStatus -dict-add … '{
    /// enabled_context_menu = 0; }'` stores that `0` as an **`NSTaggedPointerString`**,
    /// because old-style plist text has no number syntax at all. An `as? NSNumber`
    /// reader returns nil for it and falls through to "no entry means on", so the
    /// switch reads 开 for a service that is off. Booleans are what this app writes and
    /// what System Settings most likely writes; integers are what a plist editor
    /// produces. Whoever wrote the entry, it has to be read.
    static func boolValue(_ raw: Any) -> Bool? {
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        // `NSString.boolValue`, so "0"/"1"/"true"/"NO" all land where they should.
        case let s as String: return NSString(string: s).boolValue
        default: return nil
        }
    }

    /// `status` with this service set to `enabled`, leaving every other service's
    /// entry exactly as it was.
    ///
    /// Merged rather than replaced: this dictionary is shared with every other app on
    /// the machine that has a service, and writing back only our own key would switch
    /// theirs back on.
    public static func applying(enabled: Bool, to status: [String: Any]?,
                                key: String) -> [String: Any] {
        var next = status ?? [:]
        next[key] = [contextMenuKey: enabled, servicesMenuKey: enabled]
        return next
    }
}
