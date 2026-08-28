import AppKit
import SwiftUI
import GitPicCore

/// Lets a menu-bar-only app show a real window with a normal title bar, then go
/// back to being invisible. Reference-counted because more than one window (or a
/// modal alert) can need `.regular` at the same time.
///
/// **Raising the policy and coming to the front are two acts, and separating them is the
/// whole point of this type's shape.** The policy is per *window*: taken when one opens,
/// given back when the last one closes, which is what returns the app to the status bar —
/// so it is counted. Coming to the front is per *click*: it has to happen every time,
/// because between two clicks the user can have gone somewhere else. They used to be one
/// call, which handed the reference count a decision it has no business making —
/// ``SettingsWindowController/showWindow(_:)`` carries what that cost.
@MainActor
enum AppActivationPolicy {
    private static var depth = 0

    /// Take a reference on `.regular`. Deliberately does **not** bring the app forward;
    /// pair it with ``comeForward()``.
    static func enter() {
        depth += 1
        NSApp.setActivationPolicy(.regular)
    }

    /// Put this app in front of whatever is active.
    ///
    /// One spelling of the call, in one place, because it is subtler than it looks: under
    /// cooperative activation a background app cannot pull itself past the active one
    /// unless something granted it activation rights. `AppDelegate.pickFiles` records what
    /// grants them here. `.regular` plus this is measured to work from a status-item click,
    /// which is the only way into this app.
    static func comeForward() {
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        depth = max(0, depth - 1)
        if depth == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Hands out monotonically increasing tickets to one install's progress callbacks.
///
/// The ticket is taken on the URLSession queue the callback arrives on, so it records the order
/// the *bytes* arrived in — which is the order the UI has to be told about, and the one thing the
/// `Task { @MainActor in … }` hop per callback does not promise. `AppModel.observeInstall` then
/// drops anything that arrives out of order, and drops everything once the install's gate has
/// been let go of.
///
/// `NSLock` over a counter, following `SelfUpdate`'s `DownloadDelegate`: the callbacks are not
/// `async`, so an actor cannot be used without hopping inside every one of them, which is the
/// hop being made ordering-independent in the first place. `Synchronization.Atomic` is macOS 15;
/// this package targets macOS 14 (`Package.swift`).
final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0

    /// The next ticket. Starts at 1, so 0 can mean "nothing seen yet".
    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }
}

