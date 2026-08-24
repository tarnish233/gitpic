import Foundation
import ServiceManagement

/// Whether GitPic starts itself when the user logs in — as the settings window needs
/// it, and with the third state a boolean cannot hold.
///
/// **Why this is not a setting of GitPic's own.** `SMAppService.mainApp` writes the
/// same per-user registration that 系统设置 ▸ 通用 ▸ 登录项与扩展 lists, and the user can
/// switch it off *there*. A private flag beside it would be a second record of one
/// fact whose other copy is editable behind the app's back — the argument
/// ``FinderServiceStatus`` makes at length for the Finder switch, and the reason
/// neither switch caches anything past the window opening.
///
/// **Why three cases and not `Bool`.** `SMAppService.Status` has a value that "on/off"
/// cannot express and that users reach by ordinary means: `.requiresApproval`, a
/// registration macOS has accepted and is withholding until the user approves it in
/// System Settings. It is what GitPic gets after being switched off *there*. A plain
/// boolean has to call it either 开 — a switch that promises a launch that will not
/// happen — or 关, whose "turn it on" is a no-op, because registering again returns the
/// same status. ``blocked`` says the true thing instead, and ``caption`` sends the user
/// where the decision actually lives.
///
/// **Why `.notFound` is folded into ``off`` rather than kept as an error.** The header
/// calls `.notFound` an error ("no such service could be found"), and a first draft of
/// this type had a fourth case for it saying so. Measured, that would have been wrong
/// for every new user: a bundle the background-task-management store has never seen
/// reports `.notFound`, and only a bundle that was registered *and then unregistered*
/// reports `.notRegistered`. So `.notFound` is the state of a fresh install — the
/// commonest state there is — and an error banner pointing at System Settings is the
/// last thing it should draw. Both mean "not registered; the switch beside you is what
/// changes that", so both are ``off``.
///
/// In `GitPicCore` for the reason ``StatusIcon`` is: `GitPicApp` is an executable
/// target no test can import, so the mapping and the copy would otherwise be
/// unpinnable. `SMAppService.Status` values are nameable without touching the system,
/// so ``init(status:)`` is testable in every case — see `LaunchAtLoginStateTests`.
public enum LaunchAtLoginState: Equatable, Sendable {
    /// Not registered: `.notRegistered`, `.notFound`, or anything unrecognised.
    /// The switch beside this state is what changes it.
    case off
    /// Registered and eligible to run: the app will start at the next login.
    case on
    /// Registered, and withheld by macOS until the user approves it in System Settings.
    case blocked

    /// Deployment target is macOS 14 (see `Package.swift`) and `SMAppService` is
    /// macOS 13+, so no availability guard is needed anywhere in this file.
    ///
    /// `@unknown default` rather than a total switch: `SMAppService.Status` is an
    /// imported `NS_ENUM` and a later macOS may add a case. It lands on ``off``, which
    /// is the safe default because it is the one state whose remedy is a switch this app
    /// owns — flip it, and either the status agrees afterwards or
    /// ``failureMessage(request:state:reason:)`` reports what the system said. A state
    /// that instead sent the user to System Settings on a guess would be unfixable from
    /// here.
    public init(status: SMAppService.Status) {
        switch status {
        case .enabled:           self = .on
        case .requiresApproval:  self = .blocked
        case .notRegistered:     self = .off
        case .notFound:          self = .off
        @unknown default:        self = .off
        }
    }

    /// Where the switch sits.
    ///
    /// **``blocked`` reads as on, and that is the load-bearing line in this file.** The
    /// registration exists; what is missing is the user's approval. Reading it as off
    /// would put the switch one click from an action that cannot change it — macOS
    /// answers a second `register()` with the same `.requiresApproval` — so the switch
    /// would bounce back to 关 and read as broken. On, plus ``caption`` naming System
    /// Settings, is the honest arrangement: GitPic has done its half, and the sentence
    /// under the switch says who is holding the other half.
    public var isOn: Bool {
        switch self {
        case .on, .blocked:  true
        case .off:           false
        }
    }

    /// The line under the switch, for every state.
    ///
    /// Exhaustive rather than `Optional` with one entry: a state added later cannot
    /// compile without an answer here, which is the same trick ``StatusIcon/symbol``
    /// uses. `LaunchAtLoginStateTests` pins that none is empty, that no two read alike,
    /// and that ``blocked`` names 系统设置 — the copy is the only thing standing between
    /// a withheld registration and a switch that appears to work.
    public var caption: String {
        switch self {
        case .off:
            "登录后 GitPic 不会自动启动，需要自己打开。"
        case .on:
            "下次登录时 GitPic 会自动出现在菜单栏。"
        case .blocked:
            "已经登记，但被 macOS 拦住了：还需要在「系统设置 ▸ 通用 ▸ 登录项与扩展」里"
            + "允许 GitPic，否则登录后它不会启动。"
        }
    }

