import SwiftUI
import GitPicCore

/// What a new release says, and the two ways to act on it.
///
/// A sheet rather than a pane, because it is about one moment: a version was found, here is
/// what is in it, do you want it. Raised by a *manual* check, and by 「查看更新内容」 for one
/// the daily check found — never by the daily check itself, which reports through
/// Notification Center instead of interrupting whatever the window was being used for.
struct UpdateSheet: View {
    @Bindable var model: AppModel
    let report: UpdateReport

    @State private var confirmingUpgrade = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notes
            Divider()
            actions
        }
        .frame(width: 480, height: 420)
        // Asked when the sheet appears rather than at launch: it spawns `brew list`, which
        // is up to 20 s of somebody else's process, and nothing before this moment needs
        // the answer.
        .task { await model.resolveUpgradePath() }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GitPic \(report.latest) 可以更新了")
                .font(.title3.weight(.semibold))
            Text("当前版本 \(report.current)")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// The release notes, scrollable and selectable.
    ///
    /// `report.summary` rather than `report.notes`: the Release body repeats its own title
    /// as a leading heading and ends with `## `-level install instructions for someone who
    /// downloaded the DMG, and this reader is neither — see ``UpdateReport/summary``.
    ///
    /// Rendered through `AttributedString` with `.inlineOnlyPreservingWhitespace`, which
    /// keeps line breaks and `- ` bullets as written while resolving inline syntax. See
    /// ``UpdateReport/displayMarkdown(_:)`` for why the headings are rewritten before they
    /// get here, and why the full parser is not an option.
    @ViewBuilder private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let name = report.name {
                    Text(name).font(.headline)
                }
                let body = report.summary
                if body.isEmpty {
                    Text("这个版本没有附更新说明。")
                        .foregroundStyle(.secondary)
                } else {
                    Text(markdown(UpdateReport.displayMarkdown(body)))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.updateFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                switch model.upgradePath {
                case .ready:
                    Button("立即更新") { confirmingUpgrade = true }
                        .buttonStyle(.borderedProminent)
                case .unavailable, .none:
                    // No 立即更新 at all rather than a disabled one. `brew upgrade --cask`
                    // cannot work here — this app was not installed by Homebrew, or brew
                    // is not on the machine — and a greyed-out button with a tooltip is a
                    // worse answer than the one route that does work.
                    EmptyView()
                }
                Button("打开发布页") {
                    if let url = URL(string: report.url) { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("稍后") { model.updateSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            if model.upgradePath == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在确认升级方式…").font(.caption).foregroundStyle(.secondary)
                }
            } else if case .unavailable = model.upgradePath {
                // Says why the one-click path is missing, and what to do instead. The
                // command is the same one the button would have run.
                Text("这份 GitPic 不是用 Homebrew 装的，或者机器上没有 brew，所以不能在这里直接升级。"
                     + "可以到发布页下载，或在终端运行 `brew upgrade --cask gitpic`。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .alert("升级前需要退出 GitPic", isPresented: $confirmingUpgrade) {
            Button("退出并升级") { model.performUpgrade() }
            Button("取消", role: .cancel) {}
        } message: {
            // Says exactly what is about to happen, because all of it is visible and some
            // of it is alarming: the window closes, the menu-bar icon disappears for the
            // length of a download, and the app comes back on its own.
            Text("Homebrew 不能替换正在运行的 App，所以 GitPic 会先退出，"
                 + "升级完成后自动重新打开。这期间菜单栏图标会消失。\n\n"
                 + "升级过程记录在 GitPic-update.log 里；万一失败，原来的版本仍然可用。")
        }
    }
}
