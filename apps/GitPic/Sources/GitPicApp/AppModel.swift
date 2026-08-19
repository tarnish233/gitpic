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

    /// The config as last read from disk — the baseline a save diffs against.
    var savedConfig: GitpicConfig?
    /// The config as edited in the UI.
    var draft: GitpicConfig?
    var history: [HistoryRecord] = []

    var busy = false
    var statusLine: String?
    var lastDoctor: DoctorReport?

    var dirtyKeys: [ConfigKey] {
        guard let savedConfig, let draft else { return [] }
        return changedKeys(from: savedConfig, to: draft)
    }

    private init() {}

    func attach(runner: GitpicRunner, tools: ToolPaths) {
        self.runner = runner
        self.tools = tools
    }

    func reload() async {
        guard let runner else { return }
        busy = true
        defer { busy = false }
        do {
            let cfg = try await runner.loadConfig()
            savedConfig = cfg
            // Never clobber in-progress edits on a background refresh.
            if draft == nil || dirtyKeys.isEmpty { draft = cfg }
            history = try await runner.history(limit: 100)
            statusLine = nil
        } catch {
            statusLine = "读取失败：\(String(describing: error))"
        }
    }

    func save() async {
        guard let runner, let savedConfig, let draft else { return }
        let keys = changedKeys(from: savedConfig, to: draft)
        guard !keys.isEmpty else {
            statusLine = "没有改动"
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await runner.applyConfig(from: savedConfig, to: draft)
            // Re-read rather than assume: `config set` re-validates the whole file
            // and normalises some values (`github.repo` accepts `owner/name`),
            // so what landed can differ from what was typed.
            let fresh = try await runner.loadConfig()
            self.savedConfig = fresh
            self.draft = fresh
            statusLine = "已写入 \(keys.count) 项：" + keys.map(\.rawValue).joined(separator: ", ")
        } catch {
            statusLine = "写入失败：\(String(describing: error))"
        }
    }

    func revert() {
        draft = savedConfig
        statusLine = nil
    }

    func runDoctor() async {
        guard let runner else { return }
        busy = true
        defer { busy = false }
        do { lastDoctor = try await runner.doctor() }
        catch { statusLine = "doctor 失败：\(String(describing: error))" }
    }
}
