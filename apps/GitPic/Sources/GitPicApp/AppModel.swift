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
    /// nothing to retry, and a drop in the first seconds after launch reported
    /// "找不到 gitpic" for a binary that simply had not been located yet. The probe
    /// shells out to a login shell and to `gh auth status`, up to 8 s each, so that
    /// window is wide enough to hit by hand.
    enum ToolState: Sendable { case resolving, ready, missing }
    private(set) var toolState: ToolState = .resolving

    /// The config as last read from disk — the baseline a save diffs against.
    var savedConfig: GitpicConfig?
    /// The config as edited in the UI.
    var draft: GitpicConfig?
    var history: [HistoryRecord] = []

    var busy = false
    /// Distinguishes "still loading" from "the last read failed", so the form
    /// does not sit on "读取配置中…" forever after a failure.
    var loadFailed = false
    private(set) var statusLine: String?
    var lastDoctor: DoctorReport?

    /// Who wrote `statusLine`, so a writer clears only what it is entitled to.
    ///
    /// Four call sites share this one line and none of them could clear another's:
    /// a failed save's "写入失败" outlived the successful reload that disproved it,
    /// and "没有改动" was cleared by nothing at all. Blanket-clearing on reload is
    /// not the fix either — `GitPicApp.finish` starts a reload and then posts the
    /// upload's outcome in the same MainActor turn, so a reload that cleared
    /// everything would wipe a message written after it began.
    ///
    /// `.window` is a message the window's own actions own, superseded by the next
    /// successful read; `.upload` is status-item feedback with its own reset timer.
    /// Making the setter private is what found the fourth writer — the history
    /// pane's copy button, whose "写剪贴板失败" was stranded the same way.
    enum StatusAuthor: Sendable { case window, upload }
    private(set) var statusAuthor: StatusAuthor?

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

    // MARK: - Status line

    func post(_ text: String?, from author: StatusAuthor) {
        statusLine = text
        statusAuthor = text == nil ? nil : author
    }

    /// Drop a message this author left behind, and only that.
    func clearStatus(from author: StatusAuthor) {
        guard statusAuthor == author else { return }
        post(nil, from: author)
    }

    /// Drop `text` only while it is still the message on screen, so a reset timer
    /// firing late cannot erase a newer message that replaced it.
    func clearStatus(_ text: String?, from author: StatusAuthor) {
        guard statusAuthor == author, statusLine == text else { return }
        post(nil, from: author)
    }

    private func beginWork() {
        inflight += 1
        busy = true
    }

    private func endWork() {
        inflight = max(0, inflight - 1)
        busy = inflight > 0
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
        do {
            let cfg = try await runner.loadConfig()
            savedConfig = cfg
            if let current = draft, let baseline {
                draft = reconcile(draft: current, toward: cfg, untouchedSince: baseline)
            } else {
                draft = cfg
            }
            history = try await runner.history(limit: 100)
            loadFailed = false
            // A read that succeeded supersedes whatever the last window action left
            // on screen, including a "写入失败" this read just disproved. An
            // upload's message is not ours to clear.
            clearStatus(from: .window)
        } catch {
            loadFailed = true
            post("读取失败：\(String(describing: error))", from: .window)
        }
    }

    func save() async {
        guard let runner, let savedConfig, let draft else { return }
        let keys = changedKeys(from: savedConfig, to: draft)
        guard !keys.isEmpty else {
            post("没有改动", from: .window)
            return
        }
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
            post("已写入 \(keys.count) 项：" + keys.map(\.rawValue).joined(separator: ", "),
                 from: .window)
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
            post("写入失败：\(String(describing: error))", from: .window)
        }
    }

    func revert() {
        draft = savedConfig
        clearStatus(from: .window)
    }

    func runDoctor() async {
        guard let runner else { return }
        beginWork()
        defer { endWork() }
        do {
            lastDoctor = try await runner.doctor()
            clearStatus(from: .window)
        } catch {
            // Drop the previous report rather than leave it standing beside the
            // failure: those checks did not run, and a stale "仓库可写 ✓" next to
            // "doctor 失败" is a claim nothing supports.
            lastDoctor = nil
            post("doctor 失败：\(String(describing: error))", from: .window)
        }
    }
}
