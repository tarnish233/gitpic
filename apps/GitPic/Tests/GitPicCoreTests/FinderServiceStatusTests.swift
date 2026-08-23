import Testing
import Foundation
@testable import GitPicCore

@Suite("Finder service switch")
struct FinderServiceStatusTests {

    /// Built from the shipped constants, not from copies of them. A test that re-typed
    /// the title and the message would assert against itself, and `titleIsPartOfTheKey`
    /// below — the one written to warn that a rename orphans a user's off-state — could
    /// not notice the rename it exists for.
    private let key = FinderServiceStatus.statusKey(
        bundleID: "dev.gitpic.app",
        menuItem: FinderServiceStatus.defaultMenuItemTitle,
        message: FinderServiceStatus.message)

    @Test("the key is the shape pbs files a service under")
    func keyShape() {
        #expect(key == "dev.gitpic.app - GitPic 上传至图床 - uploadImagesToGitPic")
    }

    /// The four raw strings this file has to spell the way the OS does.
    ///
    /// Pinned against literals for the same reason ``keyShape()`` is. Every other test
    /// in this suite builds its fixtures *from* these constants, so all of them stay
    /// green through a typo in any one — and these are exactly the four values
    /// `FinderServiceStatus` marks as inferred rather than observed, which is where a
    /// typo is most likely and least visible. Rename `presentationModesKey` to the
    /// singular and the whole suite still passes, while `isEnabled` stops finding the
    /// modern key on a real machine and reports 开 for a service the user switched off:
    /// the precise regression the modern-key read was added for.
    @Test("the pbs wire keys are the strings the OS writes, not what we call them")
    func wireKeys() {
        #expect(FinderServiceStatus.presentationModesKey == "presentation_modes")
        #expect(FinderServiceStatus.contextMenuMode == "ContextMenu")
        #expect(FinderServiceStatus.contextMenuKey == "enabled_context_menu")
        #expect(FinderServiceStatus.servicesMenuKey == "enabled_services_menu")
    }

    /// The case a fresh install is in. Reading absence as off would show 关 next to a
    /// right-click item that is right there in the menu.
    @Test("a service nothing has toggled reads as on")
    func absentMeansEnabled() {
        #expect(FinderServiceStatus.isEnabled(nil, key: key))
        #expect(FinderServiceStatus.isEnabled([:], key: key))
        #expect(FinderServiceStatus.isEnabled(["someone.else - X - y": [:]], key: key))
    }

