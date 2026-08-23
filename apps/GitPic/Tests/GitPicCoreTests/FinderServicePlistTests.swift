import Testing
import Foundation
@testable import GitPicCore

/// The half of the `NSServices` contract that no other test can see.
///
/// `FinderServiceStatus.message` and ``FinderServiceStatus/defaultMenuItemTitle`` are
/// Swift constants that have to equal `NSMessage` and `NSMenuItem.default` in the
/// bundle's `Info.plist` (written by `scripts/build-app.sh`). Drift between the two
/// sides is silent in the worst way: the menu item still appears, still highlights, and
/// does nothing — and `FinderService.menuItemTitle`, which finds its entry *by*
/// `NSMessage`, then falls back and builds a `pbs` key for a service that does not
/// exist, so the 设置 switch looks like it works and changes nothing. Until this test
/// the only detection was a `Diagnostics.log` line nobody reads on a healthy machine.
///
/// `FinderServiceStatusTests` cannot cover this: it asserts the Swift constants against
/// Swift, so it stays green through exactly the drift that matters.
///
/// Reads the built bundle rather than the script, so what is asserted is what ships.
@Suite("Finder service plist contract")
struct FinderServicePlistTests {

    /// Located from `#filePath`, not the working directory. `swift test` is run both
    /// from the repository root (`--package-path apps/GitPic`) and from inside the
    /// package, and a path that guessed wrong would leave this suite silently skipped
    /// rather than failing — the one outcome a tripwire must not have.
    static var infoPlist: [String: Any]? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("dist-app/GitPic.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    /// Skipped when there is no bundle — `swift test` alone does not build one, and a
    /// missing `dist-app` is not a drifted plist. Everything past that point fails
    /// rather than skips: the entry is looked up the same way the app looks it up, so a
    /// renamed `NSMessage` cannot make this suite quietly pass by finding nothing.
    @Test("the built bundle declares the message and title the Swift side assumes",
          .enabled(if: FinderServicePlistTests.infoPlist != nil))
    func plistMatchesConstants() throws {
        let plist = try #require(Self.infoPlist)
        let services = try #require(plist["NSServices"] as? [[String: Any]],
                                    "the built bundle declares no NSServices at all")
        let entry = try #require(
            services.first { $0["NSMessage"] as? String == FinderServiceStatus.message },
            """
            no NSServices entry with NSMessage == \(FinderServiceStatus.message); \
            FinderService.menuItemTitle would fall back and key the wrong service
            """)
        let title = (entry["NSMenuItem"] as? [String: Any])?["default"] as? String
        #expect(title == FinderServiceStatus.defaultMenuItemTitle)
        // Without this key the item is absent from Finder's context menu entirely, while
        // registration, the services cache and `NSPerformService` all still work — which
        // is how its omission survived a full round of verification once already.
        let context = entry["NSRequiredContext"] as? [String: Any]
        #expect(context?["NSTextContent"] as? String == "FilePath")
    }
}
