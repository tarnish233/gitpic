import AppKit
import GitPicCore

/// GitPic's half of the Finder right-click switch.
///
/// Reads and writes the one place macOS keeps that state — `NSServicesStatus` in the
/// `pbs` preference domain — so the switch in 设置 and the checkbox in 系统设置 ▸ 键盘
/// ▸ 键盘快捷键 ▸ 服务 are the same switch. ``FinderServiceStatus`` holds the argument for
/// why the state has to live there, and the shape of the entry.
///
/// What this file owns on top of that: GitPic is not sandboxed, so
/// `~/Library/Preferences/pbs.plist` is an ordinary user-owned file it may write. And
/// `kCFPreferencesAnyHost`, not `CurrentHost` — `pbs.plist` is the any-host file, and
/// writing the per-host one would be ignored.
@MainActor
enum FinderService {

    /// The menu title `pbs` files this service's state under.
    ///
    /// **Read out of the running bundle, not hardcoded.** `pbs` keys the entry by title,
    /// so the authority has to be the same plist Launch Services read — anything else is
    /// a second copy that can disagree, and disagreeing means writing an entry for a
    /// service that does not exist, i.e. a switch that appears to work and does nothing.
    ///
    /// This replaces a constant whose comment justified itself by saying the array could
    /// not be read back reliably because "the system localises the title on the way
    /// through". That reason was self-defeating: if it were true, a key built from the
    /// hardcoded raw string would *already* be the wrong key — the exact failure the
    /// constant claimed to prevent. (It is also moot here. The bundle declares
    /// `CFBundleLocalizations` `[zh-Hans]` and ships no `.lproj` or `InfoPlist.strings`,
    /// and `infoDictionary` is the raw plist regardless; `localizedInfoDictionary` is
    /// where overrides would appear.)
    ///
    /// The entry is found by `NSMessage`, which *is* legitimately a literal — it is an
    /// `@objc` selector name. `FinderServiceStatus.defaultMenuItemTitle` is the fallback
    /// for a plist that cannot be read at all, which would mean a broken bundle.
    static let menuItemTitle: String = {
        let services = Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]]
        let entry = services?.first {
            $0["NSMessage"] as? String == FinderServiceStatus.message
        }
        guard let title = (entry?["NSMenuItem"] as? [String: Any])?["default"] as? String,
              !title.isEmpty else {
            Diagnostics.log("finder service: no NSServices entry for"
                            + " \(FinderServiceStatus.message); falling back to the"
                            + " built-in title. The 设置 switch may not match the menu.")
            return FinderServiceStatus.defaultMenuItemTitle
        }
        return title
    }()

    private static let domain = "pbs" as CFString
    private static let statusKeyName = "NSServicesStatus" as CFString

    /// Built once: neither the bundle id nor the title can change while the app runs.
    private static let statusKey = FinderServiceStatus.statusKey(
        bundleID: Bundle.main.bundleIdentifier ?? "dev.gitpic.app",
        menuItem: menuItemTitle,
        message: FinderServiceStatus.message)

    /// Whether the right-click item is on right now.
    ///
    /// Asked fresh every time rather than cached, and the synchronise is why: System
    /// Settings can change this behind the app's back, and `cfprefsd` hands each
    /// process its own snapshot until told otherwise.
    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        return FinderServiceStatus.isEnabled(read(), key: statusKey)
    }

    private static func read() -> [String: Any]? {
        CFPreferencesCopyValue(statusKeyName, domain,
                               kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost) as? [String: Any]
    }

    /// Turn the right-click item on or off, and return **the state the system reports
    /// afterwards** — which is not necessarily the one asked for.
    ///
    /// Returning the observed state rather than a `landed` flag is what lets the caller
    /// assign and compare from one read. Writing another domain can fail, and a switch
    /// that slides over and changes nothing is worse than one that refuses: the user
    /// would go to Finder, still find the item, and have no reason to suspect the switch.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        CFPreferencesAppSynchronize(domain)
        let next = FinderServiceStatus.applying(enabled: enabled, to: read(),
                                                key: statusKey)
        CFPreferencesSetValue(statusKeyName, next as CFDictionary, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let flushed = CFPreferencesAppSynchronize(domain)
        // Tell the services machinery to re-read the state it just changed. Without
        // this the menu keeps its old shape until something else invalidates the
        // cache; with it, the next context menu is already right.
        NSUpdateDynamicServices()
        // Read back rather than trust the write: this is a different domain, and the
        // only claim worth making to the user is one that has been confirmed. The flush
        // above is this process's own write, so no second synchronise is needed.
        let observed = FinderServiceStatus.isEnabled(read(), key: statusKey)
        Diagnostics.log("finder service: set enabled=\(enabled)"
                        + " flushed=\(flushed) observed=\(observed)")
        return observed
    }
}