/// Shared state for the window UI.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var runner: GitpicRunner?
    var tools: ToolPaths?

    /// How far tool discovery has got.
    ///
    /// `runner == nil` used to mean two different things — still probing, and
    /// probed and absent — and every surface assumed the second. `reload()` returned
    /// early without setting `loadFailed`, so the pane sat on "读取配置中…" with
    /// nothing to retry, and a picker or clipboard upload in the first seconds after
    /// launch reported "找不到 gitpic" for a binary that simply had not been located
    /// yet. The probe can shell out to a login shell, up to 8 s, so that window is
    /// wide enough to hit by hand.
    enum ToolState: Sendable, Equatable { case resolving, ready, missing }
    private(set) var toolState: ToolState = .resolving

    // MARK: - Agent skill

    /// Detected agent targets and the action the bundled skill would take at each.
    private(set) var skillTargets: [SkillTarget] = []
    private(set) var skillVersion: String?
    private(set) var skillTargetsLoaded = false
    private(set) var skillTargetsLoading = false
    private(set) var skillFailure: String?
    /// `agent:<name>` while that agent's installation is running.
    private(set) var skillInstallID: String?
    /// Prevents an older refresh from replacing a newer answer.
    private var skillTargetsGeneration = 0

    /// The config as last read from disk — the baseline a save diffs against.
    var savedConfig: GitpicConfig?
    /// The config as edited in the UI.
    var draft: GitpicConfig?
    var history: [HistoryRecord] = []

    /// Thumbnails for the history pane.
    ///
    /// One store for the whole process, not one per view: the settings window now
    /// survives being closed (see ``SettingsWindowController``), and even if it did
    /// not, the point of a memory cache is that reopening 历史 costs nothing. Its disk
    /// layer outlives the process anyway — see ``ThumbnailStore``.
    let thumbnails = ThumbnailStore()

    /// Which snippet form the next copy produces — syntax and address, chosen
    /// independently.
    ///
    /// Derived, not stored, and that is the whole design: both halves are config keys
    /// (`upload.format`, `upload.link_kind`), so the file is the single answer to
    /// "what will a copy produce" and every surface reads it. It used to be a `var`
    /// living only in memory, which meant two ways to be wrong — it reset to
    /// Markdown · CDN on every launch however the config was set, and the status-item
    /// menu's checkmarks could disagree with the window with nothing on screen
    /// explaining why.
    ///
    /// Falls back to Markdown · CDN only while there is no config to read — during
    /// tool discovery, or when the file cannot be parsed. That is what the CLI
    /// defaults to, so the fallback is not a guess.
    var linkForm: LinkForm {
        savedConfig.map(LinkForm.init(config:)) ?? LinkForm()
    }

    /// Called when something the status-item menu is built from has changed, so it can be
    /// redrawn.
    ///
    /// A callback rather than the menu observing the model: `rebuildMenu()` replaces
    /// `statusItem.menu` wholesale, which is `AppDelegate`'s business and must not
    /// happen from inside an `@Observable` read. Without it, changing the form in the
    /// window left the menu displaying the previous choice until the next upload
    /// rebuilt it — measured, and the reason this exists.
    ///
    /// Named `onConfigChange` while the config was the only thing the menu derived from.
    /// The update check is the second: the menu's last item becomes 「有新版本 x.y.z…」 when
    /// one is found, and a hook named after the config would have had to be called for
    /// something that is not a config change to keep that label honest.
    var onMenuNeedsRebuild: (() -> Void)?

    var busy = false
    var lastDoctor: DoctorReport?

    // MARK: - Credential

    /// Where the login stands. The type and the report-to-state rule both live in
    /// `GitPicCore`, where a test can reach them.
    private(set) var auth: AuthState = .unknown

    /// Repositories the credential can upload to, for the picker.
    private(set) var repos: [RepoCandidate] = []
    /// False when the CLI said its listing was truncated — the picker says so rather
    /// than letting a missing repository read as "you do not have one".
    private(set) var reposComplete = true
    /// How many the listing returned that cannot be pushed to.
    ///
    /// Filtered out of `repos`, because a target that cannot be written to is not a
    /// choice — but counted, because with no way left to type a repository by hand,
    /// "why isn't mine in the list" is the one question that could strand someone.
    private(set) var skippedRepos = 0
    private(set) var reposLoading = false
    private(set) var reposFailure: String?

    /// Branches on the *selected* repository, for the second picker.
    ///
    /// A separate listing rather than a field on `RepoCandidate` because `gitpic repos`
    /// would have to call GitHub once per repository to fill it — a dozen requests to
    /// answer a question about the one repository the user actually picked.
    private(set) var branches: [BranchCandidate] = []
    private(set) var branchesComplete = true
    private(set) var branchesLoading = false
    private(set) var branchesFailure: String?
    /// Which repository `branches` belongs to, so a stale answer for a repository the
    /// user has already moved away from is discarded instead of shown.
    private var branchesFor: String?
    /// Bumped by every `loadBranches`, so a request can tell whether it is still the
    /// newest one.
    ///
    /// The repository spec is not enough on its own: switching A → B → A gives two
    /// in-flight requests that both match the draft, and whichever finishes first would
    /// otherwise report "done loading" while the other is still running.
    private var branchesGeneration = 0
    /// The same, for the repository listing — see ``loadRepos()``.
    private var reposGeneration = 0

    /// The in-flight login, held so it can be cancelled.
    ///
    /// Cancelling the task tears down the `AsyncStream`, whose `onTermination`
    /// terminates the `gitpic` child — otherwise a login the user walked away from
    /// keeps polling GitHub until the code expires, fifteen minutes later.
    private var loginTask: Task<Void, Never>?
    /// Identifies the login allowed to write `auth` and to clear ``loginTask``.
    ///
    /// Cancellation releases the handle immediately so a new login can start. The old
    /// task still gets one turn to unwind its `AsyncStream`; without a generation check,
    /// its `defer` could then clear the *new* task's handle, making that login appear idle
    /// and leaving no task for 取消 or window close to stop — and a `.done` already in
    /// the pipe would still write a logged-in state over 「登录已取消」.
    private var loginGeneration = 0

    var loginInFlight: Bool { loginTask != nil }

    func refreshAuth() async {
        await refreshAuth(onlyIfLoginGeneration: nil)
    }

    /// Re-read `auth status`, and only write `auth` when this call still owns it.
    ///
    /// `expected` is the generation the caller captured. The stream can still yield
    /// a `.done` or `.failed` after 取消 — the child is killed, the event is already
    /// in the pipe — and without this check that event would write a logged-in or
    /// `.broken` state over 「登录已取消」, then `loadRepos` would refill a picker
    /// `logout` just cleared. `nil` means “the generation as of entry”: 再检查一次
    /// and `attach` pass that. `cancelLogin` / `logout` / `.done` pass the value
    /// they bumped or captured, so a newer login cannot be overwritten.
    private func refreshAuth(onlyIfLoginGeneration expected: Int?) async {
        guard let runner else {
            // Never leave `.unknown` standing on a *finished* discovery: the pane
            // renders it as a spinner, and with no runner there will never be an
            // answer. While discovery is still running, `attach` is what calls back.
            let generation = expected ?? loginGeneration
            if loginGeneration == generation, toolState == .missing {
                auth = .broken(detail: "找不到 gitpic，没法检查登录状态")
            }
            return
        }
        let generation = expected ?? loginGeneration
        if loginGeneration != generation { return }
        auth = .checking
        let next: AuthState
        do {
            next = try await runner.authStatus().state
        } catch let RunFailure.cli(_, error) {
            next = error.code == "CONFIG_MISSING"
                ? .loggedOut(detail: nil)
                : .broken(detail: "\(error.code)：\(error.message)")
        } catch {
            next = .broken(detail: "\(error)")
        }
        // The await above is the window: 取消 / logout bump the generation while
        // status is in flight, and a write here would still land.
        if loginGeneration != generation { return }
        auth = next
        if case .loggedIn = auth {
            await loadRepos()
            // `loadRepos` can return early because logout already bumped
            // `reposGeneration`. Without this check, `loadBranches` would then
            // bump `branchesGeneration` itself and refill the picker `clearBranches`
            // just emptied — the branches half of the hole `reposGeneration += 1`
            // was added to close.
            if loginGeneration != generation { return }
            // After the repositories, not concurrently: the branch listing is about
            // whichever repository the draft names, and on a fresh window that draft is
            // only readable once `reload` has landed.
            await loadBranches()
        }
    }

    /// Start a device-flow login and follow it to its outcome.
    ///
    /// Not `async`: the caller is a button, and this runs for as long as the user takes
    /// in the browser. The task is stored instead, which is also what makes 取消 and
    /// closing the window able to stop it.
    func beginLogin(scope: String? = nil) {
        guard let runner, loginTask == nil else { return }
        loginGeneration += 1
        let generation = loginGeneration
        auth = .checking
        reposFailure = nil
        loginTask = Task { @MainActor [weak self] in
            defer {
                if self?.loginGeneration == generation {
                    self?.loginTask = nil
                }
            }
            for await event in runner.loginEvents(scope: scope) {
                guard let self else { return }
                // Same generation the `defer` already consults. Without this, a `.done`
                // or `.failed` already in the pipe still writes `auth` after 取消.
                guard self.loginGeneration == generation else { return }
                switch event {
                case let .code(userCode, url, _):
                    self.auth = .awaitingCode(userCode: userCode, url: url)
                    // Opened once, here rather than by the CLI, so 打开浏览器 can offer
                    // it again without a second process.
                    NSWorkspace.shared.open(url)
                case let .done(login):
                    // Re-read rather than trusting the event: `auth status` is what
                    // every other surface shows, and one code path deciding what
                    // "logged in" looks like is one fewer way for the two to disagree.
                    _ = login
                    await self.refreshAuth(onlyIfLoginGeneration: generation)
                case let .failed(error):
                    self.auth = error.code == "CONFIG_MISSING"
                        ? .loggedOut(detail: error.message)
                        : .broken(detail: "\(error.code)：\(error.message)")
                }
            }
        }
    }

    /// Stop a login in progress. The code on screen becomes useless immediately, which
    /// is why the state goes back rather than staying on a code nobody is polling for.
    func cancelLogin() {
        // Nothing in flight is not a cancellation. The guard is here rather than at
        // the callers because `windowWillClose` now calls this on *every* close, and
        // without it an ordinary close would overwrite a perfectly good logged-in
        // state with 「登录已取消」.
        guard let task = loginTask else { return }
        // Invalidate the cancelled task's `defer` before releasing the handle. A new
        // login may start while the old stream is still unwinding.
        loginGeneration += 1
        let generation = loginGeneration
        task.cancel()
        loginTask = nil
        auth = .loggedOut(detail: "登录已取消")
        // Pass the generation just bumped. `refreshAuth()` with `nil` would write
        // whatever `auth status` returns even after a newer login has started —
        // `beginLogin` only requires `loginTask == nil`, which this already cleared.
        Task { await refreshAuth(onlyIfLoginGeneration: generation) }
    }

    func logout() async {
        guard let runner else { return }
        // Same invalidation as `cancelLogin`: logout releases the handle before the
        // cancelled stream is guaranteed to have finished unwinding.
        loginGeneration += 1
        let generation = loginGeneration
        loginTask?.cancel()
        loginTask = nil
        do {
            _ = try await runner.logout()
        } catch {
            // The file is gone or it is not; either way the state below is read back
            // from the CLI rather than assumed here.
            Diagnostics.log("logout failed: \(error)")
        }
        // Same invalidation `loadRepos` already applies to a stale answer: without
        // the bump, a listing that left before the file was gone would refill the
        // picker after this just cleared it.
        reposGeneration += 1
        repos = []
        reposFailure = nil
        clearBranches()
        await refreshAuth(onlyIfLoginGeneration: generation)
    }

    func loadRepos() async {
        guard let runner else { return }
        // The same generation guard `loadBranches` carries, and for the same reason.
        // Two of these can be in flight at once — `refreshAuth` calls it on every login
        // and 重新检查 calls it again — and without the guard an older answer landing last
        // would replace the newer list, while `reposLoading = false` from the older
        // request would report "done" with the newer one still running. It happened not
        // to bite only because `GitpicRunner.gate` serialises the invocations so the
        // newest finishes last: an invariant enforced two files away from the code
        // relying on it, which is not a guarantee this should be spending.
        reposGeneration += 1
        let generation = reposGeneration
        reposLoading = true
        reposFailure = nil
        defer { if generation == reposGeneration { reposLoading = false } }
        do {
            let report = try await runner.repos()
            guard generation == reposGeneration else { return }
            if let list = report.repos {
                // Only what can actually be uploaded to: the picker is now the only way
                // to set a target, so offering one that cannot work would be the
                // "accepted, then silently broken" shape this project refuses.
                skippedRepos = list.filter { !$0.canPush }.count
                repos = list.filter(\.canPush)
                reposComplete = report.complete ?? true
            } else {
                repos = []
                reposFailure = report.error.map { "\($0.code)：\($0.message)" }
            }
        } catch let RunFailure.cli(_, error) {
            guard generation == reposGeneration else { return }
            repos = []
            reposFailure = "\(error.code)：\(error.message)"
        } catch {
            guard generation == reposGeneration else { return }
            repos = []
            reposFailure = "\(error)"
        }
    }

    /// Load the branches of whichever repository the draft names.
    ///
    /// Driven off the draft rather than off a saved config, because the interesting
    /// moment is *after* picking a repository and *before* 保存 — that is when someone
    /// wants to see what else is in there.
    func loadBranches() async {
        guard let runner, let draft else { return }
        let spec = "\(draft.github.owner)/\(draft.github.repo)"
        guard !draft.github.owner.isEmpty, !draft.github.repo.isEmpty else {
            clearBranches()
            return
        }
        branchesGeneration += 1
        let generation = branchesGeneration
        branchesLoading = true
        branchesFailure = nil
        // Only the newest request may report that loading finished. Clearing the flag
        // unconditionally let an older request — one whose *result* is correctly
        // discarded below — still say "done" while the current one was mid-flight,
        // leaving the branch row with neither a spinner nor a list.
        defer { if generation == branchesGeneration { branchesLoading = false } }
        do {
            let report = try await runner.branches(repo: spec)
            // The user may have picked a different repository while this was in flight.
            // Landing the old answer would offer branches that belong to someone else's
            // repository — and the picker writes what it is given.
            guard generation == branchesGeneration else { return }
            if let list = report.branches {
                branches = list
                branchesComplete = report.complete ?? true
                branchesFor = spec
            } else {
                branches = []
                branchesFailure = report.error.map { "\($0.code)：\($0.message)" }
            }
        } catch let RunFailure.cli(_, error) {
            guard generation == branchesGeneration else { return }
            branches = []
            branchesFailure = "\(error.code)：\(error.message)"
        } catch {
            guard generation == branchesGeneration else { return }
            branches = []
            branchesFailure = "\(error)"
        }
    }

    private func clearBranches() {
        branches = []
        branchesComplete = true
        branchesFailure = nil
        branchesFor = nil
        // Invalidates anything in flight. `chooseRepo` calls this precisely because the
        // old repository's request is still running, and without the bump that request
        // would land its branches for a repository the user has already left.
        branchesGeneration += 1
    }

    /// Put a chosen branch into the draft — not onto disk, same as `chooseRepo`.
    func chooseBranch(_ branch: BranchCandidate) {
        guard var next = draft else { return }
        next.github.branch = branch.name
        draft = next
    }

    /// The branch the draft names, if it is one the listing knows.
    ///
    /// `nil` covers two states the picker has to render differently from a normal
    /// selection: a branch that was deleted on GitHub, and a listing not loaded yet.
    var selectedBranch: BranchCandidate? {
        guard let draft else { return nil }
        return branches.first { $0.name == draft.github.branch }
    }

    /// A repository with no commits: the listing succeeded and returned nothing.
    ///
    /// Distinct from "not loaded yet" and from "the listing failed", and it needs saying:
    /// the branch row silently stops being a picker, and the CLI does explain this case
    /// (`gitpic branches` says the first upload will create the ref) while the window
    /// used to say nothing at all.
    var repositoryHasNoBranches: Bool {
        branchesMatchDraft && branches.isEmpty && branchesFailure == nil
    }

    /// Whether `branches` describes the repository the draft currently names.
    ///
    /// The picker needs this to avoid offering the previous repository's branches for a
    /// second while a fresh listing is in flight. It compares the stored spec rather
    /// than a generation, because the question here is about the *data on hand*, not
    /// about which request is newest.
    var branchesMatchDraft: Bool {
        guard let draft else { return false }
        return branchesFor == "\(draft.github.owner)/\(draft.github.repo)"
    }

    /// Put a chosen repository into the draft — not onto disk.
    ///
    /// The draft stays the source of truth and 保存 stays the only thing that writes, so
    /// picking is undoable by 还原 like any other edit. It is now the *only* way the
    /// window sets a target: the three text fields are gone, and `gitpic config set` is
    /// what remains for a repository no listing can offer.
    func chooseRepo(_ repo: RepoCandidate) {
        guard var next = draft else { return }
        next.github.owner = repo.owner
        next.github.repo = repo.name
        // The default branch comes from GitHub, so picking a repo whose default is
        // `master` does not silently leave `main` behind for the upload to 404 on. It
        // is also a value the branch picker below is guaranteed to contain, which keeps
        // the two pickers consistent the instant the repository changes.
        next.github.branch = repo.defaultBranch
        draft = next
        // The old repository's branches are wrong the moment the repository changes, and
        // they must not linger as offerable choices while the new listing loads.
        clearBranches()
        Task { await loadBranches() }
    }

    /// The repository the draft currently names, if it is one the picker knows.
    var selectedRepo: RepoCandidate? {
        guard let draft else { return nil }
        return repos.first {
            $0.owner == draft.github.owner && $0.name == draft.github.repo
        }
    }

    /// Why the last history read failed, or `nil` if it did not.
    ///
    /// Its own field, next to `configFailure` rather than behind it: `gitpic list`
    /// never opens `config.toml`, and a `CONFIG_INVALID` file must not hide a list
    /// that actually loaded. A failed `list` leaves the previous array in
    /// `history`; this is what distinguishes that from 「还没有上传记录」 on a cold
    /// launch that could not read the file.
    private(set) var historyFailure: String?

    /// Why the last config read failed, or `nil` if it did not.
    ///
    /// Distinguishes "still loading" from "the last read failed" — the form must not
    /// sit on "读取配置中…" forever after a failure — and now also carries *what*
    /// failed. A bare `loadFailed` flag could only ever produce "读取配置失败。", and
    /// that sentence was the entire diagnosis offered for a config file whose
    /// problem the CLI had already named down to the offending key.
    private(set) var configFailure: ConfigFailure?

    /// Where the config file lives, as the CLI resolves it. Read on every reload,
    /// because it is what the repair actions in the window act on.
    private(set) var configPath: URL?

    /// Where ``rebuildConfig()`` last moved an unusable file, so the window can
    /// still point at it after the fact — the old values are in there, and a fresh
    /// config starts empty.
    private(set) var configBackup: URL?

    /// Why the last connectivity test failed. Kept beside `lastDoctor` rather than
    /// in one shared line: the failure belongs to the 连通性 section and nowhere
    /// else, and a failure there says nothing about the config read above it.
    private(set) var doctorFailure: String?

    /// Nested work (reload during save, doctor during reload) must not let the
    /// first `defer { busy = false }` clear the spinner of the one still running.
    private var inflight = 0

    var dirtyKeys: [ConfigKey] {
        guard let savedConfig, let draft else { return [] }
        return changedKeys(from: savedConfig, to: draft)
    }

    private init() {}

    /// Discovery finished and `gitpic` is here.
    ///
    /// Kicks the two reads that need it, rather than leaving them to whoever notices.
    /// Both `reload` and `refreshAuth` return early without a runner, and both are
    /// triggered from somewhere that asks exactly once — the settings window's first
    /// layout, which `SettingsWindowController.prewarm()` performs *during* discovery.
    /// So the window came up, asked while `runner` was still nil, got a silent no, and
    /// nothing ever asked again: an empty repository form and an 账号 section spinning
    /// on 检查登录状态 forever. The trigger has to be "the runner arrived", not "the
    /// view appeared".
    func attach(runner: GitpicRunner, tools: ToolPaths) {
        self.runner = runner
        self.tools = tools
        toolState = .ready
        // No `reload()` here. `resolveTools` *awaits* one ten lines after calling this,
        // and that is the one carrying the config-before-upload guarantee its comment
        // describes — so firing a second, un-awaited one here just ran the whole
        // sequence twice. Both observed `configPath == nil` before either set it, so a
        // cold-launch right-click upload waited behind a duplicate `config path`
        // (~90 ms of the ~120 ms reload), a duplicate `config get` and a duplicate
        // `list --limit 100`, all on the serial gate, all in front of an upload the
        // user is watching.
        Task { await self.refreshAuth() }
    }

    /// Discovery finished and `gitpic` is not there — distinct from `.resolving`,
    /// so the UI can tell "wait" from "install it".
    func toolsUnavailable() {
        runner = nil
        tools = nil
        toolState = .missing
        // `attach` calls back into `refreshAuth`, and this branch has to as well.
        // `refreshAuth`'s guard is written to turn a standing `.unknown` into
        // `.broken` — but only when it runs, and on this path nothing was going to
        // run it: `HostPane`'s `.task` fires once, during discovery, and returns
        // early while `toolState == .resolving`; re-opening the window does not
        // re-fire it, because the window is no longer rebuilt on open. So 账号 sat
        // on the 「检查登录状态…」 spinner for the life of the process, for a machine
        // where the answer was simply "there is no gitpic".
        Task { await self.refreshAuth() }
    }

    /// Re-read every detected skill target from the CLI.
    func loadSkillTargets() async {
        guard let runner else {
            if toolState == .missing {
                skillTargets = []
                skillTargetsLoaded = true
                skillFailure = "找不到 gitpic 可执行文件，请重新安装 GitPic。"
            }
            return
        }

        skillTargetsGeneration += 1
        let generation = skillTargetsGeneration
        skillTargetsLoading = true
        skillFailure = nil
        defer {
            if skillTargetsGeneration == generation {
                skillTargetsLoading = false
            }
        }

        do {
            let report = try await runner.skillTargets()
            guard skillTargetsGeneration == generation else { return }
            skillTargets = report.targets
            skillVersion = report.version
            skillTargetsLoaded = true
        } catch {
            guard skillTargetsGeneration == generation else { return }
            skillTargets = []
            skillTargetsLoaded = true
            skillFailure = Self.cliMessage(error)
            Diagnostics.log("skill targets failed: \(String(describing: error))")
        }
    }

    func installSkill(for agent: SkillAgent, force: Bool) async {
        await performSkillInstall(id: "agent:\(agent.rawValue)") { runner in
            try await runner.installSkill(for: agent, force: force)
        }
    }

    private func performSkillInstall(
        id: String,
        operation: (GitpicRunner) async throws -> SkillInstallEnvelope
    ) async {
        guard let runner, skillInstallID == nil else { return }
        skillInstallID = id
        skillFailure = nil
        defer { skillInstallID = nil }

        do {
            let report = try await operation(runner)
            skillVersion = report.version
            await loadSkillTargets()

            if report.ok == false {
                let message = report.error.map { "\($0.code)：\($0.message)" }
                    ?? "gitpic 返回了失败结果，但没有给出错误说明。"
                skillFailure = message
                let prefix = report.installed.isEmpty
                    ? "没有写入任何位置。"
                    : "已写入 \(report.installed.count) 个位置，但没有全部完成。"
                notify(title: "Skill 安装失败", body: "\(prefix) \(message)")
                return
            }

            let changed = report.installed.filter { $0.action != .unchanged }.count
            if changed == 0 {
                notify(title: "Skill 已是最新", body: "所有目标都已经是 v\(report.version) 的内容。")
            } else {
                notify(title: "Skill 安装完成",
                       body: "已在 \(changed) 个位置写入 gitpic skill v\(report.version)。")
            }
        } catch {
            let message = Self.cliMessage(error)
            skillFailure = message
            Diagnostics.log("skill install failed: \(String(describing: error))")
            notify(title: "Skill 安装失败", body: message)
        }
    }

    /// A `RunFailure` as a line the user can read.
    ///
    /// Named for what it does rather than for its first caller. It was `skillError` while
    /// the skill pane was the only thing that needed it; the update check needs exactly the
    /// same rendering, and a second copy of four lines whose whole point is *one* place
    /// deciding how a CLI failure reads would have been the wrong answer.
    ///
    /// The wording moved to ``RunFailure/message`` in `GitPicCore`, where it can be tested.
    /// This used to match only `.cli` and fall back to `String(describing:)`, which printed
    /// the enum at the user: `.spawnFailed` and `.undecodable` both reached the window as
    /// Swift syntax. The fallback that remains is for a genuinely foreign `Error`, which no
    /// current caller can produce.
    private static func cliMessage(_ error: Error) -> String {
        if let failure = error as? RunFailure { return failure.message }
        return String(describing: error)
    }

    // MARK: - The Finder right-click switch

    /// Whether the Finder right-click item is switched on.
    ///
    /// A mirror of system state, not a setting of our own: the truth is the `pbs` entry
    /// ``FinderService`` reads, and this exists only because `@Observable` cannot watch
    /// another process's preferences.
    ///
    /// Seeded with `true` rather than a real read, deliberately. `AppModel.shared` is
    /// first touched from `setUpStatusItem()`, so a `FinderService.isEnabled` default
    /// would put a cross-process preference read (measured 1.9 ms on a cold domain) on
    /// the launch path — to produce a value nothing reads until 设置 ▸ 通用 opens, which
    /// calls ``refreshFinderService()`` before showing it anyway. `true` is also the right
    /// placeholder: it is what the system reports for a service nobody has toggled.
    private(set) var finderServiceEnabled = true

    /// Re-read the switch from the system. Called whenever the settings window is
    /// about to show it — System Settings can change the same switch, so a value
    /// cached since launch would show 开 for an item the user removed an hour ago.
    func refreshFinderService() {
        finderServiceEnabled = FinderService.isEnabled
    }

    /// Flip the switch.
    ///
    /// Assigns what was asked for, because ``FinderService/setEnabled`` cannot report
    /// whether the write survived — see its comment for why the read-back it used to do
    /// was a tautology. The switch's caption names 系统设置 as the place to check, which
    /// is the honest substitute for a confirmation this code cannot produce.
    func setFinderServiceEnabled(_ enabled: Bool) {
        FinderService.setEnabled(enabled)
        finderServiceEnabled = enabled
    }

    // MARK: - The 开机自启动 switch

    /// What macOS reports about GitPic's login-item registration.
    ///
    /// A mirror of system state, like ``finderServiceEnabled`` and for the same reason:
    /// the truth is the registration ``LaunchAtLogin`` reads, and this exists only
    /// because `@Observable` cannot watch another process's state.
    ///
    /// Seeded with ``LaunchAtLoginState/off`` rather than a real read, on the same
    /// argument the Finder switch makes: `AppModel.shared` is first touched from
    /// `setUpStatusItem()`, and a default that called out to ServiceManagement would put
    /// an XPC round trip — measured ~12 ms on a process's first call — on the launch path,
    /// to produce a value nothing reads until 设置 ▸ 通用 opens, which refreshes it before
    /// showing it. `off` is also the right placeholder, being what the system reports for
    /// an app nobody has registered (`.notFound`, folded into `off` — see
    /// ``LaunchAtLoginState``).
    private(set) var launchAtLogin: LaunchAtLoginState = .off

    /// Why the last flip did not take, or `nil` when nothing is wrong.
    ///
    /// Distinct from ``LaunchAtLoginState/blocked``, which is not a failure: there the
    /// registration landed and macOS is waiting on the user. This is for a flip that did
    /// not happen at all — a bundle whose signature the system rejects being the
    /// realistic cause.
    private(set) var launchAtLoginFailure: String?

    /// The request ``launchAtLoginFailure`` is about, held only while it stands.
    ///
    /// Without it, ``refreshLaunchAtLogin()`` has to choose between two wrong things:
    /// clear the message on every read — and 设置 ▸ 通用 re-reads on `.onAppear`, so
    /// switching panes and back would erase a diagnosis the user had not finished
    /// reading — or never clear it, and leave a failure sitting under a switch that has
    /// since started agreeing with it. Remembering what was asked lets a later read
    /// retire the message on the evidence that it no longer applies.
    private var unmetRequest: Bool?

    /// Re-read the registration from the system. Called whenever the settings window is
    /// about to show it, for the reason ``refreshFinderService()`` is: 系统设置 can revoke
    /// the same registration, so a value cached since launch would show 开 for an app
    /// that will not start.
    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.state
        guard let wanted = unmetRequest,
              launchAtLogin.matches(request: wanted) else { return }
        launchAtLoginFailure = nil
        unmetRequest = nil
    }

    /// Flip the switch, then believe the system rather than the call.
    ///
    /// The opposite of ``setFinderServiceEnabled(_:)``, which assigns what was asked for
    /// because its write cannot be verified. Here it can: the state comes from a fresh
    /// `status` read taken after the mutation, so the switch shows what macOS will
    /// actually do — including the case where `register()` succeeded and the answer is
    /// still ``LaunchAtLoginState/blocked``.
    ///
    /// The thrown error is used only to *explain* a disagreement, never to detect one —
    /// see ``LaunchAtLoginState/matches(request:)`` for why deciding on the re-read status
    /// is the only reading that survives the header and the running system disagreeing
    /// about which errors a redundant call produces.
    func setLaunchAtLogin(_ enabled: Bool) {
        var reason: String?
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            reason = Self.launchAtLoginReason(error)
        }
        launchAtLogin = LaunchAtLogin.state
        launchAtLoginFailure = LaunchAtLoginState.failureMessage(
            request: enabled, state: launchAtLogin, reason: reason)
        unmetRequest = launchAtLoginFailure == nil ? nil : enabled
    }

    /// The system's own words, plus the one hint worth adding to them.
    ///
    /// `localizedDescription` first and always: a ServiceManagement failure is often no
    /// more specific than "Operation not permitted", but it is what the system said, and
    /// paraphrasing it loses the only detail a bug report could use. The hint is appended
    /// when the code matches — see ``LaunchAtLoginState/hint(forErrorCode:)`` for why
    /// matching on the code alone is safe when the text is additive.
    private static func launchAtLoginReason(_ error: Error) -> String {
        let ns = error as NSError
        guard let hint = LaunchAtLoginState.hint(forErrorCode: ns.code) else {
            return ns.localizedDescription
        }
        return "\(ns.localizedDescription) \(hint)"
    }

    // MARK: - Checking for updates

    /// The last completed check's answer, or `nil` if none has completed this launch.
    ///
    /// Every assignment bumps ``updateGeneration``, because ``upgradePath`` is partly derived
    /// from whatever this held at the time.
    private(set) var update: UpdateReport? {
        didSet { updateGeneration += 1 }
    }

    /// How many reports have landed this launch.
    ///
    /// Exists so a route can be tied to the report it came out of. Three of
    /// ``SelfUpdate/Route``'s refusals — 「读不懂最新版本号」, 「并不比最新发布 X 旧」 and every
    /// `AssetChoice.none` — are facts about the *release*, not about this install, and
    /// ``resolveUpgradePath()`` used to cache them as `retryable: false` for the life of the
    /// process. GitHub computes an asset's digest asynchronously *after* the upload, so a check
    /// that landed in that window cached 「GitHub 没有报 … 的校验和」 and no later release ever got
    /// an install button until the app was relaunched — precisely the failure mode `retryable`
    /// was introduced to eliminate.
    ///
    /// A counter rather than comparing reports, because `UpdateReport` is a decoded payload with
    /// no identity of its own, and "the same latest with a digest that has appeared since" has
    /// to count as a different report.
    private(set) var updateGeneration = 0

    /// Why the last check could not complete.
    ///
    /// Shown rather than swallowed: "已是最新" for a check that never reached GitHub is the
    /// one answer that hides a pending update behind a reassuring message. A failed
    /// *automatic* check is still recorded here, but ``updateSheetPresented`` stays down —
    /// a banner about a background failure the user did not ask for is noise.
    private(set) var updateFailure: String?

    /// A check is in flight. Separate from ``busy``, which is about the CLI calls the
    /// config panes make: an update check must not grey out 保存 two panes away.
    private(set) var updateChecking = false

    /// Whether the update sheet is on screen. Raised only by a check that found something
    /// — a manual check that finds nothing reports in the pane, not in a dialog nobody
    /// asked for.
    ///
    /// Raise it through ``presentUpdateSheet()`` rather than by assignment: the sheet needs a
    /// window that is actually on screen, and this flag used to be set by a check that could
    /// finish after the window had gone.
    var updateSheetPresented = false

    /// Which upgrade this install can be offered, once asked. `nil` until the sheet asks.
    private(set) var upgradePath: SelfUpdate.Route?

    /// The ``updateGeneration`` ``upgradePath`` was resolved from.
    ///
    /// A route outlives repeated sheet openings but never outlives its report — see
    /// ``updateGeneration``.
    private var upgradePathGeneration = -1

    /// How far the in-app download has got, or `nil` when one is not running.
    ///
    /// A stored property on the model rather than the `AsyncStream` machinery `ThumbnailStore`
    /// uses: the sheet is the only consumer and both ends are already on the main actor, so a
    /// multi-watcher stream would be scaffolding around a single assignment.
    private(set) var downloadProgress: SelfUpdate.Progress?

    /// The install is past downloading and is hashing, mounting, checking and copying.
    ///
    /// Cosmetic only. It picks the spinner over the bar; it does **not** gate 取消, because
    /// every one of those steps is cancellable and disabling the button there was the whole of
    /// one bug.
    private(set) var installing = false

    /// The task doing the download, kept only so 取消 can stop it.
    private var installTask: Task<Void, Never>?

    /// Orders and fences the progress callbacks of the install that is running now.
    ///
    /// The callback arrives on a URLSession queue and hops to the main actor with a fresh
    /// `Task` each time — hundreds of them for a five-megabyte image, with no ordering
    /// guarantee between them. Two things follow, and neither is fixed by hoping:
    ///
    /// - a stale tick landing after ``finishInstall()`` would set ``downloadProgress`` non-nil
    ///   again, and `UpdateSheet` renders the progress row *instead of* the button row — so the
    ///   sheet would be left showing a frozen bar with no way out;
    /// - a tick landing out of order would rewind the bar.
    ///
    /// Honest about the evidence: an attempt to force the reorder saw the main actor drain FIFO
    /// across three runs, so this is an unguarded assumption being removed rather than a
    /// demonstrated reorder. The gate costs one comparison per tick, which is cheaper than
    /// arguing about it.
    private var progressGate: ProgressGate?

    /// The highest ticket ``observeInstall`` has acted on, within the current gate.
    private var lastProgressTicket: UInt64 = 0

    /// An upgrade-path probe is in flight. The `upgradePath == nil` guard did not hold across
    /// its own `await`, so two sheet appearances could both spawn one.
    private var resolvingUpgradePath = false

    /// The user asked for a check while one was already running.
    ///
    /// The in-flight guard cannot tell a manual request from the automatic check it collided
    /// with, and dropping the manual one is what made a menu click look inert: the update was
    /// found, then reported through a banner instead of the sheet that was asked for.
    private var manualRequested = false

    /// When the last check completed, automatic or manual.
    ///
    /// **`UserDefaults`, not `config.toml`**, and the same goes for ``autoCheckUpdates``.
    /// The config file is the CLI's, and `gitpic` itself never checks on a schedule — it has
    /// no daemon to do it from. A key there that only the app honoured would appear in
    /// `gitpic config get` as a setting the CLI ignores, which is the "accepted, then
    /// ignored" shape this project deleted from the upload pane's link settings. This is app
    /// behaviour, so it lives where app behaviour lives.
    ///
    /// A **stored** property mirrored to `UserDefaults` rather than a computed one over it,
    /// because `@Observable` only tracks stored properties — a computed getter reading
    /// `UserDefaults` would return the right value and never redraw the view that showed it.
    private(set) var lastUpdateCheck: Date? = AppModel.defaults
        .object(forKey: AppModel.lastCheckKey) as? Date {
        didSet { Self.defaults.set(lastUpdateCheck, forKey: Self.lastCheckKey) }
    }

    /// Whether to check once a day on our own.
    ///
    /// Defaults to **on** for a missing key, which is what a fresh install has. An update
    /// mechanism that ships switched off helps nobody who does not go looking for it, and
    /// the check is one unauthenticated GET a day against a public endpoint — it sends
    /// nothing about the user and reads nothing but the release feed. The switch is here for
    /// anyone who would still rather it did not.
    var autoCheckUpdates: Bool = AppModel.defaults
        .object(forKey: AppModel.autoCheckKey) as? Bool ?? true {
        didSet {
            Self.defaults.set(autoCheckUpdates, forKey: Self.autoCheckKey)
            // Switching it on is itself a reason to look: the user just asked for this, and
            // making them wait up to a day to see it work would read as broken. Through
            // `checkForUpdatesIfDue` rather than straight into a check, because going
            // straight in bypassed the daily rule altogether — flicking the switch off and
            // on was an unmetered request every time, and the unauthenticated feed allows
            // 60 an hour before it starts answering 403 to the checks the user *did* ask
            // for. When a check already happened today the answer is on the pane already.
            if autoCheckUpdates { Task { await checkForUpdatesIfDue() } }
        }
    }

    /// The version a banner has already announced.
    ///
    /// `Notifier.post` uses a fresh identifier for every notification, so nothing coalesces:
    /// without this record, a daily check kept telling the user about the release they had
    /// already seen and decided against. Persisted, because being quiet only until the next
    /// launch is not being quiet. Nothing else is suppressed — 设置 ▸ 通用 and the sheet still
    /// say so for as long as the update stands, which is where someone who wants to act on it
    /// later goes looking.
    private(set) var announcedVersion: String? = AppModel.defaults
        .string(forKey: AppModel.announcedKey) {
        didSet { Self.defaults.set(announcedVersion, forKey: Self.announcedKey) }
    }

    fileprivate static let defaults = UserDefaults.standard
    fileprivate static let lastCheckKey = "update.lastCheck"
    fileprivate static let autoCheckKey = "update.autoCheck"
    fileprivate static let announcedKey = "update.announced"

    /// Run the daily check if one is due. Called at launch, and whenever the settings window
    /// is put on screen — `SettingsWindowController.showWindow`, which is the call that
    /// covers reopening, not `GeneralPane`'s `.task`.
    ///
    /// That distinction is the whole of one bug: the `.task` fires when the pane is first
    /// mounted and never again, because `orderOut` emits no `onDisappear` and the window
    /// survives being closed. So the "once a day" the switch promises was in practice once
    /// per launch, and `GitPicApp`'s argument for not using a repeating timer — that the
    /// settings pane checks again whenever it is opened — was not true of the code.
    ///
    /// The due-or-not rule is in ``UpdateSchedule/isDue(lastChecked:now:interval:)`` so it
    /// can be tested; what is left here is the decision to ask at all.
    func checkForUpdatesIfDue() async {
        guard autoCheckUpdates,
              UpdateSchedule.isDue(lastChecked: lastUpdateCheck, now: Date())
        else { return }
        await checkForUpdates(manual: false)
    }

    /// Ask the CLI what the latest release is.
    ///
    /// `manual` decides only how loudly the result is reported: a manual check owes the
    /// user an answer either way, while an automatic one speaks up only when there is
    /// something to say.
    func checkForUpdates(manual: Bool) async {
        // Cleared here, above the guards, and again below them. It used to be cleared only
        // after both early returns, so a click that returned early left the previous
        // attempt's orange banner standing — indistinguishable from a check that had just
        // run and failed again.
        if manual { updateFailure = nil }
        // A manual request that collides with a check already in flight is remembered rather
        // than dropped. The guard below cannot tell the two apart, and dropping the manual
        // one meant the found update reported through a banner instead of the sheet the
        // click asked for, so the click looked inert.
        if manual { manualRequested = true }
        // Same shape as `loadSkillTargets`: a `nil` runner while discovery is still
        // running is not a failure to report, and only `.missing` is. `.resolving` therefore
        // falls through to a silent return — which is right here, but was the whole bug at
        // the status-item entry, where there is no `validateMenuItem` to grey the item out
        // the way the pane's button is greyed. `AppDelegate` now waits for discovery before
        // calling in, so this stays as the backstop for every other caller.
        guard let runner else {
            if manual, toolState == .missing {
                updateFailure = "找不到 gitpic 可执行文件，请重新安装 GitPic。"
            }
            return
        }
        // One check at a time. Unlike the config reads this is not idempotent in the way
        // that matters — two in flight would both stamp `lastUpdateCheck` and both may
        // raise the sheet.
        guard !updateChecking else { return }
        updateChecking = true
        defer {
            updateChecking = false
            manualRequested = false
        }
        updateFailure = nil
        do {
            let report = try await runner.updateCheck()
            update = report
            // Stamped only on a completed check, so a week offline does not silently
            // count as a week of checking.
            lastUpdateCheck = Date()
            Diagnostics.log("update check: current=\(report.current) latest=\(report.latest)"
                            + " available=\(report.updateAvailable) ahead=\(report.ahead)")
            // The status item's last row is 「检查更新」 or 「有新版本 x.y.z…」 depending on
            // this answer, and it is built once and cached — so it has to be told.
            onMenuNeedsRebuild?()
            guard report.updateAvailable else { return }
            // Read *after* the await, so a manual request that arrived while this check was
            // running is honoured by the check that was already going.
            let asked = manual || manualRequested
            if asked, presentUpdateSheet() { return }
            // Either nobody asked, or the window went away while the check ran — a manual
            // answer must not be lost just because its sheet has nowhere to appear.
            //
            // A daily check must not throw a sheet in front of whatever the user was doing
            // either, and the window is usually shut when one lands anyway, where a sheet
            // would be a report nobody sees (the argument `notify` makes about upload
            // outcomes). The banner tells them; 设置 ▸ 通用 keeps a 「查看更新内容」 button for
            // as long as the update stands, so nothing is lost by not interrupting.
            //
            // Once per version, unless the user asked: `Notifier.post` uses a fresh
            // identifier per banner so nothing coalesces, and without that record someone
            // who saw the notice and stayed on their version got it again every day.
            guard asked || announcedVersion != report.latest else { return }
            announcedVersion = report.latest
            notify(title: "GitPic \(report.latest) 可以更新了",
                   body: "当前 \(report.current)。打开设置 ▸ 通用 查看更新内容。")
        } catch {
            updateFailure = Self.cliMessage(error)
            Diagnostics.log("update check failed: \(String(describing: error))")
        }
    }

    /// Put the update sheet on screen, reporting whether there was a window to put it on.
    ///
    /// Two things went wrong with assigning ``updateSheetPresented`` directly. The sheet was
    /// attached inside 通用, so a check that completed after the user had switched panes had
    /// nowhere to present — the answer was simply lost. And the flag stayed raised, so the
    /// next visit to 通用 opened a sheet nobody had asked for, about whichever report
    /// ``update`` held by then. It is attached to the window's root view now, which fixes the
    /// pane switch; this fixes the other half, because a window that is not on screen still
    /// cannot show a sheet and the caller needs to know so it can answer some other way.
    @discardableResult
    func presentUpdateSheet() -> Bool {
        guard SettingsWindowController.isOnScreen else { return false }
        updateSheetPresented = true
        return true
    }

    /// Ask which upgrade this install can be offered. Called when the sheet appears, and again
    /// whenever a new report lands under it.
    ///
    /// **Only a definite answer is kept, and only for the report it came from.** Two separate
    /// bugs live here, and they pull in the same direction.
    ///
    /// `guard upgradePath == nil` cached whatever came back, including the two failures that say
    /// nothing about this install: `brew list --cask` hitting its 20 s bound (its own doc comment
    /// names Homebrew's housekeeping as a cause) and the 8 s login-shell probe timing out. Either
    /// one then told a user with a perfectly good Homebrew 「这份 GitPic 不是用 Homebrew 装的」 for
    /// the rest of the process's life, with quitting the app as the only way to ask again. That
    /// is what `retryable` fixed.
    ///
    /// But three of the `retryable: false` refusals are computed from the *report* rather than
    /// from this machine — 「读不懂最新版本号」, 「并不比最新发布 X 旧」 and every
    /// `AssetChoice.none` — and `update` is reassigned on every check. Caching those for the
    /// process was the same bug wearing the other hat: a check landing in the window where
    /// GitHub has not yet computed an asset's digest cached 「GitHub 没有报 … 的校验和」 and no
    /// later release could ever offer an install again. So `retryable` keeps its narrow meaning
    /// — "asking the machine again could answer differently" — and the *report* generation
    /// decides whether the cached route is about the release in front of the user at all.
    func resolveUpgradePath() async {
        if upgradePathGeneration == updateGeneration {
            if case .unavailable(_, retryable: false) = upgradePath { return }
            if case .selfInstall = upgradePath { return }
        }
        // The old guard also did not hold across the `await`, so two sheet appearances could
        // both spawn the probe.
        guard !resolvingUpgradePath else { return }
        // Nothing to resolve without a report: the answer depends on which assets the release
        // published, so it cannot be computed before the check has completed.
        guard update != nil else { return }
        resolvingUpgradePath = true
        defer { resolvingUpgradePath = false }
        // Back to `nil` for the duration, because that is what `UpdateSheet` renders as
        // 「正在确认升级方式…」. Leaving the previous retryable failure in place would show the
        // 「不能在这里直接升级」 paragraph while the probe that may contradict it is running.
        upgradePath = nil
        // A loop, not one call. A check completing *while* the probe runs moves the generation
        // on, and `UpdateSheet`'s `.task(id:)` cannot recover from that on its own — it re-enters
        // and is turned away by the in-flight guard above. So the probe already running is the
        // one that has to notice, and discard a route it computed from a report the user is no
        // longer looking at. It converges: `checkForUpdates` allows one check at a time, so each
        // extra pass is a real new report and not a spin.
        while true {
            guard let report = update else { return }
            let generation = updateGeneration
            let route = await Updater.resolve(report: report)
            guard generation == updateGeneration else {
                Diagnostics.log("update: a newer report landed mid-probe — resolving again")
                continue
            }
            upgradePath = route
            upgradePathGeneration = generation
            return
        }
    }

    /// Do the upgrade that was resolved, and quit.
    ///
    /// One arm, where there were two. The other handed the install to `brew upgrade --cask gitpic`
    /// and could fail *before* the app quit — hence the `catch` that used to be here, setting
    /// 「启动升级失败」 while this process was still alive to show it. `performSelfInstall` reports
    /// its own failures through `updateFailure` from inside its `Task`, so there is nothing to
    /// catch at this level any more.
    func performUpgrade() {
        switch upgradePath {
        case .selfInstall(let asset, let sha, let version):
            performSelfInstall(asset: asset, sha256: sha, version: version)
        case .unavailable, .none:
            return
        }
    }

    /// Download, verify, stage and hand off — reporting each stage into the sheet.
    ///
    /// Everything here can fail while the app is still on screen, which is the point: a failed
    /// download or a digest that does not match costs a message, not the application.
    ///
    /// The version comes from the route, alongside the asset, rather than from `update?.latest`
    /// at click time. Those are two different reports whenever a check lands between the sheet
    /// resolving and the button being pressed, and the mismatch surfaced as far away as
    /// possible: a full download that verified against the right digest and then died at
    /// `stage`'s version gate with 「映像里是 0.20.0，不是预期的 0.21.0」 — a message that reads
    /// like a tampered release.
    private func performSelfInstall(asset: ReleaseAsset, sha256: String, version: String) {
        guard installTask == nil else { return }
        updateFailure = nil
        // Seeded from the release's own `size`, which the sheet has been showing all along, so
        // there is a total to draw a bar against before a single byte has arrived — and one that
        // survives a response with no `Content-Length`.
        downloadProgress = SelfUpdate.Progress(received: 0, total: asset.size)
        installing = false
        let gate = ProgressGate()
        progressGate = gate
        lastProgressTicket = 0
        // `self` strongly, unlike `loginTask` above: this type is a main-actor singleton, and
        // the progress callback arrives on a URLSession queue, so a weak capture inside that
        // `@Sendable` closure is the one thing Swift 6 will not allow here.
        installTask = Task {
            do {
                try await Updater.installAndRelaunch(
                    asset: asset, sha256: sha256, version: version,
                    onProgress: { progress in
                        // The ticket is taken here, on the URLSession queue, in the order the
                        // bytes actually arrived. What happens to these `Task`s afterwards is
                        // then no longer load-bearing.
                        let ticket = gate.next()
                        Task { @MainActor in
                            self.observeInstall(progress, from: gate, ticket: ticket)
                        }
                    })
            } catch {
                // **取消 is an outcome, not a failure**, and the test is the task's own
                // cancellation rather than the error's type. Cancellation reaches here as at
                // least three different things — `CancellationError` from `sha256OfFile` and
                // from `Updater`'s own checks, `SelfUpdate.Failure.download` when URLSession
                // reports `.cancelled` first, and a `SelfUpdate.InstallFailure` case for a
                // staging step that stopped half-way — and every one of them would otherwise
                // put an orange 「安装失败」 line in front of a user who had just pressed 取消.
                // `Task.isCancelled` is the one thing all three have in common.
                if error is CancellationError || Task.isCancelled {
                    Diagnostics.log("update: install cancelled by the user"
                                    + " (\(String(describing: error)))")
                } else if let failure = error as? SelfUpdate.Failure {
                    self.reportInstallFailure(failure.message, log: String(describing: failure))
                } else if let failure = error as? SelfUpdate.InstallFailure {
                    self.reportInstallFailure(failure.message, log: String(describing: failure))
                } else {
                    self.reportInstallFailure(
                        "安装失败：\((error as NSError).localizedDescription)",
                        log: String(describing: error))
                }
            }
            // Either way the sheet goes back to its buttons: nothing was installed, and there is
            // no half-state left to explain.
            self.finishInstall()
        }
    }

    private func observeInstall(_ progress: SelfUpdate.Progress, from gate: ProgressGate,
                               ticket: UInt64) {
        // Identity first, then order: a tick from a finished install must not resurrect the
        // progress row, and a tick that overtook a later one must not rewind the bar.
        guard gate === progressGate, ticket > lastProgressTicket else { return }
        lastProgressTicket = ticket
        // The release's `size` is kept whenever the response does not report one:
        // `DownloadDelegate` maps `NSURLSessionTransferSizeUnknown` to `nil`, and taking that
        // `nil` erased the good value seeded above — a chunked or compressed response left the
        // sheet with no bar and no way to tell the download had finished.
        let total = progress.total ?? downloadProgress?.total
        downloadProgress = SelfUpdate.Progress(received: progress.received, total: total)
        // The hash, the mount, the version check, the signature check and the copy all come
        // after the last byte, and they are not instant — say so rather than leaving a full bar
        // sitting there looking stuck. 取消 stays live throughout; every one of those steps
        // stops when asked.
        if let total, progress.received >= total { installing = true }
    }

    private func reportInstallFailure(_ message: String, log: String) {
        updateFailure = message
        Diagnostics.log("update: install failed: \(log)")
    }

    private func finishInstall() {
        installTask = nil
        // Closed before the progress row is torn down, so a tick still in flight is dropped by
        // ``observeInstall(_:from:ticket:)`` rather than putting it back.
        progressGate = nil
        lastProgressTicket = 0
        downloadProgress = nil
        installing = false
    }

    /// Stop an in-flight download or install.
    ///
    /// Honoured at every stage, which is the only thing that makes offering the button honest:
    /// `SelfUpdate.download` deletes its own partial file, `sha256OfFile` checks every megabyte,
    /// and `Updater.installAndRelaunch` checks either side of the staging copy and removes the
    /// staging directory if the answer arrived late.
    func cancelInstall() {
        installTask?.cancel()
    }

    // MARK: - Telling the user what happened

    /// Post an outcome to Notification Center, and log it.
    ///
    /// The window has no status line any more: outcomes are events, the window is
    /// usually closed when one happens, and a line at the bottom of a window nobody
    /// is looking at is not a report. Notification Center is the one surface now —
    /// the same one uploads have always used.
    ///
    /// The log line is not decoration. With notification permission denied a banner
    /// goes nowhere at all, and this is then the only trace an outcome leaves;
    /// `Notifier.authorize()` records that denial for the same reason.
    func notify(title: String, body: String) {
        Diagnostics.log("notice: \(title) — \(body)")
        Notifier.post(UploadNotice(title: title, body: body))
    }

    /// How long work has to run before it is worth telling anyone about.
    ///
    /// Every `reload()` used to flip `busy` twice — and a reload runs on every window
    /// open. Measured on this machine it takes ~40ms of `gitpic` and finishes long
    /// before anyone could read a spinner, yet everything gated on `busy` still
    /// changed twice on the way past: the toolbar's 刷新 and the 连通性测试 button
    /// greyed out and came back, and the spinner appeared and vanished. A progress
    /// report for work that is already over is not a report, it is a flicker.
    ///
    /// So `busy` now means "still running after a quarter second". Work that is
    /// genuinely slow — a save, an upload, a connectivity test — crosses that
    /// line and reports normally.
    private static let busyDelay = Duration.milliseconds(250)

    /// Pending "announce it now" for the debounce above, cancelled if the work
    /// finishes first.
    private var busyAnnouncement: Task<Void, Never>?

    private func beginWork() {
        inflight += 1
        guard busyAnnouncement == nil, !busy else { return }
        busyAnnouncement = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.busyDelay)
            guard let self, !Task.isCancelled else { return }
            self.busy = self.inflight > 0
        }
    }

    private func endWork() {
        inflight = max(0, inflight - 1)
        guard inflight == 0 else { return }
        busyAnnouncement?.cancel()
        busyAnnouncement = nil
        busy = false
    }

    func reload() async {
        guard let runner else { return }
        // The draft's baseline as it stands *now*. `reconcile` needs it to tell an
        // edit made during the await from a value the user never touched; reading it
        // afterwards would compare the draft against the file it is about to adopt
        // and call every key untouched.
        let baseline = savedConfig
        beginWork()
        defer { endWork() }
        // Asked once per launch, not once per read. `config path` does not load the
        // file, so it answers whether or not the read fails — and the window needs the
        // path exactly when the read fails, which is why it is fetched up front rather
        // than in the `catch`. But it is a whole `gitpic` process for an answer that
        // cannot change while this app runs: the path comes from `XDG_CONFIG_HOME` and
        // the home directory, and `rebuildConfig()` renames the file *into the same
        // place*. Reading it on every reload was the most expensive call in the
        // sequence — measured ~90ms of the ~120ms a window-opening reload cost, since
        // the first spawn of a cycle also waits on the main thread finishing the
        // window's first layout.
        if configPath == nil {
            configPath = try? await runner.configPath()
        }
        do {
            let cfg = try await runner.loadConfig()
            savedConfig = cfg
            if let current = draft, let baseline {
                draft = reconcile(draft: current, toward: cfg, untouchedSince: baseline)
            } else {
                draft = cfg
            }
            // A read that succeeded supersedes the last failure, including one this
            // read just disproved.
            configFailure = nil
            onMenuNeedsRebuild?()
            // What the form is now showing, and whether it came from the file or from
            // an edit the reconcile kept. A form that reads back empty while the file
            // is fine — which is how the late-runner bug looked — is otherwise
            // indistinguishable in the log from a genuinely unconfigured machine.
            let shown = draft?.github ?? cfg.github
            Diagnostics.log("config read: file=\(cfg.github.owner)/\(cfg.github.repo)"
                            + " form=\(shown.owner)/\(shown.repo)@\(shown.branch)")
        } catch {
            configFailure = ConfigFailure(error)
            // Logged as well as shown: this is the failure users report as "App 没
            //反应", and the log is what can be read back afterwards.
            Diagnostics.log("config read failed: \(String(describing: error))")
        }
        // Its own step, outside the block above, because it is its own failure:
        // `gitpic list` reads `history.jsonl` and never opens `config.toml`. Inside
        // that `do` it took the config read down with it — an unreadable history file
        // (root-owned after a `sudo` run is the usual way) set `configFailure`, and
        // both panes render that by replacing the entire editable form with 「读取配置
        // 失败」, so a bad history file made every setting uneditable and named the
        // wrong file while doing it. It also skipped `onMenuNeedsRebuild?()`, leaving the
        // status-item menu on stale checkmarks. A history that will not load costs
        // the history list and nothing else.
        do {
            history = try await runner.history(limit: 100)
            historyFailure = nil
        } catch {
            // Keep whatever `history` already holds: a later failure must not
            // pretend the list is empty. `historyFailure` is what the pane shows
            // when there is nothing to keep (a cold launch that could not read).
            historyFailure = ConfigFailure(error).message
            Diagnostics.log("history read failed: \(String(describing: error))")
        }
    }

    /// Move an unusable config file aside, then read again — which leaves the CLI
    /// free to write a fresh default file on the next `config set`.
    ///
    /// The rename happens here because no subcommand can do it: every config
    /// *writer* begins with `Config::load()` (`src/commands/config_cmd.rs`), the very
    /// call that is failing, so `config set` cannot be the way out of a file it
    /// refuses to parse. `config get` on a *missing* file returns the defaults
    /// (`src/config.rs`), so a rename is all it takes to get an editable form back.
    ///
    /// Renamed, never read. The app does not parse the old file and never shows its
    /// contents: a config carried over from before 0.5.0 still holds a
    /// `github.token` line, and putting that on screen — or in a notification —
    /// would leak a live credential. `src/config.rs` has a test pinning that the CLI
    /// keeps the same silence in its error messages; this keeps the app from being
    /// the leak the CLI declined to be.
    ///
    /// Moved rather than deleted for the same reason: `owner`/`repo`/`branch` in
    /// there are probably still correct, and the backup is where the user reads them
    /// back from.
    func rebuildConfig() async {
        guard let runner else { return }
        beginWork()
        defer { endWork() }
        let path: URL
        do {
            path = try await runner.configPath()
        } catch {
            notify(title: "重建配置失败",
                   body: "问不出配置文件的位置：\(ConfigFailure(error).message)")
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            let backup = path.deletingLastPathComponent()
                .appendingPathComponent("\(path.lastPathComponent).broken-\(Self.stamp())")
            do {
                try fm.moveItem(at: path, to: backup)
            } catch {
                notify(title: "重建配置失败",
                       body: "移不动 \(path.lastPathComponent)：\(error.localizedDescription)")
                return
            }
            configBackup = backup
            Diagnostics.log("config moved aside: \(backup.path)")
            notify(title: "配置文件已备份",
                   body: "旧文件是 \(backup.lastPathComponent)，现在可以在「图床」里重新填。")
        }
        await reload()
    }

    /// A filename-safe stamp, so a second rebuild cannot overwrite the first
    /// backup — which would destroy the values the first one was kept for.
    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    func save() async {
        guard let runner, let savedConfig, let draft else { return }
        let keys = changedKeys(from: savedConfig, to: draft)
        // 保存 is disabled with nothing to write, so this is unreachable by hand
        // (⌘S while nothing is dirty is the one way in) and needs no message.
        guard !keys.isEmpty else { return }
        // Capture the draft we are writing so a concurrent edit is not replaced
        // by the re-read below.
        let snapshot = draft
        beginWork()
        defer { endWork() }
        do {
            try await runner.applyConfig(from: savedConfig, to: snapshot)
            // Re-read rather than assume: `config set` re-validates the whole file
            // and normalises some values (`github.repo` accepts `owner/name`),
            // so what landed can differ from what was typed.
            let fresh = try await runner.loadConfig()
            self.savedConfig = fresh
            self.draft = reconcile(
                draft: self.draft ?? snapshot, toward: fresh, untouchedSince: snapshot)
            notify(title: "已保存配置",
                   body: "写入 \(keys.count) 项：" + keys.map(\.rawValue).joined(separator: ", "))
        } catch {
            // A later key may have failed after an earlier one landed. Re-read
            // so dirtyKeys reflects the file, not the pre-save snapshot.
            if let fresh = try? await runner.loadConfig() {
                // Only the keys the file actually moved on are adopted. Taking all
                // of them would overwrite the values whose writes just failed, which
                // is precisely what the user needs left in the form to retry.
                self.draft = reconcile(
                    draft: self.draft ?? snapshot, toward: fresh, untouchedSince: snapshot,
                    keys: changedKeys(from: savedConfig, to: fresh))
                self.savedConfig = fresh
            }
            notify(title: "保存配置失败", body: ConfigFailure(error).message)
        }
    }

    func revert() {
        draft = savedConfig
    }

    /// Write a copy form straight to the config file, without waiting for 保存.
    ///
    /// This is the status-item menu's path, and its write policy differs from the
    /// window's on purpose. The menu has no 保存 button and no room for one: a click
    /// there is the whole interaction, so it has to land. The window's two pickers are
    /// ordinary config rows that go through the draft like every other setting on the
    /// pane — one deferred write for the batch, which is what makes 放弃 mean
    /// something.
    ///
    /// Only the keys that actually differ are written (`applyConfig` diffs), so
    /// picking the syntax does not rewrite the address, and a menu click while the
    /// window holds unsaved edits cannot clobber them: the reload afterwards
    /// reconciles key by key, keeping whatever the user has touched.
    func writeLinkForm(_ form: LinkForm) async {
        guard let runner else { return }
        guard let savedConfig else {
            // No config read means no baseline to diff against, and writing blind here
            // would mean inventing values for the other ten keys.
            notify(title: "改不了链接形态",
                   body: configFailure?.headline ?? "配置还没读出来，稍后再试")
            return
        }
        let target = form.applied(to: savedConfig)
        let keys = changedKeys(from: savedConfig, to: target)
        guard !keys.isEmpty else { return }
        beginWork()
        defer { endWork() }
        do {
            try await runner.applyConfig(from: savedConfig, to: target)
            // No banner on success — the checkmark that moved is the feedback, and a
            // notification per menu click would be noise. Logged, though: it is a write
            // to the config file, and the log is where a write can be read back.
            Diagnostics.log("link form written: " + keys.map(\.rawValue).joined(separator: ", ")
                            + " → \(form.label)")
        } catch {
            notify(title: "写入失败", body: ConfigFailure(error).message)
        }
        // Reload either way: a partly-applied batch leaves the file in a state the
        // window and the menu both have to be told about.
        await reload()
    }

    func runDoctor() async {
        guard let runner else {
            // Reachable from the status-item menu while discovery is still running,
            // and from the pane if `toolState` races the button. A silent return
            // left the 连通性 section on its idle explanation, hiding why nothing ran.
            lastDoctor = nil
            doctorFailure = switch toolState {
            case .resolving: "还在查找 gitpic，稍后再试"
            case .missing, .ready: "找不到 gitpic 可执行文件，请重新安装 GitPic。"
            }
            return
        }
        beginWork()
        defer { endWork() }
        do {
            lastDoctor = try await runner.doctor()
            doctorFailure = nil
        } catch {
            // Drop the previous report rather than leave it standing beside the
            // failure: those checks did not run, and a stale "仓库可写 ✓" next to
            // "doctor 失败" is a claim nothing supports.
            lastDoctor = nil
            doctorFailure = ConfigFailure(error).message
        }
    }
}