    /// Whether to offer the button that opens 登录项与扩展.
    ///
    /// Only ``blocked``, because that is the only state whose answer changes somewhere
    /// else. On ``off`` and ``on`` the switch beside it *is* the control, and a second
    /// way to do the same thing would be one more thing to read.
    public var needsSystemSettings: Bool {
        switch self {
        case .blocked:    true
        case .off, .on:   false
        }
    }

    /// Whether the state the system now reports is the one that was asked for.
    ///
    /// **This is what lets the thrown error stay out of the decision.** `SMAppService.h`
    /// says `register()` answers an already-registered app with
    /// `kSMErrorAlreadyRegistered` and `unregister()` an unregistered one with
    /// `kSMErrorJobNotFound` — but measured on macOS 26.5, *neither is thrown*: both
    /// redundant calls simply succeed. So the documented behaviour and the observed
    /// behaviour disagree, and a `catch` written against either one is a bet on which is
    /// true today. Deciding on a re-read status is right under both: a redundant call
    /// that throws and one that does not leave the same status behind.
    ///
    /// The same rule is why `wanted == true` is satisfied by ``blocked``: the
    /// registration landed, and the approval that is still missing is not something
    /// `register()` failed at — see ``isOn``.
    public func matches(request wanted: Bool) -> Bool { isOn == wanted }

    /// What to show when the request did not take, or `nil` when it did.
    ///
    /// `reason` is the system's own error text, passed in verbatim rather than
    /// paraphrased — the same call `ConfigTrouble` makes about the CLI's messages.
    /// It is appended, never substituted: an `NSError` from ServiceManagement is often
    /// no more specific than "Operation not permitted", so the sentence naming what
    /// was asked and what the system now reports has to carry the meaning on its own.
    public static func failureMessage(request wanted: Bool,
                                      state: LaunchAtLoginState,
                                      reason: String?) -> String? {
        guard !state.matches(request: wanted) else { return nil }
        let asked = wanted ? "开启" : "关闭"
        var text = "\(asked)开机自启动没有生效，系统现在报告的状态是「\(state.shortLabel)」。"
        if let reason, !reason.isEmpty { text += "系统给出的原因：\(reason)" }
        return text
    }

    /// A word for this state, for use inside a sentence.
    ///
    /// Separate from ``caption`` because that one is a whole sentence about what
    /// happens next; this is a noun to quote in ``failureMessage(request:state:reason:)``.
    public var shortLabel: String {
        switch self {
        case .off:      "未开启"
        case .on:       "已开启"
        case .blocked:  "等待系统设置里批准"
        }
    }

    /// The one ServiceManagement error worth explaining rather than merely quoting.
    ///
    /// `kSMErrorInvalidSignature` is 3 in the anonymous enum in `SMErrors.h`, and
    /// `SMAppService.h` says outright that "Apps that use SMAppService APIs must be code
    /// signed" and that `register()` answers an improperly signed bundle with this code.
    /// The system's own message for it says nothing about signing, so this is the one
    /// place a sentence of ours beats a quote.
    ///
    /// **Ad-hoc signing is not the cause, measured.** An earlier version of this hint
    /// blamed `build-app.sh`'s ad-hoc default; a probe bundle signed `codesign --sign -`
    /// registered, reported `.enabled`, and unregistered cleanly, so ad-hoc satisfies
    /// this API and a from-source build is not on the failing path. What is left for
    /// code 3 is a bundle with a broken or absent signature.
    ///
    /// **The domain is deliberately not asserted.** The symbol that names it,
    /// `SMAppServiceErrorDomain`, is macOS 15+ while this app targets 14, so matching
    /// it would mean either an availability dance or a hardcoded copy of the string.
    /// Matching the code alone is safe here *because this text is additive*: the caller
    /// always shows the system's own message too (see
    /// ``failureMessage(request:state:reason:)``), so a foreign error that happens to
    /// be code 3 gains a wrong sentence rather than losing the right one.
    public static func hint(forErrorCode code: Int) -> String? {
        code == 3
            ? "这通常是签名问题：macOS 只接受签名完整的 App 登记登录项，"
              + "请重新安装一份完整的 GitPic.app 再试。"
            : nil
    }
}
