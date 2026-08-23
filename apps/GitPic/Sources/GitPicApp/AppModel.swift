import AppKit
import SwiftUI
import GitPicCore

/// Lets a menu-bar-only app show a real window with a normal title bar, then go
/// back to being invisible. Reference-counted because more than one window (or a
/// modal alert) can need `.regular` at the same time.
@MainActor
enum AppActivationPolicy {
    private static var depth = 0

    static func enter() {
        depth += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        depth = max(0, depth - 1)
        if depth == 0 { NSApp.setActivationPolicy(.accessory) }
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
    /// yet. The probe shells out to a login shell and to `gh auth status`, up to 8 s
    /// each, so that window is wide enough to hit by hand.
    enum ToolState: Sendable { case resolving, ready, missing }
    private(set) var toolState: ToolState = .resolving

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

    /// Called after `savedConfig` changes, so the status-item menu can redraw the
    /// checkmarks it derives from it.
    ///
    /// A callback rather than the menu observing the model: `rebuildMenu()` replaces
    /// `statusItem.menu` wholesale, which is `AppDelegate`'s business and must not
    /// happen from inside an `@Observable` read. Without it, changing the form in the
    /// window left the menu displaying the previous choice until the next upload
    /// rebuilt it — measured, and the reason this exists.
    var onConfigChange: (() -> Void)?

    var busy = false
    var lastDoctor: DoctorReport?

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

    func attach(runner: GitpicRunner, tools: ToolPaths) {
        self.runner = runner
        self.tools = tools
        toolState = .ready
    }

    /// Discovery finished and `gitpic` is not there — distinct from `.resolving`,
    /// so the UI can tell "wait" from "install it".
    func toolsUnavailable() {
        runner = nil
        tools = nil
        toolState = .missing
    }

    // MARK: - Telling the user what happened

    /// Whether the Finder right-click item is switched on.
    ///
    /// A mirror of system state, not a setting of our own: the truth is the `pbs` entry
    /// ``FinderService`` reads, and this exists only because `@Observable` cannot watch
    /// another process's preferences.
    ///
    /// Seeded with `true` rather than a real read, deliberately. `AppModel.shared` is
    /// first touched from `setUpStatusItem()`, so a `FinderService.isEnabled` default
    /// would put a cross-process preference read (measured 1.9 ms on a cold domain) on
    /// the launch path — to produce a value nothing reads until 设置 ▸ 上传 opens, which
    /// calls ``refreshFinderService()`` before showing it anyway. `true` is also the right
    /// placeholder: it is what the system reports for a service nobody has toggled.
    private(set) var finderServiceEnabled = true

    /// Re-read the switch from the system. Called whenever the settings window is
    /// about to show it — System Settings can change the same switch, so a value
    /// cached since launch would show 开 for an item the user removed an hour ago.
    func refreshFinderService() {
        finderServiceEnabled = FinderService.isEnabled
    }

    /// Flip the switch, and show what the system actually did.
    ///
    /// `setEnabled` returns the state it observed after writing, so this assigns that —
    /// one read, one comparison. A switch that slid over while the menu item stayed put
    /// would be a lie the user cannot see through, so a refusal springs the switch back
    /// and says where the same setting can be changed by hand.
    func setFinderServiceEnabled(_ enabled: Bool) {
        let observed = FinderService.setEnabled(enabled)
        finderServiceEnabled = observed
        guard observed != enabled else { return }
        notify(title: "改不了右键菜单",
               body: "系统没有接受这次修改。可在「系统设置 ▸ 键盘 ▸ 键盘快捷键 ▸ 服务」"
                     + "里手动开关 GitPic。")
    }

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
            history = try await runner.history(limit: 100)
            // A read that succeeded supersedes the last failure, including one this
            // read just disproved.
            configFailure = nil
            onConfigChange?()
        } catch {
            configFailure = ConfigFailure(error)
            // Logged as well as shown: this is the failure users report as "App 没
            //反应", and the log is what can be read back afterwards.
            Diagnostics.log("config read failed: \(String(describing: error))")
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
            // left the 连通性 section on "还没测过", which is a claim this did not test.
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
