import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case host, upload, history, agent, about
    var id: Self { self }

    var title: String {
        switch self {
        case .host:    "图床"
        case .upload:  "上传"
        case .history: "历史"
        case .agent:   "Agent"
        case .about:   "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .host:    "photo.stack"
        case .upload:  "arrow.up.circle"
        case .history: "clock.arrow.circlepath"
        case .agent:   "cpu"
        case .about:   "info.circle"
        }
    }

    /// Whether this pane edits the config file, and so carries the save bar.
    var savesConfig: Bool {
        switch self {
        case .host, .upload:           true
        case .history, .agent, .about: false
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .host

    /// Visited panes, oldest first, and where in that list we currently are.
    ///
    /// Held here rather than in the view's `@State` because the window is no longer
    /// thrown away when it closes — see ``SettingsWindowController``. The behaviour is
    /// the one it always had; it is now stated instead of falling out of a destroyed
    /// view: ``endSession()`` spends the history when the window closes, the way
    /// System Settings starts over. `selectedTab` deliberately survives, because the
    /// status item's 连通性测试 sets it before the window exists.
    var history: [SettingsTab] = [.host]
    var historyIndex = 0
    /// Suppresses recording while back/forward is what moved the selection —
    /// otherwise stepping back appends the pane just left, and the two buttons
    /// walk in a circle instead of walking a history.
    var steppingThroughHistory = false

    private init() {}

    /// The window closed: the trail through it is spent, and the next open starts
    /// from wherever it will land rather than from a stale list.
    func endSession() {
        history = [selectedTab ?? .host]
        historyIndex = 0
        steppingThroughHistory = false
    }
}

/// The settings window: a sidebar, one pane at a time, and a toolbar.
///
/// **No bottom bar, deliberately.** It used to carry a status line and the
/// 保存/放弃 pair. The line is gone rather than moved: an outcome is an event, this
/// window is usually shut when one happens, and Notification Center is where the
/// app already reported uploads — two surfaces saying the same thing meant the
/// bottom one was mostly stale. What the line *did* uniquely carry, a failed config
/// read, is now stated in the pane that owns it, next to the buttons that fix it,
/// instead of as one truncated line of `undecodable(status: 10, raw: …)` at the
/// bottom of the window. The buttons moved to the toolbar.
///
/// The cost is stated because it is real: with notification permission denied,
/// outcomes reach only `~/Library/Logs/GitPic.log` — see `AppModel.notify`.
struct SettingsWindowView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var model = AppModel.shared

    private var activeTab: SettingsTab { navigation.selectedTab ?? .host }
    private var refreshing: Bool {
        activeTab == .agent
            ? model.skillTargetsLoading || model.skillInstallID != nil
            : model.busy
    }

    /// **The sidebar does not collapse, and there is no button offering to collapse
    /// it.** Both were here and both are gone; the reasoning is on ``sidebar``.
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 480)
        // A toolbar is what forces NSToolbar to exist, which the liquid-glass
        // title bar treatment depends on. It is also where 保存 lives, now that the
        // window has no bottom bar to put it in.
        .toolbar {
            // Leading, where the platform puts navigation: the sidebar can reach any
            // pane in one click, so these are for retracing — the same role they play
            // in System Settings, and the reason they are `.navigation` rather than
            // two more buttons crowded in beside 保存.
            ToolbarItemGroup(placement: .navigation) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!canStep(-1))
                    .help(canStep(-1) ? "回到\(navigation.history[navigation.historyIndex - 1].title)"
                                      : "没有上一个")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!canStep(1))
                    .help(canStep(1) ? "前往\(navigation.history[navigation.historyIndex + 1].title)"
                                     : "没有下一个")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Progress goes *inside* the refresh button, in place of its glyph.
                //
                // Two earlier arrangements were wrong in opposite ways. A separate
                // spinner item inserted when work started and removed when it stopped
                // made AppKit relayout the toolbar, so 刷新 / 放弃 / 保存 slid sideways
                // and back on every window open. Reserving the space for it instead —
                // a hidden `ProgressView` next to the button — stopped the sliding but
                // left the button and the invisible spinner sharing one glass capsule:
                // a pill twice the width it needed, with the arrow sitting off-centre
                // in it and nothing matching 放弃 / 保存 beside it.
                //
                // Swapping the glyph has neither problem. The button is one control in
                // its own capsule, the same size busy or idle, and the thing that
                // reports the work is the thing the work belongs to. A save is one
                // `gitpic config set` of every dirty key, so "nothing is happening"
                // and "a write is queued" still need telling apart — this says it
                // in the space the button already occupies.
                Button { Task { await reloadActivePane() } } label: {
                    ZStack {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    // One box for both states, so the button is the same width busy or
                    // idle — otherwise the spinner is a hair wider than the glyph and
                    // the sliding toolbar comes back in miniature.
                    .frame(width: 16, height: 16)
                }
                // Not disabled while a read is in flight. `reload()` is idempotent and
                // every invocation goes through `GitpicRunner`'s serial gate, so a
                // second press queues a second read rather than racing the first —
                // and gating it on `busy` meant the button greyed out and came back on
                // every window open, which is a worse trade than an extra read.
                //
                // ⌘R, where reload lives on every other Mac. `⌘S` on 保存 already
                // worked this way: SwiftUI dispatches these inside the window, which
                // is why they were the two keys that *did* respond before the app had
                // a main menu at all — see `MainMenu`.
                .keyboardShortcut("r")
                .help(activeTab == .agent ? "重新检查 Agent（⌘R）" : "重新读取配置与历史（⌘R）")

                if activeTab.savesConfig {
                    // Present on every config pane whether or not anything is dirty,
                    // for the reason the bottom bar had them unconditionally: a
                    // button that only appears once you have changed something cannot
                    // teach you that clicking it is how a change gets written.
                    Button("放弃") { model.revert() }
                        .disabled(model.dirtyKeys.isEmpty || model.busy)
                    Button("保存") { Task { await model.save() } }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                        .disabled(model.dirtyKeys.isEmpty || model.busy)
                        // Which keys, since there is no longer a line of text saying
                        // "N 项未保存".
                        .help(model.dirtyKeys.isEmpty
                              ? "没有改动"
                              : "保存 \(model.dirtyKeys.count) 项："
                                + model.dirtyKeys.map(\.rawValue).joined(separator: ", "))
                }
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in recordVisit() }
    }

    // MARK: - Sidebar

    @ViewBuilder private var sidebar: some View {
        List(selection: $navigation.selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .foregroundStyle(.primary)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("设置")
        // Fixed at 200, and not collapsible at all.
        //
        // **This reverses what `192566c` decided**, so here is why. That commit added
        // the toggle back — `columnVisibility` became a real `@State` binding and this
        // line was deleted — on the grounds that a missing sidebar toggle "did not
        // match the platform", citing Passwords and Mail. But those are content
        // browsers with resizable sidebars, and this window is not modelled on them:
        // it is modelled on System Settings, which is said out loud twice elsewhere in
        // this file — and **System Settings has no sidebar toggle.** Five fixed panes
        // do not need one, and the analogy was to the wrong kind of window.
        //
        // The collapse was also measurably broken, which is what brought this back up.
        // At the window's own minimum width of 680 the sidebar takes 200 and leaves 480
        // for a `Form` whose rows need very nearly that, while 保存 ends 4pt from the
        // window's right edge — measured. Every expansion therefore had a frame or two
        // where the detail content was still laid out at its collapsed width, running
        // off the right edge, and the toolbar could not fit its items and grew an `»`
        // overflow chevron that vanished again. Two symptoms, one cause: nothing had
        // any slack to animate through.
        //
        // A leftover made it worse and is worth recording, since it would bite anyone
        // who tries a toggle again: a `.frame(width: 200)` sat on this content as well
        // as on the column. It was harmless when written — the sidebar could not
        // collapse then — but once it could, every collapse animated a column from
        // 200pt to 0 around content told in absolute points that it may only ever be
        // 200 wide. No width satisfies both, so the transition had nowhere smooth to go.
        // `navigationSplitViewColumnWidth` was always the whole of what was wanted.
        //
        // The cost, stated: the 200pt is permanent, so a small screen cannot reclaim
        // it. That is the same deal System Settings offers.
        .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        Group {
            switch activeTab {
            case .host:    HostPane(model: model)
            case .upload:  UploadPane(model: model)
            case .history: HistoryPane(model: model)
            case .agent:   AgentPane(model: model)
            case .about:   AboutPane(model: model)
            }
        }
        // Title 设置, subtitle the pane — in that order, and not the other way round.
        // A settings window normally lets the title bar be the pane alone (System
        // Settings does), because the app it belongs to is named in the Dock and the
        // menu bar. This app is `.accessory`: no Dock icon, no app menu. A title bar
        // reading only 「图床」 leaves nothing on screen that says which window this is
        // or that it is where settings are edited.
        .navigationTitle("设置")
        .navigationSubtitle(activeTab.title)
        // Top-left, explicitly. A pane whose content is shorter than the window gets
        // centred by the detail column otherwise — which is exactly how the history
        // pane's format switcher ended up floating halfway down the window. Fixing it
        // per-pane leaves the next pane to rediscover it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Navigation history

    private func canStep(_ delta: Int) -> Bool {
        navigation.history.indices.contains(navigation.historyIndex + delta)
    }

    private func reloadActivePane() async {
        if activeTab == .agent {
            await model.loadSkillTargets()
        } else {
            await model.reload()
        }
    }

    private func step(_ delta: Int) {
        let target = navigation.historyIndex + delta
        guard navigation.history.indices.contains(target) else { return }
        navigation.steppingThroughHistory = true
        navigation.historyIndex = target
        navigation.selectedTab = navigation.history[target]
        // Cleared in a later turn than the `onChange` this assignment triggers, which
        // is the whole point: clearing it here would let `recordVisit` see `false`
        // and append the pane we just stepped to.
        Task { @MainActor in navigation.steppingThroughHistory = false }
    }

    private func recordVisit() {
        guard !navigation.steppingThroughHistory,
              let tab = navigation.selectedTab else { return }
        guard navigation.history[navigation.historyIndex] != tab else { return }
        // Anything ahead of here was reached by going back; a new choice replaces that
        // future rather than being spliced into it.
        navigation.history = Array(navigation.history.prefix(navigation.historyIndex + 1))
        navigation.history.append(tab)
        navigation.historyIndex = navigation.history.count - 1
    }
}

extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
