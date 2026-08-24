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
                    label: "开机时自动启动 GitPic",
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
    }
}
