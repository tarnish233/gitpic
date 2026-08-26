import Foundation
import Testing

/// Opening the settings window has to *show* it, on the second click as much as the first.
///
/// A source scan, for the same reason ``QuitPathContractTests`` is one: the wiring lives in
/// `GitPicApp`, an `executableTarget` tests cannot import, and what goes wrong is AppKit's
/// answer to a real window in a real app that is not frontmost. `swift test` reaches neither.
///
/// The bug this holds closed: `AppActivationPolicy.enter()` used to raise `.regular` *and*
/// activate, and `SettingsWindowController.showWindow` calls it behind a
/// `holdingActivation` guard so the reference count cannot leak. Raising the policy twice is
/// the leak worth guarding; activating twice is free — so the guard was skipping the one
/// call that had to happen every time. With the window already open behind another app,
/// every route in that can be taken while the app is in the background (the status menu's
/// 打开设置, 连通性测试, 检查更新/有新版本…) ordered the window to the front of GitPic's own
/// windows and stopped there, which is nothing the user can see.
///
/// Measured, one variable apart: the same accessibility-tree script driven against the
/// shipped 0.20.5 and against this tree, window already open behind Finder, five trials
/// each. 0/5 came forward, then 5/5. Every earlier phase of that script — cold open, close,
/// reopen, close, reopen, switch away — behaved identically on both, so the difference is
/// this and nothing else. The grep below cannot see any of that; what it can see is the
/// shape that caused it, an activation reachable only from inside the guard.
@Suite("Window focus contract")
struct WindowFocusContractTests {

    /// The property: `showWindow` activates whether or not the guard runs.
    @Test("reopening the window brings the app forward, not just the window")
    func reopeningComesForward() throws {
        let controller = try QuitPathContractTests.read("SettingsWindowController.swift")
        let show = try #require(
            QuitPathContractTests.body(of: "override func showWindow(_ sender: Any?)",
                                       in: controller),
            "cannot find showWindow's body")

        let outside = try #require(
            Self.withoutTheActivationGuard(show),
            """
            cannot find the `if !holdingActivation { … }` block in showWindow. If the guard \
            was renamed, update this test; if it was removed, check that the policy is still \
            taken exactly once per window — closing the window has to return the app to the \
            status bar, and a leaked reference leaves a Dock icon behind.
            """)
        #expect(outside.contains("AppActivationPolicy.comeForward()"),
                """
                showWindow does not come to the front outside the holdingActivation guard, so \
                a second 打开设置 with the window already open does nothing visible: \
                makeKeyAndOrderFront only orders the window within this app's own windows, and \
                an app that is not active puts none of them in front of the active app's. \
                Body outside the guard was: \(outside)
                """)
    }

    /// The other half: taking the policy reference must not be what activates, or the guard
    /// silently owns the decision again and the test above passes over a body that has
    /// `comeForward()` in it for show.
    @Test("taking the .regular reference is not what activates")
    func enterDoesNotActivate() throws {
        let model = try QuitPathContractTests.read("AppModel.swift")

        let enter = try #require(QuitPathContractTests.body(of: "static func enter()", in: model),
                                 "cannot find AppActivationPolicy.enter's body")
        let code = Self.withoutComments(enter)
        #expect(!code.contains("activate") && !code.contains("comeForward"),
                """
                AppActivationPolicy.enter() activates. It is reference-counted and called \
                behind a guard, so anything it does happens only on the first open — which is \
                exactly how coming to the front got lost. Keep it to the policy. Body was: \
                \(code)
                """)

        let forward = try #require(
            QuitPathContractTests.body(of: "static func comeForward()", in: model),
            "cannot find AppActivationPolicy.comeForward's body")
        #expect(Self.withoutComments(forward).contains("NSApp.activate"),
                """
                comeForward() does not activate anything, which makes every call to it a \
                no-op and the assertion above a decoration. Body was: \(forward)
                """)
    }

    /// `body` with the `if !holdingActivation { … }` block cut out, or `nil` if there is no
    /// such block to cut.
    ///
    /// **`nil` rather than the untouched body, and that is the whole design.** Strip nothing
    /// on a body whose only activation sits *inside* the guard — verbatim the bug — and the
    /// caller finds `comeForward()` and goes green. A helper that cannot find what it was
    /// asked to remove has to say so, not hand back something that looks like an answer.
    static func withoutTheActivationGuard(_ body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            !QuitPathContractTests.isComment($0)
                && $0.contains("holdingActivation")
                && $0.contains("if ")
        }) else { return nil }
        let indent = String(lines[start].prefix { $0 == " " })
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == indent + "}" })
        else { return nil }
        var kept = lines
        kept.removeSubrange(start...end)
        return kept.joined(separator: "\n")
    }

    /// Comment lines dropped. The explanations here name the very calls being asserted
    /// absent — `enter()`'s documentation says "pair it with `comeForward()`" — so a scan
    /// that counted comments would fail on a body that is correct.
    static func withoutComments(_ body: String) -> String {
        body.components(separatedBy: "\n")
            .filter { !QuitPathContractTests.isComment($0) }
            .joined(separator: "\n")
    }
}
