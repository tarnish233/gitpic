import AppKit
import GitPicCore
import ServiceManagement

/// GitPic's half of the 开机自启动 switch.
///
/// Reads and writes the one place macOS keeps that state — the per-user login-item
/// registration behind `SMAppService.mainApp` — so the switch in 设置 and the entry in
/// 系统设置 ▸ 通用 ▸ 登录项与扩展 are the same switch. ``LaunchAtLoginState`` holds the
/// argument for why the state has to live there rather than in GitPic's config, and why
/// three of `SMAppService.Status`'s four values collapse into two.
///
/// **How this differs from ``FinderService``, on purpose.** That one writes a preference
/// domain it cannot read back — an in-process read hits the cache the write just
/// populated — so it returns nothing and says so. This one is the opposite: `status` is
/// a genuine cross-process read, so a flip *can* be verified, and nothing here assumes
/// it worked. Every mutation is followed by a fresh ``state`` read in `AppModel`, and
/// that read — not the absence of a thrown error — is what the switch shows. See
/// ``LaunchAtLoginState/matches(request:)`` for why that ordering matters more than it
/// looks like it should: the errors the header documents for a redundant call are not
/// the ones this machine throws.
///
/// **What this file does not do:** register a separate helper. `SMAppService.mainApp`
/// launches *this* bundle, which is the whole ask for a menu-bar app — a
/// `Contents/Library/LoginItems` helper would be a second executable to sign, embed and
/// keep at the same version, to accomplish what one property already does.
///
/// **The registration is per bundle path**, which is worth knowing when a build is moved:
/// the store records the URL the app was registered from (visible in `sfltool dumpbtm`),
/// so registering a copy in `dist-app/` and later installing to `/Applications` leaves
/// the first record behind, disabled, pointing at wherever it was. Nothing here can tidy
/// that up — there is no per-item removal API — and `sfltool resetbtm` is not a
/// substitute, because it resets *every* login item on the machine.
@MainActor
enum LaunchAtLogin {

    /// What the system reports right now.
    ///
    /// Asked fresh every time rather than cached, for the reason `FinderService.isEnabled`
    /// is: System Settings can change this behind the app's back, so a value held since
    /// launch would show 开 for a registration the user revoked an hour ago — and
    /// flipping a stale switch writes the wrong value back.
    ///
    /// **Not free, measured.** The read is an XPC round trip to the
    /// background-task-management service: 3–6 ms warm, ~12 ms on a process's first call.
    /// Small enough to ask on demand when a window is being put on screen, big enough to
    /// keep off the launch path — see `AppModel.launchAtLogin` for the seeding that does
    /// that, and `SettingsWindowView.refreshing` for why it still needs no spinner.
    static var state: LaunchAtLoginState {
        LaunchAtLoginState(status: SMAppService.mainApp.status)
    }

    /// Register or unregister the app as a login item.
    ///
    /// Throws whatever ServiceManagement threw, unfiltered. Filtering the two "already in
    /// that state" errors out here was the first shape of this and it was the wrong place
    /// for it twice over: the caller has to re-read the status anyway, and — measured on
    /// macOS 26.5 — neither error is actually thrown, so the filter was dead code written
    /// against the header rather than against the system.
    ///
    /// Synchronous, on the main actor, like the Finder switch. `unregister()` also has an
    /// async form; it is not used, because what it waits for is "the running process has
    /// been killed" — which for `mainApp` is *this* process, and the docs say the app keeps
    /// running and is merely unregistered. There is nothing to wait for.
    static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // The raw status, not the mapped state: `LaunchAtLoginState` folds
            // `.notFound` into `.off` because the two are the same thing to the user, and
            // the log is the one place that distinction is still worth having — it is how
            // "never registered" and "registered once, then removed" can be told apart in
            // a bug report.
            Diagnostics.log("launch at login: set enabled=\(enabled),"
                            + " status now \(rawStatusName)")
        } catch {
            // Logged here as well as reported to the user, because the settings window is
            // usually shut a moment later and `~/Library/Logs/GitPic.log` is then the only
            // trace — the argument `AppModel.notify` makes about outcomes generally.
            let ns = error as NSError
            Diagnostics.log("launch at login: set enabled=\(enabled) failed —"
                            + " \(ns.domain) \(ns.code): \(ns.localizedDescription);"
                            + " status now \(rawStatusName)")
            throw error
        }
    }

    /// The status under its own name, for the log only.
    ///
    /// Hand-written rather than `String(describing:)`, which prints an imported `NS_ENUM`
    /// as its integer and would put a bare `3` in the log next to the error's own `code`,
    /// where the two would be easy to mistake for each other.
    private static var rawStatusName: String {
        switch SMAppService.mainApp.status {
        case .notRegistered:     "notRegistered"
        case .enabled:           "enabled"
        case .requiresApproval:  "requiresApproval"
        case .notFound:          "notFound"
        @unknown default:        "unknown"
        }
    }

    /// Open 系统设置 ▸ 通用 ▸ 登录项与扩展.
    ///
    /// The framework's own call rather than an `x-apple.systempreferences:` URL: the pane
    /// identifiers moved in Ventura and again after it, and this is the one route Apple
    /// maintains. Nothing to report — it takes no completion handler and returns nothing,
    /// so a failure to open is silent by construction.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
