import SwiftUI
import GitPicCore

/// 设置 ▸ 通用: the two switches that write system state the moment they move.
///
/// **This pane is defined by *how* its rows behave, not by what they are about**, which
/// is the one grouping in this window that earns an exception. Every row on 图床 and
/// 上传 edits a draft of the config file and waits for the toolbar's 保存; these two
/// write to macOS immediately and have no config key behind them at all. Mixing the two
/// kinds in one pane means a switch that has already taken effect sits beside fields
/// that have not, under one 保存 button that applies to only half of them.
///
/// The Finder right-click switch moved here from 上传, and it is worth saying what that
/// fixed. It had lived at the bottom of that pane, outside its `ConfigGate`, under a
/// comment explaining that it deliberately did not behave like any of its neighbours —
/// an inconsistency documented rather than resolved. It also inherited a real property
/// from being outside the gate: it stays usable when the config cannot be read, which is
/// exactly when someone might want to switch the right-click entry off. On this pane
/// that is no longer a special case to arrange, because there is no gate here to be
/// outside of.
///
/// The cost, stated: anyone who knew the Finder switch as "the last row of 上传" has to
/// find it again. That is a real one-time cost, accepted because the alternative was
/// either leaving it where its own comment argued it did not fit, or a 通用 pane holding
/// a single switch above two-thirds of an empty window.
struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("启动") {
                // Reads from the state rather than from a stored `Bool`, so 开/关 is
                // always what macOS currently reports — including the case where the
                // registration exists and is being withheld, which reads as 开 for the
                // reason `LaunchAtLoginState.isOn` gives.
                CaptionedToggle(
                    label: "开机自启动",
                    caption: model.launchAtLogin.caption,
                    isOn: Binding(get: { model.launchAtLogin.isOn },
                                  set: { model.setLaunchAtLogin($0) }))

                // Only where System Settings is where the answer changes — on a plain
                // 开 or 关 the switch above already is the control.
                if model.launchAtLogin.needsSystemSettings {
                    Button("打开「登录项与扩展」") { LaunchAtLogin.openSystemSettings() }
                        .controlSize(.small)
                }

                if let failure = model.launchAtLoginFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("更新") {
                // The label is short; the caption carries the two facts it dropped — that
                // this checks rather than installs, and that it does so daily. Nothing here
                // ever replaces the app on its own: a found update is reported, and the
                // sheet's button is the only thing that downloads, verifies and installs it.
                CaptionedToggle(
                    label: "自动更新",
                    caption: "每天检查一次，发现新版本会告诉你，不会自动装。"
                        + "只读取 GitHub 上的发布信息，不会上传任何内容。",
                    isOn: Binding(get: { model.autoCheckUpdates },
                                  set: { model.autoCheckUpdates = $0 }))

                LabeledContent("状态") {
                    if model.updateChecking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在检查…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }

                if let failure = model.updateFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("检查更新") {
                        Task { await model.checkForUpdates(manual: true) }
                    }
                    .disabled(model.updateChecking || model.toolState != .ready)
                    // Present only while an update actually stands. This is the route to
                    // the notes for one the *daily* check found: that check reports through
                    // Notification Center rather than raising a sheet over whatever the
                    // window was being used for, so without this button the banner would be
                    // the only mention of it.
                    if model.update?.updateAvailable == true {
                        Button("查看更新内容") { model.presentUpdateSheet() }
                    }
                }
                .controlSize(.small)
            }

            Section("系统集成") {
                // The menu title comes from the running bundle's `NSServices` entry, not
                // from a constant here — `pbs` keys the on/off state by that title, so
                // the label and the thing it switches cannot drift apart. See
                // `FinderService.menuItemTitle`.
                CaptionedToggle(
                    label: "在右键菜单里显示「\(FinderService.menuItemTitle)」",
                    isOn: Binding(get: { model.finderServiceEnabled },
                                  set: { model.setFinderServiceEnabled($0) }))
            }


            CommandLineSection(
                status: model.commandLineStatus,
                reach: model.commandLineReach,
                probing: model.commandLineProbing,
                completionsInstalled: model.completionsInstalled,
                working: model.commandLineWorking,
                installDisabled: model.toolState != .ready,
                failure: model.commandLineFailure,
                onInstall: { replacing in
                    Task { await model.installCommandLineTool(replacing: replacing) }
                },
                onRemove: {
                    Task { await model.removeCommandLineTool() }
                },
                onCopySetup: model.copyCommandLineSetup,
                onCopyPath: model.copyCommandLinePath,
                shellConfiguration: model.shellConfiguration,
                onConfigureShell: { shell in Task { await model.configureShell(shell) } },
                onUnconfigureShell: { shell in Task { await model.unconfigureShell(shell) } })
        }
        .formChrome()
        // Both switches mirror state that 系统设置 can change, so both are re-read
        // whenever this pane comes back rather than trusted from the last time it was
        // shown. Not sufficient on its own: `orderOut` emits no `onDisappear`, so
        // reopening the window does not re-fire this — `SettingsWindowController.showWindow`
        // covers that case.
        .onAppear {
            model.refreshLaunchAtLogin()
            model.refreshFinderService()
        }
        // Only when one is due. `.task` rather than `.onAppear` so it can await, and
        // due-ness rather than every appearance so switching panes back and forth is not a
        // request per visit — see `UpdateSchedule`. Like `.onAppear` above it fires once per
        // mount and not on reopen, which is why `showWindow` calls this too.
        .task { await model.checkForUpdatesIfDue() }
        .task { await model.refreshCommandLine() }
    }

    /// One line for "where does the update situation stand".
    ///
    /// Four states, and the third is the one worth having: a build *newer* than the latest
    /// release. Every unreleased build of this repository is in it, and calling that
    /// 「已是最新」 would be technically defensible and actively confusing.
    ///
    /// `model.update` is not persisted across launches while `lastUpdateCheck` is, so after
    /// a relaunch this says when the last check happened without claiming a verdict it no
    /// longer holds. Storing the verdict too would let it show 「已是最新」 for a release
    /// that came out overnight, which is the one thing this line must not do.
    private var statusText: String {
        if let update = model.update {
            if update.updateAvailable { return "有新版本 \(update.latest)" }
            if update.ahead {
                return "当前 \(update.current) 比最新发布 \(update.latest) 更新（未发布版本）"
            }
            return "已是最新 \(update.current)"
        }
        if let last = model.lastUpdateCheck {
            // 「成功」 is load-bearing, not padding. `lastUpdateCheck` is stamped only on a
            // check that completed — see `AppModel`, where that is deliberate so a week
            // offline does not count as a week of checking — so after a failed check this
            // line and the failure row below it describe two different moments. Labelled
            // 「上次检查」 they read as one, and a stale 「RATE_LIMITED」 next to a two-day-old
            // timestamp says "it was rate-limited two days ago" when the truth is "it
            // succeeded two days ago and failed at some later time this line cannot name".
            return "上次成功检查 \(Self.stamp.string(from: last))"
        }
        return "还没检查过"
    }

    /// "今天 10:42" — relative day plus a short time.
    ///
    /// `static`, because a `DateFormatter` built in a view body is rebuilt on every redraw
    /// and it is one of the more expensive objects in Foundation to construct.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