    /// Regression test for a switch that read 开 next to a service that was off.
    ///
    /// A real `pbs.plist` can hold this flag as a boolean, an integer, **or a string** —
    /// `defaults write … '{enabled_context_menu = 0;}'` stores the `0` as a string,
    /// because old-style plist text has no number syntax. An `as? NSNumber`-only
    /// reader saw nil, fell through to "absent means on", and reported the wrong state.
    @Test("booleans, integers and strings are all understood")
    func acceptsEveryPlistSpelling() {
        for off in [false, 0, "0", "NO", "false"] as [Any] {
            let status = [key: [FinderServiceStatus.contextMenuKey: off]]
            #expect(FinderServiceStatus.isEnabled(status, key: key) == false,
                    "\(type(of: off)) \(off) should read as off")
        }
        for on in [true, 1, "1", "YES", "true"] as [Any] {
            let status = [key: [FinderServiceStatus.contextMenuKey: on]]
            #expect(FinderServiceStatus.isEnabled(status, key: key) == true,
                    "\(type(of: on)) \(on) should read as on")
        }
    }

    /// A value of a type or spelling that is not a boolean is not evidence the service is
    /// off, so it falls back to on — the same answer as no entry at all.
    ///
    /// `""` is the one that mattered: `NSString.boolValue` maps it (and "maybe", and
    /// "off") to `false`, so the previous reader *disabled* the feature on an
    /// unreadable value — hiding nothing from Finder's menu while refusing every
    /// right-click, which is what fail-open exists to prevent.
    @Test("an uninterpretable value falls back to on")
    func ignoresNonsense() {
        for junk in [["what"], "", "maybe", "off"] as [Any] {
            let status: [String: Any] = [key: [FinderServiceStatus.contextMenuKey: junk]]
            #expect(FinderServiceStatus.isEnabled(status, key: key),
                    "\(junk) should not be read as a decision")
        }
    }

    // MARK: - The modern key

    /// `enabled_context_menu` is what AppKit's own diagnostics call "the older" key.
    /// A reader that consults only it reports 开 for a service System Settings switched
    /// off using `presentation_modes` alone.
    @Test("presentation_modes decides, in either encoding")
    func readsPresentationModes() {
        let asDict: [String: Any] = [key: [
            FinderServiceStatus.presentationModesKey: [
                FinderServiceStatus.contextMenuMode: false, "ServicesMenu": true,
            ],
        ]]
        #expect(FinderServiceStatus.isEnabled(asDict, key: key) == false)

        let asList: [String: Any] = [key: [
            FinderServiceStatus.presentationModesKey: ["ServicesMenu", "TouchBar"],
        ]]
        #expect(FinderServiceStatus.isEnabled(asList, key: key) == false)

        let listWithIt: [String: Any] = [key: [
            FinderServiceStatus.presentationModesKey: [
                FinderServiceStatus.contextMenuMode, "ServicesMenu",
            ],
        ]]
        #expect(FinderServiceStatus.isEnabled(listWithIt, key: key))
    }

    @Test("the modern key wins over a stale legacy one")
    func modernKeyWins() {
        let status: [String: Any] = [key: [
            FinderServiceStatus.presentationModesKey: [
                FinderServiceStatus.contextMenuMode: false,
            ],
            FinderServiceStatus.contextMenuKey: true,
        ]]
        #expect(FinderServiceStatus.isEnabled(status, key: key) == false)
    }

    /// An unreadable `presentation_modes` must not swallow the answer the legacy key
    /// still carries.
    @Test("an unreadable modern key falls through to the legacy one")
    func fallsThroughToLegacy() {
        let status: [String: Any] = [key: [
            FinderServiceStatus.presentationModesKey: 42,
            FinderServiceStatus.contextMenuKey: false,
        ]]
        #expect(FinderServiceStatus.isEnabled(status, key: key) == false)
    }

    /// The dictionary is shared with every other app on the machine that ships a
    /// service. Writing back only our own key would switch all of theirs on.
    @Test("writing our entry leaves every other service alone")
    func preservesOtherServices() {
        let others: [String: Any] = [
            "com.example.other - Do Thing - doThing": [
                FinderServiceStatus.contextMenuKey: 0,
                FinderServiceStatus.servicesMenuKey: 0,
            ],
        ]
        let next = FinderServiceStatus.applying(enabled: false, to: others, key: key)
        #expect(next.count == 2)
        #expect(FinderServiceStatus.isEnabled(next, key: key) == false)
        #expect(FinderServiceStatus.isEnabled(next,
                                              key: "com.example.other - Do Thing - doThing")
                == false)
    }

    /// The inner merge. Replacing the sub-dictionary threw away `key_equivalent` — the
    /// Services keyboard shortcut the user assigned — so turning the item off and on
    /// again quietly took their shortcut away.
    @Test("writing keeps the sibling keys inside our own entry")
    func preservesSiblingKeys() {
        let existing: [String: Any] = [key: [
            "key_equivalent": "$@g",
            FinderServiceStatus.contextMenuKey: true,
        ]]
        let next = FinderServiceStatus.applying(enabled: false, to: existing, key: key)
        let entry = next[key] as? [String: Any]
        #expect(entry?["key_equivalent"] as? String == "$@g")
        #expect(FinderServiceStatus.isEnabled(next, key: key) == false)
        // Both legacy keys are written, which is the path watched working end to end.
        #expect(entry?[FinderServiceStatus.contextMenuKey] as? Bool == false)
        #expect(entry?[FinderServiceStatus.servicesMenuKey] as? Bool == false)
    }

    /// `presentation_modes` is updated in place, keeping its shape and its other modes —
    /// and is never created from scratch, because its real encoding has not been observed.
    @Test("an existing presentation_modes is updated, not replaced or invented")
    func updatesPresentationModesInPlace() {
        let dictShape: [String: Any] = [key: [
            FinderServiceStatus.presentationModesKey: [
                FinderServiceStatus.contextMenuMode: true, "ServicesMenu": true,
            ],
        ]]
        let offDict = FinderServiceStatus.applying(enabled: false, to: dictShape, key: key)
        let modes = (offDict[key] as? [String: Any])?[
            FinderServiceStatus.presentationModesKey] as? [String: Any]
        #expect(modes?[FinderServiceStatus.contextMenuMode] as? Bool == false)
        // The placement this switch is not about survives.
        #expect(modes?["ServicesMenu"] as? Bool == true)
        #expect(FinderServiceStatus.isEnabled(offDict, key: key) == false)

        // Nothing to update: the key must not appear.
        let fresh = FinderServiceStatus.applying(enabled: false, to: nil, key: key)
        let entry = fresh[key] as? [String: Any]
        #expect(entry?[FinderServiceStatus.presentationModesKey] == nil)
        #expect(FinderServiceStatus.isEnabled(fresh, key: key) == false)
    }

    @Test("a written state reads back as itself, both ways")
    func roundTrips() {
        let off = FinderServiceStatus.applying(enabled: false, to: nil, key: key)
        #expect(FinderServiceStatus.isEnabled(off, key: key) == false)
        let backOn = FinderServiceStatus.applying(enabled: true, to: off, key: key)
        #expect(FinderServiceStatus.isEnabled(backOn, key: key))
    }

    /// Not a wish, a warning: `pbs` files the state under the menu *title*, so
    /// renaming the item orphans the entry and the service silently comes back on.
    @Test("a renamed menu item is a different key")
    func titleIsPartOfTheKey() {
        let renamed = FinderServiceStatus.statusKey(
            bundleID: "dev.gitpic.app",
            menuItem: FinderServiceStatus.defaultMenuItemTitle + "（改过的）",
            message: FinderServiceStatus.message)
        #expect(renamed != key)
        let off = FinderServiceStatus.applying(enabled: false, to: nil, key: key)
        #expect(FinderServiceStatus.isEnabled(off, key: renamed))
    }
}
