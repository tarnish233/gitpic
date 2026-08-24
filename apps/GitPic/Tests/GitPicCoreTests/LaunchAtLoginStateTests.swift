import Testing
import Foundation
import ServiceManagement
@testable import GitPicCore

/// The rule this suite exists for: **a switch that cannot express what the system
/// reports will lie.** `SMAppService.Status` has four values and a checkbox has two, and
/// the value that does not fit — `.requiresApproval`, a registration macOS is holding
/// until the user approves it — is the one a user reaches by switching GitPic off in
/// 系统设置. Folding it into either 开 or 关 produces a switch that either promises a
/// launch that will not happen or offers a fix that does nothing.
///
/// Statuses here are the framework's own cases, never `rawValue` literals: the point is
/// to pin *our* mapping, and a test that spelled the statuses as numbers would keep
/// passing through a reordering of Apple's enum while `LaunchAtLoginState` silently
/// started reading `.enabled` as off.
///
/// Not covered, because it cannot be: the `@unknown default` arm of ``init(status:)``.
/// `SMAppService.Status` is an imported `NS_ENUM`, so `init?(rawValue:)` answers `nil`
/// for any value not in the SDK and there is no way to hand it a future case.
@Suite("Launch at login")
struct LaunchAtLoginStateTests {

    @Test("each status maps to the state that describes it")
    func mapping() {
        #expect(LaunchAtLoginState(status: .enabled) == .on)
        #expect(LaunchAtLoginState(status: .requiresApproval) == .blocked)
        #expect(LaunchAtLoginState(status: .notRegistered) == .off)
    }

