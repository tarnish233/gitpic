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

    /// Turn the right-click item on or off.
    ///
    /// **Returns nothing, because nothing here can be verified.** This used to read the
    /// value back and hand the caller a `landed` flag, which was a tautology: the
    /// read-back hits the same in-process CFPreferences cache the write just populated, so
    /// it echoed the written value whatever happened underneath. Measured with `chflags
    /// uchg` on `pbs.plist`: `CFPreferencesAppSynchronize` still returned `true`, the
    /// in-process read showed the new value, and `NSDictionary(contentsOfFile:)` showed the
    /// old one — so neither the flush result nor the read-back was evidence of anything.
    /// Reading the file instead does not work either: on a healthy write cfprefsd has
    /// usually not flushed yet, so it would report failure for writes that were fine.
    ///
    /// So the write is best-effort and says so. What covers the rare real failure — a
    /// locked, MDM-managed or root-owned `pbs.plist` — is the switch's caption pointing at
    /// 系统设置, rather than a reassuring dialog this code cannot honestly produce.
    static func setEnabled(_ enabled: Bool) {
        CFPreferencesAppSynchronize(domain)
        let next = FinderServiceStatus.applying(enabled: enabled, to: read(),
                                                key: statusKey)
        CFPreferencesSetValue(statusKeyName, next as CFDictionary, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let flushed = CFPreferencesAppSynchronize(domain)
        // Tell the services machinery to re-read the definitions it caches. This does
        // *not* rewrite the menu: the menu is assembled in the requesting process
        // (Finder), from that process's own preferences snapshot — which is why
        // `isEnabled` above has to synchronise for itself. So a menu already on screen,
        // or a Finder that has not refreshed its snapshot, can still show the item.
        NSUpdateDynamicServices()
        Diagnostics.log("finder service: set enabled=\(enabled) flushed=\(flushed)"
                        + " (not verifiable in-process — see setEnabled)")
    }
}
