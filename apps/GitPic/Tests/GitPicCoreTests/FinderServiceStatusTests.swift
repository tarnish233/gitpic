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

    /// The case a fresh install is in. Reading absence as off would show 关 next to a
    /// right-click item that is right there in the menu.
    @Test("a service nothing has toggled reads as on")
    func absentMeansEnabled() {
        #expect(FinderServiceStatus.isEnabled(nil, key: key))
        #expect(FinderServiceStatus.isEnabled([:], key: key))
        #expect(FinderServiceStatus.isEnabled(["someone.else - X - y": [:]], key: key))
    }

    @Test("an explicit off is read as off, and an explicit on as on")
    func readsExplicitState() {
        let off = [key: [FinderServiceStatus.contextMenuKey: 0,
                         FinderServiceStatus.servicesMenuKey: 0]]
        #expect(FinderServiceStatus.isEnabled(off, key: key) == false)
        let on = [key: [FinderServiceStatus.contextMenuKey: 1,
                        FinderServiceStatus.servicesMenuKey: 1]]
        #expect(FinderServiceStatus.isEnabled(on, key: key))
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

    /// A value of a type that is not a boolean in any spelling is not evidence the
    /// service is off, so it falls back to on — the same answer as no entry at all.
    @Test("an uninterpretable value falls back to on")
    func ignoresNonsense() {
        let status: [String: Any] = [key: [FinderServiceStatus.contextMenuKey: ["what"]]]
        #expect(FinderServiceStatus.isEnabled(status, key: key))
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