    /// Regression test for a state that would have been wrong for every new user.
    ///
    /// `SMAppService.h` calls `.notFound` an error ("no such service could be found"), and
    /// a first draft gave it its own case, an orange warning and a button to System
    /// Settings. Measured, that is the state of a **fresh install**: a probe bundle the
    /// background-task-management store had never seen reported `.notFound`, and only
    /// after a register/unregister cycle did it start reporting `.notRegistered`. So the
    /// commonest state of all would have opened 设置 ▸ 通用 on a warning about a broken
    /// registration that had simply never been made.
    @Test("a bundle the system has never registered is off, not broken")
    func notFoundIsOff() {
        #expect(LaunchAtLoginState(status: .notFound) == .off)
        #expect(!LaunchAtLoginState(status: .notFound).needsSystemSettings)
        #expect(LaunchAtLoginState(status: .notFound).caption
                == LaunchAtLoginState(status: .notRegistered).caption)
    }

    /// The load-bearing assertion of the whole feature.
    ///
    /// `.requiresApproval` means GitPic's registration is in place and macOS is withholding
    /// it. Reading that as off would put the switch one click from `register()`, which
    /// answers with the same status — so the switch would flip to 开, be re-read, and drop
    /// straight back to 关. On, plus a caption naming 系统设置, is the only arrangement that
    /// is both true and actionable.
    @Test("a withheld registration reads as on, not off")
    func blockedReadsAsOn() {
        #expect(LaunchAtLoginState.blocked.isOn)
        #expect(LaunchAtLoginState.on.isOn)
        #expect(!LaunchAtLoginState.off.isOn)
    }

    /// Why `register()`'s own error is never consulted to decide success.
    ///
    /// `SMAppService.h` documents `kSMErrorAlreadyRegistered` for a redundant `register()`
    /// and `kSMErrorJobNotFound` for a redundant `unregister()`; measured on macOS 26.5,
    /// neither is thrown and both calls simply succeed. Since the documentation and the
    /// system disagree, a `catch` written against either is a bet — while a re-read status
    /// is correct under both, because a redundant call leaves the same status behind
    /// whether or not it threw.
    @Test("the state the system reports is what decides whether a flip took")
    func matchesRequest() {
        #expect(LaunchAtLoginState.on.matches(request: true))
        #expect(LaunchAtLoginState.off.matches(request: false))
        #expect(!LaunchAtLoginState.on.matches(request: false))
        #expect(!LaunchAtLoginState.off.matches(request: true))
        // Asking for on and getting a withheld registration is not a failed request:
        // the registration landed. The caption carries the rest.
        #expect(LaunchAtLoginState.blocked.matches(request: true))
        #expect(!LaunchAtLoginState.blocked.matches(request: false))
    }

    @Test("a request that landed reports no failure")
    func noFailureWhenSatisfied() {
        #expect(LaunchAtLoginState.failureMessage(request: true, state: .on,
                                                  reason: nil) == nil)
        #expect(LaunchAtLoginState.failureMessage(request: false, state: .off,
                                                  reason: nil) == nil)
        // Even with an error in hand: `register()` reports `kSMErrorLaunchDeniedByUser`
        // for a service the user has revoked, and the status is then `.requiresApproval`.
        // The registration exists, so this is the approval caption's business, not a red
        // failure line — showing both would say the flip failed *and* that it is waiting
        // for approval.
        #expect(LaunchAtLoginState.failureMessage(request: true, state: .blocked,
                                                  reason: "denied by user") == nil)
    }

    @Test("a request that did not land says so, and quotes the system verbatim")
    func failureNamesStateAndReason() throws {
        let message = LaunchAtLoginState.failureMessage(
            request: true, state: .off, reason: "Operation not permitted")
        let text = try #require(message)
        // The state is named, because the system's own text is usually too generic to
        // identify what happened.
        #expect(text.contains(LaunchAtLoginState.off.shortLabel))
        // And the system's words survive into it unparaphrased.
        #expect(text.contains("Operation not permitted"))
    }

    /// An empty `reason` must not produce a dangling "原因：" with nothing after it.
    @Test("a failure with nothing to quote is still a complete sentence")
    func failureWithoutReason() throws {
        for reason in [nil, ""] as [String?] {
            let text = try #require(LaunchAtLoginState.failureMessage(
                request: false, state: .on, reason: reason))
            #expect(!text.contains("原因"))
            #expect(text.contains(LaunchAtLoginState.on.shortLabel))
        }
    }

    /// Every state explains itself, and the one that is fixed elsewhere says where.
    ///
    /// The captions are the entire difference between a withheld registration and a
    /// switch that appears to work, so "someone left one empty" has to be a test failure
    /// rather than a blank line in the window.
    @Test("every state has copy, and only the withheld one points at 系统设置")
    func captions() {
        let all: [LaunchAtLoginState] = [.off, .on, .blocked]
        for state in all {
            #expect(!state.caption.isEmpty, "\(state) has no caption")
            #expect(!state.shortLabel.isEmpty, "\(state) has no short label")
        }
        // No two states may read the same, or a change of state is one the user cannot
        // see — the complaint `StatusIconTests.distinct` was written for.
        #expect(Set(all.map(\.caption)).count == all.count)
        #expect(Set(all.map(\.shortLabel)).count == all.count)

        #expect(LaunchAtLoginState.blocked.needsSystemSettings)
        #expect(LaunchAtLoginState.blocked.caption.contains("系统设置"),
                "blocked is only fixable in System Settings and must say so")
        // The switch itself is the control in the other two; a button beside it would be
        // a second way to do the same thing. `off` in particular is where a fresh install
        // sits — see `notFoundIsOff`.
        #expect(!LaunchAtLoginState.on.needsSystemSettings)
        #expect(!LaunchAtLoginState.off.needsSystemSettings)
    }

    /// `kSMErrorInvalidSignature` is 3 in `SMErrors.h`'s anonymous enum, and the system's
    /// own message for it does not mention signing — which is the only reason a sentence
    /// of ours is attached to any error code at all.
    ///
    /// Pinned against the literal because the number is the contract: there is no Swift
    /// symbol for it, and a hint attached to the wrong code would explain a signature
    /// problem to someone who does not have one.
    @Test("the signature failure gets an explanation; other codes get none")
    func signatureHint() throws {
        let hint = try #require(LaunchAtLoginState.hint(forErrorCode: 3))
        #expect(hint.contains("签名"))
        // The neighbours in that enum — internalFailure, authorizationFailure,
        // jobNotFound, launchDeniedByUser, alreadyRegistered — carry no hint, so the
        // system's own message is shown alone rather than under a guess.
        for code in [0, 1, 2, 4, 5, 6, 10, 11] {
            #expect(LaunchAtLoginState.hint(forErrorCode: code) == nil,
                    "code \(code) should not borrow the signature hint")
        }
    }
}
