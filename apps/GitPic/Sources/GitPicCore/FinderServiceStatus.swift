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

    /// The modern key, and the mode within it this switch is about.
    ///
    /// `enabled_context_menu` is not the current spelling: AppKit's own diagnostic
    /// strings call it "the older 'enabled_context_menu' key" (found verbatim in the
    /// macOS 26.5 dyld shared cache, next to `presentation_modes`, `ContextMenu`,
    /// `ServicesMenu`, `TouchBar` and `initWithLegacyServicePresentationMode:`). A reader
    /// that consults only the legacy key reports 开 for a service switched off in System
    /// Settings, whenever System Settings wrote the modern key alone.
    ///
    /// **The value shape here is inferred, not observed.** Nothing on the build machine
    /// has ever been toggled — `NSServicesStatus` reads back as an empty dictionary — so
    /// there was no real entry to inspect, and the mode names come from AppKit's symbols
    /// rather than from a plist. That is exactly why ``modeEnabled(in:)`` accepts both
    /// plausible encodings and why nothing here ever *invents* this key: see ``applying``.
    static let presentationModesKey = "presentation_modes"
    static let contextMenuMode = "ContextMenu"

    /// The legacy keys. Still read by AppKit — the diagnostic above exists precisely to
    /// announce that it honoured one — and still the only shape this project has watched
    /// work end to end, which is why a write always includes them.
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
    ///
    /// Modern key first, legacy second, on by default. Anything unrecognisable at either
    /// step falls through to the next rather than deciding — being unable to read the
    /// entry is not evidence the user switched anything off.
    public static func isEnabled(_ status: [String: Any]?, key: String) -> Bool {
        guard let entry = status?[key] as? [String: Any] else { return true }
        if let modes = entry[presentationModesKey], let on = modeEnabled(in: modes) {
            return on
        }
        if let raw = entry[contextMenuKey], let on = boolValue(raw) { return on }
        return true
    }

    /// Read the context-menu mode out of a `presentation_modes` value.
    ///
    /// Two encodings are accepted because the real one has not been seen (see
    /// ``presentationModesKey``): a dictionary of mode name → boolean, and a list of the
    /// enabled mode names. `nil` means "this value did not say", which leaves the legacy
    /// key to answer instead of guessing.
    ///
    /// Mode names are matched case-insensitively: `ContextMenu` is AppKit's spelling, and
    /// a plist written by something else is not worth failing over.
    static func modeEnabled(in value: Any) -> Bool? {
        if let dict = value as? [String: Any] {
            let hit = dict.first { $0.key.caseInsensitiveCompare(contextMenuMode) == .orderedSame }
            return hit.flatMap { boolValue($0.value) }
        }
        if let names = value as? [String] {
            return names.contains { $0.caseInsensitiveCompare(contextMenuMode) == .orderedSame }
        }
        return nil
    }

    /// One plist value, three ways of spelling a boolean.
    ///
    /// Not defensive programming for its own sake — measured against a real
    /// `pbs.plist`. `defaults write pbs NSServicesStatus -dict-add … '{
    /// enabled_context_menu = 0; }'` stores that `0` as an **`NSTaggedPointerString`**,
    /// because old-style plist text has no number syntax at all. An `as? NSNumber`
    /// reader returns nil for it and falls through to "no entry means on", so the
    /// switch reads 开 for a service that is off.
    ///
    /// Strings are matched against a known set rather than handed to
    /// `NSString.boolValue`, which never returns nil: it maps `""`, `"maybe"` and `"off"`
    /// all to `false`, so an unreadable value would *disable* the feature — hiding
    /// nothing from Finder's menu while refusing every right-click, which is the one
    /// outcome the fail-open default exists to prevent.
    static func boolValue(_ raw: Any) -> Bool? {
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "1", "true", "yes", "y": return true
            case "0", "false", "no", "n": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// `status` with this service set to `enabled`, leaving everything else as it was.
    ///
    /// Merged at **both** levels, and the inner one is the half that was wrong. Replacing
    /// the whole sub-dictionary discards every sibling key the system keeps in it — most
    /// visibly `key_equivalent`, the Services keyboard shortcut the user assigned (this
    /// machine's `pbs.plist` carries `ServicesShortcutsPresent`, so those exist in
    /// practice), and any `presentation_modes` for placements this switch is not about.
    /// Turning the right-click item off and on again would silently take a shortcut away.
    ///
    /// The legacy pair is always written, because that is the path watched working end to
    /// end. `presentation_modes` is *updated where it already exists* and never created:
    /// its encoding has not been observed (see ``presentationModesKey``), and inventing a
    /// structure the system will parse is a worse bet than leaving it absent and letting
    /// the legacy keys — which AppKit still honours — carry the answer.
    public static func applying(enabled: Bool, to status: [String: Any]?,
                                key: String) -> [String: Any] {
        var next = status ?? [:]
        var entry = (next[key] as? [String: Any]) ?? [:]
        entry[contextMenuKey] = enabled
        entry[servicesMenuKey] = enabled
        if let modes = entry[presentationModesKey] {
            entry[presentationModesKey] = applyingMode(enabled: enabled, to: modes)
        }
        next[key] = entry
        return next
    }

    /// Set the context-menu mode inside an existing `presentation_modes` value, keeping
    /// its shape and its other modes.
    ///
    /// Returns the value unchanged when it is in neither recognised shape: a mangled
    /// `presentation_modes` is not something to "fix" by overwriting.
    static func applyingMode(enabled: Bool, to value: Any) -> Any {
        if var dict = value as? [String: Any] {
            let existing = dict.keys.first {
                $0.caseInsensitiveCompare(contextMenuMode) == .orderedSame
            }
            dict[existing ?? contextMenuMode] = enabled
            return dict
        }
        if let names = value as? [String] {
            var kept = names.filter {
                $0.caseInsensitiveCompare(contextMenuMode) != .orderedSame
            }
            if enabled { kept.append(contextMenuMode) }
            return kept
        }
        return value
    }
}
